#!/usr/bin/env python3
"""Real libtorrent transfers, private D-Bus/state and loopback-only networking."""
import hashlib
import http.server
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
import libtorrent as lt

ROOT = Path(__file__).resolve().parents[1]

def wait(predicate, label, timeout=25):
    until = time.monotonic() + timeout
    while time.monotonic() < until:
        result = predicate()
        if result:
            return result
        time.sleep(.05)
    raise AssertionError(label)

class Client:
    def __init__(self, runtime):
        self.socket = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
        self.socket.connect(str(runtime / 'files-transfers.sock'))
        self.socket.settimeout(.2)
        self.rows = []
        self.error = ''
        self.replies = {}
    def send(self, **args):
        self.socket.send(json.dumps(args).encode())
    def read(self):
        try:
            data = self.socket.recv(192 * 1024)
        except socket.timeout:
            return self.rows
        assert data, 'helper disconnected'
        value = json.loads(data)
        if 'error' in value:
            self.error = value['error']
        elif 'transfers' in value:
            self.rows = value['transfers']
        else:
            self.replies.update(value)
        return self.rows
    def reply(self, kind, timeout=10):
        self.replies.pop(kind, None)
        return wait(lambda: self.read() is not None and self.replies.get(kind), f'{kind} reply', timeout)
    def until(self, predicate, label, timeout=25):
        return wait(lambda: predicate(self.read()), label, timeout)
    def close(self):
        self.socket.close()

def run():
    with tempfile.TemporaryDirectory(prefix='rediwm-torrents-') as temporary:
        tmp = Path(temporary)
        runtime = tmp / 'runtime'; runtime.mkdir(mode=0o700)
        seed_dir = tmp / 'seed'; seed_dir.mkdir()
        dest = tmp / 'downloads'; dest.mkdir()
        payload = os.urandom(512 * 1024)
        (seed_dir / 'bundle').mkdir()
        (seed_dir / 'bundle' / 'wanted.bin').write_bytes(payload)
        extra = os.urandom(512 * 1024)
        (seed_dir / 'bundle' / 'skip.bin').write_bytes(extra)
        seed = lt.session({'listen_interfaces': '127.0.0.1:0', 'enable_dht': False,
                           'enable_lsd': False, 'enable_upnp': False, 'enable_natpmp': False,
                           'enable_outgoing_utp': False, 'enable_incoming_utp': False,
                           'upload_rate_limit': 65536, 'alert_mask': 0x7fffffff, 'allow_multiple_connections_per_ip': True})
        class Tracker(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                port = int(urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query).get('port', ['0'])[0])
                if port and port != seed.listen_port():
                    seeding.connect_peer(('127.0.0.1', port))
                peers = b'' if port == seed.listen_port() else socket.inet_aton('127.0.0.1') + struct.pack('!H', seed.listen_port())
                reply = lt.bencode({'interval': 1, 'peers': peers})
                try:
                    self.send_response(200); self.end_headers(); self.wfile.write(reply)
                except (BrokenPipeError, ConnectionResetError): pass
            def log_message(self, *_): pass
        tracker = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Tracker)
        threading.Thread(target=tracker.serve_forever, daemon=True).start()
        files = lt.file_storage()
        files.add_file('bundle/wanted.bin', len(payload))
        files.add_file('bundle/skip.bin', len(payload))
        torrent = lt.create_torrent(files, 16384)
        torrent.add_tracker(f'http://127.0.0.1:{tracker.server_port}/announce')
        lt.set_piece_hashes(torrent, str(seed_dir))
        torrent_path = tmp / 'bundle.torrent'
        torrent_path.write_bytes(lt.bencode(torrent.generate()))
        seeding = seed.add_torrent({'ti': lt.torrent_info(str(torrent_path)), 'save_path': str(seed_dir)})
        wait(lambda: seeding.status().is_seeding, 'seed ready')
        shim = tmp / 'network.so'
        subprocess.run(['cc', '-shared', '-fPIC', str(ROOT / 'tests/torrent_network.c'), '-o', str(shim), '-ldl'], check=True)
        env = dict(os.environ, XDG_RUNTIME_DIR=str(runtime), XDG_STATE_HOME=str(tmp/'state'),
                   XDG_DATA_HOME=str(tmp/'data'), HOME=str(tmp), LD_PRELOAD=str(shim))
        env['REDIWM_TORRENT_TEST_DELETE'] = '1'
        binary = Path(os.environ.get('REDIWM_TEST_BIN_DIR', ROOT/'zig-out/bin'))/'rediwm-transfers'
        log = open(tmp/'helper.log', 'w+')
        helper = None
        def launch():
            process = subprocess.Popen([str(binary)], env=env, stdout=log, stderr=log)
            def ready():
                if process.poll() is not None: return True
                try:
                    probe=Client(runtime); probe.close(); return True
                except (OSError,ConnectionError): return False
            wait(ready, 'helper startup')
            assert process.poll() is None, 'helper exited'
            return process
        try:
            helper = launch(); client = Client(runtime)
            # Looking into a torrent file adds nothing.
            client.send(op='inspect', source=str(torrent_path))
            inspected = client.reply('inspect')
            assert sorted(f['path'] for f in inspected['files']) == ['bundle/skip.bin', 'bundle/wanted.bin'], inspected
            assert inspected['name'] == 'bundle' and inspected['source'] == str(torrent_path)
            time.sleep(.3); assert not client.read(), 'inspect added a transfer'
            client.send(op='add', source=str(torrent_path), destination=str(dest))
            rows = client.until(lambda r: r if r else None, 'metadata')
            row = rows[0]; tid = row['id']
            assert row['pending'] and row['metadata'] and row['paused'], row
            assert row['source'] == str(torrent_path) and row['download_directory'] == str(dest)
            assert all(isinstance(row[k], int) and row[k] >= 0 for k in ('peers', 'known_peers', 'seeds'))
            wanted = next(f['index'] for f in row['files'] if f['path'].endswith('wanted.bin'))
            skipped = next(f['path'] for f in row['files'] if f['path'].endswith('skip.bin'))
            client.send(op='add', source=str(torrent_path), destination=str(dest))
            client.until(lambda _: 'already' in client.error, 'duplicate rejected')
            client.send(op='start', id=tid, files=[wanted], ratio=1, limit=131072)
            client.until(lambda r: r and not r[0]['pending'] and not r[0]['paused'], 'download starts')
            client.close()  # Files exit must not own the session's lifetime.
            time.sleep(2)
            assert helper.poll() is None, 'closing Files stopped the torrent'
            # Recovery of an active transfer after abrupt process death.
            resume = tmp/'state/rediwm/transfers'/f'{tid}.resume'
            def saved_selection():
                if not resume.exists(): return False
                params = lt.read_resume_data(resume.read_bytes())
                return not (params.flags & lt.torrent_flags.paused) and params.file_priorities[wanted] > 0 and sum(p > 0 for p in params.file_priorities) == 1
            wait(saved_selection, 'running selected-file checkpoint')
            helper.kill(); helper.wait(timeout=5)
            helper = launch()
            client = Client(runtime)
            rows = client.until(lambda r: r if r and r[0]['published'] else None, 'selected download finishes', 50)
            completed = rows[0]
            assert (Path(completed['destination'])/'bundle/wanted.bin').read_bytes() == payload
            assert not (Path(completed['destination'])/skipped).exists(), 'unselected file downloaded'
            assert not completed['paused'], 'seeding should continue'
            client.send(op='files', id=tid)
            files = {f['path']: f for f in client.reply('detail')['files']}
            assert files['bundle/wanted.bin']['wanted'] and files['bundle/wanted.bin']['done'] == len(payload), files
            assert not files[skipped]['wanted'], files
            client.send(op='select', id=tid, files=[])
            client.until(lambda _: 'Keep at least one' in client.error, 'empty selection rejected')
            # Ticking another file of a finished download fetches it into place.
            extra_index = next(f['index'] for f in files.values() if f['path'] == skipped)
            client.send(op='select', id=tid, files=[wanted, extra_index])
            target = Path(completed['destination'])/skipped
            wait(lambda: target.exists() and target.read_bytes() == extra, 'newly ticked file downloads', 50)
            client.send(op='files', id=tid)
            files = {f['path']: f for f in client.reply('detail')['files']}
            assert files[skipped]['wanted'] and files[skipped]['done'] == len(extra), files
            client.send(op='list')
            client.send(op='pause', id=tid)
            client.close()  # A queued command must survive an immediate window close.
            client = Client(runtime)
            client.until(lambda r: r and r[0]['paused'], 'pause before disconnect')
            # Once saves and the final active timer drain, every surviving
            # helper thread sleeps; a visible idle Files window needs no ticks.
            time.sleep(2.5)
            def switches():
                result={}
                for task in Path(f'/proc/{helper.pid}/task').iterdir():
                    try:
                        values=[int(line.split(':')[1]) for line in (task/'status').read_text().splitlines() if line.startswith(('voluntary_ctxt_switches:', 'nonvoluntary_ctxt_switches:'))]
                        result[task.name]=sum(values)
                    except FileNotFoundError: pass
                return result
            before=switches(); time.sleep(1.2); after=switches()
            deltas={tid:after[tid]-count for tid,count in before.items() if tid in after}
            assert all(delta==0 for delta in deltas.values()), f'idle thread wakeups: {deltas}'
            print(f'PASS: idle per-thread context-switch deltas {deltas}')
            client.close()
            helper.wait(timeout=12)
            helper = launch(); client = Client(runtime)
            rows = client.until(lambda r: r if r else None, 'saved session restored')
            assert rows[0]['paused'] and rows[0]['published'] and not rows[0]['pending'], rows
            client.send(op='resume', id=tid)
            client.until(lambda r: r and not r[0]['paused'], 'resume')
            client.send(op='stop_seeding')
            client.until(lambda r: r and r[0]['paused'], 'stop seeding')
            client.send(op='remove', id=tid)
            client.until(lambda r: not r, 'remove transfer')
            assert (Path(completed['destination'])/'bundle/wanted.bin').read_bytes() == payload, 'remove deleted data'
            # Existing publication folder is never replaced.
            client.send(op='add', source=str(torrent_path), destination=str(dest))
            rows = client.until(lambda r: r if r else None, 're-add')
            storage = Path(rows[0]['storage']); (storage/'bundle').mkdir(exist_ok=True)
            (storage/'bundle/wanted.bin').write_bytes(payload)
            client.send(op='start', id=tid, files=[wanted], ratio=0, limit=131072)
            rows = client.until(lambda r: r if r and 'Destination' in r[0]['error'] else None, 'collision rejected', 50)
            assert (Path(completed['destination'])/'bundle/wanted.bin').read_bytes() == payload
            assert rows[0]['paused']
            client.send(op='remove', id=tid)
            client.until(lambda r: not r, 'remove second transfer')
            magnet_dest=tmp/'magnet'; magnet_dest.mkdir()
            client.send(op='add',source=lt.make_magnet_uri(lt.torrent_info(str(torrent_path))),destination=str(magnet_dest))
            rows=client.until(lambda r:r if r and r[0]['metadata'] else None,'magnet metadata',30)
            assert rows[0]['pending'] and rows[0]['done']==0, rows
            client.send(op='remove',id=rows[0]['id']); client.until(lambda r:not r,'remove magnet')
            # Added again, it takes up its partial-download folder.
            client.error = ''
            client.send(op='add',source=lt.make_magnet_uri(lt.torrent_info(str(torrent_path))),destination=str(magnet_dest))
            rows=client.until(lambda r:r if r else None,'magnet added again',30)
            assert not client.error, client.error
            client.send(op='remove',id=rows[0]['id']); client.until(lambda r:not r,'remove magnet again')

            # Deleting an actively downloading torrent must stop writes,
            # preserve the partial payload and retain verified progress.
            active_dest = tmp/'delete-active'
            active_dest.mkdir()
            client.send(op='add', source=str(torrent_path),
                        destination=str(active_dest))
            rows = client.until(lambda r: r if r else None,
                                'active deletion fixture')
            active_id = rows[0]['id']
            active_storage = Path(rows[0]['storage'])
            client.send(op='start', id=active_id, files=[wanted],
                        ratio=1, limit=131072)
            rows = client.until(
                lambda r: r if r and not r[0]['paused'] and
                0 < r[0]['done'] < r[0]['total'] else None,
                'partial active download', 50)
            assert rows[0]['deletion_phase'] == 'none', rows
            client.error = ''
            client.send(op='probe_delete', id=active_id)
            rows = client.until(
                lambda r: r if r and r[0]['deletion_phase'] in
                ('ready', 'failed') else None,
                'active deletion disk barrier', 25)
            assert rows[0]['deletion_phase'] == 'ready', rows
            assert rows[0]['paused'], rows
            client.send(op='files', id=active_id)
            detail = client.reply('detail')
            progress = {f['path']: f['done'] for f in detail['files']}
            assert 0 < progress['bundle/wanted.bin'] < len(payload), detail
            before = {
                p.relative_to(active_storage): p.read_bytes()
                for p in active_storage.rglob('*') if p.is_file()
            }
            assert before, 'active download produced no payload'
            time.sleep(1)
            after = {
                p.relative_to(active_storage): p.read_bytes()
                for p in active_storage.rglob('*') if p.is_file()
            }
            assert before == after, 'payload changed after disk barrier'
            assert torrent_path.exists()
            assert not client.error, client.error
            print('PASS: active download deletion stops writes and preserves progress')

            # Restart clears the test fixture from libtorrent but must not
            # resurrect it. Remove its state files only after checking this.
            client.close()
            helper.kill(); helper.wait(timeout=5)
            helper = launch(); client = Client(runtime)
            rows = client.until(lambda r: r if r else None,
                                'active deletion recovery')
            assert rows[0]['id'] == active_id
            assert rows[0]['deletion_phase'] == 'failed', rows
            assert rows[0]['paused'], rows
            assert active_storage.exists(), 'recovery removed partial data'
            client.close()
            helper.kill(); helper.wait(timeout=5)
            state = tmp/'state/rediwm/transfers'
            (state/f'{active_id}.ini').unlink()
            (state/f'{active_id}.resume').unlink(missing_ok=True)
            helper = launch(); client = Client(runtime)
            assert not client.until(lambda r: r if r else True,
                                    'active fixture cleared'), 'unexpected transfer'

            # A user-paused torrent takes the flush path directly.
            paused_dest = tmp/'delete-paused'
            paused_dest.mkdir()
            client.send(op='add', source=str(torrent_path),
                        destination=str(paused_dest))
            rows = client.until(lambda r: r if r else None,
                                'paused deletion fixture')
            paused_id = rows[0]['id']
            paused_storage = Path(rows[0]['storage'])
            client.send(op='start', id=paused_id, files=[wanted],
                        ratio=1, limit=131072)
            client.until(lambda r: r if r and not r[0]['paused'] and
                         r[0]['done'] > 0 else None,
                         'paused fixture starts downloading', 50)
            client.send(op='pause', id=paused_id)
            client.until(lambda r: r if r and r[0]['paused'] else None,
                         'paused fixture stops')
            client.error = ''
            client.send(op='probe_delete', id=paused_id)
            rows = client.until(
                lambda r: r if r and r[0]['deletion_phase'] in
                ('ready', 'failed') else None,
                'paused deletion disk barrier')
            assert rows[0]['deletion_phase'] == 'ready', rows
            assert rows[0]['paused'], rows
            assert paused_storage.exists()
            assert torrent_path.exists()
            assert not client.error, client.error
            print('PASS: paused download deletion reaches disk barrier')

            client.close()
            helper.kill(); helper.wait(timeout=5)
            (state/f'{paused_id}.ini').unlink()
            (state/f'{paused_id}.resume').unlink(missing_ok=True)
            helper = launch(); client = Client(runtime)

            # Exercise deletion without removing any payload.
            probe_dest = tmp/'delete-probe'
            probe_dest.mkdir()
            client.send(op='add', source=str(torrent_path),
                        destination=str(probe_dest))
            rows = client.until(lambda r: r if r else None,
                                'pending deletion fixture')
            probe = rows[0]
            assert probe['pending'] and probe['paused'], probe
            probe_id = probe['id']
            probe_storage = Path(probe['storage'])
            marker = probe_storage/'preserve-me'
            marker.write_bytes(b'untouched')
            client.error = ''
            client.send(op='probe_delete', id=probe_id)
            rows = client.until(
                lambda r: r if r and r[0]['deletion_phase'] in
                ('ready', 'failed') else None,
                'pending deletion disk barrier')
            assert rows[0]['deletion_phase'] == 'ready', rows
            assert rows[0]['paused'], rows
            assert marker.read_bytes() == b'untouched'
            assert torrent_path.exists()
            assert not client.error, client.error
            print('PASS: pending torrent deletion disk barrier')

            # A durable deletion intent must prevent automatic restart.
            client.close()
            helper.kill()
            helper.wait(timeout=5)
            helper = launch()
            client = Client(runtime)
            rows = client.until(lambda r: r if r else None,
                                'interrupted deletion restored')
            assert rows[0]['id'] == probe_id, rows
            assert rows[0]['deletion_phase'] == 'failed', rows
            assert rows[0]['paused'], rows
            assert 'interrupted' in rows[0]['error'], rows
            client.send(op='resume', id=probe_id)
            client.until(lambda _: 'deletion' in client.error,
                         'interrupted deletion cannot resume')
            assert marker.read_bytes() == b'untouched'
            assert torrent_path.exists()
            print('PASS: interrupted deletion cannot restart')

            client.close()
            helper.wait(timeout=12)
            print('PASS: inspection, file selection and reselection, real transfer, background lifetime, crash recovery, magnet metadata, seeding, persistence, pause/resume, removal and no-clobber publication')
        except Exception:
            log.flush(); log.seek(0); print(log.read(), file=sys.stderr)
            print('\n'.join(a.message() for a in seed.pop_alerts() if 'peer' in a.what()), file=sys.stderr)
            raise
        finally:
            if helper and helper.poll() is None:
                helper.terminate()
                try: helper.wait(timeout=8)
                except subprocess.TimeoutExpired: helper.kill(); helper.wait()
            tracker.shutdown(); log.close()

if __name__ == '__main__':
    if '--private-bus' not in sys.argv:
        raise SystemExit(subprocess.call(['dbus-run-session', '--', sys.executable, __file__, '--private-bus']))
    run()

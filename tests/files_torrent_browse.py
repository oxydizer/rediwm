#!/usr/bin/env python3
"""A torrent file opens as a folder: its files are ghosts with checkboxes,
ticking downloads, a folder's tick takes everything in it, and a finished
file is a real one. Real libtorrent over loopback only (see
files_torrents.py); the shell is headless. Needs the libtorrent module:

    /usr/bin/python3.12 tests/files_torrent_browse.py

REDIWM_TORRENT_SHOTS=<directory> keeps review pictures.
"""
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

from files_browser import wait_for
from ipc_client import IPCClient, spawn_compositor, stop_process

ROOT = Path(__file__).resolve().parents[1]
ENTER, SPACE, HOME, RIGHT, BACKSPACE, ALT, LEFT = 28, 57, 102, 106, 14, 56, 105


class Helper:
    """An observer of the transfer helper, like a second Files window."""

    def __init__(self, runtime):
        self.socket = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
        self.socket.connect(str(runtime / 'files-transfers.sock'))
        self.socket.settimeout(.2)
        self.rows = []

    def read(self):
        try:
            while True:
                value = json.loads(self.socket.recv(192 * 1024))
                if 'transfers' in value:
                    self.rows = value['transfers']
        except socket.timeout:
            return self.rows


def run():
    with tempfile.TemporaryDirectory(prefix='rediwm-torrent-browse-') as directory:
        tmp = Path(directory)
        home = tmp / 'home'
        downloads = home / 'Downloads'
        seed_dir = tmp / 'seed'
        for d in (downloads, seed_dir / 'bundle' / 'sub', tmp / 'state'):
            d.mkdir(parents=True)
        payload = {name: os.urandom(256 * 1024) for name in ('a.bin', 'sub/b.bin', 'sub/c.bin')}
        for name, data in payload.items():
            (seed_dir / 'bundle' / name).write_bytes(data)

        seed = lt.session({'listen_interfaces': '127.0.0.1:0', 'enable_dht': False,
                           'enable_lsd': False, 'enable_upnp': False, 'enable_natpmp': False,
                           'enable_outgoing_utp': False, 'enable_incoming_utp': False,
                           'allow_multiple_connections_per_ip': True})

        class Tracker(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                port = int(urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query).get('port', ['0'])[0])
                if port and port != seed.listen_port():
                    seeding.connect_peer(('127.0.0.1', port))
                peers = b'' if port == seed.listen_port() else socket.inet_aton('127.0.0.1') + struct.pack('!H', seed.listen_port())
                try:
                    self.send_response(200)
                    self.end_headers()
                    self.wfile.write(lt.bencode({'interval': 1, 'peers': peers}))
                except (BrokenPipeError, ConnectionResetError):
                    pass

            def log_message(self, *_):
                pass

        tracker = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Tracker)
        threading.Thread(target=tracker.serve_forever, daemon=True).start()
        storage = lt.file_storage()
        for name, data in payload.items():
            storage.add_file('bundle/' + name, len(data))
        torrent = lt.create_torrent(storage, 16384)
        torrent.add_tracker(f'http://127.0.0.1:{tracker.server_port}/announce')
        lt.set_piece_hashes(torrent, str(seed_dir))
        torrent_path = downloads / 'bundle.torrent'
        torrent_path.write_bytes(lt.bencode(torrent.generate()))
        seeding = seed.add_torrent({'ti': lt.torrent_info(str(torrent_path)), 'save_path': str(seed_dir)})
        wait_for(lambda: seeding.status().is_seeding, 'seed ready')

        shim = tmp / 'network.so'
        subprocess.run(['cc', '-shared', '-fPIC', str(ROOT / 'tests/torrent_network.c'), '-o', str(shim), '-ldl'], check=True)
        comp, comp_log = spawn_compositor(
            tmp, config_content='[compositor]\nxwayland = false\n',
            renderer=os.environ.get('REDIWM_TEST_RENDERER', 'gles2'), env_extra={'HOME': str(home)})
        processes = []
        try:
            with IPCClient(tmp, timeout=15) as ipc:
                display = next(p.name for p in tmp.glob('wayland-*') if not p.name.endswith('.lock'))
                env = dict(os.environ, HOME=str(home), XDG_RUNTIME_DIR=str(tmp), XDG_DATA_HOME=str(tmp / 'data'),
                           XDG_STATE_HOME=str(tmp / 'state'), XDG_CONFIG_HOME=str(tmp / 'config'),
                           REDIWM_CONFIG=str(tmp / 'rediwm-config.toml'), WAYLAND_DISPLAY=display,
                           DBUS_SESSION_BUS_ADDRESS='unix:path=/nonexistent', REDIWM_FILES_DEVICES='0')
                for name in ('DISPLAY', 'REDIWM_SOCKET', 'WAYLAND_DEBUG'):
                    env.pop(name, None)
                bin_dir = Path(os.environ.get('REDIWM_TEST_BIN_DIR', ROOT / 'zig-out/bin'))
                # The helper first, behind the loopback-only shim; Files connects to it.
                helper_log = (tmp / 'helper.log').open('w')
                processes.append(subprocess.Popen([str(bin_dir / 'rediwm-transfers'), '--no-scope'],
                                                  env=dict(env, LD_PRELOAD=str(shim)), stdout=helper_log, stderr=helper_log))
                wait_for(lambda: (tmp / 'files-transfers.sock').exists(), 'helper did not start')
                observer = Helper(tmp)
                files_log = (tmp / 'files.log').open('w')
                processes.append(subprocess.Popen([str(bin_dir / 'rediwm-files'), str(downloads)],
                                                  env=env, stdout=files_log, stderr=files_log))

                def windows():
                    return [w for w in ipc.get_windows() if w['app_id'] == 'rediwm-files']

                win = wait_for(lambda: next(iter(windows()), None), 'Files did not map')
                ipc.focus_window(win['id'])

                def key(code, *mods):
                    for mod in mods:
                        ipc.key(mod, True)
                    ipc.key_down_up(code)
                    for mod in reversed(mods):
                        ipc.key(mod, False)
                    time.sleep(.2)

                def title(value):
                    wait_for(lambda: windows() and windows()[0]['title'] == value + ' — RediWM Files',
                             'Files did not reach ' + value + ': ' + str(windows() and windows()[0]['title']))

                def shot(name):
                    if os.environ.get('REDIWM_TORRENT_SHOTS'):
                        time.sleep(.5)
                        ipc.screenshot(str(Path(os.environ['REDIWM_TORRENT_SHOTS']) / (name + '.png')), window_id=win['id'])

                def transfer():
                    rows = observer.read()
                    return rows[0] if rows else None

                title('Downloads')
                time.sleep(.6)
                # Entering the torrent file looks into it; nothing is added.
                key(HOME)
                key(ENTER)
                title('bundle.torrent')
                time.sleep(1)
                shot('1-entered')
                assert transfer() is None, 'looking into a torrent added it'

                # Folders first: sub, then a.bin. Space on the folder ticks both its files.
                key(HOME)
                key(SPACE)
                row = wait_for(lambda: (lambda t: t if t and not t['pending'] else None)(transfer()), 'ticking did not start a download', 20)
                assert row['download_directory'] == str(downloads) and row['source'] == str(torrent_path), row
                shot('2-folder-ticked')
                published = wait_for(lambda: (lambda t: Path(t['destination']) if t and t['published'] else None)(transfer()),
                                     'the ticked folder did not download', 60)
                for name in ('sub/b.bin', 'sub/c.bin'):
                    assert (published / 'bundle' / name).read_bytes() == payload[name], name
                time.sleep(1.5)
                shot('3-folder-finished')

                # Into the torrent's folder, and back out.
                key(HOME)
                key(ENTER)
                title('sub')
                shot('4-inside-folder')
                key(LEFT, ALT)
                title('bundle.torrent')

                # Ticking a.bin later fetches it into the same place.
                key(HOME)
                key(RIGHT)
                key(SPACE)
                wait_for(lambda: (published / 'bundle/a.bin').exists() and
                         (published / 'bundle/a.bin').read_bytes() == payload['a.bin'], 'ticking a file did not download it', 60)
                time.sleep(1.5)
                shot('5-all-finished')
                # The download sits in its folder as a ghost of what it brings.
                key(LEFT, ALT)
                title('Downloads')
                shot('6-destination')
                print('PASS: a torrent file opens as a folder; ticks download, folders tick their files, back and forth')
        except Exception:
            for log in ('helper.log', 'files.log'):
                path = tmp / log
                if path.exists():
                    print(f'--- {log}', file=sys.stderr)
                    print(path.read_text()[-4000:], file=sys.stderr)
            raise
        finally:
            for process in reversed(processes):
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=8)
                    except subprocess.TimeoutExpired:
                        process.kill()
            stop_process(comp)


if __name__ == '__main__':
    run()

#!/usr/bin/env python3
"""Native dialog on a private bus/headless output, with a test-only wlroots keyboard."""
import os
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import time

if '--private' not in sys.argv:
    raise SystemExit(subprocess.call(['dbus-run-session', '--', sys.executable, __file__, *sys.argv[1:], '--private']))

import polkit as fixture
from ipc_client import IPCClient, IPCError, spawn_compositor, stop_process
from gi.repository import GLib, Gio
from input_protocols import compile_client
from capture import build_client as build_capture_client
from xwayland import wait_for, wayland_display_name

ROOT = Path(__file__).resolve().parents[1]


def run(scale='1', renderer='pixman'):
    with tempfile.TemporaryDirectory(prefix='rediwm-polkit-ui-') as directory:
        tmp = Path(directory)
        compile_client(tmp)
        build_capture_client(tmp)
        hook = tmp / 'input.so'
        flags = subprocess.check_output(['pkg-config', '--cflags', '--libs', 'wlroots-0.20', 'wayland-server', 'xkbcommon'], text=True).split()
        subprocess.run(['cc', '-shared', '-fPIC', '-Wall', '-Wextra', '-Werror', str(ROOT / 'tests/polkit_input_hook.c'), '-o', str(hook), *flags, '-ldl'], check=True)
        fifo = tmp / 'input'
        os.mkfifo(fifo)
        authority = fixture.Authority()
        os.environ.pop('REDIWM_POLKIT_HELPER_SOCKET', None)
        def config(enabled):
            return f'[polkit]\nenable = {str(enabled).lower()}\nhelper_socket = "{tmp / 'helper'}"\n'
        proc, log = spawn_compositor(tmp, scale=scale, renderer=renderer, config_content=config(False), env_extra={
            'LD_PRELOAD': str(hook), 'REDIWM_TEST_POLKIT_INPUT': str(fifo),
            'DBUS_SYSTEM_BUS_ADDRESS': os.environ['DBUS_SESSION_BUS_ADDRESS'],
            'REDIWM_FORCE_POLKIT': '1', 'XDG_SESSION_ID': 'ui-test',
            'XDG_CACHE_HOME': directory, 'DBUS_SESSION_BUS_ADDRESS': '',
        })
        fd = os.open(fifo, os.O_RDWR)
        clients = []
        client_env = dict(os.environ, XDG_RUNTIME_DIR=directory)

        class Peer:
            def __init__(self, mode):
                self.path = tmp / (mode + '.log')
                with self.path.open('w') as out:
                    self.process = subprocess.Popen([str(tmp / 'protocol-client'), mode], env=client_env, stdin=subprocess.PIPE, stdout=out, stderr=out, text=True)
                clients.append(self.process)
                wait_for(lambda: 'ready\n' in self.text(), 'protocol peer failed to start')
            def text(self): return self.path.read_text()
            def send(self, command):
                old = self.text().count('ack ' + command + '\n')
                self.process.stdin.write(command + '\n'); self.process.stdin.flush()
                wait_for(lambda: self.text().count('ack ' + command + '\n') > old, 'protocol command timed out: ' + command)

        try:
            with IPCClient(tmp, timeout=15) as ipc:
                ipc.wait_for('wallpaper_presented', timeout_ms=10000)
                while GLib.MainContext.default().pending():
                    GLib.MainContext.default().iteration(False)
                assert not any(e['method'] == 'RegisterAuthenticationAgent' for e in fixture.events)
                (tmp / 'rediwm-config.toml').write_text(config(True))
                name = fixture.wait_event('RegisterAuthenticationAgent')['sender']
                stream = IPCClient(tmp, timeout=5).connect()
                stream.query('event_stream', {'events': ['polkit_prompt_opened', 'polkit_prompt_closed']})
                assert 'StateSnapshot' in json.loads(stream.reader.readline())

                def key(code):
                    os.write(fd, struct.pack('4I', code, 1, code, 0))
                output = ipc.get_outputs()[0]
                def click(x, y):
                    position = (int(x / output['logical_width'] * 65535) << 16) | int(y / output['logical_height'] * 65535)
                    os.write(fd, struct.pack('6I', 0xffffffff, position, 0xfffffffe, 1, 0xfffffffe, 0))
                def panel(state):
                    deadline = time.monotonic() + 5
                    while time.monotonic() < deadline:
                        value = ipc.get_shell_state()['polkit_dialog']
                        if (state is None and value is None) or (value and value['state'] == state):
                            return value
                        time.sleep(.03)
                    raise AssertionError(('dialog state', state, value))
                def capture_rejected():
                    ipc.wait_for_frame()
                    try:
                        ipc.screenshot(str(tmp / 'forbidden.png'))
                    except IPCError as err:
                        assert 'AuthenticationActive' in str(err), err
                    else:
                        raise AssertionError('authentication dialog was captured')
                    assert not (tmp / 'forbidden.png').exists()
                def response():
                    # Exercise editing without ever supplying a real password.
                    key(45)  # x
                    key(14)  # Backspace
                    for code in (20, 18, 31, 20, 12, 19, 18, 31, 25, 24, 49, 31, 18):
                        key(code)
                def begin(scenario):
                    path = tmp / 'helper'
                    if path.exists(): path.unlink()
                    peer = fixture.HelperSocket(directory, scenario)
                    peer.pid = proc.pid
                    start = len(fixture.events)
                    def completed(conn, result):
                        error = None
                        try: conn.call_finish(result)
                        except GLib.Error as err: error = Gio.DBusError.get_remote_error(err)
                        fixture.event({'method': 'UIDone', 'error': error})
                    authority.conn.call(name, fixture.AGENT_PATH, fixture.AGENT_IFACE, 'BeginAuthentication',
                        GLib.Variant(fixture.BEGIN_SIGNATURE, fixture.begin_args()), None, Gio.DBusCallFlags.NONE, 15000, None, completed)
                    authority.conn.flush_sync(None)
                    return peer, start

                client_env['WAYLAND_DISPLAY'] = wayland_display_name(tmp)
                def capture_peer(label):
                    path = tmp / (label + '.log')
                    with path.open('w') as output:
                        peer = subprocess.Popen([str(tmp / 'client')], stdin=subprocess.PIPE,
                            stdout=output, stderr=output, text=True, env=client_env)
                    clients.append(peer)
                    wait_for(lambda: 'presented' in path.read_text(), 'capture peer did not map')
                    peer.stdin.write('capture\n'); peer.stdin.flush()
                    return peer, path
                existing_capture, existing_capture_log = capture_peer('existing-capture')
                wait_for(lambda: 'ready ' in existing_capture_log.read_text(), 'capture did not start')

                app = Peer('polkit-test-app')
                wait_for(lambda: any(w['app_id'] == 'polkit-test-app' for w in ipc.get_windows()), 'app did not map')
                ime = Peer('ime')
                ime.send('method'); ime.send('grab')
                wait_for(lambda: 'grab-keymap' in ime.text(), 'IME did not receive initial keymap')
                app.send('enable')
                peer, start = begin('success')
                box = panel('prompt')['box']
                existing_capture.wait(timeout=3)
                refused_capture, refused_capture_log = capture_peer('refused-capture')
                refused_capture.wait(timeout=3)
                assert 'ready ' not in refused_capture_log.read_text(), 'authentication pixels escaped through capture protocol'

                opened = json.loads(stream.reader.readline())['PolkitPromptOpened']
                assert set(opened) == {'seq', 'time_ms'}
                click(10, 10)  # Outside click is swallowed, never dismisses.
                panel('prompt')
                capture_rejected()
                app.send('sync'); ime.send('sync')
                app_keys = app.text().count('app-key ')
                ime_keys = ime.text().count('grab-key ')
                ime.send('virtual-key'); ime.send('compose')
                for attempt in (lambda: ipc.type_text('SHOULD_NOT_ENTER'), lambda: ipc.key_down_up(1), lambda: ipc.click_at(10, 10)):
                    try: attempt()
                    except IPCError as err: assert 'AuthenticationActive' in str(err), err
                    else: raise AssertionError('synthetic input accepted')
                capture_rejected()
                for _ in range(4): key(15)  # Tab visits Cancel, Authenticate, action id, input.
                response()
                os.write(fd, struct.pack('8I', 29, 1, 46, 1, 46, 0, 29, 0))  # Ctrl+C cannot copy the response.
                capture_rejected()
                # No secret is exposed via status or input inspection.
                assert 'test-response' not in str(ipc.get_shell_state())
                click(box['x'] + box['width'] * 410 / 560, box['y'] + box['height'] * 430 / 480)
                assert fixture.wait_event('UIDone', start)['error'] is None
                app.send('sync'); ime.send('sync')
                assert app.text().count('app-key ') == app_keys, 'authentication key leaked to client'
                assert ime.text().count('grab-key ') == ime_keys, 'authentication key leaked to IME'
                peer.finish()
                panel(None)
                closed = json.loads(stream.reader.readline())['PolkitPromptClosed']
                assert set(closed) == {'seq', 'time_ms'} and closed['seq'] > opened['seq']
                stream.close()
                mark = len(fixture.events)
                (tmp / 'rediwm-config.toml').write_text(config(False))
                fixture.wait_event('UnregisterAuthenticationAgent', mark)
                mark = len(fixture.events)
                (tmp / 'rediwm-config.toml').write_text(config(True))
                fixture.wait_event('RegisterAuthenticationAgent', mark)

                # Multi-prompt (echo on), failure rendering, Escape and authority cancel.
                for index, scenario in enumerate(('multiple', 'failure', 'hold', 'hold', 'hold')):
                    peer, start = begin(scenario)
                    panel('prompt')
                    if scenario == 'hold':
                        if index == 2:
                            key(1)
                        elif index == 4:
                            box = panel('prompt')['box']
                            click(box['x'] + box['width'] * 150 / 560, box['y'] + box['height'] * 430 / 480)
                        else:
                            fixture.call(authority.conn, name, fixture.AGENT_PATH, fixture.AGENT_IFACE,
                                         'CancelAuthentication', '(s)', ('SECRET_COOKIE',))
                    else:
                        response(); key(28)
                        if scenario == 'failure':
                            for attempt in (2, 3):
                                wait_for(lambda: peer.prompt_count >= attempt, 'retry helper did not prompt')
                                panel('prompt')
                                response(); key(28)
                        if scenario == 'multiple':
                            # Observe the newly cleared field, then feed echo-on input.
                            time.sleep(.1)
                            panel('prompt')
                            response(); key(28)
                    error = fixture.wait_event('UIDone', start)['error']
                    assert error == (None if scenario == 'multiple' else fixture.AUTH + '.Error.Cancelled'), error
                    peer.finish()
                    if scenario == 'failure':
                        panel('failed'); key(1)
                    panel(None)
                assert proc.poll() is None
                print(f'PASS: native polkit dialog, secret editing, modal synthetic rejection, echo-on, success/failure/cancel at {scale} ({renderer})')
        except Exception:
            print((tmp / 'compositor.log').read_text()[-6000:], file=sys.stderr)
            raise
        finally:
            os.close(fd)
            for client in clients: stop_process(client)
            stop_process(proc)
            log.close()
            authority.close()
        logs = (tmp / 'compositor.log').read_text()
        assert 'test-response' not in logs and 'SECRET_COOKIE' not in logs


if __name__ == '__main__':
    args = [arg for arg in sys.argv[1:] if arg != '--private']
    run(*args)

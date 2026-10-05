#!/usr/bin/env python3
"""Real compositor and independent Application peer on a fresh private bus."""
import json
import os
from pathlib import Path
import queue
import socket
import subprocess
import sys
import tempfile
import threading

if __name__ == '__main__' and '--private' not in sys.argv:
    raise SystemExit(subprocess.call(['dbus-run-session', '--', sys.executable, __file__, '--private']))

from gi.repository import Gio, GLib
from ipc_client import IPCClient, spawn_compositor, stop_process


def run():
    conn = Gio.DBusConnection.new_for_address_sync(os.environ['DBUS_SESSION_BUS_ADDRESS'],
        Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION, None, None)
    name = 'org.rediwm.Activation-Test'
    path = '/org/rediwm/Activation_Test'
    conn.call_sync('org.freedesktop.DBus', '/org/freedesktop/DBus', 'org.freedesktop.DBus',
                   'RequestName', GLib.Variant('(su)', (name, 4)), None, Gio.DBusCallFlags.NONE, 3000, None)
    xml = '''<node><interface name="org.freedesktop.Application">
      <method name="Activate"><arg type="a{sv}" direction="in"/></method>
      <method name="Open"><arg type="as" direction="in"/><arg type="a{sv}" direction="in"/></method>
    </interface></node>'''
    calls = queue.Queue()
    behavior = ['success']
    held = []

    def method(_conn, _sender, _path, _iface, member, params, invocation):
        calls.put((member, params.unpack()))
        if behavior[0] == 'error':
            invocation.return_dbus_error('org.example.Refused', 'fixture refusal')
        elif behavior[0] == 'hold':
            held.append(invocation)
        else:
            invocation.return_value(None)

    conn.register_object(path, Gio.DBusNodeInfo.new_for_xml(xml).interfaces[0], method, None, None)
    loop = GLib.MainLoop()
    thread = threading.Thread(target=loop.run, daemon=True)
    thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix='rediwm-activation-') as directory:
            tmp = Path(directory)
            apps = tmp / 'data/applications'
            apps.mkdir(parents=True)
            receiver = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
            receiver.bind(str(tmp / 'fallback.sock'))
            receiver.settimeout(8)
            fallback = tmp / 'fallback.py'
            fallback.write_text('''import json, os, socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
s.sendto(json.dumps({'argv':sys.argv[2:], 'display':os.getenv('WAYLAND_DISPLAY'),
                    'token':os.getenv('XDG_ACTIVATION_TOKEN'),
                    'supervisor':os.getenv('REDIWM_SESSION_FD')}).encode(), sys.argv[1])
''')
            desktop = apps / (name + '.desktop')
            desktop.write_text(f'''[Desktop Entry]
Type=Application
Name=Activation Fixture
DBusActivatable=true
Exec={sys.executable} {fallback} {tmp / 'fallback.sock'} %U
''')
            proc, log = spawn_compositor(tmp, config_content='[compositor]\nxwayland = false\n', env_extra={
                'REDIWM_FORCE_DBUS': '1', 'XDG_DATA_HOME': str(tmp / 'data'),
                'XDG_DATA_DIRS': str(tmp / 'empty'), 'XDG_CACHE_HOME': str(tmp / 'cache'),
            })
            try:
                with IPCClient(tmp) as ipc:
                    ipc.wait_for('catalog_published', timeout_ms=10000)
                    def launch(uris=()):
                        ipc.action('launch_app', {'desktop_id': name + '.desktop', 'uris': list(uris)})
                        return calls.get(timeout=5)
                    member, args = launch()
                    assert member == 'Activate', (member, args)
                    assert args[0]['activation-token'], args
                    assert args[0]['desktop-startup-id'] == args[0]['activation-token'], args
                    uri = 'file:///tmp/test%20document.txt'
                    member, args = launch([uri])
                    assert member == 'Open' and args[0] == [uri], (member, args)
                    assert args[1]['activation-token'], args
                    receiver.settimeout(.2)
                    try:
                        receiver.recv(8192)
                        raise AssertionError('Exec ran despite successful D-Bus activation')
                    except socket.timeout:
                        pass
                    receiver.settimeout(8)
                    behavior[0] = 'error'
                    launch([uri])
                    fallback_result = json.loads(receiver.recv(8192))
                    assert fallback_result['argv'] == [uri], fallback_result
                    assert fallback_result['display'].startswith('wayland-'), fallback_result
                    assert fallback_result['token'], fallback_result
                    assert fallback_result['supervisor'] is None, fallback_result
                    behavior[0] = 'hold'
                    launch()
                    # Real five-second timeout drives Exec fallback.
                    assert json.loads(receiver.recv(8192))['argv'] == []
                    launch()
                    # Disconnect with a call pending: shutdown must cancel it,
                    # without running the Exec fallback during teardown.
                stop_process(proc)
                assert proc.returncode == 0, (tmp / 'compositor.log').read_text()
            finally:
                if proc.poll() is None:
                    stop_process(proc)
                log.close()
                receiver.close()
        print('PASS: Activate/Open, object naming, tokens, error/timeout fallback, pending-call teardown')
    finally:
        conn.close_sync(None)
        loop.quit()
        thread.join(timeout=2)


if __name__ == '__main__':
    run()

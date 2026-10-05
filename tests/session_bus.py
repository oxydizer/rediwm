#!/usr/bin/env python3
"""Run rediwm-session against independent logind/systemd peers on a private bus.

Checks the supervisor's real D-Bus method signatures and reply parsing: login
verification, graphical contention, publication while the compositor runs,
restoration after it exits, and that a refused publication still releases
direct launches.
Usage: session_bus.py <rediwm-session binary>
"""
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import threading

if __name__ == '__main__' and '--private' not in sys.argv:
    raise SystemExit(subprocess.call(['dbus-run-session', '--', sys.executable, __file__, '--private', *sys.argv[1:]]))

from gi.repository import Gio, GLib

ARGS = [arg for arg in sys.argv[1:] if arg != '--private']
SUPERVISOR = Path(ARGS[0] if ARGS else Path(__file__).resolve().parents[1] / 'zig-out/bin/rediwm-session')
OWNER = 'REDIWM_ACTIVATION_OWNER'
ORIGINAL = {'DISPLAY': ':prior', 'PATH': '/usr/bin', 'OTHER': 'untouched'}

# Reports the environment it was given, then holds the session open until the
# test closes the report socket.
FAKE = '''#!/usr/bin/env python3
import json, os, socket, sys
s = socket.socket(fileno=int(os.environ['REDIWM_SESSION_FD']))
s.send(json.dumps({'WAYLAND_DISPLAY': 'wayland-fixture', 'DISPLAY': ':14'}).encode())
acked = s.recv(32) == b'ready'
report = socket.socket(socket.AF_UNIX)
report.connect(os.path.join(os.path.dirname(os.path.realpath(__file__)), 'report.sock'))
report.sendall(json.dumps({'acked': acked, 'env': dict(os.environ)}).encode() + b'\\n')
report.recv(1)
'''


class Fixture:
    def __init__(self, address):
        self.address = address
        self.environment = dict(ORIGINAL)
        self.properties = {
            'Id': GLib.Variant('s', 'c1'), 'User': GLib.Variant('(uo)', (os.getuid(), '/user/test')),
            'Type': GLib.Variant('s', 'wayland'), 'Class': GLib.Variant('s', 'user'),
            'Desktop': GLib.Variant('s', 'rediwm'), 'Remote': GLib.Variant('b', False),
            'State': GLib.Variant('s', 'active'),
        }
        self.extra = []
        self.refuse_set = False
        self.conn = Gio.DBusConnection.new_for_address_sync(address,
            Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION, None, None)
        for name in ('org.freedesktop.login1', 'org.freedesktop.systemd1'):
            self.conn.call_sync('org.freedesktop.DBus', '/org/freedesktop/DBus', 'org.freedesktop.DBus',
                'RequestName', GLib.Variant('(su)', (name, 4)), None, Gio.DBusCallFlags.NONE, 3000, None)
        logind_xml = '''<node><interface name="org.freedesktop.login1.Manager">
          <method name="GetSessionByPID"><arg type="u" direction="in"/><arg type="o" direction="out"/></method>
          <method name="ListSessions"><arg type="a(susso)" direction="out"/></method>
        </interface></node>'''
        props_xml = '<node><interface name="org.freedesktop.login1.Session">' + ''.join(
            f'<property name="{key}" type="{value.get_type_string()}" access="read"/>'
            for key, value in self.properties.items()) + '</interface></node>'
        systemd_xml = '''<node><interface name="org.freedesktop.systemd1.Manager">
          <property name="Environment" type="as" access="read"/>
          <method name="SetEnvironment"><arg type="as" direction="in"/></method>
          <method name="UnsetEnvironment"><arg type="as" direction="in"/></method>
        </interface></node>'''
        node = Gio.DBusNodeInfo.new_for_xml
        self.conn.register_object('/org/freedesktop/login1', node(logind_xml).interfaces[0], self.logind, None, None)
        self.conn.register_object('/session/test', node(props_xml).interfaces[0], None,
                                  lambda _c, _s, _p, _i, prop: self.properties[prop], None)
        self.conn.register_object('/org/freedesktop/systemd1', node(systemd_xml).interfaces[0], self.manager,
                                  lambda *_: GLib.Variant('as', [f'{k}={v}' for k, v in self.environment.items()]), None)
        self.loop = GLib.MainLoop()
        self.thread = threading.Thread(target=self.loop.run, daemon=True)
        self.thread.start()

    def logind(self, _conn, _sender, _path, _iface, method, _params, invocation):
        if method == 'GetSessionByPID':
            invocation.return_value(GLib.Variant('(o)', ('/session/test',)))
        else:
            invocation.return_value(GLib.Variant('(a(susso))', (
                [('c1', os.getuid(), 'fixture', 'seat0', '/session/test')] + self.extra,)))

    def manager(self, _conn, _sender, _path, _iface, method, params, invocation):
        if method == 'SetEnvironment' and self.refuse_set:
            invocation.return_dbus_error('org.freedesktop.DBus.Error.AccessDenied', 'fixture refusal')
            return
        for value in params.unpack()[0]:
            if method == 'SetEnvironment':
                key, text = value.split('=', 1)
                self.environment[key] = text
            else:
                self.environment.pop(value, None)
        invocation.return_value(None)

    def close(self):
        self.loop.quit()
        self.thread.join(timeout=2)
        self.conn.close_sync(None)

    def run_session(self, while_running=None):
        """Runs the supervisor around the fake compositor; returns (report, stderr + log)."""
        early = ''
        with tempfile.TemporaryDirectory(prefix='rediwm-bus-') as directory:
            tmp = Path(directory)
            os.chmod(tmp, 0o700)
            shutil.copy2(SUPERVISOR, tmp / 'rediwm-session')
            (tmp / 'rediwm').write_text(FAKE)
            (tmp / 'rediwm').chmod(0o700)
            listener = socket.socket(socket.AF_UNIX)
            listener.bind(str(tmp / 'report.sock'))
            listener.listen(1)
            listener.settimeout(20)
            env = {**os.environ, 'HOME': str(tmp), 'XDG_RUNTIME_DIR': str(tmp),
                   'DBUS_SYSTEM_BUS_ADDRESS': self.address, 'DBUS_SESSION_BUS_ADDRESS': self.address}
            env.pop('XDG_STATE_HOME', None)
            proc = subprocess.Popen([str(tmp / 'rediwm-session')], env=env, stderr=subprocess.PIPE, text=True)
            try:
                peer, _ = listener.accept()
                with peer, peer.makefile() as stream:
                    report = json.loads(stream.readline())
                    if while_running:
                        while_running(report)
                _, early = proc.communicate(timeout=20)
                assert proc.returncode == 0, early
            finally:
                if proc.poll() is None:
                    proc.kill()
                    proc.wait()
            # Login diagnostics precede session.log and go to the journal (stderr).
            return report, early + (tmp / '.local/state/rediwm/session.log').read_text()


def check_publication(fixture):
    def running(report):
        env = report['env']
        assert report['acked']
        assert env['REDIWM_LOGIN_SESSION'] == 'c1' and env['XDG_SESSION_ID'] == 'c1', env
        assert env['REDIWM_SESSION_PRIMARY'] == '1'
        published = fixture.environment
        assert published['WAYLAND_DISPLAY'] == 'wayland-fixture' and published['DISPLAY'] == ':14', published
        assert len(published[OWNER]) == 32, published
        assert published['OTHER'] == 'untouched'
    _, log = fixture.run_session(running)
    assert fixture.environment == ORIGINAL, (fixture.environment, log)


def check_foreign_desktop(fixture):
    fixture.properties['Desktop'] = GLib.Variant('s', 'GNOME')
    try:
        report, log = fixture.run_session()
    finally:
        fixture.properties['Desktop'] = GLib.Variant('s', 'rediwm')
    assert report['acked']
    assert 'REDIWM_LOGIN_SESSION' not in report['env'], 'host desktop accepted as RediWM login'
    assert 'global activation disabled' in log, log
    assert fixture.environment == ORIGINAL


def check_contention(fixture):
    fixture.extra.append(('c2', os.getuid(), 'fixture', 'seat1', '/session/test'))
    try:
        report, log = fixture.run_session()
    finally:
        fixture.extra.clear()
    assert report['acked']
    assert report['env']['REDIWM_LOGIN_SESSION'] == 'c1'
    assert 'REDIWM_SESSION_PRIMARY' not in report['env']
    assert 'graphical session c2 already uses this user bus' in log, log
    assert fixture.environment == ORIGINAL


def check_refusal(fixture):
    fixture.refuse_set = True
    try:
        report, log = fixture.run_session()
    finally:
        fixture.refuse_set = False
    assert report['acked'], 'a refused publication must still release direct launches'
    assert 'activation unavailable' in log and 'fixture refusal' in log, log
    assert fixture.environment == ORIGINAL


def main():
    fixture = Fixture(os.environ['DBUS_SESSION_BUS_ADDRESS'])
    try:
        check_publication(fixture)
        check_foreign_desktop(fixture)
        check_contention(fixture)
        check_refusal(fixture)
        print('PASS: verified logind identity, graphical contention, publication while running, restoration and refusal')
    finally:
        fixture.close()


if __name__ == '__main__':
    main()

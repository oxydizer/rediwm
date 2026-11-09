#!/usr/bin/env python3
"""Own and validate ConsoleKit2 logins against an independent private-bus peer.

The client is a noninstalled fixture; no host login or power service is reached.
"""
import os
import subprocess
import sys
import threading
import tempfile
from pathlib import Path

if __name__ == '__main__' and '--private' not in sys.argv:
    raise SystemExit(subprocess.call(['dbus-run-session', '--', sys.executable, __file__, '--private', *sys.argv[1:]]))

from gi.repository import Gio, GLib

NAME = 'org.freedesktop.ConsoleKit'
MANAGER = '/org/freedesktop/ConsoleKit/Manager'
SESSION = '/org/freedesktop/ConsoleKit/Session9'
COOKIE = 'private-fixture-cookie'


class Fixture:
    def __init__(self):
        self.conn = Gio.DBusConnection.new_for_address_sync(os.environ['DBUS_SESSION_BUS_ADDRESS'],
            Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION, None, None)
        self.conn.call_sync('org.freedesktop.DBus', '/org/freedesktop/DBus', 'org.freedesktop.DBus', 'RequestName',
                           GLib.Variant('(su)', (NAME, 4)), None, Gio.DBusCallFlags.NONE, 3000, None)
        self.values = {'GetUnixUser': ('u', os.getuid()), 'IsLocal': ('b', True),
                       'GetSessionType': ('s', 'wayland'), 'GetSessionClass': ('s', 'user'),
                       'GetRemoteHostName': ('s', '')}
        manager_xml = f'''<node><interface name="{NAME}.Manager">
          <method name="OpenSessionWithParameters"><arg type="a(sv)" direction="in"/><arg type="s" direction="out"/></method>
          <method name="GetSessionForCookie"><arg type="s" direction="in"/><arg type="o" direction="out"/></method>
          <method name="CloseSession"><arg type="s" direction="in"/><arg type="b" direction="out"/></method>
        </interface></node>'''
        session_xml = f'<node><interface name="{NAME}.Session">' + ''.join(
            f'<method name="{method}"><arg type="{sig}" direction="out"/></method>'
            for method, (sig, _) in self.values.items()) + '</interface></node>'
        self.conn.register_object(MANAGER, Gio.DBusNodeInfo.new_for_xml(manager_xml).interfaces[0], self.method, None, None)
        self.conn.register_object(SESSION, Gio.DBusNodeInfo.new_for_xml(session_xml).interfaces[0], self.method, None, None)
        self.calls = []
        self.refuse_lookup = False
        self.loop = GLib.MainLoop()
        self.thread = threading.Thread(target=self.loop.run, daemon=True)
        self.thread.start()

    def method(self, _conn, sender, _path, _interface, method, parameters, invocation):
        self.calls.append((method, sender, parameters.unpack()))
        if method == 'OpenSessionWithParameters':
            invocation.return_value(GLib.Variant('(s)', (COOKIE,)))
        elif method == 'GetSessionForCookie':
            if self.refuse_lookup:
                invocation.return_dbus_error(NAME + '.Manager.Error.General', 'no such session')
            else:
                invocation.return_value(GLib.Variant('(o)', (SESSION,)))
        elif method == 'CloseSession':
            invocation.return_value(GLib.Variant('(b)', (True,)))
        else:
            signature, value = self.values[method]
            invocation.return_value(GLib.Variant(f'({signature})', (value,)))

    def run(self, binary, device='/dev/ttyv0'):
        self.calls.clear()
        return subprocess.run([binary, device], text=True, capture_output=True, timeout=15)

    def assert_closed(self):
        methods = [entry[0] for entry in self.calls]
        assert methods[0] == 'OpenSessionWithParameters', self.calls
        assert methods[-1] == 'CloseSession' and methods.count('CloseSession') == 1, self.calls
        assert len({entry[1] for entry in self.calls}) == 1, 'ownership connection changed'
        assert self.calls[-1][2] == (COOKIE,), self.calls

    def close(self):
        self.loop.quit()
        self.thread.join(timeout=2)
        self.conn.close_sync(None)


def main():
    binary = next(arg for arg in sys.argv[1:] if arg != '--private')
    fixture = Fixture()
    try:
        result = fixture.run(binary)
        assert result.returncode == 0, result.stderr
        assert result.stdout == f'verified {SESSION}\n', result.stdout
        fixture.assert_closed()
        parameters = dict(fixture.calls[0][2][0])
        assert parameters == {'session-type': 'wayland', 'session-class': 'user',
                              'display-device': '/dev/ttyv0', 'remote-host-name': ''}, parameters
        for method, wrong in [('GetUnixUser', os.getuid() + 1), ('IsLocal', False),
                              ('GetSessionType', 'x11'), ('GetSessionClass', 'greeter'),
                              ('GetRemoteHostName', 'remote.example')]:
            original = fixture.values[method]
            fixture.values[method] = (original[0], wrong)
            try:
                result = fixture.run(binary)
            finally:
                fixture.values[method] = original
            assert result.returncode != 0 and 'NotLocalWaylandLogin' in result.stderr, (method, result)
            assert not result.stdout, result.stdout
            fixture.assert_closed()
        result = fixture.run(binary, '/dev/pts/1')
        assert result.returncode != 0 and not fixture.calls, (result, fixture.calls)
        fixture.refuse_lookup = True
        result = fixture.run(binary)
        assert result.returncode != 0, result
        fixture.assert_closed()
        with tempfile.TemporaryDirectory(prefix='rediwm-consolekit-') as directory:
            env = {**os.environ, 'HOME': directory, 'XDG_RUNTIME_DIR': directory,
                   'XDG_CONFIG_HOME': directory, 'XDG_CACHE_HOME': directory,
                   'XDG_STATE_HOME': directory, 'XDG_DATA_HOME': directory}
            result = subprocess.run([binary, '--user-bus', directory], env=env,
                                    capture_output=True, text=True, timeout=15)
            assert result.returncode == 0, result.stderr
            assert result.stdout == 'private user bus ready\n', result.stdout
            assert not list(Path(directory).glob('rediwm-bus-*')), 'daemon socket survived cleanup'
        print('PASS: ConsoleKit session ownership, console-only admission, identity checks, and cleanup on rejection')
    finally:
        fixture.close()


if __name__ == '__main__':
    main()

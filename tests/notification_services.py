#!/usr/bin/env python3
"""Notification ownership/selection on a private bus, with owned fake helpers."""
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile

if __name__ == '__main__' and '--private' not in sys.argv:
    raise SystemExit(subprocess.call(['dbus-run-session', '--', sys.executable, __file__, '--private']))

from gi.repository import Gio, GLib
from ipc_client import IPCClient, spawn_compositor, stop_process

BUS = 'org.freedesktop.DBus'
NAME = 'org.freedesktop.Notifications'


def main():
    conn = Gio.DBusConnection.new_for_address_sync(os.environ['DBUS_SESSION_BUS_ADDRESS'],
        Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION, None, None)
    def call(member, signature, args):
        return conn.call_sync(BUS, '/org/freedesktop/DBus', BUS, member,
                             GLib.Variant(signature, args), None, Gio.DBusCallFlags.NONE, 3000, None).unpack()
    # Allow replacement deliberately: the compositor still must not replace us.
    assert call('RequestName', '(su)', (NAME, 1)) == (1,)
    try:
        for mode in ('builtin-existing', 'external-existing', 'external-new', 'nested'):
            if mode == 'external-new':
                call('ReleaseName', '(s)', (NAME,))
            with tempfile.TemporaryDirectory(prefix='rediwm-notify-owner-') as directory:
                tmp = Path(directory)
                receiver = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
                receiver.bind(str(tmp / 'started'))
                receiver.settimeout(3 if mode == 'external-new' else .3)
                helper = tmp / 'helper.py'
                helper.write_text('''import socket, sys, time
s = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
s.sendto(b'started', sys.argv[1])
time.sleep(60)
''')
                config = '[compositor]\nxwayland = false\n'
                if mode != 'builtin-existing':
                    config += f'[notifications]\ndaemon = "{sys.executable} {helper} {tmp / "started"}"\n'
                proc, log = spawn_compositor(tmp, config_content=config, env_extra={
                    'REDIWM_FORCE_DBUS': '0' if mode == 'nested' else '1',
                    'XDG_CACHE_HOME': str(tmp / 'cache'), 'GIO_USE_VFS': 'local',
                    'XDG_DATA_HOME': str(tmp / 'data'), 'XDG_DATA_DIRS': str(tmp / 'empty'),
                })
                try:
                    with IPCClient(tmp) as ipc:
                        ipc.wait_for('wallpaper_presented', timeout_ms=10000)
                        if mode.endswith('existing'):
                            assert call('GetNameOwner', '(s)', (NAME,))[0] == conn.get_unique_name()
                        if mode == 'external-new':
                            assert receiver.recv(1024) == b'started'
                            receiver.settimeout(.2)
                        try:
                            receiver.recv(1024)
                            raise AssertionError(f'unexpected/duplicate external daemon in {mode}')
                        except socket.timeout:
                            pass
                finally:
                    stop_process(proc)
                    log.close()
                    receiver.close()
        print('PASS: existing notification owner preserved, external selection, no duplicates, nested isolation')
    finally:
        conn.close_sync(None)


if __name__ == '__main__':
    main()

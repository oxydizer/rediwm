#!/usr/bin/env python3
"""org.freedesktop.ScreenSaver idle inhibition on a private session bus."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile

if __name__ == '__main__' and '--private' not in sys.argv:
    raise SystemExit(subprocess.call(['dbus-run-session', '--', sys.executable, __file__, '--private']))

from gi.repository import Gio, GLib
from desktop_zoom import wait_for
from ipc_client import IPCClient, spawn_compositor, stop_process

BUS = 'org.freedesktop.DBus'
NAME = 'org.freedesktop.ScreenSaver'
PATH = '/org/freedesktop/ScreenSaver'


def connect():
    return Gio.DBusConnection.new_for_address_sync(os.environ['DBUS_SESSION_BUS_ADDRESS'],
        Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION, None, None)


def call(conn, dest, path, iface, member, signature=None, args=None):
    params = GLib.Variant(signature, args) if signature else None
    reply = conn.call_sync(dest, path, iface, member, params, None, Gio.DBusCallFlags.NONE, 3000, None)
    return reply.unpack() if reply else ()


def saver(conn, member, signature=None, args=None, path=PATH):
    return call(conn, NAME, path, NAME, member, signature, args)


def main():
    conn = connect()
    with tempfile.TemporaryDirectory(prefix='rediwm-screensaver-') as directory:
        tmp = Path(directory)
        proc, log = spawn_compositor(tmp, config_content=(
            '[compositor]\nxwayland = false\n\n[idle]\nenabled = true\nblank_after_seconds = 10\nsuspend_after_seconds = 0\n'),
            env_extra={'REDIWM_FORCE_DBUS': '1', 'XDG_CACHE_HOME': str(tmp / 'cache'),
                       'XDG_STATE_HOME': str(tmp / 'state'), 'GIO_USE_VFS': 'local'})
        try:
            with IPCClient(tmp) as ipc:
                def state():
                    return ipc.request(query='get_idle_state')

                wait_for(lambda: call(conn, BUS, '/org/freedesktop/DBus', BUS, 'NameHasOwner', '(s)', (NAME,))[0],
                         'compositor did not take org.freedesktop.ScreenSaver')
                assert saver(conn, 'GetActive') == (False,)

                # An inhibitor holds off blanking however long the session idles.
                (cookie,) = saver(conn, 'Inhibit', '(ss)', ('brave', 'Playing video'))
                assert cookie != 0
                s = state()
                assert s['is_inhibited'] is True and s['inhibitor_count'] == 1, s
                entry = s['inhibitors'][0]
                assert entry['app_id'] == 'brave' and entry['title'] == 'Playing video' and entry['is_active'], entry
                ipc.action('advance_idle_time', {'seconds': 60})
                assert state()['state'] == 'active'

                # Another client cannot release it; the holder can.
                other = connect()
                saver(other, 'UnInhibit', '(u)', (cookie,))
                assert state()['is_inhibited'] is True
                saver(conn, 'UnInhibit', '(u)', (cookie,))
                s = state()
                assert s['is_inhibited'] is False and s['inhibitor_count'] == 0, s

                # Released: the full timeout runs again, then the displays blank.
                ipc.action('advance_idle_time', {'seconds': 5})
                assert state()['state'] == 'active'
                ipc.action('advance_idle_time', {'seconds': 6})
                wait_for(lambda: state()['state'] == 'blanked', 'displays did not blank after release')
                assert saver(conn, 'GetActive') == (True,)
                saver(conn, 'SimulateUserActivity')
                wait_for(lambda: state()['state'] == 'active', 'SimulateUserActivity did not wake')

                # The short path works too, and a client that leaves the bus loses its inhibitors.
                saver(other, 'Inhibit', '(ss)', ('mpv', 'video'), path='/ScreenSaver')
                saver(other, 'Inhibit', '(ss)', ('mpv', 'audio'))
                assert state()['inhibitor_count'] == 2
                other.close_sync(None)
                wait_for(lambda: state()['inhibitor_count'] == 0, 'departed client kept its inhibitors')
                assert state()['is_inhibited'] is False
        finally:
            stop_process(proc)
            log.close()
    conn.close_sync(None)
    print('PASS: ScreenSaver Inhibit/UnInhibit, owner checks, blank after release, GetActive, departure cleanup')


if __name__ == '__main__':
    main()

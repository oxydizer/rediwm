#!/usr/bin/env python3
"""Production readiness fd, environment, duplicate helpers and exec restart."""
import json
import os
from pathlib import Path
import select
import signal
import socket
import subprocess
import sys
import tempfile
import time

from ipc_client import IPCClient, IPCError, ROOT


def main():
    with tempfile.TemporaryDirectory(prefix='rediwm-readiness-') as directory:
        tmp = Path(directory)
        parent, child = socket.socketpair(socket.AF_UNIX, socket.SOCK_SEQPACKET)
        parent.settimeout(15)
        receiver = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        receiver.bind(str(tmp / 'child.sock'))
        receiver.settimeout(10)
        helper = tmp / 'helper.py'
        helper.write_text('''import json, os, socket, sys, time
s = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
s.sendto(json.dumps({'pid':os.getpid(), 'wayland':os.getenv('WAYLAND_DISPLAY'),
    'ipc':os.getenv('REDIWM_SOCKET'), 'desktop':os.getenv('XDG_CURRENT_DESKTOP'),
    'display':os.getenv('DISPLAY'), 'path':os.getenv('PATH'),
    'private':[os.getenv(key) for key in ('REDIWM_SESSION_FD','REDIWM_LOGIN_SESSION','REDIWM_SESSION_PRIMARY')]}).encode(), sys.argv[1])
time.sleep(60)
''')
        command = f'{sys.executable} {helper} {tmp / "child.sock"}'
        config = tmp / 'config.toml'
        config.write_text('[compositor]\nxwayland = false\n' +
                          f'[[autostart]]\ncmd = "{command}"\n' * 2)
        env = dict(os.environ, XDG_RUNTIME_DIR=directory, WLR_BACKENDS='headless',
                   WLR_RENDERER='pixman', WLR_HEADLESS_OUTPUTS='1', REDIWM_CONFIG=str(config),
                   REDIWM_SESSION_FD=str(child.fileno()), REDIWM_LOGIN_SESSION='must-not-escape',
                   XDG_CACHE_HOME=str(tmp / 'cache'), DISPLAY=':host',
                   XDG_STATE_HOME=str(tmp / 'state'),
                   PULSE_SERVER='unix:' + str(tmp / 'missing-pulse'),
                   DBUS_SYSTEM_BUS_ADDRESS='unix:path=/nonexistent-rediwm-system',
                   DBUS_SESSION_BUS_ADDRESS='unix:path=/nonexistent-rediwm-user')
        env.pop('REDIWM_SOCKET', None)
        env.pop('WAYLAND_DISPLAY', None)
        handles = []
        with (tmp / 'log').open('w') as log:
            proc = subprocess.Popen([str(ROOT / 'zig-out/bin/rediwm')], env=env,
                                    pass_fds=(child.fileno(),), start_new_session=True, stdout=log, stderr=log)
            child.close()
            try:
                for attempt in range(2):
                    ready = json.loads(parent.recv(16384))
                    assert ready['WAYLAND_DISPLAY'].startswith('wayland-'), ready
                    assert ready['DISPLAY'] == '', ready
                    # Withhold publication acknowledgement. The compositor must
                    # already present the desktop and handle input/IPC; neither
                    # initial commands nor autostart may launch during the wait.
                    with IPCClient(ready['REDIWM_SOCKET'], timeout=2) as ipc:
                        before = ipc.get_perf()['startup']
                        assert before['first_presented_ns'] > 0, before
                        assert before['session_ready_ns'] == 0, before
                        assert before['session_clients_started_ns'] == 0, before
                        ipc.click_at(100, 100)
                        assert ipc.get_perf()['startup']['first_input_ns'] > 0
                        time.sleep(.5)
                        assert ipc.get_perf()['startup']['session_ready_ns'] == 0
                    assert not select.select([receiver], [], [], .1)[0], 'autostart preceded readiness acknowledgement'
                    parent.send(b'ready')
                    launched = json.loads(receiver.recv(8192))
                    assert launched['wayland'] == ready['WAYLAND_DISPLAY'], launched
                    assert launched['ipc'] == ready['REDIWM_SOCKET'], launched
                    assert launched['desktop'] == 'rediwm' and launched['display'] is None, launched
                    assert launched['private'] == [None, None, None], launched
                    assert launched['path'].startswith(str(ROOT / 'zig-out/bin') + ':'), launched
                    handles.append(os.pidfd_open(launched['pid']))
                    assert not select.select([receiver], [], [], .1)[0], 'duplicate helper launch'
                    with IPCClient(ready['REDIWM_SOCKET']) as ipc:
                        after = ipc.get_perf()['startup']
                        assert after['session_clients_started_ns'] >= after['session_ready_ns'] > after['first_presented_ns'], after
                        ipc.wait_for('wallpaper_presented', timeout_ms=10000)
                        if attempt == 0:
                            try:
                                ipc.action('restart_shell')
                            except EOFError:
                                pass  # Restart closes the old IPC connection.
                    if attempt == 0:
                        assert select.select([handles[-1]], [], [], 5)[0], 'helper descendant survived exec restart'
                proc.terminate()
                assert proc.wait(timeout=5) == 0, (tmp / 'log').read_text()
                assert select.select([handles[-1]], [], [], 3)[0], 'helper survived normal shutdown'
            except BaseException:
                log.flush()
                print((tmp / 'log').read_text())
                raise
            finally:
                if proc.poll() is None:
                    os.killpg(proc.pid, signal.SIGKILL)
                    proc.wait(timeout=5)
                for fd in handles:
                    try:
                        signal.pidfd_send_signal(fd, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    os.close(fd)
                parent.close()
                receiver.close()
    print('PASS: responsive desktop during publication, readiness before autostart, shared child environment, duplicate suppression, helper cleanup, exec handshake')


def test_restart_during_publication():
    with tempfile.TemporaryDirectory(prefix='rediwm-pending-restart-') as directory:
        tmp = Path(directory)
        parent, child = socket.socketpair(socket.AF_UNIX, socket.SOCK_SEQPACKET)
        parent.settimeout(10)
        config = tmp / 'config.toml'
        config.write_text('[compositor]\nxwayland = false\n')
        env = dict(os.environ, XDG_RUNTIME_DIR=directory, WLR_BACKENDS='headless',
                   WLR_RENDERER='pixman', WLR_HEADLESS_OUTPUTS='1', REDIWM_CONFIG=str(config),
                   REDIWM_SESSION_FD=str(child.fileno()), XDG_STATE_HOME=str(tmp / 'state'),
                   XDG_CACHE_HOME=str(tmp / 'cache'), PULSE_SERVER='unix:' + str(tmp / 'missing-pulse'),
                   DBUS_SYSTEM_BUS_ADDRESS='unix:path=/nonexistent-rediwm-system',
                   DBUS_SESSION_BUS_ADDRESS='unix:path=/nonexistent-rediwm-user')
        env.pop('REDIWM_SOCKET', None)
        env.pop('WAYLAND_DISPLAY', None)
        with (tmp / 'log').open('w') as log:
            proc = subprocess.Popen([str(ROOT / 'zig-out/bin/rediwm')], env=env,
                                    pass_fds=(child.fileno(),), stdout=log, stderr=log)
            child.close()
            try:
                ready = json.loads(parent.recv(16384))
                with IPCClient(ready['REDIWM_SOCKET'], timeout=2) as ipc:
                    assert ipc.get_perf()['startup']['session_ready_ns'] == 0
                    ipc.action('restart_shell')
                    # The old process keeps serving until it consumes its ack.
                    assert ipc.get_perf()['startup']['session_ready_ns'] == 0
                parent.send(b'ready')
                renewed = json.loads(parent.recv(16384))
                with IPCClient(renewed['REDIWM_SOCKET'], timeout=2) as ipc:
                    assert ipc.get_perf()['startup']['session_ready_ns'] == 0, 'new process consumed an old ack'
                    parent.send(b'ready')
                    ipc.wait_for_frame(timeout_ms=2000)
                    assert ipc.get_perf()['startup']['session_ready_ns'] > 0
                proc.terminate()
                assert proc.wait(timeout=5) == 0, (tmp / 'log').read_text()
            except BaseException:
                log.flush()
                print((tmp / 'log').read_text())
                raise
            finally:
                if proc.poll() is None:
                    proc.kill()
                    proc.wait(timeout=5)
                parent.close()
    print('PASS: restart during publication consumes the old ack before the exec handshake')


def test_restart_behind_lock():
    """rediwm-session queues "lock" for a compositor whose predecessor crashed
    while locked: it must report the lock before readiness and refuse IPC."""
    with tempfile.TemporaryDirectory(prefix='rediwm-relock-') as directory:
        tmp = Path(directory)
        parent, child = socket.socketpair(socket.AF_UNIX, socket.SOCK_SEQPACKET)
        parent.settimeout(10)
        parent.send(b'lock')
        config = tmp / 'config.toml'
        config.write_text('[compositor]\nxwayland = false\n')
        env = dict(os.environ, XDG_RUNTIME_DIR=directory, WLR_BACKENDS='headless',
                   WLR_RENDERER='pixman', WLR_HEADLESS_OUTPUTS='1', REDIWM_CONFIG=str(config),
                   REDIWM_SESSION_FD=str(child.fileno()), XDG_STATE_HOME=str(tmp / 'state'),
                   XDG_CACHE_HOME=str(tmp / 'cache'), PULSE_SERVER='unix:' + str(tmp / 'missing-pulse'),
                   DBUS_SYSTEM_BUS_ADDRESS='unix:path=/nonexistent-rediwm-system',
                   DBUS_SESSION_BUS_ADDRESS='unix:path=/nonexistent-rediwm-user')
        env.pop('REDIWM_SOCKET', None)
        env.pop('WAYLAND_DISPLAY', None)
        with (tmp / 'log').open('w') as log:
            proc = subprocess.Popen([str(ROOT / 'zig-out/bin/rediwm')], env=env,
                                    pass_fds=(child.fileno(),), stdout=log, stderr=log)
            child.close()
            try:
                assert parent.recv(64) == b'locked', 'the lock was not reported before readiness'
                ready = json.loads(parent.recv(16384))
                with IPCClient(ready['REDIWM_SOCKET'], timeout=2) as ipc:
                    try:
                        ipc.get_perf()
                        raise AssertionError('IPC answered a session that should be locked')
                    except IPCError as err:
                        assert 'SessionLocked' in str(err), err
                proc.terminate()
                assert proc.wait(timeout=5) == 0, (tmp / 'log').read_text()
            except BaseException:
                log.flush()
                print((tmp / 'log').read_text())
                raise
            finally:
                if proc.poll() is None:
                    proc.kill()
                    proc.wait(timeout=5)
                parent.close()
    print('PASS: a restart behind the lock reports it before readiness and refuses IPC')


if __name__ == '__main__':
    main()
    test_restart_during_publication()
    test_restart_behind_lock()

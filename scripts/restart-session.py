#!/usr/bin/env python3
"""Restart only this user's installed RediWM, never a development/nested instance."""
import json
import os
from pathlib import Path
import signal
import socket
import struct
import sys
import time

INSTALLED = Path('/usr/local/bin/rediwm')


def connect(path):
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(3)
    try:
        sock.connect(str(path))
        pid, uid, _ = struct.unpack('3i', sock.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))
        executable = os.readlink(f'/proc/{pid}/exe').removesuffix(' (deleted)')
        if uid != os.getuid() or executable != str(INSTALLED):
            raise ValueError('not this user\'s installed compositor')
        return sock, pid
    except BaseException:
        sock.close()
        raise


def request(sock, value):
    sock.sendall(json.dumps(value).encode() + b'\n')
    data = b''
    while b'\n' not in data:
        chunk = sock.recv(65536)
        if not chunk:
            raise ConnectionError('compositor disconnected')
        data += chunk
    return json.loads(data.split(b'\n', 1)[0])


def main():
    runtime = Path(os.environ.get('XDG_RUNTIME_DIR', f'/run/user/{os.getuid()}'))
    explicit = os.environ.get('REDIWM_SOCKET')
    display = os.environ.get('WAYLAND_DISPLAY')
    if explicit:
        paths = [Path(explicit)]
    elif display:
        paths = [runtime / f'rediwm-{display}.sock']
    else:
        paths = sorted(runtime.glob('rediwm-*.sock'))
    sessions = []
    for path in paths:
        try:
            sock, pid = connect(path)
            sessions.append((path, sock, pid))
        except (OSError, ValueError):
            continue
    if not sessions:
        print('Installed ReleaseSafe. No installed RediWM session found; select RediWM at login.')
        return
    if len(sessions) != 1:
        for _, sock, _ in sessions:
            sock.close()
        raise RuntimeError('Multiple installed sessions found; set REDIWM_SOCKET to choose one.')
    path, sock, pid = sessions[0]
    with sock:
        # Probe before sending: old versions cannot acquire new restart support
        # merely by replacing their executable on disk.
        capabilities = request(sock, {'query': 'Capabilities'})
        if 'Err' in capabilities:
            raise RuntimeError(f'Cannot inspect session: {capabilities["Err"]}')
        if 'RestartShell' not in capabilities.get('Ok', {}).get('Capabilities', []):
            print('Installed ReleaseSafe. This running version lacks clean restart support. '
                  'Log out and back in once; subsequent installs restart automatically.')
            return
        print('Restarting RediWM; connected applications will close.', flush=True)
        signal.signal(signal.SIGHUP, signal.SIG_IGN)
        try:
            reply = request(sock, {"action": "RestartShell"})
            if "Err" in reply:
                raise RuntimeError(f"Restart rejected: {reply['Err']}")
        except (ConnectionError, socket.timeout):
            pass  # Shutdown can close IPC before its buffered reply is flushed.
    expected = INSTALLED.stat()
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        try:
            current = Path(f'/proc/{pid}/exe').stat()
            if (current.st_dev, current.st_ino) == (expected.st_dev, expected.st_ino):
                ready, ready_pid = connect(path)
                with ready:
                    if ready_pid == pid and request(ready, {'query': 'Version'}).get('Ok') is not None:
                        print('ReleaseSafe restarted successfully.')
                        return
        except (OSError, ValueError, ConnectionError):
            pass
        time.sleep(0.2)
    raise RuntimeError('Restart did not become ready within 20 seconds; check the RediWM session log.')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, RuntimeError) as error:
        print(f'Installed, but restart failed: {error}', file=sys.stderr)
        sys.exit(1)

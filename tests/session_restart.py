#!/usr/bin/env python3
"""Replace a live executable and restart twice, preserving PID and renewing IPC."""
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
from unittest.mock import patch

from ipc_client import ROOT, IPCClient, stop_process


def run():
    spec = importlib.util.spec_from_file_location('restart_session', ROOT / 'scripts/restart-session.py')
    restart = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(restart)
    with tempfile.TemporaryDirectory(prefix='rediwm-restart-') as directory:
        tmp = Path(directory)
        binary = tmp / 'rediwm'
        source = ROOT / 'zig-out/release-safe/bin/rediwm'
        shutil.copy2(source, binary)
        config = tmp / 'config.toml'
        config.write_text('[compositor]\nxwayland = false\n[autostart]\n')
        env = dict(os.environ, XDG_RUNTIME_DIR=str(tmp), WLR_BACKENDS='headless',
                   WLR_HEADLESS_OUTPUTS='1', WLR_RENDERER='pixman',
                   REDIWM_CONFIG=str(config), XDG_CACHE_HOME=str(tmp / 'cache'),
                   REDIWM_SOCKET=str(tmp / 'rediwm-test.sock'))
        env.pop('WAYLAND_DISPLAY', None)
        with (tmp / 'compositor.log').open('w') as log:
            proc = subprocess.Popen([str(binary)], env=env, stdout=log, stderr=log)
            try:
                deadline = time.monotonic() + 15
                while not Path(env['REDIWM_SOCKET']).exists():
                    assert proc.poll() is None, 'compositor exited at startup'
                    assert time.monotonic() < deadline, 'IPC not ready'
                    time.sleep(.05)
                with patch.object(restart, 'INSTALLED', binary), patch.dict(os.environ, env, clear=True):
                    for _ in range(2):
                        with IPCClient(env['REDIWM_SOCKET']) as previous:
                            assert previous.request(query='version')
                            staged = tmp / 'replacement'
                            shutil.copy2(source, staged)
                            staged.replace(binary)
                            assert os.readlink(f'/proc/{proc.pid}/exe').endswith(' (deleted)')
                            restart.main()
                            assert proc.poll() is None, 'login process exited'
                            assert Path(f'/proc/{proc.pid}/exe').stat().st_ino == binary.stat().st_ino
                            assert previous.sock.recv(1) == b'', 'old client connection survived restart'
                    with IPCClient(env['REDIWM_SOCKET']) as ipc:
                        assert ipc.request(query='outputs'), 'output missing after restart'
                print('PASS: two atomic executable replacements; PID preserved, IPC renewed, output available')
            except BaseException:
                log.flush()
                print((tmp / 'compositor.log').read_text())
                raise
            finally:
                stop_process(proc)


if __name__ == '__main__':
    run()

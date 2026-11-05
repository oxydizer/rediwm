#!/usr/bin/env python3
"""Replace a live executable and restart twice, preserving PID and renewing IPC."""
import os
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

from ipc_client import ROOT, IPCClient, stop_process


def run():
    restart = ROOT / 'zig-out/release-safe/bin/rediwm-restart'
    with tempfile.TemporaryDirectory(prefix='rediwm-restart-') as directory:
        tmp = Path(directory)
        # Compile a helper with a private runtime prefix, so its no-argument
        # path can be exercised without writing to a system installation.
        options = tmp / 'install_paths.zig'
        options.write_text('pub const bin = ' + json.dumps(str(tmp)) + ';\n')
        configured_restart = tmp / 'rediwm-restart'
        subprocess.run(['zig', 'build-exe', '-lc', '--dep', 'install_paths', '--dep', 'platform',
                        '-Mroot=' + str(ROOT / 'src/session_restart.zig'),
                        '-Minstall_paths=' + str(options),
                        '-Mplatform=' + str(ROOT / 'src/platform/mod.zig'),
                        '-femit-bin=' + str(configured_restart)], check=True)
        binary = tmp / 'rediwm'
        source = ROOT / 'zig-out/release-safe/bin/rediwm'
        shutil.copy2(source, binary)
        config = tmp / 'config.toml'
        config.write_text('[compositor]\nxwayland = false\n[autostart]\n')
        env = dict(os.environ, XDG_RUNTIME_DIR=str(tmp), WLR_BACKENDS='headless',
                   WLR_HEADLESS_OUTPUTS='1', WLR_RENDERER='gles2',
                   REDIWM_CONFIG=str(config), XDG_CACHE_HOME=str(tmp / 'cache'),
                   HOME=str(tmp), XDG_CONFIG_HOME=str(tmp / 'config'),
                   XDG_STATE_HOME=str(tmp / 'state'), XDG_DATA_HOME=str(tmp / 'data'),
                   DBUS_SYSTEM_BUS_ADDRESS='unix:path=' + str(tmp / 'no-system-bus'),
                   DBUS_SESSION_BUS_ADDRESS='unix:path=' + str(tmp / 'no-session-bus'),
                   REDIWM_IPC_AUTOMATION='1', REDIWM_FILES_DEVICES='0',
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
                for command in ([str(restart), str(binary), env['REDIWM_SOCKET']],
                                [str(configured_restart)]):
                    with IPCClient(env['REDIWM_SOCKET']) as previous:
                        assert previous.request(query='version')
                        staged = tmp / 'replacement'
                        shutil.copy2(source, staged)
                        staged.replace(binary)
                        assert os.readlink(f'/proc/{proc.pid}/exe').endswith(' (deleted)')
                        result = subprocess.run(command, env=env, capture_output=True, text=True, timeout=40)
                        assert result.returncode == 0, result.stdout + result.stderr
                        assert 'restarted successfully' in result.stdout, result.stdout
                        assert proc.poll() is None, 'login process exited'
                        assert Path(f'/proc/{proc.pid}/exe').stat().st_ino == binary.stat().st_ino
                        assert previous.sock.recv(1) == b'', 'old client connection survived restart'
                with IPCClient(env['REDIWM_SOCKET']) as ipc:
                    assert ipc.request(query='outputs'), 'output missing after restart'
                print('PASS: explicit and configured helper paths; two atomic replacements; PID preserved, IPC renewed, output available')
            except BaseException:
                log.flush()
                print((tmp / 'compositor.log').read_text())
                raise
            finally:
                stop_process(proc)


if __name__ == '__main__':
    run()

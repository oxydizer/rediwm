#!/usr/bin/env python3
"""Files dragged from a client onto the dock's Trash item are moved to the Trash, unasked.

A real wl_data_device source (tests/desktop_transfer.c) drags a URI list onto the
dock. `gio` is a stand-in on PATH (real trashing depends on the mount the temporary
directory is on) that logs its arguments, so the check is what the compositor ran.
"""
import os
import subprocess
import tempfile
import time
from pathlib import Path

from desktop_zoom import build_client, wait_for
from ipc_client import IPCClient, spawn_compositor, stop_process
from ui_driver import UIDriver

ROOT = Path(__file__).resolve().parents[1]


def run(auto_hide):
    scale = float(os.environ.get('REDIWM_TEST_SCALE', '1'))
    with tempfile.TemporaryDirectory(prefix='rediwm-dock-trash-drop-') as directory:
        tmp = Path(directory)
        build_client(tmp)
        sender_bin = tmp / 'transfer-client'
        subprocess.run(['cc', '-Wall', '-Wextra', f'-I{tmp}', str(ROOT / 'tests/desktop_transfer.c'),
                        str(tmp / 'xdg-shell-protocol.c'), str(tmp / 'xdg-decoration-protocol.c'),
                        '-lwayland-client', '-o', str(sender_bin)], check=True)
        trash = tmp / 'data/Trash/files'
        failure = tmp / 'fail-trash'
        calls = tmp / 'gio-calls'
        helpers = tmp / 'bin'
        helpers.mkdir()
        gio = helpers / 'gio'
        gio.write_text('#!/usr/bin/python3\n'
            'import pathlib, shutil, sys\n'
            f'pathlib.Path({str(calls)!r}).open("a").write(repr(sys.argv[1:]) + "\\n")\n'
            f'if pathlib.Path({str(failure)!r}).exists(): sys.exit(1)\n'
            f'dest = pathlib.Path({str(trash)!r})\n'
            'dest.mkdir(parents=True, exist_ok=True)\n'
            'assert sys.argv[1:3] == ["trash", "--"], sys.argv\n'
            'for path in sys.argv[3:]: shutil.move(path, dest / pathlib.Path(path).name)\n')
        gio.chmod(0o755)
        process, log = spawn_compositor(tmp, scale=scale, outputs='1',
            config_content='[compositor]\nxwayland = false\ndock_enabled = true\n'
                           f'dock_auto_hide = {"true" if auto_hide else "false"}\n[animations]\nenabled = false\n',
            env_extra={'DBUS_SESSION_BUS_ADDRESS': '', 'XDG_CONFIG_HOME': str(tmp / 'config'),
                       'XDG_DATA_HOME': str(tmp / 'data'), 'XDG_CACHE_HOME': str(tmp / 'cache'),
                       'PATH': f'{helpers}:{os.environ["PATH"]}'})
        senders = []
        try:
            with IPCClient(tmp) as ipc:
                ipc.wait_for('wallpaper_presented', timeout_ms=10000)
                ui = UIDriver(ipc)
                display = wait_for(lambda: next((p.name for p in tmp.glob('wayland-*') if not p.name.endswith('.lock')), None), 'display')

                def dock():
                    return ui.widgets('dock')

                def center(name):
                    b = next(w for w in dock() if w['name'] == name)['global_box']
                    return round(b['x'] + b['width'] / 2), round(b['y'] + b['height'] / 2)

                def drag_to(files, name, aim):
                    """Starts a drag of `files` from a fixture window, then `aim` moves the pointer and it is released."""
                    log_path = tmp / f'{name}.log'
                    with log_path.open('w') as sender_log:
                        sender = subprocess.Popen([str(sender_bin)], stdout=sender_log, stderr=sender_log,
                            env=dict(os.environ, XDG_RUNTIME_DIR=str(tmp), WAYLAND_DISPLAY=display,
                                     REDIWM_TEST_TRANSFER=''.join(f.as_uri() + '\r\n' for f in files)))
                    senders.append(sender)
                    window = wait_for(lambda: next(iter(ipc.get_windows()), None), 'sender window')
                    ipc.action('move_window_to', {'id': window['id'], 'x': 200, 'y': 150})
                    ipc.wait_for('window_geometry_settled', window_id=window['id'], timeout_ms=5000)
                    ipc.move_cursor(240, 240)
                    ipc.wait_for_frame()
                    ipc.pointer_button(0x110, True)
                    time.sleep(.15)
                    aim()
                    ipc.wait_for_frame()
                    ipc.pointer_button(0x110, False)
                    return sender, log_path

                def finish_sender(sender):
                    sender.terminate()
                    sender.wait()
                    wait_for(lambda: not ipc.get_windows(), 'sender window gone')

                def reach(name):
                    """Moves onto dock item `name`; an auto-hiding dock first needs the pointer at its edge."""
                    if auto_hide:
                        ipc.move_cursor(960, edge)
                        wait_for(lambda: any(w['name'] == name for w in dock()), 'dock revealed for the drag')
                    ipc.move_cursor(*center(name))

                edge = ipc.get_outputs()[0]['logical_height'] - 1
                if auto_hide:
                    # Away: nothing is built to aim at until the pointer reaches the edge.
                    assert not any(w['name'] for w in dock()), 'auto-hidden dock showed'
                else:
                    wait_for(lambda: any(w['name'] == 'trash' for w in dock()), 'dock Trash')

                # A drop on the Trash item moves every dropped file, without a dialog.
                first, second = tmp / 'Drop me.txt', tmp / 'and me #2.txt'
                first.write_text('one')
                second.write_text('two')
                sender, sender_log = drag_to([first, second], 'trash', lambda: reach('trash'))
                wait_for(lambda: 'transfer-finished' in sender_log.read_text(), 'the drag was not finished')
                assert not first.exists() and not second.exists(), 'dropped files were not moved'
                assert (trash / first.name).read_text() == 'one' and (trash / second.name).read_text() == 'two'
                assert eval(calls.read_text().splitlines()[-1]) == ['trash', '--', str(first), str(second)]
                finish_sender(sender)

                # Anywhere else on the dock a drop does nothing.
                keep = tmp / 'Keep me.txt'
                keep.write_text('kept')
                before = calls.read_text()
                sender, sender_log = drag_to([keep], 'elsewhere', lambda: reach('files'))
                time.sleep(.5)
                assert keep.exists() and calls.read_text() == before, 'a drop beside the Trash trashed a file'
                assert 'transfer-finished' not in sender_log.read_text()
                finish_sender(sender)

                # When gio fails the files stay where they are, and the source is told it was cancelled.
                failure.write_text('')
                sender, sender_log = drag_to([keep], 'failure', lambda: reach('trash'))
                wait_for(lambda: calls.read_text() != before, 'gio was not run')
                time.sleep(.3)
                assert keep.exists(), 'a failed trash moved the file'
                assert 'transfer-finished' not in sender_log.read_text()
                finish_sender(sender)
        finally:
            for sender in senders:
                stop_process(sender)
            stop_process(process)
            log.close()


if __name__ == '__main__':
    run(auto_hide=False)
    run(auto_hide=True)
    print('Dock Trash drops passed')

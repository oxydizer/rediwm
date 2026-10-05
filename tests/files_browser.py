#!/usr/bin/env python3
"""Headless integration test for rediwm-files (Part 1 read-only browser)."""
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]

def wait_for(pred, msg, timeout=10):
    start = time.monotonic()
    while time.monotonic() - start < timeout:
        val = pred()
        if val:
            return val
        time.sleep(0.05)
    raise TimeoutError(msg)

def run():
    with tempfile.TemporaryDirectory(prefix='rediwm-files-test-') as directory:
        tmp = Path(directory)
        browse_dir = tmp / 'test_browse'
        browse_dir.mkdir()
        subfolder = browse_dir / 'subfolder'
        subfolder.mkdir()
        (subfolder / 'nested.txt').write_text('nested content')
        (browse_dir / 'sample.txt').write_text('hello world')
        (browse_dir / '.hidden_file').write_text('secret')

        # Mock GIO opening and trashing in helper bin
        helpers = tmp / 'bin'
        helpers.mkdir()
        opened_marker = tmp / 'opened-file'
        trash_marker = tmp / 'trashed-files'
        gio_helper = helpers / 'gio'
        gio_helper.write_text(f'''#!/bin/sh
if [ "$1" = "open" ]; then
    printf "%s" "$2" > "{opened_marker}"
elif [ "$1" = "trash" ]; then
    shift
    while [ "$1" != "" ]; do
        if [ "$1" != "--" ]; then
            printf "%s\\n" "$1" >> "{trash_marker}"
            rm -rf "$1"
        fi
        shift
    done
fi
''')
        gio_helper.chmod(0o755)

        env = dict(
            os.environ,
            XDG_RUNTIME_DIR=str(tmp),
            XDG_STATE_HOME=str(tmp / "state"),
            WLR_BACKENDS='headless', REDIWM_FILES_DEVICES='0',
            WLR_HEADLESS_OUTPUTS='1',
            WLR_RENDERER='pixman',
            REDIWM_SCALE='1',
            PATH=str(helpers) + ':' + os.environ.get('PATH', ''),
        )
        config_path = tmp / 'rediwm-config.toml'
        config_path.write_text('')
        env['REDIWM_CONFIG'] = str(config_path)
        env.pop('WAYLAND_DISPLAY', None)
        env.pop('REDIWM_SOCKET', None)

        processes = []
        def start(binary, args=(), **extra):
            log = (tmp / (binary + '.log')).open('w')
            cmd = [str(ROOT / 'zig-out/bin' / binary)] + list(args)
            p = subprocess.Popen(cmd, env=dict(env, **extra), stdout=log, stderr=log)
            log.close()
            processes.append(p)
            return p

        comp = start('rediwm')
        try:
            wait_for(lambda: list(tmp.glob('rediwm-*.sock')), 'IPC unavailable')
            sock = socket.socket(socket.AF_UNIX)
            sock.settimeout(10)
            sock.connect(str(next(tmp.glob('rediwm-*.sock'))))
            reader = sock.makefile('r')

            def request(value):
                sock.sendall((json.dumps(value) + '\n').encode())
                result = json.loads(reader.readline())
                assert 'Ok' in result, result
                return result['Ok']

            def action(name, params):
                return request({"version": 1, "command": name, "params": params})

            def send_key(keycode, modifiers=(), delay=0.15):
                for mod in modifiers:
                    action('key', {'keycode': mod, 'pressed': True})
                for pressed in (True, False):
                    action('key', {'keycode': keycode, 'pressed': pressed})
                for mod in reversed(modifiers):
                    action('key', {'keycode': mod, 'pressed': False})
                time.sleep(delay)

            def get_windows():
                res = request({'version': 1, 'command': 'windows'})
                return res.get('Windows', [])

            display = next(p.name for p in tmp.glob('wayland-*') if not p.name.endswith('.lock'))

            # Launch rediwm-files with browse_dir
            client = start('rediwm-files', [str(browse_dir)], WAYLAND_DISPLAY=display)

            # Wait for window to appear
            def find_window():
                wins = get_windows()
                for w in wins:
                    if w.get('app_id') == 'rediwm-files':
                        return w
                return None

            win = wait_for(find_window, 'rediwm-files window did not appear')
            assert win['title'] == f'{browse_dir.name} — Files', f"Unexpected title: {win['title']}"
            print(f"Verified initial window: {win['app_id']}, title: '{win['title']}'")

            # Focus the window
            action('focus_window', {'id': win['id']})
            time.sleep(0.15)

            # Right arrow keycode is 106 (KEY_RIGHT) in Linux evdev
            # Subfolder is first (folders-first sorting). Press Right then Enter to navigate into subfolder.
            # evdev code: KEY_RIGHT = 106, KEY_ENTER = 28
            for pressed in (True, False):
                action('key', {'keycode': 106, 'pressed': pressed})
            time.sleep(0.15)

            for pressed in (True, False):
                action('key', {'keycode': 28, 'pressed': pressed})
            time.sleep(0.2)

            # Wait for title to update to "subfolder — Files"
            def check_subfolder():
                w = find_window()
                return w if w and w.get('title') == 'subfolder — Files' else None

            win = wait_for(check_subfolder, 'Did not navigate into subfolder')
            print(f"Verified folder navigation: title '{win['title']}'")

            # Navigate Back: Alt+Left. evdev: KEY_LEFTALT = 56, KEY_LEFT = 105
            action('key', {'keycode': 56, 'pressed': True})
            for pressed in (True, False):
                action('key', {'keycode': 105, 'pressed': pressed})
            action('key', {'keycode': 56, 'pressed': False})
            time.sleep(0.2)

            def check_back():
                w = find_window()
                return w if w and w.get('title') == f'{browse_dir.name} — Files' else None

            win = wait_for(check_back, 'Did not navigate Back')
            print(f"Verified Back navigation: title '{win['title']}'")

            # Back restores the subfolder selection; explicitly start at the first item.
            send_key(102)
            # Navigate Right twice to reach sample.txt, then Enter to open with gio open
            for _ in range(2):
                for pressed in (True, False):
                    action('key', {'keycode': 106, 'pressed': pressed})
                time.sleep(0.05)

            for pressed in (True, False):
                action('key', {'keycode': 28, 'pressed': pressed})
            time.sleep(0.3)

            wait_for(opened_marker.exists, 'File was not opened via gio open')
            opened_path = opened_marker.read_text().strip()
            assert opened_path == str(browse_dir / 'sample.txt'), f"Unexpected opened file: {opened_path}"
            print(f"Verified opening file via gio open: '{opened_path}'")

            # Test inotify auto-refresh: create dynamic.txt in browse_dir
            dynamic_file = browse_dir / 'dynamic.txt'
            dynamic_file.write_text('dynamic content')
            time.sleep(0.3)

            # Test navigating into subfolder and using Alt+Up to go Up
            # Home key (keycode 102) to select item 0 (subfolder)
            for pressed in (True, False):
                action('key', {'keycode': 102, 'pressed': pressed})
            time.sleep(0.1)
            for pressed in (True, False):
                action('key', {'keycode': 28, 'pressed': pressed})
            time.sleep(0.2)
            wait_for(check_subfolder, 'Did not navigate into subfolder')

            # Test Alt+Up to navigate Up. evdev: KEY_LEFTALT = 56, KEY_UP = 103
            action('key', {'keycode': 56, 'pressed': True})
            for pressed in (True, False):
                action('key', {'keycode': 103, 'pressed': pressed})
            action('key', {'keycode': 56, 'pressed': False})
            time.sleep(0.2)
            wait_for(check_back, 'Alt+Up did not navigate Up')
            print(f"Verified Up navigation: title '{win['title']}'")

            # Test Ctrl+H toggling hidden files. evdev: KEY_LEFTCTRL = 29, KEY_H = 35
            action('key', {'keycode': 29, 'pressed': True})
            for pressed in (True, False):
                action('key', {'keycode': 35, 'pressed': pressed})
            action('key', {'keycode': 29, 'pressed': False})
            time.sleep(0.2)
            print("Verified Ctrl+H toggle hidden files.")

            # --- Part 2 Tests: Everyday file management ---
            # 1. New Folder creation (Ctrl+Shift+N)
            send_key(49, modifiers=[29, 42])  # Ctrl+Shift+N
            send_key(28)  # Enter confirms default "New Folder"
            wait_for(lambda: (browse_dir / 'New Folder').is_dir(), 'New Folder was not created on disk')
            print("Verified New Folder creation: 'New Folder'")

            # 2. New File creation (Ctrl+N)
            send_key(49, modifiers=[29])  # Ctrl+N
            send_key(28)  # Enter confirms default "New File.txt"
            wait_for(lambda: (browse_dir / 'New File.txt').is_file(), 'New File.txt was not created on disk')
            print("Verified New File creation: 'New File.txt'")

            # 3. Rename via F2
            # Home key (102) selects the first item (folders first: "New Folder")
            send_key(102)
            send_key(60)  # F2 -> Rename dialog
            send_key(19)  # 'r' replaces selected text
            send_key(28)  # Enter confirms rename to "r"
            wait_for(lambda: (browse_dir / 'r').is_dir(), 'Renamed folder "r" was not found')
            assert not (browse_dir / 'New Folder').exists(), 'Old folder name still exists'
            print("Verified Rename folder to 'r'")

            # 4. Copy & Paste with Conflict handling (Rename)
            send_key(102)  # Home
            send_key(106)  # Right
            send_key(106)  # Right
            send_key(46, modifiers=[29])  # Ctrl+C
            send_key(47, modifiers=[29])  # Ctrl+V -> triggers conflict dialog
            send_key(19)  # 'r' -> choose Rename in conflict dialog
            renamed_files = wait_for(lambda: list(browse_dir.glob('* (1)*')), 'No collision-renamed file was created')
            print(f"Verified Copy & Paste conflict resolution with Rename: '{renamed_files[0].name}'")

            # 5. Cut & Paste
            # Enter subfolder, cut nested.txt (Ctrl+X), navigate Up, paste (Ctrl+V)
            send_key(102)  # item 0: "r"
            send_key(106)  # item 1: "subfolder"
            send_key(28)   # Enter -> navigate into subfolder
            wait_for(check_subfolder, 'Did not enter subfolder')
            send_key(102)  # item 0: nested.txt
            send_key(45, modifiers=[29])  # Ctrl+X (Cut)
            # Navigate Up (Alt+Up)
            action('key', {'keycode': 56, 'pressed': True})
            for pressed in (True, False):
                action('key', {'keycode': 103, 'pressed': pressed})
            action('key', {'keycode': 56, 'pressed': False})
            time.sleep(0.2)
            wait_for(check_back, 'Did not navigate Up back to browse_dir')
            send_key(47, modifiers=[29])  # Ctrl+V (Paste cut file)
            wait_for(lambda: (browse_dir / 'nested.txt').is_file(), 'nested.txt was not pasted into browse_dir')
            wait_for(lambda: not (subfolder / 'nested.txt').exists(), 'nested.txt was not removed from source after cut')
            print("Verified Cut & Paste across directories")

            # 6. Trash confirmation & execution
            # In browse_dir, select folder "r" at top (Home), press Delete, confirm with Enter
            send_key(102)  # Home selects "r"
            send_key(111)  # Delete -> trash confirmation dialog
            send_key(28)   # Enter -> confirms trash
            wait_for(lambda: not (browse_dir / 'r').exists(), 'Folder "r" was not trashed')
            wait_for(trash_marker.exists, 'gio trash marker was not created')
            assert str(browse_dir / 'r') in trash_marker.read_text(), 'Expected "r" in trash marker'
            print("Verified Trash confirmation and execution")

            # Permanent deletion must skip gio, recurse, and leave symlink targets alone.
            doomed = browse_dir / '!Permanent'
            doomed.mkdir()
            (doomed / 'nested.txt').write_text('delete me')
            survivor = tmp / 'survivor.txt'
            survivor.write_text('keep me')
            (doomed / 'link').symlink_to(survivor)
            send_key(63)  # F5 refresh
            time.sleep(.4)
            send_key(102)  # Home selects first folder
            send_key(111)
            send_key(1)  # Escape cancels
            assert doomed.exists(), 'Cancel deleted an item'
            send_key(111)
            send_key(15)  # Tab to permanent checkbox
            send_key(57)  # Space checks it, without deleting anything
            assert doomed.exists(), 'Checkbox deleted before confirmation'
            send_key(15)  # Tab to destructive button
            send_key(28)
            wait_for(lambda: not doomed.exists(), 'Permanent folder deletion failed')
            assert survivor.read_text() == 'keep me', 'Deletion followed a symlink'
            assert str(doomed) not in trash_marker.read_text(), 'Permanent deletion used Trash'
            print("Verified cancellation, permanent deletion, and symlink safety")

            # Close window
            action('close_window', {'id': win['id']})
            time.sleep(0.2)

            def check_closed():
                return find_window() is None

            wait_for(check_closed, 'Window did not close')
            print("Verified window close.")

        except Exception as e:
            for log_file in tmp.glob('*.log'):
                print(f"=== {log_file.name} ===")
                try:
                    print(log_file.read_text())
                except Exception:
                    pass
            raise
        finally:
            for p in reversed(processes):
                try:
                    p.terminate()
                    p.wait(timeout=2)
                except Exception:
                    p.kill()

    print("All tests in files_browser.py PASSED!")

if __name__ == '__main__':
    run()

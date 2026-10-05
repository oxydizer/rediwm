#!/usr/bin/env python3
"""Headless integration test for rediwm-files' self-decorated (CSD) fallback.

rediwm-files normally lets the compositor draw its window decorations via
zxdg_decoration_manager_v1 (see plan-file-manager.md section 1). On a
compositor that doesn't implement that protocol -- GNOME/Mutter is the
common real-world case -- it must draw its own titlebar instead, or the
window would have no way to move or close.

REDIWM_FILES_FORCE_CSD makes the client skip decoration negotiation, like an
application using GTK header bars. The compositor must leave that window
unframed, and its own titlebar must still support dragging and closing.
"""
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]

# Must match CSD_TITLEBAR_H in src/files/main.zig.
CSD_TITLEBAR_H = 32

def wait_for(pred, msg, timeout=10):
    start = time.monotonic()
    while time.monotonic() - start < timeout:
        val = pred()
        if val:
            return val
        time.sleep(0.05)
    raise TimeoutError(msg)

def run():
    with tempfile.TemporaryDirectory(prefix='rediwm-files-decoration-test-') as directory:
        tmp = Path(directory)
        browse_dir = tmp / 'browse'
        browse_dir.mkdir()
        (browse_dir / 'a.txt').write_text('hi')

        env = dict(
            os.environ,
            XDG_RUNTIME_DIR=str(tmp),
            XDG_STATE_HOME=str(tmp / "state"),
            WLR_BACKENDS='headless', REDIWM_FILES_DEVICES='0',
            WLR_HEADLESS_OUTPUTS='1',
            WLR_RENDERER='pixman',
            REDIWM_SCALE='1',
            PATH=os.environ.get('PATH', ''),
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

            def action(name, params=None):
                return request({"version": 1, "command": name, "params": params or {}})

            def click(x, y):
                request({"version": 1, "command": 'move_cursor', "params": {'x': x, 'y': y}})
                time.sleep(0.1)
                request({'version': 1, 'command': 'pointer_button', 'params': {'button': 272, 'pressed': True}})
                time.sleep(0.05)
                request({'version': 1, 'command': 'pointer_button', 'params': {'button': 272, 'pressed': False}})
                time.sleep(0.2)

            def get_windows():
                return request({'version': 1, 'command': 'windows'}).get('Windows', [])

            def find_window():
                for w in get_windows():
                    if w.get('app_id') == 'rediwm-files':
                        return w
                return None

            display = next(p.name for p in tmp.glob('wayland-*') if not p.name.endswith('.lock'))

            # --- Baseline: normal SSD window, and the negative control ---
            baseline = start('rediwm-files', [str(browse_dir)], WAYLAND_DISPLAY=display)
            win_ssd = wait_for(find_window, 'rediwm-files (SSD) window did not appear')
            print(f"SSD geometry: w={win_ssd['width']} h={win_ssd['height']}")

            compositor_chrome_top = win_ssd['height'] - 540  # rediwm's own titlebar+footer
            probe_x = win_ssd['x'] + win_ssd['width'] - 17
            probe_y = win_ssd['y'] + compositor_chrome_top + 16

            action('focus_window', {'id': win_ssd['id']})
            time.sleep(0.1)
            click(probe_x, probe_y)
            assert find_window() is not None, (
                'negative control failed: clicking just below the compositor chrome '
                'closed the SSD window, so the same click closing the CSD window '
                "below wouldn't prove rediwm-files drew its own titlebar there"
            )
            print('Verified negative control: same click position leaves the SSD window open.')

            action('close_window', {'id': win_ssd['id']})
            wait_for(lambda: find_window() is None, 'SSD window did not close')
            baseline.wait(timeout=2)
            processes.remove(baseline)

            # --- Force the self-decorated (CSD) path ---
            start('rediwm-files', [str(browse_dir)], WAYLAND_DISPLAY=display, REDIWM_FILES_FORCE_CSD='1')

            win = wait_for(find_window, 'rediwm-files (CSD) window did not appear')
            print(f"CSD geometry: x={win['x']} y={win['y']} w={win['width']} h={win['height']}")
            assert win['width'] == 960, win
            assert win_ssd['width'] > win['width'], (win, win_ssd)
            assert win['height'] == 540 + CSD_TITLEBAR_H, win
            print('Verified CSD geometry contains no compositor frame.')

            action('focus_window', {'id': win['id']})
            time.sleep(0.15)

            # Drag the titlebar body (clear of the close button) and confirm
            # the window actually moves: proves the CSD titlebar forwards
            # xdg_toplevel.move() to the compositor on press.
            drag_from_x = win['x'] + 100
            drag_from_y = win['y'] + 16
            request({"version": 1, "command": 'drag', "params": {
                'from_x': drag_from_x, 'from_y': drag_from_y,
                'to_x': drag_from_x + 40, 'to_y': drag_from_y + 30,
            }})

            def moved():
                w = find_window()
                if w is not None and (w['x'], w['y']) != (win['x'], win['y']):
                    return w
                return None

            win = wait_for(moved, 'CSD titlebar drag did not move the window')
            print(f"Verified CSD titlebar drag moves the window (now at {win['x']},{win['y']}).")

            # Click the client's close button with no compositor offset.
            close_x = win['x'] + win['width'] - 17
            close_y = win['y'] + 16
            click(close_x, close_y)
            wait_for(lambda: find_window() is None, 'CSD close button did not close the window')
            print('Verified CSD close button closes the window.')

        except Exception:
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

    print("All tests in files_decoration.py PASSED!")

if __name__ == '__main__':
    run()

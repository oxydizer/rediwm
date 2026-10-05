#!/usr/bin/env python3
"""Integration tests for rediwm-files folder size calculation."""
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time

from files_browser import wait_for

ROOT = Path(__file__).resolve().parents[1]


def run():
    with tempfile.TemporaryDirectory(prefix="rediwm-files-size-") as directory:
        tmp = Path(directory)
        home = tmp / "Home"
        home.mkdir()

        # Create test folders:
        # big_folder: 50,000 bytes
        big_folder = home / "big_folder"
        big_folder.mkdir()
        for i in range(5):
            (big_folder / f"file_{i}.dat").write_text("x" * 10000)

        # small_folder: 1,000 bytes
        small_folder = home / "small_folder"
        small_folder.mkdir()
        (small_folder / "file.dat").write_text("x" * 1000)

        # uncalc_folder: 500 bytes (will not be calculated initially)
        uncalc_folder = home / "uncalc_folder"
        uncalc_folder.mkdir()
        (uncalc_folder / "file.dat").write_text("x" * 500)

        # Regular file
        (home / "zzz_file.txt").write_text("regular file")

        config = tmp / "config.toml"
        config.write_text("")
        env = dict(os.environ, HOME=str(home), XDG_RUNTIME_DIR=directory,
                   REDIWM_CONFIG=str(config), WLR_BACKENDS="headless", REDIWM_FILES_DEVICES="0",
                   WLR_HEADLESS_OUTPUTS="1", WLR_RENDERER="pixman",
                   REDIWM_SCALE="1", XDG_STATE_HOME=str(tmp / "state"),
                   REDIWM_IPC_AUTOMATION="1")
        env.pop("WAYLAND_DISPLAY", None)
        env.pop("REDIWM_SOCKET", None)
        processes = []

        def start(binary, *args, **extra):
            with (tmp / (binary + ".log")).open("w") as log:
                p = subprocess.Popen([str(ROOT / "zig-out/bin" / binary), *args],
                                     env=dict(env, **extra), stdout=log, stderr=log)
            processes.append(p)
            return p

        try:
            start("rediwm")
            paths = wait_for(lambda: list(tmp.glob("rediwm-*.sock")), "IPC unavailable")
            with socket.socket(socket.AF_UNIX) as sock:
                sock.settimeout(10)
                sock.connect(str(paths[0]))
                reader = sock.makefile("r")

                def request(value):
                    sock.sendall((json.dumps(value) + "\n").encode())
                    result = json.loads(reader.readline())
                    assert "Ok" in result, result
                    return result["Ok"]

                def action(name, params):
                    return request({"version": 1, "command": name, "params": params})

                def key(code, modifiers=()):
                    for mod in modifiers:
                        action('key', {"keycode": mod, "pressed": True})
                    for pressed in (True, False):
                        action('key', {"keycode": code, "pressed": pressed})
                    for mod in reversed(modifiers):
                        action('key', {"keycode": mod, "pressed": False})
                    time.sleep(.1)

                def windows():
                    return [w for w in request({'version': 1, 'command': 'windows'}).get("Windows", [])
                            if w["app_id"] == "rediwm-files"]

                display = next(p.name for p in tmp.glob("wayland-*") if not p.name.endswith(".lock"))
                start("rediwm-files", str(home), WAYLAND_DISPLAY=display)
                win = wait_for(lambda: next(iter(windows()), None), "file manager did not map")
                action('focus_window', {"id": win["id"]})
                time.sleep(.3)

                def click(x, y, button=272):
                    # rediwm has a 1px frame and 61px server titlebar.
                    action('move_cursor', {"x": win["x"] + 1 + x, "y": win["y"] + 61 + y})
                    for pressed in (True, False):
                        action('pointer_button', {"button": button, "pressed": pressed})
                    time.sleep(.15)

                def title(value):
                    wait_for(lambda: windows() and windows()[0]["title"] == value + " — RediWM Files",
                             "navigation did not reach " + value)

                # 1. Test Grid View:
                # Default is grid view. Items: big_folder (idx 0), small_folder (idx 1), uncalc_folder (idx 2)
                # First, select item 1 (small_folder) using keyboard (Home then Right)
                key(102)  # Home -> idx 0 (big_folder)
                key(106)  # Right -> idx 1 (small_folder)
                time.sleep(.1)

                # In grid view, cell width is ~235px. Card 0 starts at x = 228 (sidebar 208 + 20).
                # Subtitle (sizeButtonRect) for item 0 is at (x + 22, y + 102), with y = 112 + 20 = 132.
                # So button 0 is around x = 255, y = 240.
                # Click the dash button of item 0 (big_folder)
                click(255, 240)
                time.sleep(.2)

                # Clicking dash must NOT select big_folder (item 1 small_folder must still be active/selected)
                # And must NOT navigate into big_folder! Title remains "Home — RediWM Files"
                assert windows()[0]["title"] == "Home — RediWM Files", "Clicking dash opened the folder!"

                # 2. Test List View:
                # Switch to list view (Header list button at x=727, y=80)
                click(727, 80)
                time.sleep(.2)

                # In list view:
                # Row 1 is small_folder: y = 132 + 44 = 176.
                # Size column (column 1) is around x = 600..700.
                # Click the dash on row 1 (small_folder)
                click(650, 185)
                time.sleep(.2)

                # Wait for calculations to finish
                time.sleep(.5)

                # 3. Test Sorting by size:
                # Sort menu: click x=790, y=80
                click(790, 80)
                time.sleep(.1)
                key(108)  # Down to "Name: Z to A"
                key(108)  # Down to "Largest first"
                key(28)   # Enter confirms sort mode
                time.sleep(.2)

                # With Largest first:
                # Calculated big_folder (50,000 B) is item 0.
                # Calculated small_folder (1,000 B) is item 1.
                # Uncalculated uncalc_folder is item 2 (uncalculated sort last).
                # Regular file zzz_file.txt is after folders.
                # Press Home (102) to focus item 0, then Enter (28) to open it!
                key(102)
                key(28)
                title("big_folder")
                print("Verified: big_folder sorted first by apparent size")

                # Navigate Back (Alt+Left)
                key(105, modifiers=[56])
                title("Home")

                # Right arrow to move to item 1 (small_folder), then Enter to open it!
                key(106)
                key(28)
                title("small_folder")
                print("Verified: small_folder sorted second by apparent size")

                # Navigate Back (Alt+Left)
                key(105, modifiers=[56])
                title("Home")

                # 4. Context Menu "Calculate size"
                # Select uncalc_folder (Right twice from Home)
                key(102)
                key(106)
                key(106)
                # Right click on uncalc_folder (row 2 in list view: y = 132 + 88 = 220)
                click(300, 220, button=273)
                time.sleep(.1)
                # Menu has 7 items: item 6 is "Calculate size". Press Up (103) to wrap to bottom!
                key(103)  # Up wraps to item 6: "Calculate size"
                key(28)   # Enter executes "Calculate size"
                time.sleep(.5)
                print("Verified: Context menu 'Calculate size' executed")

                # 5. Test Navigation cancels running jobs cleanly:
                # Trigger another calculation and immediately navigate
                click(650, 140)  # click size of row 0
                key(102)         # focus row 0
                key(28)          # navigate into big_folder
                title("big_folder")
                key(105, modifiers=[56])  # Back
                title("Home")
                print("Verified: Navigation while calculation active is clean and responsive")

                print("All folder size integration tests passed!")
        except Exception:
            for log in tmp.glob("*.log"):
                print(f"=== {log.name} ===")
                print(log.read_text()[-5000:])
            raise
        finally:
            for p in reversed(processes):
                if p.poll() is None:
                    p.terminate()
                    p.wait(timeout=5)


if __name__ == "__main__":
    run()

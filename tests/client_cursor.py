"""Shared real-client cursor transition checks (Files and Images)."""
import re
import time


def assert_enter_serials(log):
    serial = None
    count = 0
    for line in log.read_text().splitlines():
        enter = re.search(r"wl_pointer#\d+\.enter\((\d+),", line)
        if enter:
            serial = int(enter[1])
        cursor = re.search(r"(?:wl_pointer#\d+\.set_cursor|wp_cursor_shape_device_v1#\d+\.set_shape)\((\d+),", line)
        if cursor:
            assert int(cursor[1]) == serial, ("cursor used a button/stale serial", line, serial)
            count += 1
    return count


def exercise_csd(ipc, win, log):
    def move(x, y):
        box = ipc.get_window_debug(win["id"])["client_box"]
        ipc.move_cursor(box["x"] + x, box["y"] + y)
        time.sleep(.12)

    # Click changes the button serial without generating another pointer enter.
    move(150, 180)
    for pressed in (True, False):
        ipc.action('pointer_button', {"button": 272, "pressed": pressed})
    before = assert_enter_serials(log)
    move(2, 140)
    move(150, 180)
    assert assert_enter_serials(log) >= before + 2, "edge/content cursor was not restored"
    # A compositor resize grab clears pointer focus; release must restore it.
    move(2, 140)
    for pressed in (True, False):
        ipc.action('pointer_button', {"button": 272, "pressed": pressed})
    move(150, 180)
    assert_enter_serials(log)
    assert "wp_cursor_shape_device_v1" in log.read_text(), "client bypassed compositor cursor theme"


def exercise_files_text(ipc, win, log):
    box = ipc.get_window_debug(win["id"])["client_box"]
    def shape(expected):
        time.sleep(.15)
        shapes = re.findall(r"wp_cursor_shape_device_v1#\d+\.set_shape\(\d+, (\d+)\)", log.read_text())
        assert shapes and int(shapes[-1]) == expected, (expected, shapes[-5:])
        assert_enter_serials(log)

    ipc.move_cursor(box["x"] + 200, box["y"] + 32 + 20)
    shape(9)  # text, including before the address bar has focus
    for pressed in (True, False):
        ipc.action('pointer_button', {"button": 272, "pressed": pressed})
    shape(9)
    # Leave address editing without moving the pointer, then open a dialog.
    for pressed in (True, False):
        ipc.action('key', {"keycode": 1, "pressed": pressed})
    shape(9)
    # Opening/closing a dialog updates the stationary pointer too.
    for key, pressed in ((29, True), (42, True), (49, True), (49, False), (42, False), (29, False)):
        ipc.action('key', {"keycode": key, "pressed": pressed})
    shape(1)
    # The new-folder field uses the same text cursor.
    ipc.move_cursor(box["x"] + box["width"] // 2,
                    box["y"] + 32 + (box["height"] - 32 - 130) // 2 + 52)
    shape(9)
    for pressed in (True, False):
        ipc.action('key', {"keycode": 1, "pressed": pressed})
    shape(1)


def run():
    import os
    from pathlib import Path
    import shutil
    import struct
    import subprocess
    import tempfile
    from PIL import Image
    from cursor_shape import build_theme
    from desktop_zoom import ROOT, wait_for
    from ipc_client import IPCClient, spawn_compositor, stop_process

    with tempfile.TemporaryDirectory(prefix="rediwm-client-cursor-") as directory:
        tmp = Path(directory)
        build_theme(tmp)
        shutil.copytree(tmp / "icons/default", tmp / "icons/selected")
        for path in (tmp / "icons/selected/cursors").iterdir():
            path.write_bytes(path.read_bytes()[:-4096] + struct.pack("<I", 0xff00ff00) * 1024)
        config = '[compositor]\nxwayland = false\n[input]\ncursor_theme = "default"\n'
        compositor, comp_log = spawn_compositor(
            tmp, config_content=config,
            env_extra={"XCURSOR_PATH": str(tmp / "icons"), "XCURSOR_THEME": "default"})
        client = None
        try:
            with IPCClient(tmp) as ipc:
                display = next(p.name for p in tmp.glob("wayland-*") if not p.name.endswith(".lock"))
                log = tmp / "files.log"
                with log.open("w") as output:
                    client = subprocess.Popen(
                        [str(ROOT / "zig-out/bin/rediwm-files"), str(tmp)],
                        env=dict(os.environ, XDG_RUNTIME_DIR=str(tmp), WAYLAND_DISPLAY=display,
                                 WAYLAND_DEBUG="client", REDIWM_FILES_FORCE_CSD="1",
                                 REDIWM_FILES_DEVICES="0"),
                        stdout=output, stderr=output)
                win = wait_for(lambda: next(iter(ipc.get_windows()), None), "Files did not map")
                ipc.focus_window(win["id"])
                time.sleep(.3)
                exercise_csd(ipc, win, log)
                exercise_files_text(ipc, win, log)
                box = ipc.get_window_debug(win["id"])["client_box"]

                def pixels(x, y, colour):
                    ipc.move_cursor(x, y)
                    time.sleep(.12)
                    shot = tmp / "cursor.png"
                    subprocess.run(["grim", "-c", str(shot)], check=True,
                                   env=dict(os.environ, XDG_RUNTIME_DIR=str(tmp), WAYLAND_DISPLAY=display))
                    with Image.open(shot) as image:
                        assert image.convert("RGB").getpixel((int(x) + 8, int(y) + 8)) == colour

                # The system arrow must come from Xcursor, including over Files.
                pixels(20, 20, (255, 255, 255))
                pixels(box["x"] + 150, box["y"] + 180, (255, 255, 255))
                (tmp / "rediwm-config.toml").write_text(config.replace('"default"', '"selected"'))
                ipc.reload_config()
                # Already-open clients follow a live theme change.
                pixels(box["x"] + 150, box["y"] + 180, (0, 255, 0))
                pixels(20, 20, (0, 255, 0))
        finally:
            if client is not None:
                stop_process(client)
            stop_process(compositor)
            comp_log.close()
    print("PASS: themed shell/Files cursor pixels, live reload and CSD serials")


if __name__ == "__main__":
    run()

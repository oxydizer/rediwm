#!/usr/bin/env python3
"""Cursors over compositor-drawn UI: the text cursor over shell text fields,
the grab cursor while a window moves, the crosshair while picking a
screenshot region, and the arrow everywhere else."""
from pathlib import Path
import subprocess
import tempfile

from desktop_zoom import build_client, wait_for
from ipc_client import IPCClient, spawn_compositor, stop_process


def centre(box):
    return box["x"] + box["width"] // 2, box["y"] + box["height"] // 2


def run():
    with tempfile.TemporaryDirectory(prefix="rediwm-shell-cursors-") as directory:
        tmp = Path(directory)
        build_client(tmp)
        proc, log = spawn_compositor(
            tmp, config_content='[input]\ncursor_theme = "phinger-cursors-dark"\n[compositor]\nxwayland = false\n',
            env_extra={"XDG_CACHE_HOME": str(tmp / "cache")})
        client = None
        try:
            with IPCClient(tmp) as ipc:
                def state():
                    s = ipc.get_input_state()
                    return s["cursor_source"], s["cursor_name"]

                # Start menu: I-beam over the search field, arrow over the rest.
                ipc.open_start_menu()
                ipc.wait_for_panel_settled("start_menu")
                widgets = {w["path"]: w for w in ipc.get_widget_tree("start_menu")["widgets"] if w["path"]}
                ipc.move_cursor(*centre(widgets["start_menu/search/search_input"]["global_box"]))
                assert state() == ("theme", "text"), ipc.get_input_state()
                ipc.move_cursor(*centre(widgets["start_menu/categories/all"]["global_box"]))
                assert state() == ("default", "default"), ipc.get_input_state()
                ipc.close_panel("start_menu")
                wait_for(lambda: ipc.hit_test(*centre(widgets["start_menu/search/search_input"]["global_box"]))
                         .get("target_type") != "start_menu", "start menu did not close")

                # Titlebar drag: grabbing while held, arrow again on release.
                display = next(p.name for p in tmp.glob("wayland-*") if not p.name.endswith(".lock"))
                client = subprocess.Popen([str(tmp / "client"), "--app-id", "mover"],
                                          env={"XDG_RUNTIME_DIR": str(tmp), "WAYLAND_DISPLAY": display},
                                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                win = wait_for(lambda: next((w for w in ipc.get_windows() if w["app_id"] == "mover"), None), "window did not map")
                x = win["x"] + win["width"] // 2
                # Window y is the frame top; the titlebar starts there.
                y = win["y"] + 15
                assert ipc.hit_test(x, y).get("widget") == "titlebar", ipc.hit_test(x, y)
                ipc.move_cursor(x, y)
                assert state() == ("default", "default"), ipc.get_input_state()
                ipc.pointer_button(0x110, True)
                ipc.move_cursor(x + 60, y + 40)
                assert state() == ("theme", "grabbing"), ipc.get_input_state()
                ipc.pointer_button(0x110, False)
                assert state() == ("default", "default"), ipc.get_input_state()

                # Region screenshot picker: crosshair, arrow after Escape.
                ipc.key(29, True)
                ipc.key(42, True)
                ipc.key_down_up(31)
                ipc.key(42, False)
                ipc.key(29, False)
                wait_for(lambda: state() == ("theme", "crosshair"), "picker did not show the crosshair")
                ipc.key_press("Escape")
                assert state() == ("default", "default"), ipc.get_input_state()
            stop_process(proc)
            assert proc.returncode == 0, (tmp / "compositor.log").read_text()
        finally:
            if client:
                client.kill()
            if proc.poll() is None:
                stop_process(proc)
            log.close()
    print("PASS: text field, window move and screenshot picker cursors")


if __name__ == "__main__":
    run()

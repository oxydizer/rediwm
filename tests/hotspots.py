#!/usr/bin/env python3
"""Integration tests for Phase 5 non-widget hotspots (taskbar and window controls).

Tests:
1. list_panels includes the taskbar panel with bounding box.
2. get_widget_tree("taskbar") exposes taskbar/start, taskbar/clock, taskbar/tray/0, and taskbar/window/<id>.
3. get_widget_tree("window/<id>") exposes titlebar, close, maximize, and minimize buttons.
4. Clicking window/<id>/maximize toggles maximized state.
5. Clicking window/<id>/minimize minimizes the window.
6. Clicking taskbar/window/<id> restores and focuses the window.
7. Clicking window/<id>/close closes the window and verifies disappearance via wait_for conditions.
"""
import os
from pathlib import Path
import subprocess
import tempfile
import time

from desktop_zoom import build_client, wait_for
from ipc_client import IPCClient, spawn_compositor, stop_process
from ui_driver import UIDriver

ROOT = Path(__file__).resolve().parents[1]


def run():
    with tempfile.TemporaryDirectory(prefix="rediwm-hotspots-") as directory:
        tmp = Path(directory)
        build_client(tmp)
        process, log = spawn_compositor(tmp, config_content="[compositor]\n")
        client_proc = None
        try:
            with IPCClient(tmp, timeout=15) as ipc:
                ipc.wait_for("wallpaper_presented", timeout_ms=10000)
                ipc.wait_for("catalog_published", timeout_ms=10000)
                ui = UIDriver(ipc)

                # 1. list_panels includes taskbar
                panels = ipc.list_panels().get("panels", [])
                taskbar_panel = next((p for p in panels if p.get("name") == "taskbar"), None)
                assert taskbar_panel is not None, f"taskbar not found in panels: {panels}"
                assert taskbar_panel.get("open") is True, f"taskbar not open: {taskbar_panel}"
                assert taskbar_panel.get("box", {}).get("height", 0) > 0, f"taskbar invalid box: {taskbar_panel}"
                print("PASS: list_panels reports taskbar with geometry", flush=True)

                # 2. get_widget_tree("taskbar") contains start, clock, tray
                tb_tree = ipc.get_widget_tree("taskbar")
                assert tb_tree.get("panel") == "taskbar", tb_tree
                tb_widgets = tb_tree.get("widgets", [])

                start_w = next((w for w in tb_widgets if w.get("path") == "taskbar/start"), None)
                assert start_w is not None, f"taskbar/start not found in {tb_widgets}"
                assert start_w.get("role") == "button"
                assert start_w.get("global_box", {}).get("width", 0) > 0

                clock_w = next((w for w in tb_widgets if w.get("path") == "taskbar/clock"), None)
                assert clock_w is not None, f"taskbar/clock not found in {tb_widgets}"

                tray_w = next((w for w in tb_widgets if w.get("path") == "taskbar/tray/0"), None)
                assert tray_w is not None, f"taskbar/tray/0 not found in {tb_widgets}"
                print("PASS: get_widget_tree('taskbar') exposes virtual start, clock, and tray hotspots", flush=True)

                # 3. Launch a client window
                display = next(p.name for p in tmp.glob("wayland-*") if not p.name.endswith(".lock"))
                env = dict(
                    os.environ,
                    XDG_RUNTIME_DIR=str(tmp),
                    WAYLAND_DISPLAY=display,
                    REDIWM_TEST_DECORATION="server",
                )
                client_proc = subprocess.Popen([str(tmp / "client")], env=env)

                # 4. Wait for window to map and appear in taskbar
                win = wait_for(
                    lambda: next(iter(ipc.get_windows()), None),
                    "window did not map",
                    timeout=10,
                )
                win_id = win["id"]

                # Wait for taskbar chip via WaitFor widget_present
                chip_path = f"taskbar/window/{win_id}"
                ipc.wait_for_widget_present(chip_path, timeout_ms=5000)
                print(f"PASS: taskbar chip virtual node present: {chip_path}", flush=True)

                # 5. Query window widget tree
                win_tree = ipc.get_widget_tree(f"window/{win_id}")
                assert win_tree.get("panel") == f"window/{win_id}", win_tree
                w_widgets = win_tree.get("widgets", [])

                win_root = next((w for w in w_widgets if w.get("path") == f"window/{win_id}"), None)
                assert win_root is not None
                assert win_root.get("role") == "window"

                tb_node = next((w for w in w_widgets if w.get("path") == f"window/{win_id}/titlebar"), None)
                assert tb_node is not None
                assert tb_node.get("role") == "titlebar"

                close_btn = next((w for w in w_widgets if w.get("path") == f"window/{win_id}/close"), None)
                assert close_btn is not None
                assert close_btn.get("role") == "button"

                max_btn = next((w for w in w_widgets if w.get("path") == f"window/{win_id}/maximize"), None)
                assert max_btn is not None
                assert max_btn.get("role") == "button"

                min_btn = next((w for w in w_widgets if w.get("path") == f"window/{win_id}/minimize"), None)
                assert min_btn is not None
                assert min_btn.get("role") == "button"
                print(f"PASS: get_widget_tree('window/{win_id}') exposes window root, titlebar, and controls", flush=True)

                # 6. Test Maximize via clicking window/<id>/maximize
                ui.click(f"window/{win_id}/maximize")
                wait_for(
                    lambda: next(w for w in ipc.get_windows() if w["id"] == win_id).get("is_maximized") is True,
                    "window was not maximized via titlebar control click",
                    timeout=5,
                )
                ipc.wait_for("window_geometry_settled", window_id=win_id, timeout_ms=5000)

                # Unmaximize via clicking window/<id>/maximize again
                ui.click(f"window/{win_id}/maximize")
                wait_for(
                    lambda: next(w for w in ipc.get_windows() if w["id"] == win_id).get("is_maximized") is False,
                    "window was not unmaximized via titlebar control click",
                    timeout=5,
                )
                ipc.wait_for("window_geometry_settled", window_id=win_id, timeout_ms=5000)
                print("PASS: ClickWidget on window/<id>/maximize toggles maximize state", flush=True)

                # 7. Test Minimize via clicking window/<id>/minimize
                ui.click(f"window/{win_id}/minimize")
                wait_for(
                    lambda: next(w for w in ipc.get_windows() if w["id"] == win_id).get("is_minimized") is True,
                    "window was not minimized via titlebar control click",
                    timeout=5,
                )
                print("PASS: ClickWidget on window/<id>/minimize minimizes window", flush=True)

                # 8. Test Restore via clicking taskbar chip taskbar/window/<id>
                ui.click(f"taskbar/window/{win_id}")
                wait_for(
                    lambda: next(w for w in ipc.get_windows() if w["id"] == win_id).get("is_minimized") is False,
                    "window was not restored via taskbar chip click",
                    timeout=5,
                )
                wait_for(
                    lambda: next(w for w in ipc.get_windows() if w["id"] == win_id).get("is_focused") is True,
                    "window was not focused via taskbar chip click",
                    timeout=5,
                )
                print("PASS: ClickWidget on taskbar/window/<id> restores and focuses window", flush=True)

                # 9. Test Close via clicking window/<id>/close
                ui.click(f"window/{win_id}/close")
                ipc.wait_for_widget_absent(f"window/{win_id}/close", timeout_ms=5000)
                ipc.wait_for_widget_absent(f"taskbar/window/{win_id}", timeout_ms=5000)

                # Confirm client process received close and exited cleanly
                client_proc.wait(timeout=5)
                client_proc = None
                print("PASS: ClickWidget on window/<id>/close closes window and triggers widget_absent", flush=True)

        finally:
            if client_proc and client_proc.poll() is None:
                client_proc.terminate()
                client_proc.wait(timeout=2)
            stop_process(process)
            log.close()


if __name__ == "__main__":
    run()
    print("ALL HOTSPOT TESTS PASSED!")

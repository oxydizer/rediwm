#!/usr/bin/env python3
"""An xdg_popup on a panned or zoomed Canvas window uses the visible output."""
import os
from pathlib import Path
import re
import subprocess
import tempfile

from desktop_zoom import build_client, wait_for
from ipc_client import IPCClient, spawn_compositor, stop_process


def run_case(name, *, zoom, window_x, pan_dx, popup_at, expect_slide):
    with tempfile.TemporaryDirectory(prefix="rediwm-popup-test-") as directory:
        tmp = Path(directory)
        build_client(tmp)
        config = ('[input]\npan_speed = 1.0\n'
                  '[compositor]\nxwayland = false\nfocus_zoom = "keep"\n'
                  '[animations]\nenabled = false\n')
        private = {key: str(tmp / key) for key in ("HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME")}
        compositor, log = spawn_compositor(tmp, config_content=config,
            env_extra={**private, "DBUS_SESSION_BUS_ADDRESS": "unix:path=/nonexistent-popup-bus"})
        client = None
        try:
            with IPCClient(tmp) as ipc:
                ipc.wait_for("wallpaper_presented")
                display = next(p.name for p in tmp.glob("wayland-*") if not p.name.endswith(".lock"))
                client_log = tmp / "client.log"
                with client_log.open("w") as out:
                    client = subprocess.Popen([str(tmp / "client")], stdout=out,
                        env={**os.environ, **private, "XDG_RUNTIME_DIR": str(tmp), "WAYLAND_DISPLAY": display,
                             "REDIWM_TEST_POPUP_SLIDE": "1", "REDIWM_TEST_POPUP_AT": f"{popup_at},40",
                             "REDIWM_TEST_DECORATION": "server"})
                wid = wait_for(lambda: next((w["id"] for w in ipc.get_windows()
                    if w["app_id"] == "rediwm.zoom-fixture"), None), "fixture did not map")
                if zoom != 100:
                    ipc.move_cursor(0, 0)
                    ipc.action("set_zoom", {"percent": zoom})
                ipc.action("move_window_to", {"id": wid, "x": window_x, "y": 100})
                if pan_dx:
                    ipc.move_cursor(1200, 400)
                    ipc.key(125, True)
                    ipc.key(56, True)
                    ipc.move_cursor(1200 - pan_dx, 400)
                    ipc.key(56, False)
                    ipc.key(125, False)
                ipc.wait_for("window_geometry_settled", window_id=wid)
                ipc.wait_for_frame()
                cam = ipc.query("get_camera")
                assert cam["zoom_percent"] == zoom and cam["x"] == pan_dx, (name, cam)
                debug = ipc.get_window_debug(wid)
                frame, content = debug["chrome_box"], debug["client_box"]
                z = zoom / 100
                scale = debug["effective_zoom"]
                assert abs(scale - z) < .001, (name, scale, z)
                # Project the frame through the camera, then use the actual
                # decoration insets and effective client scale for popup coordinates.
                cx = (frame["x"] - cam["x"]) * z + (content["x"] - frame["x"]) * scale
                cy = (frame["y"] - cam["y"]) * z + (content["y"] - frame["y"]) * scale
                ipc.click_at(round(cx + 200 * scale), round(cy + 180 * scale), button=273)
                match = wait_for(lambda: re.search(r"^popup (-?\d+) (-?\d+) (\d+) (\d+)",
                    client_log.read_text(), re.M), f"{name}: popup did not configure")
                x, y, width, _ = map(int, match.groups())
                if expect_slide:
                    output = ipc.get_outputs()[0]
                    right = cx + (x + width) * scale
                    assert x < popup_at and abs(right - output["logical_width"]) <= 2, (name, x, right, output)
                else:
                    assert (x, y) == (popup_at, 40), (name, x, y)
        finally:
            if client is not None:
                stop_process(client)
            stop_process(compositor)
            log.close()


def run():
    run_case("zoomed", zoom=55, window_x=1900, pan_dx=0, popup_at=50, expect_slide=False)
    run_case("zoomed edge", zoom=55, window_x=1900, pan_dx=0, popup_at=390, expect_slide=True)
    run_case("panned", zoom=100, window_x=1500, pan_dx=1100, popup_at=50, expect_slide=False)
    run_case("panned edge", zoom=100, window_x=1500, pan_dx=500, popup_at=390, expect_slide=True)
    print("PASS: zoomed and panned Canvas windows keep popups on the visible output")


if __name__ == "__main__":
    run()

#!/usr/bin/env python3
"""Blackout chrome, shared striped tracks, and live removal at both raster scales."""
import os
from pathlib import Path
import subprocess
import tempfile

from PIL import Image
from desktop_zoom import wait_for
from ipc_client import IPCClient, spawn_compositor, stop_process
from ui_driver import UIDriver

ROOT = Path(__file__).resolve().parents[1]


def yellow(pixel):
    return pixel[0] > 180 and pixel[1] > 170 and pixel[2] < 60


def run(scale):
    with tempfile.TemporaryDirectory(prefix="rediwm-blackout-") as directory:
        tmp = Path(directory)
        home = tmp / "home"
        home.mkdir()
        for index in range(80):
            (home / f"Folder {index:02}").mkdir()
        env = dict(HOME=str(home), XDG_DATA_HOME=str(tmp / "data"),
                   XDG_CONFIG_HOME=str(tmp / "config"), XDG_CACHE_HOME=str(tmp / "cache"),
                   XDG_STATE_HOME=str(tmp / "state"), DBUS_SESSION_BUS_ADDRESS="",
                   DBUS_SYSTEM_BUS_ADDRESS="unix:path=/nonexistent", REDIWM_FILES_DEVICES="0")
        env.pop("REDIWM_THEME", None)
        env.pop("REDIWM_SOCKET", None)
        config = ('[compositor]\nxwayland = false\nfocus_zoom = "keep"\n'
                  '[desktop]\nenabled = false\n[animations]\nenabled = false\n'
                  '[theme]\nbase = "blackout"\n')
        process, log = spawn_compositor(tmp, scale=str(scale), config_content=config, env_extra=env)
        files = None
        try:
            with IPCClient(tmp, timeout=20) as ipc:
                assert "blackout" in {p["id"] for p in ipc.query("theme.list")["packs"]}
                display = wait_for(lambda: next((p.name for p in tmp.glob("wayland-*")
                                                if not p.name.endswith(".lock")), None), "display")
                files = subprocess.Popen([str(ROOT / "zig-out/bin/rediwm-files"), str(home)],
                    env=dict(os.environ, **env, XDG_RUNTIME_DIR=str(tmp), WAYLAND_DISPLAY=display,
                             REDIWM_CONFIG=str(tmp / "rediwm-config.toml")),
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                win = wait_for(lambda: next((w for w in ipc.get_windows()
                                             if w["app_id"] == "rediwm-files"), None), "Files")
                wid = win["id"]
                ipc.set_zoom(wid, 100)
                ipc.action("set_window_size", {"id": wid, "width": 900, "height": 500})
                wait_for(lambda: ipc.get_window_debug(wid)["client_box"]["width"] == 900, "initial resize")
                ipc.action("move_window_to", {"id": wid, "x": 70, "y": 70})
                ipc.focus_window(wid)
                ipc.move_cursor(10, 10)
                ipc.wait_for("window_geometry_settled", window_id=wid)

                def capture():
                    ipc.wait_for_frame()
                    path = tmp / "shot.png"
                    path.unlink(missing_ok=True)
                    ipc.screenshot(str(path))
                    image = Image.open(path).convert("RGB")
                    image.save(f"/tmp/blackout-latest-{scale}.png")
                    return image

                def crop(image, box, rect):
                    x, y, w, h = rect
                    return image.crop(tuple(round(v * scale) for v in
                        (box["x"] + x, box["y"] + y, box["x"] + x + w, box["y"] + y + h)))

                def corners(image):
                    box = ipc.get_window_debug(wid)["chrome_box"]
                    return [sum(yellow(p) for p in crop(image, box, (x, y, 28, 28)).getdata())
                            for x, y in ((0, 0), (box["width"] - 28, 0),
                                         (0, box["height"] - 28),
                                         (box["width"] - 28, box["height"] - 28))]

                def folders_ready():
                    image = capture()
                    box = ipc.get_window_debug(wid)["client_box"]
                    area = crop(image, box, (230, 110, box["width"] - 260, box["height"] - 140))
                    return image if sum(yellow(p) for p in area.getdata()) > 300 else None

                shot = wait_for(folders_ready, "yellow pack folder artwork")
                assert all(n > 20 * scale for n in corners(shot)), corners(shot)
                body = ipc.get_window_debug(wid)["client_box"]
                # The overflowing Files viewport must use the shared charcoal
                # track and its lighter hatch, even below the resting thumb.
                track = crop(shot, body, (body["width"] - 18, 100, 18, body["height"] - 130))
                colors = dict((color, count) for count, color in track.getcolors(track.width * track.height))
                assert colors.get((26, 32, 33), 0) > 30, colors
                assert colors.get((52, 61, 62), 0) > 30, colors
                debug = ipc.get_window_debug(wid)
                assert debug["titlebar_height"] == 48, debug
                assert debug["frame_border"] == debug["footer_height"] == 2, debug
                controls = {w["name"]: w for w in ipc.get_widget_tree(f"window/{wid}")["widgets"]}
                close = controls["close"]["box"]
                assert close["x"] + close["width"] > debug["chrome_box"]["width"] - 14, close
                assert close["y"] + close["height"] / 2 > debug["titlebar_height"] / 2 + 3, close
                # Keep a real rendered preview for review (never the reference image).
                shot.save(f"/tmp/blackout-preview-{scale}.png")

                from blackout_resize import check_resize
                check_resize(ipc, wid, scale, tmp, capture, crop, yellow)

                from blackout_config import check_config
                check_config(ipc, wid, scale, tmp, capture, crop, yellow)

                from blackout_shapes import check_shapes
                check_shapes(ipc, wid, scale, tmp, capture)

                from blackout_resize import check_narrow
                ipc.minimize(wid)
                try:
                    check_narrow(ipc, scale, tmp, capture, crop)
                finally:
                    ipc.restore(wid)

                # Narrow widths retain working window controls and a clipped title.
                ipc.action("set_window_size", {"id": wid, "width": 360, "height": 300})
                wait_for(lambda: ipc.get_window_debug(wid)["client_box"]["width"] == 360, "narrow resize")
                ipc.wait_for("window_geometry_settled", window_id=wid)
                counts = corners(capture())
                assert all(n > 20 * scale for n in counts), (counts, ipc.get_window_debug(wid))
                controls = {w["name"]: w for w in ipc.get_widget_tree(f"window/{wid}")["widgets"]}
                UIDriver(ipc).click(controls["maximize"])
                wait_for(lambda: ipc.get_window_debug(wid)["maximized"], "maximize")
                # Switching away releases the decoration visually, including
                # after restoring from a rectangular maximized frame.
                ipc.action("theme.apply", {"id": "rediwm-dark"})
                controls = {w["name"]: w for w in ipc.get_widget_tree(f"window/{wid}")["widgets"]}
                UIDriver(ipc).click(controls["maximize"])
                wait_for(lambda: not ipc.get_window_debug(wid)["maximized"], "restore")
                ipc.wait_for("window_geometry_settled", window_id=wid)
                ipc.move_cursor(10, 10)
                assert not any(corners(capture())), "stale corner accents after theme switch"
                ipc.action("theme.apply", {"id": "blackout"})
                ipc.wait_for("window_geometry_settled", window_id=wid)
                counts = corners(capture())
                assert all(n > 20 * scale for n in counts), (counts, ipc.get_window_debug(wid))
                controls = {w["name"]: w for w in ipc.get_widget_tree(f"window/{wid}")["widgets"]}
                UIDriver(ipc).click(controls["minimize"])
                wait_for(lambda: ipc.get_window_debug(wid)["minimized"], "shifted minimize target")
                ipc.restore(wid)
                ipc.wait_for("window_geometry_settled", window_id=wid)
                UIDriver(ipc).click(controls["close"])
                wait_for(lambda: not any(w["id"] == wid for w in ipc.get_windows()), "shifted close target")
            print(f"PASS: Blackout frame, striped Files track, controls and reload (scale={scale})")
        except Exception:
            print((tmp / "compositor.log").read_text())
            raise
        finally:
            if files:
                stop_process(files)
            stop_process(process)
            log.close()


if __name__ == "__main__":
    os.environ.pop("REDIWM_THEME", None)
    run(1)
    run(1.5)

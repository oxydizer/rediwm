#!/usr/bin/env python3
"""Rounded window borders must not develop a bright antialiasing fringe."""
import math
import os
from pathlib import Path
import subprocess
import tempfile
import time

from PIL import Image

from desktop_zoom import build_client, wait_for
from ipc_client import IPCClient, spawn_compositor, stop_process
from ui_driver import UIDriver


def settings_resize(scale):
    """The opaque body joins its skirt, and shadows follow shell resizes."""
    with tempfile.TemporaryDirectory(prefix="rediwm-settings-corners-") as directory:
        tmp = Path(directory)
        wallpaper = tmp / "wallpaper.png"
        Image.new("RGB", (64, 64), (240, 240, 240)).save(wallpaper)
        config = (
            f'[compositor]\nxwayland = false\nwallpaper = "{wallpaper}"\n'
            '[desktop]\nenabled = false\n[animations]\nenabled = false\n'
            '[theme]\nwindow_bg = "#101215"\napp_bg = "#101215"\nshadow = "#00000080"\n'
            'shadow_size = 24\nshadow_offset_y = 0\n'
        )
        process, log = spawn_compositor(
            tmp, scale=str(scale), config_content=config,
            renderer=os.environ.get("REDIWM_TEST_RENDERER", "pixman"),
            env_extra={"HOME": str(tmp), "DBUS_SESSION_BUS_ADDRESS": "",
                       "DBUS_SYSTEM_BUS_ADDRESS": "unix:path=/nonexistent",
                       "REDIWM_THEME": str(tmp / "rediwm-config.toml"), "REDIWM_NO_GLASS": "1"},
        )
        try:
            with IPCClient(tmp) as ipc:
                ipc.wait_for("wallpaper_presented", timeout_ms=10000)
                ipc.open_control_center()
                ui = UIDriver(ipc)
                ui.wait_settled("control_center")
                window = next(w for w in ipc.get_windows() if w.get("app_id") == "rediwm-settings")
                ipc.action("move_window_to", {"id": window["id"], "x": 80, "y": 40})
                ipc.move_cursor(2, 2)
                for width, height in ((801, 481), (850, 510), (803, 483), (800, 480)):
                    ipc.action("set_window_size", {"id": window["id"], "width": width, "height": height})
                    ui.wait_settled("control_center")
                    box = ipc.get_shell_state()["control_center"]["box"]
                    frame = next(w for w in ipc.get_windows() if w["id"] == window["id"])
                    path = tmp / f"resize-{width}-{height}.png"
                    ipc.screenshot(str(path))
                    with Image.open(path) as image:
                        image = image.convert("RGB")
                    x = round((box["x"] + box["width"] / 2) * scale)
                    join = round((box["y"] + box["height"]) * scale)
                    for y in range(join - 3, join + 3):
                        pixel = image.getpixel((x, y))
                        assert pixel == (16, 18, 21), ("body/skirt seam", scale, width, height, y, pixel)
                    for sx, sy in ((frame["x"] + frame["width"] + 5, box["y"] + box["height"] / 2),
                                   (box["x"] + box["width"] / 2, frame["y"] + frame["height"] + 5)):
                        pixel = image.getpixel((round(sx * scale), round(sy * scale)))
                        assert max(pixel) < 230, ("shadow missed resized edge", scale, width, height, pixel)
            print(f"PASS scale {scale}: Settings resize body/skirt join and shadow")
        finally:
            stop_process(process)
            log.close()


def run(scale, background=(48, 50, 56), chrome_alpha=0.98):
    with tempfile.TemporaryDirectory(prefix="rediwm-corners-") as directory:
        tmp = Path(directory)
        build_client(tmp)
        wallpaper = tmp / "wallpaper.png"
        Image.new("RGB", (64, 64), background).save(wallpaper)
        config = (
            f'[compositor]\nxwayland = false\nwallpaper = "{wallpaper}"\n'
            '[desktop]\nenabled = false\n'
            '[animations]\nreduced_motion = "on"\n'
            '[theme]\nshadow = "#00000000"\nradius_lg = 10\n'
            f'window_bg = "rgba(16,18,21,{chrome_alpha})"\n'
        )
        process, log = spawn_compositor(
            tmp, scale=str(scale), config_content=config,
            renderer=os.environ.get("REDIWM_TEST_RENDERER", "pixman"),
            env_extra={"HOME": str(tmp), "DBUS_SESSION_BUS_ADDRESS": "",
                       "REDIWM_THEME": str(tmp / "rediwm-config.toml"), "REDIWM_NO_GLASS": "1"},
        )
        client = None
        try:
            with IPCClient(tmp) as ipc:
                ipc.wait_for("wallpaper_presented", timeout_ms=10000)
                display = next(p.name for p in tmp.glob("wayland-*") if not p.name.endswith(".lock"))
                live = tmp / "live"
                live.write_text("ff101215 400 260 Corner test")
                with (tmp / "client.log").open("w") as client_log:
                    client = subprocess.Popen(
                        [str(tmp / "client")], stdout=client_log, stderr=client_log,
                        env=dict(os.environ, XDG_RUNTIME_DIR=str(tmp), WAYLAND_DISPLAY=display,
                                 REDIWM_TEST_LIVE_FILE=str(live)),
                    )
                window = wait_for(lambda: next(iter(ipc.get_windows()), None), "window did not map")
                ipc.action("set_camera", {"x": 0, "y": 0})
                ipc.action("move_window_to", {"id": window["id"], "x": 80, "y": 80})
                for hovered in (False, True):
                    ipc.move_cursor(180 if hovered else 20, 100 if hovered else 20)
                    time.sleep(0.3)  # Hover fade and sampled client footer settle.
                    ipc.wait_for_frame()
                    window = ipc.get_windows()[0]
                    path = tmp / f"corners-{hovered}.png"
                    ipc.screenshot(path=str(path))
                    with Image.open(path) as image:
                        image = image.convert("RGB")
                    preview = os.environ.get("REDIWM_CORNERS_PREVIEW")
                    if preview:
                        image.save(f"{preview}-{background[0]}-{scale}-{'hover' if hovered else 'idle'}.png")
                    x, y, w, h = (window[key] for key in ("x", "y", "width", "height"))
                    # The body-side border needs the same chrome backing as
                    # the titlebar. A faint stroke over bare wallpaper looks
                    # like a missing pixel beside a dark client on light apps.
                    if background[0] > 200:
                        border_alpha = 0.13 if hovered else 0.09
                        expected = tuple(round(255 * border_alpha +
                                         (fill * chrome_alpha + backdrop * (1 - chrome_alpha)) * (1 - border_alpha))
                                         for fill, backdrop in zip((16, 18, 21), background))
                        for column in (math.floor(x * scale + 0.5), math.floor((x + w) * scale + 0.5) - 1):
                            titlebar = ipc.get_window_debug(window["id"])["titlebar_height"]
                            for row in range(math.ceil((y + titlebar) * scale), math.floor((y + h - 10) * scale)):
                                pixel = image.getpixel((column, row))
                                assert all(abs(a - b) <= 2 for a, b in zip(pixel, expected)), (
                                    "side border fill", scale, hovered, column, row, pixel, expected)
                    # Straight borders and the surrounding wallpaper
                    # bound every colour in an antialiased corner. The old
                    # straight-alpha interpolation overshot this by ~40 levels.
                    straight = [image.getpixel((round((x + w / 2) * scale), row))
                                for edge in (y, y + h - 1)
                                for row in range(math.floor(edge * scale), math.ceil((edge + 1) * scale))]
                    straight += [image.getpixel((column, round((y + h / 2) * scale)))
                                 for edge in (x, x + w - 1)
                                 for column in range(math.floor(edge * scale), math.ceil((edge + 1) * scale))]
                    limit = tuple(max(background[c], *(p[c] for p in straight)) + 2 for c in range(3))
                    for left in (x, x + w - 10):
                        for top in (y, y + h - 10):
                            corner = image.crop((math.floor(left * scale), math.floor(top * scale),
                                                 math.ceil((left + 10) * scale), math.ceil((top + 10) * scale)))
                            peaks = tuple(hi for _, hi in corner.getextrema())
                            assert all(p <= bound for p, bound in zip(peaks, limit)), (
                                scale, hovered, left, top, peaks, limit)
                print(f"PASS scale {scale}, background {background}: corners and side borders, idle and hovered")
        except Exception:
            log.flush()
            print((tmp / "compositor.log").read_text()[-6000:])
            raise
        finally:
            if client is not None:
                stop_process(client)
            stop_process(process)
            log.close()


if __name__ == "__main__":
    for scale in (1, 1.25, 1.5, 2):
        settings_resize(scale)
        run(scale)
        run(scale, (224, 225, 232))
    run(1, (224, 225, 232), chrome_alpha=0.5)

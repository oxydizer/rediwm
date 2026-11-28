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


# One shape clips the whole window (stage 4 of docs/plans/scene-graph.md): the
# client's corners are transparent and the frame's footer is the border.


def border_glow_resize(scale):
    """The edge highlight follows held-button motion and committed geometry."""
    with tempfile.TemporaryDirectory(prefix="rediwm-resize-glow-") as directory:
        tmp = Path(directory)
        build_client(tmp)
        config = ('[compositor]\nxwayland = false\n'
                  '[desktop]\nenabled = false\n[animations]\nenabled = false\n'
                  '[theme]\nwindow_bg = "#101215"\nwindow_border = "#101215"\n'
                  'shadow = "#00000000"\nborder_glow = "#00ff00ff"\n'
                  'border_glow_length = 72\n')
        process, log = spawn_compositor(tmp, scale=str(scale), config_content=config,
            renderer=os.environ.get("REDIWM_TEST_RENDERER", "gles2"),
            env_extra={"DBUS_SESSION_BUS_ADDRESS": "", "REDIWM_NO_GLASS": "1",
                       "REDIWM_THEME": str(tmp / "rediwm-config.toml")})
        client = None
        try:
            with IPCClient(tmp) as ipc:
                ipc.wait_for("wallpaper_presented", timeout_ms=10000)
                display = next(p.name for p in tmp.glob("wayland-*") if not p.name.endswith(".lock"))
                client = subprocess.Popen([str(tmp / "client"), "--app-id", "resize-glow"],
                    env=dict(os.environ, XDG_RUNTIME_DIR=str(tmp), WAYLAND_DISPLAY=display,
                             REDIWM_TEST_DECORATION="server"))
                id = wait_for(lambda: next((w["id"] for w in ipc.get_windows()
                    if w["app_id"] == "resize-glow"), None), "map resize glow client")
                ipc.action("move_window_to", {"id": id, "x": 100, "y": 80})
                ipc.wait_for("window_geometry_settled", window_id=id)

                def frame():
                    if owner == "shell":
                        return next(w for w in ipc.get_windows() if w["id"] == id)
                    return ipc.get_window_debug(id)["chrome_box"]

                def green_at(x, y):
                    path = tmp / "glow.png"
                    ipc.wait_for_frame()
                    path.unlink(missing_ok=True)
                    ipc.screenshot(str(path))
                    with Image.open(path) as image:
                        image = image.convert("RGB")
                    pixels = image.crop((math.floor((x - 2) * scale), math.floor((y - 2) * scale),
                                         math.ceil((x + 2) * scale), math.ceil((y + 2) * scale)))
                    return max(g - max(r, b) for r, g, b in pixels.getdata())

                for owner in ("client", "shell"):
                    if owner == "shell":
                        ipc.open_control_center()
                        UIDriver(ipc).wait_settled("control_center")
                        id = next(w["id"] for w in ipc.get_windows()
                                  if w.get("app_id") == "rediwm-settings")
                        ipc.action("move_window_to", {"id": id, "x": 100, "y": 80})
                        ipc.wait_for("window_geometry_settled", window_id=id)
                    box = frame()
                    x = box["x"] + box["width"] - 1
                    y = box["y"] + box["height"] * 0.4
                    ipc.move_cursor(round(x), round(y))
                    assert green_at(x, y) > 100, (owner, "initial glow")
                    ipc.pointer_button(0x110, True)
                    assert ipc.get_input_state()["cursor_mode"] == "resize"
                    # Tangential motion changes no size, but must move the glow.
                    ipc.move_cursor(round(x), round(y + 100))
                    assert green_at(x, y + 100) > 100, (owner, "glow stuck during resize")
                    assert green_at(x, y) < 40, (owner, "old glow remains")
                    ipc.move_cursor(round(x + 80), round(y + 100))
                    resized = wait_for(lambda: current if (current := frame())["width"] > box["width"] + 60 else None,
                                       "resize configure applied")
                    edge = resized["x"] + resized["width"] - 1
                    assert green_at(edge, y + 100) > 100, (owner, "glow missed resized edge")
                    ipc.pointer_button(0x110, False)
                    ipc.move_cursor(2, 2)
                    assert green_at(edge, y + 100) < 40, (owner, "glow remains after leaving")
            print(f"PASS scale {scale}: resize glow follows pointer and client/shell geometry")
        finally:
            if client is not None:
                stop_process(client)
            stop_process(process)
            log.close()


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
            renderer=os.environ.get("REDIWM_TEST_RENDERER", "gles2"),
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
                    # Below the body the frame is the border alone: one row.
                    footer = frame["y"] + frame["height"] - (box["y"] + box["height"])
                    assert footer == 1, ("footer height", footer)
                    # The ring is max(1, round(border * scale)) device pixels at the bottom
                    # of the frame, so the body colour is certain only above it.
                    ring = max(1, round(scale))
                    for y in range(join - 3, join - ring + 1):
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


def workspace_focus(scale):
    """Focus colours both border paths, CSD input survives, and gaps have mode defaults."""
    with tempfile.TemporaryDirectory(prefix="rediwm-workspace-borders-") as directory:
        tmp = Path(directory)
        build_client(tmp)
        wallpaper = tmp / "wallpaper.png"
        Image.new("RGB", (64, 64), (48, 50, 56)).save(wallpaper)
        live = tmp / "live"
        live.write_text("ff101215\n")  # Colour only; configure replies still own size.
        config = (f'[compositor]\nxwayland = false\nwallpaper = "{wallpaper}"\n'
                  '[desktop]\nenabled = false\n[animations]\nenabled = false\n'
                  '[theme]\nwindow_bg = "#101215"\nshadow = "#00000000"\n')
        process, log = spawn_compositor(tmp, scale=str(scale), config_content=config,
            renderer=os.environ.get("REDIWM_TEST_RENDERER", "gles2"),
            env_extra={"DBUS_SESSION_BUS_ADDRESS": "", "REDIWM_THEME": str(tmp / "rediwm-config.toml")})
        clients = []
        try:
            with IPCClient(tmp) as ipc:
                ipc.wait_for("wallpaper_presented", timeout_ms=10000)
                display = next(p.name for p in tmp.glob("wayland-*") if not p.name.endswith(".lock"))
                ids, paths = [], []
                for mode in ("server", "client"):
                    path = tmp / f"{mode}.log"
                    with path.open("w") as stream:
                        clients.append(subprocess.Popen([str(tmp / "client"), "--app-id", "border-" + mode],
                            env=dict(os.environ, XDG_RUNTIME_DIR=str(tmp), WAYLAND_DISPLAY=display,
                                     REDIWM_TEST_DECORATION=mode, REDIWM_TEST_LIVE_FILE=str(live)), stdout=stream, stderr=stream))
                    ids.append(wait_for(lambda: next((w["id"] for w in ipc.get_windows()
                        if w["app_id"] == "border-" + mode), None), "map " + mode))
                    paths.append(path)
                ipc.action("set_desktop_mode", {"mode": "tiling", "persist": False})
                wait_for(lambda: all(w["placement"] == "automatic" for w in ipc.get_windows()), "default tiles")
                assert ipc.get_workspaces()[0]["window_gap"] == 8
                def tiled_frames():
                    boxes = [ipc.get_window_debug(id)["chrome_box"] for id in ids]
                    return boxes if boxes[1]["x"] - boxes[0]["x"] - boxes[0]["width"] == 8 else None
                frames = wait_for(tiled_frames, "client split configure replies")
                assert frames[0]["x"] == 8 and frames[0]["y"] == 8, frames
                assert frames[1]["x"] - frames[0]["x"] - frames[0]["width"] == 8, frames

                def red(pixel):
                    return pixel[0] > pixel[1] + 60 and pixel[0] > pixel[2] + 60

                def screenshot():
                    ipc.wait_for_frame()
                    path = tmp / "focus.png"
                    path.unlink(missing_ok=True)
                    ipc.screenshot(path=str(path))
                    with Image.open(path) as image:
                        return image.convert("RGB")

                def edges(id):
                    debug = ipc.get_window_debug(id)
                    box = debug["chrome_box"]
                    x, y, w, h = (box[k] for k in ("x", "y", "width", "height"))
                    outside = debug["decoration_mode"] != "server"
                    return [(x + w / 2, y - 1 if outside else y),
                            (x - 1 if outside else x, y + h / 2),
                            (x + w if outside else x + w - 1, y + h / 2),
                            (x + w / 2, y + h if outside else y + h - 1)]

                for active in ids:
                    ipc.focus_window(active)
                    image = screenshot()
                    for id in ids:
                        for x, y in edges(id):
                            # Rect edges round on the device grid; inspect the
                            # whole logical pixel at fractional scales.
                            pixels = [image.getpixel((px, py))
                                      for px in range(math.floor(x * scale), math.ceil((x + 1) * scale))
                                      for py in range(math.floor(y * scale), math.ceil((y + 1) * scale))]
                            assert any(red(pixel) for pixel in pixels) == (id == active), ("focus border", scale, active, id, x, y, pixels)
                    if active == ids[0]:
                        box = ipc.get_window_debug(active)["chrome_box"]
                        for y in (box["y"], box["y"] + box["height"] - 10):
                            corner = image.crop((round(box["x"] * scale), round(y * scale),
                                                 round((box["x"] + 10) * scale), round((y + 10) * scale)))
                            assert any(red(corner.getpixel((cx, cy))) for cy in range(corner.height)
                                       for cx in range(corner.width)), ("focus corner", scale, y)
                # A CSD outline must not steal even the first pixel of client input.
                box = ipc.get_window_debug(ids[1])["client_box"]
                before = paths[1].read_text().count("button 272 1")
                ipc.click_at(box["x"], box["y"] + 20)
                wait_for(lambda: paths[1].read_text().count("button 272 1") == before + 1, "CSD edge click")
                ipc.fullscreen(ids[1])
                wait_for(lambda: ipc.get_window_debug(ids[1])["fullscreen"], "fullscreen")
                wait_for(lambda: ipc.get_window_debug(ids[1])["client_box"]["width"] == ipc.get_outputs()[0]["logical_width"], "fullscreen client configure reply")
                image = screenshot()
                # Configure initially paints the fixture pure red. Only the
                # compositor's distinct #ed1b2e stroke is a fullscreen failure.
                focus_pixels = [x for x in range(image.width) if image.getpixel((x, 0)) == (237, 27, 46)]
                assert not focus_pixels, ("fullscreen focus border", scale, focus_pixels[:8])
                ipc.fullscreen(ids[1])
                ipc.action("set_window_gap", {"gap": 0, "persist": False})
                wait_for(lambda: ipc.get_window_debug(ids[0])["chrome_box"]["x"] == 0, "explicit gap zero")
                assert ipc.get_workspaces()[0]["window_gap"] == 0
                ipc.focus_window(ids[0])
                ipc.action("set_desktop_mode", {"mode": "canvas", "persist": False})
                wait_for(lambda: ipc.get_workspaces()[0]["name"] == "Canvas", "canvas mode")
                wait_for(lambda: ipc.get_window_debug(ids[1])["client_box"]["width"] == 400, "canvas client configure reply")
                ipc.action("move_window_to", {"id": ids[0], "x": 80, "y": 80})
                ipc.action("move_window_to", {"id": ids[1], "x": 650, "y": 80})
                image = screenshot()
                for id in ids:
                    for x, y in edges(id):
                        pixel = image.getpixel((math.floor((x + .25) * scale), math.floor((y + .25) * scale)))
                        assert not red(pixel), ("canvas kept focus outline", scale, id, x, y, pixel, ipc.get_window_debug(id))
            print(f"PASS scale {scale}: workspace focus edges/corners, CSD input, fullscreen, mode defaults and zero gap")
        except Exception:
            print((tmp / "compositor.log").read_text()[-4000:])
            raise
        finally:
            for client in clients: stop_process(client)
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
            renderer=os.environ.get("REDIWM_TEST_RENDERER", "gles2"),
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
                    # One shape clips the client too: its bottom corners are
                    # transparent, so the wallpaper shows there (no shadow here),
                    # and a click on one reaches what is below. Interior
                    # pixels next to the arc keep the client's colour.
                    for cx, cy in ((x, y + h - 1), (x + w - 1, y + h - 1)):
                        pixel = image.getpixel((round(cx * scale) if cx == x else round((cx + 1) * scale) - 1,
                                                round((cy + 1) * scale) - 1))
                        assert all(abs(a - b) <= 3 for a, b in zip(pixel, background)), (
                            "client corner is not transparent", scale, hovered, cx, cy, pixel)
                        inward = 1 if cx == x else -1
                        pixel = image.getpixel((round((cx + inward * 14) * scale), round((cy - 14) * scale)))
                        assert pixel == (16, 18, 21), ("client interior near the corner", scale, pixel)
                        hit = ipc.hit_test(cx + inward, cy - 1)
                        assert hit["target_type"] == "none", ("click on a clipped corner stayed on the window", scale, hit)
                        hit = ipc.hit_test(cx + inward * 30, cy - 30)
                        assert hit["target_type"] == "window", ("client interior is not the window's", scale, hit)
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
        border_glow_resize(scale)
        workspace_focus(scale)
        settings_resize(scale)
        run(scale)
        run(scale, (224, 225, 232))
    run(1, (224, 225, 232), chrome_alpha=0.5)

#!/usr/bin/env python3
"""Run after zig build. Requires cc, wayland-scanner, Pillow, and a headless renderer.
Set REDIWM_TEST_RENDERER=gles2 for GPU integration.
Creates its own Wayland runtime and clients; never connects to the host desktop.
"""
import json
import os
from pathlib import Path
import re
import shlex
import socket
import subprocess
import tempfile
import time

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]


def wait_for(check, message, timeout=15):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = check()
        if result:
            return result
        time.sleep(.03)
    raise AssertionError(message)


def build_client(tmp):
    protocol_dir = subprocess.check_output(["pkg-config", "--variable=pkgdatadir", "wayland-protocols"], text=True).strip()
    protocol = Path(protocol_dir) / "stable/xdg-shell/xdg-shell.xml"
    for mode, target in [("client-header", "xdg-shell-client-protocol.h"), ("private-code", "xdg-shell-protocol.c")]:
        subprocess.run(["wayland-scanner", mode, str(protocol), str(tmp / target)], check=True)
    decoration_protocol = Path(protocol_dir) / "unstable/xdg-decoration/xdg-decoration-unstable-v1.xml"
    for mode, target in [("client-header", "xdg-decoration-client-protocol.h"), ("private-code", "xdg-decoration-protocol.c")]:
        subprocess.run(["wayland-scanner", mode, str(decoration_protocol), str(tmp / target)], check=True)
    subprocess.run(["cc", "-Wall", "-Wextra", f"-I{tmp}", str(ROOT / "tests/zoom_client.c"), str(tmp / "xdg-shell-protocol.c"), str(tmp / "xdg-decoration-protocol.c"), "-lwayland-client", "-o", str(tmp / "client")], check=True)


def run():
    with tempfile.TemporaryDirectory(prefix="rediwm-zoom-test-") as tmp:
        tmp = Path(tmp)
        build_client(tmp)
        env = dict(os.environ, XDG_RUNTIME_DIR=str(tmp), WLR_BACKENDS="headless", WLR_HEADLESS_OUTPUTS=os.environ.get("REDIWM_TEST_OUTPUTS", "1"), WLR_RENDERER=os.environ.get("REDIWM_TEST_RENDERER", "pixman"), WLR_RENDERER_ALLOW_SOFTWARE="1", REDIWM_SCALE=os.environ.get("REDIWM_TEST_SCALE", "1"), REDIWM_IPC_AUTOMATION="1")
        config_path = tmp / "rediwm-config.toml"
        # Protocol deltas below deliberately use the non-inverted direction.
        # pan_speed = 1.0 keeps pan assertions below at raw screen-space motion
        # (see the default 2x pan_speed in config/loader.zig's InputConfig).
        config_path.write_text("[input]\ninvert_scroll = false\npan_speed = 1.0\n")
        env["REDIWM_CONFIG"] = str(config_path)
        env.pop("WAYLAND_DISPLAY", None)
        env.pop("REDIWM_SOCKET", None)
        client_log = tmp / "client.log"
        command = f"exec {shlex.quote(str(tmp / 'client'))} > {shlex.quote(str(client_log))} 2>&1"
        with (tmp / "compositor.log").open("w") as log:
            compositor = subprocess.Popen([str(ROOT / "zig-out/bin/rediwm"), command], env=env, stdout=log, stderr=log, start_new_session=True)
        other_client = None
        try:
            socket_path = wait_for(lambda: next(tmp.glob("rediwm-*.sock"), None), "IPC socket did not appear")
            with socket.socket(socket.AF_UNIX) as sock:
                sock.settimeout(15)
                sock.connect(str(socket_path))
                reader = sock.makefile("r")

                def request(value):
                    sock.sendall((json.dumps(value) + "\n").encode())
                    response = json.loads(reader.readline())
                    assert "Ok" in response, response
                    return response["Ok"]

                def action(name, params=None):
                    return request({"version": 1, "command": name, "params": params or {}})

                def windows():
                    return request({'version': 1, 'command': 'windows'})["Windows"]

                def geometry():
                    return [(w["id"], w["x"], w["y"], w["width"], w["height"]) for w in windows()]

                def screenshot(name):
                    path = tmp / (name + ".png")
                    action('screenshot', {"path": str(path)})
                    return Image.open(path).convert("RGB")

                def pointer(x, y):
                    action('move_cursor', {"x": round(x), "y": round(y)})

                def key(code, pressed):
                    action('key', {"keycode": code, "pressed": pressed})

                def button(code, pressed):
                    action('pointer_button', {"button": code, "pressed": pressed})

                def camera():
                    return request({'version': 1, 'command': 'get_camera'})["Camera"]

                def animations():
                    payload = request({'version': 1, 'command': 'get_animations'})
                    if isinstance(payload, dict):
                        return payload.get("Animations", [])
                    return payload

                def camera_busy():
                    return any(
                        str(item.get("site", "")).startswith("camera.") and not item.get("settled")
                        for item in animations()
                    )

                def wait_camera():
                    wait_for(lambda: not camera_busy(), "camera animation did not settle")

                def wait_window_zoom():
                    wait_for(lambda: not any(a["site"] == f"window.{win['id']}.zoom" and not a["settled"] for a in animations()), "window zoom did not settle")

                def project(x, y):
                    c = camera()
                    return ((x-c["x"])*c["zoom_percent"]/100, (y-c["y"])*c["zoom_percent"]/100)

                win = wait_for(lambda: next((w for w in windows() if w["app_id"] == "rediwm.zoom-fixture"), None), "fixture did not map")
                wait_for(lambda: client_log.exists() and "frame 8" in client_log.read_text(), "frame callbacks not delivered")
                # Per-window zoom uses the same levels without changing client
                # dimensions, the desktop camera, or a second window.
                display = next(p.name for p in tmp.glob("wayland-*") if not p.name.endswith(".lock"))
                other_client = subprocess.Popen([str(tmp / "client")], env=dict(env, WAYLAND_DISPLAY=display), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                other = wait_for(lambda: next((w for w in windows() if w["id"] != win["id"]), None), "second fixture did not map")
                action('move_window_to', {"id": other["id"], "x": 800, "y": 300})
                other_before = next(w for w in windows() if w["id"] == other["id"])

                def current_window():
                    return next(w for w in windows() if w["id"] == win["id"])

                def window_point(x, y):
                    w = current_window()
                    z = w["zoom_percent"] / 100 * camera()["zoom_percent"] / 100
                    ox, oy = project(w["x"], w["y"])
                    return ox + x*z, oy + y*z

                pointer(*window_point(200, 220))
                time.sleep(.2)
                camera_before = camera()
                configures_before = client_log.read_text().count("configure ")
                axis_before = client_log.read_text().count("axis ")
                # Plain wheel in client content remains ordinary scrolling.
                action('scroll', {"dx": 0, "dy": 40})
                wait_for(lambda: client_log.read_text().count("axis ") > axis_before, "ordinary client scrolling was swallowed")
                axis_before = client_log.read_text().count("axis ")
                key(56, True)
                for dy, percent in [(40,85),(40,70),(40,55),(40,55),(-40,70),(-40,85),(-40,100),(-40,100)]:
                    action('scroll', {"dx": 0, "dy": dy})
                    w = current_window()
                    assert w["zoom_percent"] == percent, w
                    assert (w["width"], w["height"]) == (win["width"], win["height"])
                    assert camera() == camera_before, "window wheel changed desktop camera"
                    unchanged = next(w for w in windows() if w["id"] == other["id"])
                    assert all(unchanged[k] == other_before[k] for k in ("x", "y", "width", "height", "zoom_percent")), unchanged
                key(56, False)
                assert client_log.read_text().count("axis ") == axis_before, "Alt wheel leaked to client"
                assert client_log.read_text().count("configure ") == configures_before, "window zoom reconfigured client"
                # Super+Alt wheel over a window zooms the whole desktop instead.
                key(125, True)
                key(56, True)
                for dy, percent in [(40, 85), (-40, 100)]:
                    action('scroll', {"dx": 0, "dy": dy})
                    assert camera()["zoom_percent"] == percent, "Super+Alt wheel did not zoom the desktop"
                    assert current_window()["zoom_percent"] == 100, "Super+Alt wheel zoomed the window"
                key(56, False)
                key(125, False)
                assert client_log.read_text().count("axis ") == axis_before, "Super+Alt wheel leaked to client"
                request({'version': 1, 'command': 'reset_camera'})
                wait_camera()
                assert camera() == camera_before, camera()
                # Alt-wheel zoom produces a smooth animated transition over time.
                action('set_anim_time', {"ms": 1000})
                pointer(*window_point(300, 200))
                w_start = current_window()
                key(56, True)
                action('scroll', {"dx": 0, "dy": 40})
                key(56, False)
                action('wait_for_frame', {})
                assert current_window()["zoom_percent"] == 85
                action('set_anim_time', {"ms": 1080})
                action('wait_for_frame', {})
                w_mid = current_window()
                action('set_anim_time', {"ms": 1250})
                action('wait_for_frame', {})
                w_settled = current_window()
                if w_settled["x"] != w_start["x"]:
                    assert (w_start["x"] <= w_mid["x"] <= w_settled["x"]) or (w_settled["x"] <= w_mid["x"] <= w_start["x"])
                key(56, True)
                action('scroll', {"dx": 0, "dy": -40})
                key(56, False)
                action('set_anim_time', {"ms": 1500})
                action('wait_for_frame', {})
                action('set_anim_time', {"ms": None})
                assert current_window()["zoom_percent"] == 100
                # Plain titlebar wheel also zooms; horizontal wheel does not.
                pointer(*window_point(100, 30))
                action('scroll', {"dx": 40, "dy": 0})
                assert current_window()["zoom_percent"] == 100
                for percent in (85,70,55):
                    action('scroll', {"dx": 0, "dy": 40})
                    assert current_window()["zoom_percent"] == percent
                    assert camera() == camera_before
                wait_window_zoom()
                # Camera and window zoom multiply, without changing world geometry.
                world_before = geometry()
                pointer(0, 0)
                action('set_zoom', {"percent": 70})
                wait_camera()
                assert geometry() == world_before, "camera zoom moved/resized windows in the world"
                composed = screenshot("window-and-desktop-zoom")
                density = composed.width / 1280
                for name, x, y, expected_x, expected_y, color in [
                    ("main",201,235,200,180,(0,0,255)),
                    ("child",121,145,20,10,(0,255,0)),
                ]:
                    pointer(0,0)
                    start = len(client_log.read_text())
                    px, py = window_point(x,y)
                    pointer(px,py)
                    wait_for(lambda: f"enter {name} " in client_log.read_text()[start:], "combined zoom input missing")
                    match = re.search(rf"enter {name} ([\d.]+) ([\d.]+)", client_log.read_text()[start:])
                    assert abs(float(match[1])-expected_x)<4 and abs(float(match[2])-expected_y)<4, match[0]
                    pixel = composed.getpixel((round(px*density),round(py*density)))
                    assert all(abs(a-b)<5 for a,b in zip(pixel,color)), (name,pixel)
                    button(272, True)
                    start = len(client_log.read_text())
                    pointer(*window_point(x+30, y+20))
                    wait_for(lambda: "motion " in client_log.read_text()[start:], "scaled grab motion missing")
                    motions = re.findall(r"motion (-?[\d.]+) (-?[\d.]+)", client_log.read_text()[start:])
                    actual_x, actual_y = map(float, motions[-1])
                    assert abs(actual_x-expected_x-30) < 3 and abs(actual_y-expected_y-20) < 3, (name, motions)
                    button(272, False)
                # Resetting individual zoom to 100% still respects the 55% camera.
                pointer(0,0)
                action('set_zoom', {"percent":55})
                wait_camera()
                pointer(*window_point(100,30))
                for percent in (70,85,100):
                    action('scroll', {"dx":0,"dy":-40})
                    assert current_window()["zoom_percent"] == percent
                    assert camera()["zoom_percent"] == 55
                pointer(0,0)
                time.sleep(.2)
                full_window = screenshot("full-window-small-desktop")
                # Client pixels follow the combined scale.
                px,py = window_point(380,300)
                pixel = full_window.getpixel((round(px*density),round(py*density)))
                assert pixel == (0,0,255), ("client pixel missing at combined zoom",pixel)
                pointer(*window_point(100,30))
                for percent in (85,70,55):
                    action('scroll', {"dx":0,"dy":40})
                    assert current_window()["zoom_percent"] == percent
                pointer(0,0)
                action('set_zoom', {"percent":70})
                wait_camera()
                # Moving follows camera coordinates; resizing uses the combined scale.
                previous = current_window()
                x,y = window_point(100,30)
                pointer(x,y); button(272,True)
                action('scroll', {"dx":0,"dy":40})
                assert current_window()["zoom_percent"] == 55, "zoom changed during a drag"
                pointer(x+35,y+21); button(272,False)
                w = current_window()
                assert abs(w["x"]-previous["x"]-50)<=2 and abs(w["y"]-previous["y"]-30)<=2, w
                # Bottom-right resize at window scale .55, with desktop at .70.
                x,y = window_point(w["width"]-1,w["height"]-1)
                pointer(x,y); button(272,True)
                pointer(x+55*.70,y+33*.70); button(272,False)
                wait_for(lambda: current_window()["width"] >= w["width"]+97, "combined zoom resize failed")
                resized = current_window()
                assert abs(resized["height"]-w["height"]-60)<=3, resized
                assert resized["x"] == w["x"] and resized["y"] == w["y"], resized
                time.sleep(.2)
                # Top-left resizing keeps the opposite displayed corner fixed.
                w = current_window()
                x,y = window_point(1,1)
                pointer(x,y); button(272,True)
                pointer(x-55*.70,y-33*.70); button(272,False)
                wait_for(lambda: current_window()["width"] >= w["width"]+97, "top-left zoom resize failed")
                resized = current_window()
                assert abs(resized["height"]-w["height"]-60)<=3, resized
                assert abs(resized["x"]-w["x"]+55)<=2 and abs(resized["y"]-w["y"]+33)<=2, (w,resized)
                time.sleep(.2)
                request({'version': 1, 'command': 'reset_camera'})
                wait_camera()
                assert current_window()["zoom_percent"] == 55, "desktop reset discarded individual zoom"
                # Restore the fixture for the existing desktop-camera checks.
                pointer(*window_point(100,30))
                for percent in (70,85,100):
                    action('scroll', {"dx":0,"dy":-40})
                    assert current_window()["zoom_percent"] == percent
                wait_window_zoom()
                action('move_window_to', {"id":win["id"],"x":win["x"],"y":win["y"]})
                action('close_window', {"id":other["id"]})
                other_client.wait(timeout=5)
                wait_for(lambda: len(windows()) == 1, "second fixture not removed")
                win = current_window()
                before = geometry()
                # Keep full-sized windows above the translucent taskbar in both captures.
                pointer(0, 0)
                # Wait for the taskbar's mapping/hover animations to settle.
                time.sleep(.5)
                normal = screenshot("100")
                density = normal.width / 1280
                bar_crop = (0, round(666*density), round(900*density), normal.height)
                configures = client_log.read_text().count("configure ")
                for percent in [85, 70, 55, 70, 85, 100, 55]:
                    action('set_zoom', {"percent": percent})
                    assert camera()["zoom_percent"] == percent
                    assert geometry() == before, "zoom changed world geometry"
                wait_camera()
                small = screenshot("55")
                # Ignore the clock/tray, whose contents change with time.
                assert normal.crop(bar_crop).tobytes() == small.crop(bar_crop).tobytes(), "taskbar scaled or moved"
                assert client_log.read_text().count("configure ") == configures, "zoom reconfigured the client"
                # Pointer mapping into a main surface and a positioned subsurface.
                for name, wx, wy, expected_x, expected_y in [
                    ("main", win["x"]+1+200, win["y"]+55+220, 200, 220),
                    ("child", win["x"]+1+120, win["y"]+55+90, 20, 10),
                ]:
                    pointer(1200, 550)
                    start = len(client_log.read_text())
                    pointer(*window_point(wx-win["x"], wy-win["y"]))
                    wait_for(lambda: f"enter {name} " in client_log.read_text()[start:], f"no pointer entry into {name}")
                    match = re.search(rf"enter {name} ([\d.]+) ([\d.]+)", client_log.read_text()[start:])
                    assert abs(float(match[1])-expected_x) < 3 and abs(float(match[2])-expected_y) < 3, match[0]
                    # Held-button motion must use the same inverse transform
                    # as entry, including for positioned child surfaces.
                    button(272, True)
                    start = len(client_log.read_text())
                    pointer(*window_point(wx-win["x"]+30, wy-win["y"]+20))
                    wait_for(lambda: "motion " in client_log.read_text()[start:], "grab motion missing")
                    motions = re.findall(r"motion (-?[\d.]+) (-?[\d.]+)", client_log.read_text()[start:])
                    actual_x, actual_y = map(float, motions[-1])
                    assert abs(actual_x-expected_x-30) < 3 and abs(actual_y-expected_y-20) < 3, (name, motions)
                    button(272, False)
                # Typing is still delivered at reduced scale.
                button(272, True); button(272, False)
                key(30, True); key(30, False)
                wait_for(lambda: "key 30 1" in client_log.read_text(), "typing was lost")
                # Alt wheel over the desktop clamps and uses all four levels.
                pointer(1200, 550)
                axis_count = client_log.read_text().count("axis ")
                key(56, True)
                for dy, percent in [(-40, 70), (-40, 85), (-40, 100), (-40, 100), (40, 85), (40, 70), (40, 55), (40, 55)]:
                    action('scroll', {"dx": 0, "dy": dy})
                    assert camera()["zoom_percent"] == percent
                key(56, False)
                wait_camera()
                assert client_log.read_text().count("axis ") == axis_count
                assert geometry() == before
                # Super alone no longer pans by default (pan_modifier = super_alt).
                pointer(900, 450)
                key(125, True)
                previous = camera()
                pointer(955, 483)
                assert camera() == previous, "Super alone panned"
                # Super+Alt pan and middle pan retain screen-space motion at 55%.
                key(56, True)
                pointer(1010, 516)
                current = camera()
                assert abs(current["x"] - previous["x"] + 100) <= 1
                assert abs(current["y"] - previous["y"] + 60) <= 1
                action('scroll', {"dx": 0, "dy": -40})
                assert camera()["zoom_percent"] == 70
                action('scroll', {"dx": 0, "dy": 40})
                key(56, False)
                key(125, False)
                pointer(955, 483)
                button(274, True)
                previous = camera()
                pointer(900, 450)
                current = camera()
                assert abs(current["x"] - previous["x"] - 100) <= 1
                key(56, True)
                action('scroll', {"dx": 0, "dy": -40})
                assert camera()["zoom_percent"] == 55, "zoom changed during middle drag"
                key(56, False)
                button(274, False)
                assert geometry() == before
                # Create and interact with a popup while zoomed out.
                pointer(*window_point(1+200,55+180))
                button(273, True); button(273, False)
                wait_for(lambda: "popup " in client_log.read_text(), "popup did not configure")
                match = re.search(r"popup (-?\d+) (-?\d+) (\d+) (\d+)", client_log.read_text())
                popup_x, popup_y = int(match[1]), int(match[2])
                start = len(client_log.read_text())
                pointer(*window_point(1+popup_x+20,55+popup_y+20))
                wait_for(lambda: "enter popup " in client_log.read_text()[start:], "popup input was not projected")
                # Clicking inside a popup belonging to the already-focused
                # window must not re-raise/reactivate that window: real
                # GTK/Chromium menus treat their own toplevel's wl_keyboard
                # leave/enter churn as "focus left the app" and silently
                # cancel the open menu in response to the very click that
                # triggered it (World.focusSurface regression).
                click_start = len(client_log.read_text())
                button(272, True); button(272, False)
                wait_for(lambda: "button 272 1" in client_log.read_text()[click_start:], "popup click was not delivered")
                assert "configure " not in client_log.read_text()[click_start:], "clicking a popup reconfigured its own toplevel"
                # Titlebar drag delta must be divided by zoom.
                x, y = window_point(100,30)
                pointer(x, y)
                button(272, True)
                pointer(x+55, y+33)
                button(272, False)
                moved = windows()[0]
                assert abs(moved["x"]-win["x"]-100) <= 2 and abs(moved["y"]-win["y"]-60) <= 2, moved
                # A finished drag must not leave the move grab behind: both pan
                # triggers refuse to start while a toplevel is grabbed, while zoom
                # never consults it and so keeps working and hides the breakage.
                pointer(900, 450)
                key(125, True)
                key(56, True)
                previous = camera()
                pointer(955, 483)
                current = camera()
                assert abs(current["x"] - previous["x"] + 100) <= 1, "Super+Alt pan stopped after a window drag"
                assert abs(current["y"] - previous["y"] + 60) <= 1, "Super+Alt pan stopped after a window drag"
                key(56, False)
                key(125, False)
                button(274, True)
                previous = camera()
                pointer(900, 450)
                current = camera()
                assert abs(current["x"] - previous["x"] - 100) <= 1, "middle pan stopped after a window drag"
                button(274, False)
                # A 100% window also respects the 55% camera during resizing.
                pointer(*window_point(moved["width"]-30,moved["height"]-30))
                key(56, True)
                button(273, True)
                x, y = window_point(moved["width"]-30,moved["height"]-30)
                pointer(x+55, y+33)
                button(273, False)
                key(56, False)
                wait_for(lambda: windows()[0]["width"] >= moved["width"]+98, "resize did not reach client")
                resized = windows()[0]
                assert abs(resized["height"] - moved["height"] - 60) <= 2, resized
                assert resized["x"] == moved["x"] and resized["y"] == moved["y"]
                time.sleep(.1)
                # Reset returns to 100% without moving the window back.
                after_move = geometry()
                request({'version': 1, 'command': 'reset_camera'})
                wait_camera()
                assert camera()["zoom_percent"] == 100 and camera()["x"] == camera()["y"] == 0
                assert geometry() == after_move
                # Decoration controls and maximizing also honor individual zoom.
                pointer(*window_point(100,30))
                for percent in (85,70,55):
                    action('scroll', {"dx":0,"dy":40})
                    assert current_window()["zoom_percent"] == percent
                wait_window_zoom()
                w = current_window()
                pointer(*window_point(w["width"]-68,27))
                button(272,True); button(272,False)
                wait_for(lambda: current_window()["is_maximized"], "scaled maximize control missed")
                output = request({'version': 1, 'command': 'outputs'})["Outputs"][0]
                wait_for(lambda: abs(current_window()["width"]*.55-output["logical_width"])<=1, "maximized window did not fill output at its zoom")
                assert abs(current_window()["height"]*.55-(output["logical_height"]-output["bottom_exclusion"]))<=1
                action('close_window', {"id": win["id"]})
                wait_for(lambda: not windows(), "window/mirror cleanup failed")
                print("desktop/window zoom: levels, isolation, geometry, pixels, taskbar, configure stability, frames, input, Alt-wheel, subsurface, popup, pan, dragging, resizing and cleanup passed")
        except Exception:
            print((tmp / "compositor.log").read_text()[-2500:])
            if client_log.exists():
                print(client_log.read_text()[-3000:])
            raise
        finally:
            if other_client is not None and other_client.poll() is None:
                other_client.terminate()
                other_client.wait(timeout=5)
            # Entire process group was created by this test.
            import signal
            try:
                os.killpg(compositor.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            compositor.wait(timeout=5)


if __name__ == "__main__":
    run()

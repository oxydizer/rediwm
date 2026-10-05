#!/usr/bin/env python3
"""Window switching: eased reveal, temporary boost and camera depth focus.

Uses real clients, a private headless compositor and a pinned animation clock.
"""
import os
from pathlib import Path
import subprocess
import re
import tempfile
import time

from PIL import Image

from desktop_zoom import build_client, wait_for
from ipc_client import IPCClient, spawn_compositor, stop_process


def run():
    with tempfile.TemporaryDirectory(prefix="rediwm-focus-zoom-") as directory:
        tmp = Path(directory)
        build_client(tmp)
        base = '[input]\ninvert_scroll = false\n[keybinds]\n"alt+tab" = "focus_next"\n"super+5" = "set_depth 4"\n'
        process, log = spawn_compositor(
            tmp, scale=os.environ.get("REDIWM_TEST_SCALE", "1"),
            renderer=os.environ.get("REDIWM_TEST_RENDERER", "pixman"),
            config_content=base, env_extra={"DBUS_SESSION_BUS_ADDRESS": ""})
        clients = []
        handles = []
        try:
            with IPCClient(tmp) as ipc:
                ipc.wait_for("wallpaper_presented", timeout_ms=10000)
                display = next(p.name for p in tmp.glob("wayland-*") if not p.name.endswith(".lock"))
                for i in range(2):
                    handle = (tmp / f"client-{i}.log").open("w")
                    handles.append(handle)
                    clients.append(subprocess.Popen(
                        [str(tmp / "client"), "--app-id", f"focus-zoom-{i}"],
                        env=dict(os.environ, XDG_RUNTIME_DIR=str(tmp), WAYLAND_DISPLAY=display),
                        stdout=handle, stderr=handle))
                    ipc.wait_for("window_mapped", app_id=f"focus-zoom-{i}")
                ids = [next(w["id"] for w in ipc.get_windows() if w["app_id"] == f"focus-zoom-{i}") for i in range(2)]
                target, other = ids
                clock = int(time.monotonic() * 1000) + 2000

                def tick(dt=1200):
                    nonlocal clock
                    clock += dt
                    ipc.action('set_anim_time', {"ms": clock})
                    ipc.wait_for_frame()

                def mode(value, reduced="off", enabled=True, extra=""):
                    (tmp / "rediwm-config.toml").write_text(
                        base + f'[compositor]\nfocus_zoom = "{value}"\n' + extra +
                        f'[animations]\nreduced_motion = "{reduced}"\nenabled = {str(enabled).lower()}\n')
                    ipc.action('reload_config')
                    tick()

                def camera():
                    return ipc.action('get_camera')

                def window(wid):
                    return next(w for w in ipc.get_windows() if w["id"] == wid)

                def zoom(wid):
                    return ipc.get_window_debug(wid)

                def switch_to(wid):
                    assert ipc.get_focused_window()["id"] != wid
                    ipc.key(56, True)
                    ipc.key_down_up(15)
                    ipc.key(56, False)
                    assert ipc.get_focused_window()["id"] == wid

                def taskbar_click(wid):
                    bar = ipc.get_shell_state()["taskbars"][0]
                    box = next(chip["box"] for chip in bar["chips"] if chip["window_id"] == wid)
                    ipc.click_at(box["x"] + box["width"] // 2, box["y"] + box["height"] // 2)

                def reset():
                    ipc.action('reset_camera')
                    tick()

                tick()
                width = ipc.get_outputs()[0]["logical_width"]
                ipc.focus_window(target)
                ipc.focus_window(other)
                reset()
                ipc.action('move_window_to', {"id": target, "x": width + 200, "y": 100})
                switch_to(target)
                samples = []
                for dt in (0, 16, 16, 1, 127, 160):
                    tick(dt)
                    samples.append(camera()["x"])
                assert 0 < samples[1] < samples[2] < samples[3] < samples[4] < samples[5], samples
                assert samples[3] - samples[2] < 10, samples
                frame = zoom(target)["chrome_box"]
                screen_x = frame["x"] - camera()["x"]
                assert abs(screen_x + frame["width"] / 2 - width / 2) <= 1, (frame, camera())

                # A visible sliver must also trigger a reveal.
                ipc.focus_window(other)
                reset()
                ipc.action('move_window_to', {"id": target, "x": width - 1, "y": 100})
                switch_to(target)
                tick()
                assert camera()["x"] > 0

                # Taskbar activation follows the same eased path, even when
                # the selected window already has focus but only a sliver is
                # visible. Clicking it again after the pan still minimizes.
                for focused, minimized in ((False, False), (True, False), (False, True)):
                    if not focused:
                        ipc.focus_window(other)
                    reset()
                    ipc.action('move_window_to', {"id": target, "x": width - 1 if focused else width + 200, "y": 100})
                    if minimized:
                        ipc.minimize(target)
                    tick()
                    taskbar_click(target)
                    assert ipc.get_focused_window()["id"] == target
                    assert not window(target)["is_minimized"]
                    start = camera()["x"]
                    tick(80)
                    midway = camera()["x"]
                    tick(240)
                    assert start < midway < camera()["x"], (start, midway, camera())
                    frame = zoom(target)["chrome_box"]
                    assert abs(frame["x"] - camera()["x"] + frame["width"] / 2 - width / 2) <= 1
                taskbar_click(target)
                assert window(target)["is_minimized"], "visible focused taskbar button should minimize"
                taskbar_click(target)
                assert not window(target)["is_minimized"]
                tick()

                # Boost is the default. Native geometry and saved zoom survive
                # selection, desktop zoom changes and switching away.
                ipc.focus_window(other)
                ipc.action('set_window_zoom', {"id": target, "percent": 55})
                ipc.action('move_window_to', {"id": target, "x": 100, "y": 100})
                ipc.action('move_window_to', {"id": other, "x": 850, "y": 100})
                ipc.move_cursor(0, 0)
                ipc.action('set_zoom', {"percent": 55})
                tick()
                saved = window(target)
                def configured_sizes():
                    return {tuple(line.split()[1:3]) for line in (tmp / "client-0.log").read_text().splitlines() if line.startswith("configure ")}
                sizes = configured_sizes()
                switch_to(target)
                tick(80)
                assert 0.55 * 0.55 < zoom(target)["effective_zoom"] < 1
                tick()
                info = zoom(target)
                assert info["zoom_boosted"] and abs(info["effective_zoom"] - 1) < 1e-5, info
                assert camera()["zoom_percent"] == 55
                for key in ("x", "y", "width", "height", "zoom_percent"):
                    assert saved[key] == window(target)[key], key
                assert configured_sizes() == sizes, "boost resized the client"

                # Pixels and client input both use the compensated scale.
                frame = info["chrome_box"]
                cam = camera()
                ox = (frame["x"] - cam["x"]) * 0.55
                oy = (frame["y"] - cam["y"]) * 0.55
                ipc.move_cursor(round(ox + info["frame_border"] + 100), round(oy + info["titlebar_height"] + 180))
                ipc.pointer_button(0x110, True)
                ipc.pointer_button(0x110, False)
                wait_for(lambda: "button 272 1" in (tmp / "client-0.log").read_text(), "boosted client input")
                text = (tmp / "client-0.log").read_text()
                points = re.findall(r"(?:enter main|motion) ([\d.]+) ([\d.]+)", text)
                assert any(abs(float(x) - 100) <= 1 and abs(float(y) - 180) <= 1 for x, y in points), text[-1000:]
                ipc.move_cursor(0, 0)
                image_path = tmp / "boost.png"
                ipc.screenshot(path=str(image_path))
                image = Image.open(image_path).convert("RGB")
                density = image.width / width
                pixel = image.getpixel((round((ox + 380) * density), round((oy + 300) * density)))
                assert pixel == (0, 0, 255), pixel

                ipc.action('set_zoom', {"percent": 70})
                tick()
                assert abs(zoom(target)["effective_zoom"] - 1) < 1e-5
                switch_to(other)
                tick()
                assert not zoom(target)["zoom_boosted"]

                assert abs(zoom(target)["effective_zoom"] - 0.55 * 0.70) < 1e-5
                assert window(target)["zoom_percent"] == 55
                for key in ("x", "y", "width", "height"):
                    assert window(target)[key] == saved[key], key

                # Cancellation must leave the current boost and camera alone.
                before = camera()
                ipc.key(56, True)
                ipc.key_down_up(15)
                ipc.key_down_up(1)
                ipc.key(56, False)
                tick()
                assert ipc.get_focused_window()["id"] == other
                assert zoom(other)["zoom_boosted"] and camera() == before

                mode("keep")
                switch_to(target)
                tick()
                assert not zoom(target)["zoom_boosted"]
                assert camera()["zoom_percent"] == 70

                # Camera focus leaves every saved per-window zoom unchanged.
                mode("camera")
                switch_to(other)
                tick()
                assert camera()["zoom_percent"] == 100
                switch_to(target)
                tick(80)
                live = next(a for a in ipc.action('get_animations') if a["site"] == "camera.zoom")
                assert 1 < live["value"] < 1 / 0.55 and not live["settled"], live
                tick()
                assert camera()["zoom_percent"] == 182
                assert abs(zoom(target)["effective_zoom"] - 1) < 1e-5
                assert window(target)["zoom_percent"] == 55
                assert not zoom(target)["zoom_boosted"]

                def opacity(wid):
                    return ipc.request(raw_cmd={"version": 1, "command": 'get_window_rules', "params": {"id": wid}})["live"]["effective_opacity"]

                assert abs(opacity(target) - 1) < 1e-5
                assert opacity(other) == 0, "windows passed by the camera remain visible"
                # Place the faded window in a clear part of this output: its
                # disabled scene must not intercept pointer input.
                cam = camera()
                ipc.action('move_window_to', {"id": other, "x": cam["x"] + 5, "y": cam["y"] + 50})
                hit = ipc.hit_test(35, 135)
                assert hit.get("window_id") != other, hit

                # Zooming out first returns to 100%, rather than skipping to
                # 85%; zooming in can return to the window's depth.
                ipc.key(125, True)
                ipc.key(56, True)
                ipc.action('scroll', {"dx": 0, "dy": 40})
                ipc.key(56, False)
                ipc.key(125, False)
                tick()
                assert camera()["zoom_percent"] == 100
                ipc.key(125, True)
                ipc.key(56, True)
                ipc.action('scroll', {"dx": 0, "dy": -40})
                ipc.key(56, False)
                ipc.key(125, False)
                tick()
                assert camera()["zoom_percent"] == 182

                # A new Settings window must remain reachable from a magnified
                # camera; it also gives users a way to turn this mode off.
                ipc.action('open_control_center')
                tick()
                assert camera()["zoom_percent"] == 100
                ipc.close_panel("control_center")
                tick()
                ipc.focus_window(other)

                mode("camera", extra="zoom_steps = [1.0, 0.85, 0.70, 0.55, 0.25]\n")
                ipc.focus_window(target)
                ipc.key(125, True)
                ipc.key_down_up(6)  # Super+5 selects the custom 25% window depth.
                ipc.key(125, False)
                tick()
                assert window(target)["zoom_percent"] == 25
                ipc.focus_window(other)
                switch_to(target)
                tick()
                assert camera()["zoom_percent"] == 400, camera()
                assert abs(zoom(target)["effective_zoom"] - 1) < 1e-5

                # Changing modes while magnified returns to an ordinary camera.
                mode("boost")
                assert camera()["zoom_percent"] == 100
                ipc.action('set_zoom', {"percent": 55})
                tick()
                switch_to(other)
                tick()
                ipc.minimize(other)
                tick()
                assert not zoom(other)["zoom_boosted"]

                # Reduced motion and disabled animations apply to both paths.
                for selected_mode, reduced, enabled in (("boost", "on", True), ("camera", "off", False)):
                    mode(selected_mode, reduced, enabled)
                    ipc.restore(other)
                    ipc.focus_window(other)
                    switch_to(target)
                    tick(0)
                    assert abs(zoom(target)["effective_zoom"] - 1) < 1e-5
                    assert all(a["settled"] for a in ipc.action('get_animations') if a["site"].startswith("camera.") or a["site"].endswith("zoom_boost"))
                ipc.action('set_anim_time', {"ms": None})
                print("PASS: Alt+Tab/taskbar eased reveal, boost geometry/pixels/input/lifetime, camera focus, mode changes and reduced motion")
        except Exception:
            print((tmp / "compositor.log").read_text()[-5000:])
            raise
        finally:
            for client in clients:
                stop_process(client)
            for handle in handles:
                handle.close()
            stop_process(process)
            log.close()


if __name__ == "__main__":
    os.umask(0o077)
    run()

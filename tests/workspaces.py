#!/usr/bin/env python3
"""Opt-in workspaces, group undo, automatic layout, visibility and presets."""
import os
import signal
from pathlib import Path
import subprocess
import sys
import tempfile
import time

from desktop_zoom import build_client, wait_for
from ipc_client import IPCClient, spawn_compositor, stop_process


def run(outputs=1):
    with tempfile.TemporaryDirectory(prefix="rediwm-workspaces-") as directory:
        tmp = Path(directory)
        from wlr_protocols import compile_fixture
        compile_fixture(tmp)
        canvas = '''[compositor]
desktop_mode = "canvas"
focus_zoom = "keep"
snap_to_edges = false
# Slow workspace slides: the hidden-input checks run while the old workspace
# is still sliding off screen.
desktop_switch_ms = 3000
[keybinds]
"Super+q" = "noop"
"Super+F12" = "noop"
[keybinds.workspace]
"Super+c" = "noop"
"Super+F12" = "workspace 3"
'''
        if os.getenv("REDIWM_TEST_NEGATIVE") == "1":
            canvas += '\n[[outputs]]\nname = "HEADLESS-1"\nx = 0\ny = 0\n[[outputs]]\nname = "HEADLESS-2"\nx = -1280\ny = -120\n'
        process, log = spawn_compositor(tmp, outputs=str(outputs), config_content=canvas,
            renderer=os.getenv("REDIWM_TEST_RENDERER", "gles2"), scale=os.getenv("REDIWM_TEST_SCALE", "1"),
            env_extra={"DBUS_SESSION_BUS_ADDRESS": "", "REDIWM_FILES_DEVICES": "0"})
        clients = []
        try:
            with IPCClient(tmp, timeout=15) as ipc:
                ipc.wait_for("wallpaper_presented", timeout_ms=10000)
                display = next(p.name for p in tmp.glob("wayland-*") if not p.name.endswith(".lock"))
                env = dict(os.environ, XDG_RUNTIME_DIR=str(tmp), XDG_STATE_HOME=str(tmp / "state"),
                    WAYLAND_DISPLAY=display, REDIWM_TEST_DECORATION="server", REDIWM_TEST_CLOSE_MARKER=str(tmp / "confirm-close"))

                def launch(name):
                    client = subprocess.Popen([str(tmp / "client"), "--app-id", name], env=env)
                    clients.append(client)
                    return wait_for(lambda: next((w for w in ipc.get_windows() if w["app_id"] == name), None), "map " + name)["id"]

                def window(id):
                    return next(w for w in ipc.get_windows() if w["id"] == id)

                def focused():
                    win = ipc.get_focused_window()
                    return win["id"] if win else None

                def workspace():
                    return next(w["id"] for w in ipc.get_workspaces() if w["is_focused"])

                def chord(key, shift=False):
                    ipc.key(125, True)
                    if shift: ipc.key(42, True)
                    ipc.key_press(key)
                    if shift: ipc.key(42, False)
                    ipc.key(125, False)

                def mode(workspaces):
                    (tmp / "rediwm-config.toml").write_text(canvas.replace('desktop_mode = "canvas"',
                        'desktop_mode = "tiling"' if workspaces else 'desktop_mode = "canvas"'))
                    wait_for(lambda: (ipc.get_workspaces()[0]["name"] != "Canvas") == workspaces, "mode reload")
                    ipc.wait_for_frame()

                def protocol_workspaces(activate=None):
                    return subprocess.check_output([str(tmp / "fixture"), "workspaces"] + ([str(activate)] if activate else []), env=env, text=True, timeout=15)

                a = launch("workspace-a")
                ipc.action("move_window_to", {"id": a, "x": 100, "y": 120})
                ipc.set_zoom(a, 70)
                time.sleep(.3)
                before = window(a)
                ipc.action("set_camera", {"x": 150, "y": 100})
                ipc.action("set_zoom", {"percent": 85})
                time.sleep(.4)
                camera_before = ipc.get_state()["camera"]
                ipc.key(125, True)
                ipc.key(88, True)  # Hold a canvas noop across the preset change.
                mode(True)
                initial_workspace = workspace()
                ipc.key(88, True)  # A held-key repeat must not invoke the new action.
                assert workspace() == initial_workspace
                ipc.key(88, False)
                ipc.key(125, False)
                original_workspace = window(a)["workspace_id"]
                assert window(a)["zoom_percent"] == 100, window(a)
                assert ipc.get_state()["camera"]["zoom_percent"] == 100
                marker = tmp / "confirm-close"
                marker.touch()
                ipc.action("close_window", {"id": a})
                dialog = wait_for(lambda: next((w for w in ipc.get_windows() if w["title"] == "Confirm close"), None), "dialog map")["id"]
                assert window(dialog)["workspace_id"] == original_workspace
                chord("6", shift=True)
                assert window(a)["workspace_id"] == window(dialog)["workspace_id"] == 6
                chord("z")
                assert window(a)["workspace_id"] == window(dialog)["workspace_id"] == original_workspace
                chord("6", shift=True)
                ipc.action("close_window", {"id": dialog})
                wait_for(lambda: focused() == a, "dialog focus returns to owner")
                marker.unlink()
                chord(str(original_workspace), shift=True)
                chord("F12")
                assert workspace() == 3
                assert focused() is None, ipc.get_focused_window()
                debug = ipc.get_window_debug(a)["chrome_box"]
                hit = ipc.hit_test(debug["x"] + 30, debug["y"] + 40)
                assert hit.get("window_id") != a, hit
                ipc.click_at(debug["x"] + 30, debug["y"] + 40)
                assert focused() is None
                # A later repaint/commit must not enable the hidden frame again.
                ipc.wait_for_frame()
                assert focused() is None
                b = launch("workspace-b")
                assert window(b)["workspace_id"] == 3
                chord("c")  # explicit noop overrides the close preset
                assert window(b)
                chord("4", shift=True)
                assert workspace() == 4 and window(b)["workspace_id"] == 4 and focused() == b, (ipc.get_workspaces(), window(b), ipc.get_focused_window())
                chord("3")
                assert focused() is None
                listing = protocol_workspaces(original_workspace)
                assert "workspace rediwm-canvas" not in listing and "workspace rediwm-workspace-4" in listing, listing
                assert f"groups {outputs} outputs {outputs}" in listing, listing
                assert workspace() == original_workspace
                ipc.focus_window(a)
                assert workspace() == original_workspace and focused() == a
                # Settings is a normal workspace member without a wl_surface.
                ipc.action("open_control_center")
                settings = wait_for(lambda: (ipc.get_focused_window() or {}).get("id"), "Settings focus")
                chord("5", shift=True)
                assert window(settings)["workspace_id"] == 5
                chord("3")
                assert focused() is None
                ipc.focus_window(settings)
                assert workspace() == 5 and focused() == settings
                ipc.action("close_window", {"id": settings})
                ipc.focus_window(b)
                # Input follows the slide: grab b once it has arrived.
                ipc.wait_for("window_geometry_settled", window_id=b, timeout_ms=10000)
                # Explicit placement floats a tile; Super-drag never pans the camera.
                ipc.action("move_window_to", {"id": b, "x": 100, "y": 120})
                ipc.wait_for_frame()
                box = ipc.get_window_debug(b)["client_box"]
                x, y = box["x"] + 40, box["y"] + 40
                old = window(b)
                ipc.move_cursor(x, y)
                ipc.key(125, True)
                ipc.pointer_button(0x110, True)
                ipc.move_cursor(x + 90, y + 50)
                ipc.pointer_button(0x110, False)
                ipc.key(125, False)
                assert window(b)["x"] == old["x"] + 90, (old, window(b))
                assert ipc.get_state()["camera"]["x"] == 0
                # Minimize retains membership, activation restores it, fullscreen
                # changes geometry without changing workspace ownership.
                ipc.key_down_up(68)  # F10 asks to minimize via xdg-shell.
                wait_for(lambda: window(b)["is_minimized"], "minimize")
                assert window(b)["workspace_id"] == 4
                chord("3")
                ipc.focus_window(b)
                assert workspace() == 4 and focused() == b
                chord("f")
                chord("f")
                assert window(b)["workspace_id"] == 4
                if outputs > 1:
                    other = next(o for o in ipc.get_outputs() if o["x"] != 0)
                    ipc.move_cursor(200, 200, output=other["name"])
                    chord(str(original_workspace))
                    assert focused() == a
                    assert next(o["name"] for o in ipc.get_outputs() if o["is_focused"]) != other["name"]
                mode(False)
                restored = window(a)
                assert (restored["x"], restored["y"], restored["zoom_percent"]) == (before["x"], before["y"], before["zoom_percent"]), (before, restored)
                assert ipc.get_state()["camera"] == camera_before, (camera_before, ipc.get_state()["camera"])
                assert all(w["workspace_id"] == 1 for w in ipc.get_windows())
                # Repeated transitions capture a fresh canvas snapshot each time.
                mode(True)
                mode(False)
                assert window(a)["zoom_percent"] == before["zoom_percent"]
                # Super+Shift+W switches and saves both ways: this config's own
                # [keybinds] inherits it, and the workspace preset keeps the key.
                cfg = tmp / "rediwm-config.toml"
                at_canvas = (window(a)["x"], window(a)["y"])
                chord("w", shift=True)
                wait_for(lambda: ipc.get_workspaces()[0]["name"] != "Canvas", "shortcut to workspaces")
                wait_for(lambda: 'desktop_mode = "tiling"' in cfg.read_text(), "tiling saved")
                chord("w", shift=True)
                wait_for(lambda: ipc.get_workspaces()[0]["name"] == "Canvas", "shortcut to canvas")
                wait_for(lambda: 'desktop_mode = "canvas"' in cfg.read_text(), "canvas saved")
                assert (window(a)["x"], window(a)["y"]) == at_canvas, (at_canvas, window(a))
                assert '[keybinds]\n"Super+q" = "noop"' in cfg.read_text()
                # The taskbar item is opt-in; shown, its label and icon follow the
                # mode and a click switches it.
                def mode_item():
                    return next((w for w in ipc.get_widget_tree("taskbar")["widgets"] if w["name"] == "desktop_mode"), None)
                assert mode_item() is None, "the desktop mode item defaults off"
                if outputs == 1:
                    from PIL import Image, ImageChops
                    scale = float(os.getenv("REDIWM_TEST_SCALE", "1"))
                    cfg.write_text(canvas.replace('desktop_mode = "canvas"', 'desktop_mode = "canvas"\ntaskbar_items = ["left:start", "left:windows", "right:tray", "right:battery", "~right:wifi", "~right:wired", "right:desktop_mode", "~right:input_source", "right:volume", "right:clock"]'))
                    item = wait_for(mode_item, "desktop mode item shown")
                    ipc.wait_for_frame()
                    def icon(name):
                        path = tmp / f"desktop-mode-{name}.png"
                        ipc.screenshot(str(path))
                        b = mode_item()["global_box"]
                        with Image.open(path) as image:
                            return image.convert("RGB").crop(tuple(round(v * scale) for v in (b["x"], b["y"], b["x"] + b["width"], b["y"] + b["height"])))
                    canvas_icon = icon("canvas")
                    assert item["label"] == "Canvas", item
                    for target, label in (("tiling", "Tiling"), ("canvas", "Canvas")):
                        box = mode_item()["global_box"]
                        ipc.click_at(round(box["x"] + box["width"] / 2), round(box["y"] + box["height"] / 2))
                        wait_for(lambda: (ipc.get_workspaces()[0]["name"] != "Canvas") == (target == "tiling"), "taskbar item to " + target)
                        wait_for(lambda: f'desktop_mode = "{target}"' in cfg.read_text(), target + " saved by the item")
                        assert mode_item()["label"] == label, mode_item()
                        ipc.move_cursor(400, 300)
                        ipc.wait_for_frame()
                        time.sleep(.3)  # hover and press settle
                        if target == "tiling":
                            assert ImageChops.difference(canvas_icon, icon(target)).getbbox(), "the item's icon shows the mode"
                    assert not ImageChops.difference(canvas_icon, icon("canvas-again")).getbbox(), "back to the Canvas icon"
                    mode(False)
                ipc.action("reset_camera")
                # The floating fixture overlaps the Canvas segment once Settings
                # becomes a strip member. Put it away before testing the control.
                ipc.minimize(b)
                ipc.action("open_control_center")
                ipc.wait_for_panel_settled("control_center")
                settings = ipc.get_focused_window()["id"]
                def widget_click(widget, fraction=.5):
                    box = widget["global_box"]
                    ipc.click_at(round(box["x"] + box["width"] * fraction), round(box["y"] + box["height"] / 2))
                widgets = ipc.get_widget_tree("control_center")["widgets"]
                widget_click(next(w for w in widgets if w["label"] == "Desktop"))
                # Canvas, Tiling and Scrolling share the control in thirds.
                for fraction, layout in [(.5, "split"), (.85, "scrolling"), (.15, None)]:
                    # A mode change queues a tiling reflow. After it runs, the
                    # Settings frame and its responsive widget tree settle separately.
                    ipc.wait_for_frame()
                    ipc.wait_for("window_geometry_settled", window_id=settings, timeout_ms=10000)
                    ipc.wait_for_panel_settled("control_center")
                    widget = next(w for w in ipc.get_widget_tree("control_center")["widgets"] if (w["path"] or "").endswith("/desktop_mode"))
                    widget_click(widget, fraction)
                    wait_for(lambda: ipc.get_workspaces()[0].get("layout") == layout if layout else ipc.get_workspaces()[0]["name"] == "Canvas", f"Settings mode control ({layout or 'canvas'})")
                assert '[keybinds]\n"Super+q" = "noop"' in (tmp / "rediwm-config.toml").read_text()
                assert process.poll() is None
                print(f"PASS: workspaces, visibility, preset, Settings and canvas restore ({outputs} outputs)", flush=True)
        except Exception:
            print((tmp / "compositor.log").read_text()[-6000:])
            raise
        finally:
            for client in clients: stop_process(client)
            stop_process(process)
            log.close()




def manual_controls():
    """Shared actions, tile insertion, reversible split resize and remapping."""
    with tempfile.TemporaryDirectory(prefix="rediwm-tiling-controls-") as directory:
        tmp = Path(directory)
        build_client(tmp)
        from launch_placeholder import build_test_client, create_desktop_entry
        slow_client = build_test_client(tmp)
        apps = tmp / "data/applications"
        apps.mkdir(parents=True)
        create_desktop_entry(apps, "controls-slow.desktop", "Tiling slow client",
            f"{slow_client} --app-id controls.slow --sleep-ms 700", "controls.slow")
        config = '''[compositor]
desktop_mode = "tiling"
window_gap = 8
placeholder_delay_ms = 120
[keybinds.workspace]
"Super+F11" = "tile_left"
[animations]
enabled = false
'''
        outputs = int(os.getenv("REDIWM_TEST_OUTPUTS", "1"))
        if outputs > 1 and os.getenv("REDIWM_TEST_NEGATIVE") == "1":
            config += '\n[[outputs]]\nname = "HEADLESS-1"\nx = 0\ny = 0\n[[outputs]]\nname = "HEADLESS-2"\nx = -1280\ny = -120\n'
        process, log = spawn_compositor(tmp, outputs=str(outputs), config_content=config,
            renderer=os.getenv("REDIWM_TEST_RENDERER", "gles2"), scale=os.getenv("REDIWM_TEST_SCALE", "1"),
            env_extra={"DBUS_SESSION_BUS_ADDRESS": "", "XDG_DATA_HOME": str(tmp / "data")})
        clients = []
        try:
            with IPCClient(tmp, timeout=15) as ipc:
                ipc.wait_for("wallpaper_presented", timeout_ms=10000)
                display = next(p.name for p in tmp.glob("wayland-*") if not p.name.endswith(".lock"))
                env = dict(os.environ, XDG_RUNTIME_DIR=str(tmp), WAYLAND_DISPLAY=display,
                    XDG_STATE_HOME=str(tmp / "state"), REDIWM_TEST_DECORATION="server", REDIWM_TEST_COMMANDS="1")
                def launch(name):
                    with (tmp / (name + ".log")).open("w") as stream:
                        child = subprocess.Popen([str(tmp / "client"), "--app-id", name], env=env,
                            stdin=subprocess.PIPE, stdout=stream, stderr=stream, text=True)
                    clients.append(child)
                    return wait_for(lambda: next((w["id"] for w in ipc.get_windows() if w["app_id"] == name), None), "map " + name), child
                def win(id): return next(w for w in ipc.get_windows() if w["id"] == id)
                def frame(id):
                    box = ipc.get_window_debug(id)["chrome_box"]
                    return tuple(round(box[k]) for k in ("x", "y", "width", "height"))
                def expect(id, rect):
                    try: wait_for(lambda: frame(id) == rect, f"tile {id} expected {rect}")
                    except AssertionError: raise AssertionError((id, rect, frame(id))) from None
                def action(name, id=None):
                    ipc.action("tiling_action", {"action": name, **({"id": id} if id is not None else {})})
                def chord(key, shift=False, ctrl=False):
                    ipc.key(125, True)
                    if shift: ipc.key(42, True)
                    if ctrl: ipc.key(29, True)
                    ipc.key_press(key)
                    if ctrl: ipc.key(29, False)
                    if shift: ipc.key(42, False)
                    ipc.key(125, False)
                def move(x, y, output=None):
                    if output is not None: return ipc.move_cursor(x, y, output=output)
                    out = next(o for o in ipc.get_outputs() if o["x"] <= x < o["x"] + o["logical_width"] and o["y"] <= y < o["y"] + o["logical_height"])
                    return ipc.move_cursor(x - out["x"], y - out["y"], output=out["name"])
                def begin_drag(id, button=0x110):
                    ipc.focus_window(id)
                    box = ipc.get_window_debug(id)["client_box"]
                    x, y = box["x"] + box["width"] // 2, box["y"] + min(50, box["height"] // 2)
                    move(x, y)
                    ipc.key(125, True)
                    ipc.pointer_button(button, True)
                    assert ipc.get_input_state()["cursor_mode"] == ("resize" if button == 0x111 else "move")
                    return x, y
                def end_drag(button=0x110, cancel=False):
                    if cancel: ipc.key_press("Escape")
                    ipc.pointer_button(button, False)
                    ipc.key(125, False)
                    assert ipc.get_input_state()["cursor_mode"] == "passthrough"
                a, ca = launch("controls-a")
                b, cb = launch("controls-b")
                wait_for(lambda: frame(a)[0] < frame(b)[0] and frame(a)[2] == frame(b)[2], "two halves")
                halves = {a: frame(a), b: frame(b)}
                # Each operation owns the complete affected layout, so undo
                # restores neighbours as well as the explicitly targeted tile.
                ipc.focus_window(a)
                action("swap_right", a)
                expect(a, halves[b]); expect(b, halves[a])
                chord("z")
                expect(a, halves[a]); expect(b, halves[b])
                action("toggle_split", a)
                wait_for(lambda: frame(a)[2] > halves[a][2], "rotation before undo")
                # An inapplicable directional operation must keep the snapshot.
                action("swap_left", a)
                ipc.action("undo")
                expect(a, halves[a]); expect(b, halves[b])
                action("resize_split_right", a)
                wait_for(lambda: frame(a)[2] > halves[a][2], "key resize before undo")
                ipc.action("undo")
                expect(a, halves[a]); expect(b, halves[b])
                for command, params in (("move_window_to", {"id": a, "x": 100, "y": 100}),
                                        ("set_window_size", {"id": a, "width": 450, "height": 300})):
                    ipc.action(command, params)
                    wait_for(lambda: frame(b)[2] > halves[b][2], "explicit placement before undo")
                    ipc.action("undo")
                    expect(a, halves[a]); expect(b, halves[b])
                ipc.focus_window(a)
                chord("F11")
                wait_for(lambda: frame(b)[2] > halves[b][2], "manual snap before undo")
                ipc.action("undo")
                expect(a, halves[a]); expect(b, halves[b])
                action("toggle_floating", a)
                wait_for(lambda: frame(b)[2] > halves[b][2], "floating before undo")
                ipc.action("undo")
                expect(a, halves[a]); expect(b, halves[b])
                action("toggle_workspace_tiling", a)
                wait_for(lambda: ipc.get_window_debug(a)["client_box"]["width"] == 400, "workspace off before undo")
                ipc.action("undo")
                expect(a, halves[a]); expect(b, halves[b])
                # Late client configure replies cannot make a real floating
                # resize look like a no-op or evict its starting geometry.
                action("toggle_floating", a)
                wait_for(lambda: ipc.get_window_debug(a)["client_box"]["width"] == 400, "floating resize origin")
                floating_rect = frame(a)
                for pointer in (False, True):
                    os.kill(ca.pid, signal.SIGSTOP)
                    try:
                        if pointer:
                            x, y = begin_drag(a, 0x111)
                            move(x + 70, y + 35)
                            end_drag(0x111)
                        else:
                            ipc.action("set_window_size", {"id": a, "width": 450, "height": 300})
                        ipc.action("undo")
                    finally:
                        os.kill(ca.pid, signal.SIGCONT)
                    expect(a, floating_rect)
                action("toggle_floating", a)
                expect(a, halves[a]); expect(b, halves[b])
                for override in ("fullscreen", "minimize"):
                    ipc.focus_window(a)
                    action("resize_split_right", a)
                    wait_for(lambda: frame(a)[2] > halves[a][2], "resize before lifecycle override")
                    if override == "fullscreen":
                        ipc.action("fullscreen_window", {"id": a})
                        wait_for(lambda: ipc.get_window_debug(a)["fullscreen"], "fullscreen before undo")
                    else:
                        ipc.action("minimize_window", {"id": a})
                        wait_for(lambda: win(a)["is_minimized"], "minimize before undo")
                    ipc.action("undo")
                    if override == "fullscreen":
                        assert ipc.get_window_debug(a)["fullscreen"]
                        ipc.action("fullscreen_window", {"id": a})
                    else:
                        assert win(a)["is_minimized"]
                        ipc.focus_window(a)
                    expect(a, halves[a]); expect(b, halves[b])
                # Group snapshots also restore both sides of a transfer.
                original = win(a)["workspace_id"]
                chord("8", shift=True)
                wait_for(lambda: win(a)["workspace_id"] == 8, "transfer before undo")
                ipc.action("undo")
                assert win(a)["workspace_id"] == original
                expect(a, halves[a]); expect(b, halves[b])
                # A released divider drag is undoable. Super+Z during a live
                # divider drag ends the grab first; a late release is harmless.
                for live in (False, True):
                    x, y = begin_drag(a, 0x111)
                    move(x + 80, y)
                    wait_for(lambda: frame(a)[2] > halves[a][2], "pointer resize before undo")
                    if live:
                        ipc.key_press("z")
                    else:
                        end_drag(0x111)
                        ipc.action("undo")
                    expect(a, halves[a]); expect(b, halves[b])
                    if live: end_drag(0x111)
                bx, by, bw, bh = frame(b)
                begin_drag(a)
                move(bx + bw // 2, by + bh - 30)
                end_drag()
                wait_for(lambda: frame(a)[1] > frame(b)[1], "insertion before undo")
                ipc.action("undo")
                expect(a, halves[a]); expect(b, halves[b])
                if outputs > 1:
                    source = next(o for o in ipc.get_outputs() if o["x"] <= frame(a)[0] < o["x"] + o["logical_width"])
                    destination = next(o for o in ipc.get_outputs() if o["name"] != source["name"])
                    move(200, 200, output=destination["name"])
                    d, cd = launch("controls-undo-destination")
                    destination_rect = frame(d)
                    for override in ("fullscreen_window", "maximize_window"):
                        ipc.focus_window(a)
                        ipc.action(override, {"id": a})
                        wait_for(lambda: (ipc.get_window_debug(a)["fullscreen"] if override == "fullscreen_window" else win(a)["is_maximized"]), "override before output transfer")
                        override_rect = frame(a)
                        ipc.action("move_window_to", {"id": a, "output": destination["name"]})
                        try:
                            wait_for(lambda: win(a)["workspace_id"] == win(d)["workspace_id"], "forced layout transfer")
                        except AssertionError:
                            raise AssertionError((override, win(a), win(d), ipc.get_outputs())) from None
                        ipc.action("undo")
                        assert win(a)["workspace_id"] == original
                        expect(a, override_rect); expect(d, destination_rect)
                        ipc.action("fullscreen_window" if override == "fullscreen_window" else "restore_window", {"id": a})
                        expect(a, halves[a]); expect(b, halves[b])
                    for floating in (False, True):
                        ipc.focus_window(a)
                        if floating:
                            action("toggle_floating", a)
                            wait_for(lambda: ipc.get_window_debug(a)["client_box"]["width"] == 400, "floating transfer origin")
                        origin_rect = frame(a)
                        begin_drag(a)
                        move(250, 230, output=destination["name"])
                        end_drag()
                        wait_for(lambda: win(a)["workspace_id"] == win(d)["workspace_id"], "cross-output drop before undo")
                        ipc.action("undo")
                        assert win(a)["workspace_id"] == original
                        expect(a, origin_rect); expect(d, destination_rect)
                        if floating: action("toggle_floating", a)
                        expect(a, halves[a]); expect(b, halves[b])
                    stop_process(cd)
                    wait_for(lambda: all(w["id"] != d for w in ipc.get_windows()), "close destination tile")
                # Closing the focused leaf after a resize does not consume
                # undo or resurrect it; the remaining split keeps its ratio.
                ipc.focus_window(b)
                c, cc = launch("controls-undo-closed")
                wait_for(lambda: frame(b)[3] < halves[b][3], "undo third tile")
                baseline = {a: frame(a), b: frame(b)}
                ipc.focus_window(c)
                action("resize_split_right", a)
                wait_for(lambda: frame(a)[2] > baseline[a][2], "resize before close and undo")
                stop_process(cc)
                wait_for(lambda: all(w["id"] != c for w in ipc.get_windows()), "close undo member")
                ipc.action("undo")
                expect(a, halves[a]); expect(b, halves[b])
                ipc.focus_window(a)
                chord("Right", shift=True)
                expect(a, halves[b])
                expect(b, halves[a])
                action("swap_left", a)
                expect(a, halves[a])
                action("toggle_split", a)
                wait_for(lambda: frame(a)[1] < frame(b)[1] and frame(a)[2] > halves[a][2], "rotate split")
                ipc.focus_window(a)
                chord("j")
                expect(a, halves[a])
                chord("Right", ctrl=True)
                wait_for(lambda: frame(a)[2] > halves[a][2], "resize split key")
                action("resize_split_left", a)
                expect(a, halves[a])
                chord("v")
                wait_for(lambda: ipc.get_window_debug(a)["client_box"]["width"] == 400, "float restore")
                wait_for(lambda: frame(b)[2] > halves[b][2], "remaining tile fills area")
                chord("v")
                expect(a, halves[a])
                expect(b, halves[b])
                chord("space", shift=True)
                wait_for(lambda: ipc.get_window_debug(b)["client_box"]["width"] == 400, "workspace floats")
                action("toggle_workspace_tiling", a)
                expect(a, halves[a])
                expect(b, halves[b])
                # A move preview makes no geometry changes; Escape is exact.
                from PIL import Image
                bx, by, bw, bh = frame(b)
                preview_output = next(o for o in ipc.get_outputs() if o["x"] <= bx < o["x"] + o["logical_width"])
                def preview_pixel(path):
                    ipc.screenshot(str(path), output=preview_output["name"])
                    image = Image.open(path)
                    scale = image.width / preview_output["logical_width"]
                    return image.getpixel((round((bx + bw // 2 - preview_output["x"]) * scale), round((by + bh - 70 - preview_output["y"]) * scale)))
                before_preview = preview_pixel(tmp / "before-preview.png")
                begin_drag(a)
                move(bx + bw // 2, by + bh - 30)
                expect(a, halves[a])
                expect(b, halves[b])
                ipc.wait_for_frame()
                assert preview_pixel(tmp / "during-preview.png") != before_preview, "insertion preview is invisible"
                end_drag(cancel=True)
                ipc.wait_for_frame()
                assert preview_pixel(tmp / "after-preview.png") == before_preview, "cancel left a preview behind"
                expect(a, halves[a])
                # The same drop inserts below B and collapses A's old split.
                begin_drag(a)
                move(bx + bw // 2, by + bh - 30)
                end_drag()
                wait_for(lambda: frame(a)[1] > frame(b)[1] and frame(a)[2] > halves[a][2], "drag insertion")
                action("toggle_split", a)
                action("swap_left", a)
                expect(a, halves[a])
                expect(b, halves[b])
                # Live split resizing uses an owned snapshot for Escape.
                x, y = begin_drag(a, 0x111)
                move(x + 90, y)
                wait_for(lambda: frame(a)[2] > halves[a][2], "live split resize")
                end_drag(0x111, cancel=True)
                expect(a, halves[a])
                expect(b, halves[b])
                x, y = begin_drag(a, 0x111)
                move(x + 90, y)
                end_drag(0x111)
                wait_for(lambda: frame(a)[2] > halves[a][2], "committed split resize")
                resized = {a: frame(a), b: frame(b)}
                x, y = begin_drag(a, 0x111)
                move(x + 40, y)
                wait_for(lambda: frame(a)[2] > resized[a][2], "resize before fullscreen")
                ipc.action("fullscreen_window", {"id": a})
                wait_for(lambda: ipc.get_input_state()["cursor_mode"] == "passthrough", "fullscreen cancels tiled grab")
                end_drag(0x111)
                ipc.action("fullscreen_window", {"id": a})
                expect(a, resized[a])
                expect(b, resized[b])
                # Real unmap/remap, with the original neighbour still alive.
                cb.stdin.write("unmap\n"); cb.stdin.flush()
                wait_for(lambda: all(w["id"] != b for w in ipc.get_windows()), "unmap")
                wait_for(lambda: frame(a)[2] > resized[a][2], "unmap reflow")
                cb.stdin.write("remap\n"); cb.stdin.flush()
                wait_for(lambda: any(w["id"] == b for w in ipc.get_windows()), "remap")
                expect(a, resized[a])
                expect(b, resized[b])
                # A close during a live resize cannot leave a stale tree/grab.
                c, cc = launch("controls-c")
                wait_for(lambda: frame(b)[3] < resized[b][3], "third tile")
                x, y = begin_drag(a, 0x111)
                move(x + 40, y)
                stop_process(cc)
                wait_for(lambda: all(w["id"] != c for w in ipc.get_windows()), "close during resize")
                end_drag(0x111, cancel=True)
                expect(a, resized[a])
                expect(b, resized[b])
                begin_drag(b)
                stop_process(cb)
                wait_for(lambda: all(w["id"] != b for w in ipc.get_windows()), "close dragged tile")
                end_drag()
                assert ipc.get_input_state()["grabbed_window_id"] is None
                # Workspace transfer follows the same membership path as drop.
                ipc.focus_window(a)
                original_workspace = win(a)["workspace_id"]
                chord("7", shift=True)
                assert win(a)["workspace_id"] == 7
                chord(str(original_workspace), shift=True)
                assert win(a)["workspace_id"] == original_workspace
                if outputs > 1:
                    source = next(o for o in ipc.get_outputs() if o["x"] <= frame(a)[0] < o["x"] + o["logical_width"])
                    destination = next(o for o in ipc.get_outputs() if o["name"] != source["name"])
                    begin_drag(a)
                    move(200, 200, output=destination["name"])
                    end_drag()
                    wait_for(lambda: win(a)["workspace_id"] != original_workspace, "cross-output tile drop")
                    moved = frame(a)
                    assert destination["x"] <= moved[0] < destination["x"] + destination["logical_width"], (destination, moved)
                    # Drop back onto a workspace whose automatic layout is off.
                    move(200, 200, output=source["name"])
                    chord(str(original_workspace))
                    action("toggle_workspace_tiling")
                    begin_drag(a)
                    move(200, 200, output=source["name"])
                    move(260, 230, output=source["name"])
                    end_drag()
                    wait_for(lambda: win(a)["workspace_id"] == original_workspace and ipc.get_window_debug(a)["client_box"]["width"] == 400, "drop onto floating workspace")
                    assert source["x"] <= frame(a)[0] < source["x"] + source["logical_width"]
                    action("toggle_workspace_tiling", a)
                    wait_for(lambda: frame(a)[2] > 1000, "retile destination workspace")
                # Launch placeholders own one stable slot, transferred to the
                # real client. Closing a pending placeholder also reflows.
                full = frame(a)
                ipc.wait_for("catalog_published", timeout_ms=5000)
                ipc.action("launch_app", {"desktop_id": "controls-slow.desktop"})
                ph = wait_for(lambda: next((w for w in ipc.get_windows() if w.get("placeholder")), None), "placeholder")
                wait_for(lambda: win(ph["id"])["width"] < full[2], "placeholder tile")
                wait_for(lambda: frame(a)[2] < full[2], "peer acknowledges placeholder split")
                ph_box = tuple(win(ph["id"])[k] for k in ("x", "y", "width", "height"))
                peer_box = frame(a)
                action("toggle_split", ph["id"])
                wait_for(lambda: win(ph["id"])["width"] > ph_box[2], "placeholder rearrangement")
                arranged_placeholder = tuple(win(ph["id"])[k] for k in ("x", "y", "width", "height"))
                real = wait_for(lambda: next((w for w in ipc.get_windows() if w["app_id"] == "controls.slow" and not w.get("placeholder")), None), "placeholder matched")
                expect(real["id"], arranged_placeholder)
                ipc.action("undo")
                expect(a, peer_box)
                expect(real["id"], ph_box)
                ipc.close_window(real["id"])
                wait_for(lambda: all(w["id"] != real["id"] for w in ipc.get_windows()), "close launched client")
                expect(a, full)
                ipc.action("launch_app", {"desktop_id": "controls-slow.desktop"})
                ph = wait_for(lambda: next((w for w in ipc.get_windows() if w.get("placeholder")), None), "pending placeholder")
                ipc.close_window(ph["id"])
                wait_for(lambda: all(w["id"] != ph["id"] for w in ipc.get_windows()), "cancel placeholder")
                expect(a, full)
                print(f"PASS: tiling controls, group undo, late replies, insertion, Escape, split resize, remap and lifecycle ({outputs} outputs)", flush=True)
        except Exception:
            print((tmp / "compositor.log").read_text()[-7000:])
            for path in tmp.glob("controls-*.log"): print(path.name, path.read_text()[-1800:])
            raise
        finally:
            for child in clients: stop_process(child)
            stop_process(process)
            log.close()


def automatic_layout():
    with tempfile.TemporaryDirectory(prefix="rediwm-auto-tiles-") as directory:
        tmp = Path(directory)
        build_client(tmp)
        config = '''[compositor]
desktop_mode = "tiling"
window_gap = 8
[keybinds.workspace]
"Super+Shift+Left" = "tile_left"
'''
        process, log = spawn_compositor(tmp, config_content=config,
            renderer=os.getenv("REDIWM_TEST_RENDERER", "gles2"), scale=os.getenv("REDIWM_TEST_SCALE", "1"),
            env_extra={"DBUS_SESSION_BUS_ADDRESS": ""})
        clients = []
        try:
            with IPCClient(tmp, timeout=15) as ipc:
                ipc.wait_for("wallpaper_presented", timeout_ms=10000)
                display = next(p.name for p in tmp.glob("wayland-*") if not p.name.endswith(".lock"))
                env = dict(os.environ, XDG_RUNTIME_DIR=str(tmp), WAYLAND_DISPLAY=display,
                    XDG_STATE_HOME=str(tmp / "state"), REDIWM_TEST_DECORATION="server")
                def launch(name, constraints=None):
                    child_env = dict(env)
                    if constraints:
                        path = tmp / (name + ".hints")
                        path.write_text(constraints)
                        child_env["REDIWM_TEST_CONSTRAINTS"] = str(path)
                    with (tmp / (name + ".log")).open("w") as stream:
                        child = subprocess.Popen([str(tmp / "client"), "--app-id", name], env=child_env, stdout=stream, stderr=stream)
                    clients.append(child)
                    top = wait_for(lambda: next((w for w in ipc.get_windows() if w["app_id"] == name), None), "map " + name)
                    return top["id"], child
                def frame(id):
                    b = ipc.get_window_debug(id)["chrome_box"]
                    return tuple(round(b[k]) for k in ("x", "y", "width", "height"))
                def expect(id, rect):
                    try: wait_for(lambda: frame(id) == rect, f"tile {id} should occupy {rect}")
                    except AssertionError: raise AssertionError((id, rect, frame(id))) from None
                def chord(key, shift=False):
                    ipc.key(125, True)
                    if shift: ipc.key(42, True)
                    ipc.key_press(key)
                    if shift: ipc.key(42, False)
                    ipc.key(125, False)
                output = ipc.get_outputs()[0]
                width = output["logical_width"]
                height = output["logical_height"] - next(p for p in ipc.list_panels()["panels"] if p.get("name") == "taskbar")["box"]["height"]
                full = (8, 8, width - 16, height - 16)
                left_w = (width - 24 + 1) // 2
                half = (8, 8, left_w, height - 16)
                right = (16 + left_w, 8, width - 24 - left_w, height - 16)
                a, ca = launch("auto-a", "0 0 0 0")
                expect(a, full)
                oversized, oversized_client = launch("auto-oversized", f"{width} 100 0 0")
                expect(a, full)
                stop_process(oversized_client)
                wait_for(lambda: all(w["id"] != oversized for w in ipc.get_windows()), "close overflow")
                b, cb = launch("auto-b", "0 0 0 0")
                expect(a, half)
                expect(b, right)
                # A floating snapshot obeys client limits that changed while
                # it was tiled; undo must not request the obsolete saved size.
                ipc.focus_window(a)
                for _ in range(2):
                    ipc.action("tiling_action", {"id": a, "action": "toggle_floating"})
                    if _ == 0:
                        wait_for(lambda: ipc.get_window_debug(a)["client_box"]["width"] == 400, "floating snapshot")
                    else:
                        expect(a, half)
                (tmp / "auto-a.hints").write_text("0 0 300 0")
                ipc.key_down_up(87)
                wait_for(lambda: ipc.get_window_debug(a)["client_box"]["width"] == 300, "new live maximum")
                ipc.action("undo")
                wait_for(lambda: ipc.get_window_debug(a)["client_box"]["height"] == 260, "floating undo with new maximum")
                assert ipc.get_window_debug(a)["client_box"]["width"] == 300
                (tmp / "auto-a.hints").write_text("0 0 0 0")
                ipc.key_down_up(87)
                ipc.action("tiling_action", {"id": a, "action": "toggle_floating"})
                expect(a, half); expect(b, right)
                # A new window splits the focused tile along its longer side.
                ipc.focus_window(b)
                c, cc = launch("auto-c", "0 0 0 0")
                if right[2] >= right[3]:
                    cw = (right[2] - 8 + 1) // 2
                    second = (right[0], 8, cw, right[3])
                    third = (right[0] + cw + 8, 8, right[2] - cw - 8, right[3])
                else:
                    ch = (height - 24 + 1) // 2
                    second = (right[0], 8, right[2], ch)
                    third = (right[0], 16 + ch, right[2], height - 24 - ch)
                expect(a, half)
                expect(b, second)
                expect(c, third)
                for id in (a, b, c, a):
                    ipc.focus_window(id)
                    expect(a, half)
                    expect(b, second)
                    expect(c, third)
                # With the older tile focused, a new one splits it, not the newest.
                if half[2] >= half[3]:
                    dw = (half[2] - 8 + 1) // 2
                    kept, added = (8, 8, dw, half[3]), (16 + dw, 8, half[2] - dw - 8, half[3])
                else:
                    dh = (half[3] - 8 + 1) // 2
                    kept, added = (8, 8, half[2], dh), (8, 16 + dh, half[2], half[3] - dh - 8)
                d, cd = launch("auto-d", "0 0 0 0")
                expect(a, kept)
                expect(d, added)
                expect(b, second)
                expect(c, third)
                stop_process(cd)
                wait_for(lambda: all(w["id"] != d for w in ipc.get_windows()), "close d")
                expect(a, half)
                # Minimize and temporary geometry overrides preserve the split.
                ipc.focus_window(c)
                ipc.key_down_up(68)
                wait_for(lambda: next(w for w in ipc.get_windows() if w["id"] == c)["is_minimized"], "minimized")
                expect(b, right)
                ipc.focus_window(c)
                expect(c, third)
                ipc.key_down_up(66)
                expect(b, right)
                ipc.key_down_up(67)
                expect(b, second)
                expect(c, third)
                chord("f")
                expect(b, right)
                chord("f")
                expect(c, third)
                # A live minimum-size update overflows only the newest member.
                (tmp / "auto-c.hints").write_text(f"{width} 100 0 0")
                ipc.key_down_up(87)
                expect(b, right)
                expect(a, half)
                (tmp / "auto-c.hints").write_text("0 0 0 0")
                ipc.key_down_up(87)
                expect(c, third)
                # Decoration changes keep the same outer frame; maximum sizes
                # are honored inside the allocated tile without moving peers.
                ipc.key_down_up(63)
                expect(c, third)
                wait_for(lambda: ipc.get_window_debug(c)["client_box"]["width"] == third[2], "client-side decoration")
                ipc.key_down_up(64)
                expect(c, third)
                (tmp / "auto-c.hints").write_text("0 0 250 0")
                ipc.key_down_up(87)
                wait_for(lambda: ipc.get_window_debug(c)["client_box"]["width"] == 250, "maximum width")
                expect(a, half)
                expect(b, second)
                (tmp / "auto-c.hints").write_text("0 0 0 0")
                ipc.key_down_up(87)
                expect(c, third)
                # No configure feedback loop after clients acknowledge layout.
                time.sleep(.4)
                before = (tmp / "auto-c.log").read_text().count("configure ")
                time.sleep(.5)
                assert (tmp / "auto-c.log").read_text().count("configure ") == before
                # Explicit manual snapping opts out and the other tiles reflow.
                chord("Left", shift=True)
                expect(a, half)
                expect(b, right)
                stop_process(cc)
                wait_for(lambda: all(w["id"] != c for w in ipc.get_windows()), "close c")
                # A smaller output evicts later members deterministically.
                for name, id in (("auto-a", a), ("auto-b", b)):
                    (tmp / (name + ".hints")).write_text(f"{width // 3} 100 0 0")
                    ipc.focus_window(id)
                    ipc.key_down_up(87)
                config_path = tmp / "rediwm-config.toml"
                config_path.write_text(config + '\n[[outputs]]\nname = "HEADLESS-1"\ntransform = "90"\n')
                ipc.reload_config()
                smaller = wait_for(lambda: next((o for o in ipc.get_outputs() if o["logical_width"] == output["logical_height"]), None), "output rotated")
                small_height = smaller["logical_height"] - next(p for p in ipc.list_panels()["panels"] if p.get("name") == "taskbar")["box"]["height"]
                expect(a, (8, 8, smaller["logical_width"] - 16, small_height - 16))
                config_path.write_text(config)
                ipc.reload_config()
                expect(a, half)
                expect(b, right)
                stop_process(cb)
                wait_for(lambda: all(w["id"] != b for w in ipc.get_windows()), "close b")
                expect(a, full)
                fixed, cf = launch("auto-fixed", "240 160 240 160")
                expect(a, full)
                wait_for(lambda: ipc.get_window_debug(fixed)["client_box"]["width"] == 240, "fixed width")
                assert process.poll() is None
                print("PASS: automatic splits, stable focus, constraints, overflow, overrides, manual snap and close", flush=True)
        except Exception:
            print((tmp / "compositor.log").read_text()[-6000:])
            raise
        finally:
            for child in clients: stop_process(child)
            stop_process(process)
            log.close()


def rollout_acceptance():
    """Live output changes, real input, bounded configures, idle and lock guards."""
    from wlr_protocols import compile_fixture, expect_line, locked
    from ipc_client import IPCError
    with tempfile.TemporaryDirectory(prefix="rediwm-workspace-rollout-") as directory:
        tmp = Path(directory)
        compile_fixture(tmp)
        base = '[compositor]\nxwayland = false\ndesktop_mode = "tiling"\nwindow_gap = 8\n'
        outputs = int(os.getenv("REDIWM_TEST_OUTPUTS", "1"))
        def config(scale=1, x=0, y=0):
            value = base + f'[[outputs]]\nname = "HEADLESS-1"\nscale = {scale}\nx = {x}\ny = {y}\n'
            if outputs > 1:
                value += '[[outputs]]\nname = "HEADLESS-2"\nscale = 1.5\nx = 1600\ny = -120\n'
            return value
        process, log = spawn_compositor(tmp, outputs=str(outputs), config_content=config(), scale="auto",
            renderer=os.getenv("REDIWM_TEST_RENDERER", "gles2"),
            env_extra={"DBUS_SESSION_BUS_ADDRESS": "", "XDG_CACHE_HOME": str(tmp / "cache")})
        clients = []
        try:
            with IPCClient(tmp, timeout=15) as ipc:
                ipc.wait_for("wallpaper_presented", timeout_ms=10000)
                ipc.wait_for("catalog_published", timeout_ms=10000)
                display = next(p.name for p in tmp.glob("wayland-*") if not p.name.endswith(".lock"))
                env = dict(os.environ, XDG_RUNTIME_DIR=str(tmp), WAYLAND_DISPLAY=display,
                    XDG_STATE_HOME=str(tmp / "state"), REDIWM_TEST_DECORATION="server")
                output_name = "HEADLESS-1"
                ipc.move_cursor(200, 200, output=output_name)
                workspace_id = next(w["id"] for w in ipc.get_workspaces() if w["is_focused"])
                ids, paths = [], []
                for index in range(3):
                    name = f"rollout-{index}"
                    path = tmp / f"{name}.log"
                    with path.open("w") as stream:
                        clients.append(subprocess.Popen([str(tmp / "client"), "--app-id", name], env=env,
                            stdout=stream, stderr=stream))
                    ids.append(wait_for(lambda: next((w["id"] for w in ipc.get_windows() if w["app_id"] == name), None), "map " + name))
                    paths.append(path)
                def workspace():
                    return next(w for w in ipc.get_workspaces() if w["id"] == workspace_id)
                def frames():
                    return [ipc.get_window_debug(id)["chrome_box"] for id in ids]
                def valid_tiles():
                    if any(w["placement"] != "automatic" for w in ipc.get_windows() if w["id"] in ids): return False
                    out = next(o for o in ipc.get_outputs() if o["name"] == output_name)
                    rects = frames()
                    if (min(r["x"] for r in rects), min(r["y"] for r in rects),
                        max(r["x"] + r["width"] for r in rects), max(r["y"] + r["height"] for r in rects)) != (
                            out["x"] + 8, out["y"] + 8, out["x"] + out["logical_width"] - 8,
                            out["y"] + out["logical_height"] - out["bottom_exclusion"] - 8): return False
                    for r in rects:
                        if r["width"] <= 0 or r["height"] <= 0: return False
                        if r["x"] < out["x"] + 8 or r["y"] < out["y"] + 8: return False
                        if r["x"] + r["width"] > out["x"] + out["logical_width"] - 8: return False
                        if r["y"] + r["height"] > out["y"] + out["logical_height"] - out["bottom_exclusion"] - 8: return False
                    for index, a in enumerate(rects):
                        for b in rects[index + 1:]:
                            if not (a["x"] + a["width"] + 8 <= b["x"] or b["x"] + b["width"] + 8 <= a["x"] or
                                    a["y"] + a["height"] + 8 <= b["y"] or b["y"] + b["height"] + 8 <= a["y"]): return False
                    return True
                wait_for(valid_tiles, "initial valid tiles")
                nodes = workspace()["nodes"]
                # Reload scale/position while a tile is grabbed. The output
                # transaction must cancel the preview before translating tiles.
                for scale, x, y in ((1.5, -960, -100), (1.25, 0, 0), (1, 0, 0)):
                    out = next(o for o in ipc.get_outputs() if o["name"] == output_name)
                    box = ipc.get_window_debug(ids[0])["client_box"]
                    ipc.move_cursor(round(box["x"] - out["x"] + 40), round(box["y"] - out["y"] + 40), output=output_name)
                    ipc.key(125, True)
                    ipc.pointer_button(272, True)
                    assert ipc.get_input_state()["cursor_mode"] == "move"
                    (tmp / "rediwm-config.toml").write_text(config(scale, x, y))
                    ipc.reload_config()
                    # Density alone preserves headless logical dimensions, so
                    # an unchanged usable area may retain the gesture.
                    if (out["x"], out["y"]) == (x, y): ipc.key_down_up(1)
                    wait_for(lambda: ipc.get_input_state()["cursor_mode"] == "passthrough", "output change cancels tile grab")
                    ipc.pointer_button(272, False)
                    ipc.key(125, False)
                    wait_for(valid_tiles, "valid tiles after scale/position reload")
                    assert workspace()["nodes"] == nodes, "output reload changed split topology"
                    ipc.wait_for_frame(output=output_name)
                    # Scene hit testing alone cannot prove delivery to a client.
                    for id, path in zip(ids, paths):
                        presses = path.read_text().splitlines().count("button 272 1")
                        box = ipc.get_window_debug(id)["client_box"]
                        ipc.click_at(round(box["x"] - x + 40), round(box["y"] - y + 40), output=output_name)
                        wait_for(lambda: path.read_text().splitlines().count("button 272 1") == presses + 1, "tiled client receives click after reload")
                # Measure sleeping threads directly, with no IPC/stat requests
                # during the sample. Window commits and autosave may wake once;
                # a repeating layout or rendering timer must fail this bound.
                ipc.move_cursor(4, 4, output=output_name)
                time.sleep(.8)
                configures = [p.read_text().count("configure ") for p in paths]
                def switches():
                    result = {}
                    for status in Path(f"/proc/{process.pid}/task").glob("*/status"):
                        try:
                            result[status.parent.name] = sum(int(line.split()[1]) for line in status.read_text().splitlines()
                                if line.startswith("voluntary_ctxt_switches:"))
                        except FileNotFoundError:
                            pass  # A startup worker may finish between reads.
                    return result
                before = switches()
                time.sleep(1.2)
                after = switches()
                wakeups = {tid: value - before[tid] for tid, value in after.items() if tid in before}
                assert all(value <= 4 for value in wakeups.values()), ("tiled idle wakeups", wakeups)
                assert [p.read_text().count("configure ") for p in paths] == configures, "idle configure storm"
                print(f"PASS: live scale/origin reload, grab cancellation, real clicks and idle ({wakeups})", flush=True)
                # A protocol activation must obey the same lock guard as IPC.
                ipc.action("switch_workspace", {"workspace": 9})
                ipc.action("switch_workspace", {"workspace": workspace_id})
                ipc.focus_window(ids[0])
                original_frames = frames()
                lock = subprocess.Popen([str(tmp / "fixture"), "lock"], env=env,
                    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                clients.append(lock)
                expect_line(lock, "locked")
                assert locked(ipc)
                for action, params in (
                    ("workspaces", None), ("focus_window", {"id": ids[1]}),
                    ("switch_workspace", {"workspace": 9}), ("move_to_workspace", {"id": ids[0], "workspace": 9}),
                    ("tiling_action", {"id": ids[0], "action": "toggle_floating"}),
                    ("set_desktop_mode", {"mode": "canvas", "persist": False}),
                    ("set_workspace_layout", {"workspace": workspace_id, "automatic": False}),
                    ("set_window_gap", {"gap": 20, "persist": False}), ("undo", None)):
                    try:
                        ipc.request(query=action, params=params)
                    except IPCError as exc:
                        assert "SessionLocked" in str(exc), (action, exc)
                    else:
                        raise AssertionError(f"{action} bypassed the lock")
                subprocess.run([str(tmp / "fixture"), "workspaces", "9"], env=env,
                    check=True, capture_output=True, text=True, timeout=15)
                lock.stdin.write("unlock\n")
                lock.stdin.flush()
                expect_line(lock, "unlocked")
                wait_for(lambda: not locked(ipc), "protocol unlock")
                assert workspace()["is_focused"] and workspace()["is_visible"]
                assert workspace()["nodes"] == nodes and frames() == original_frames
                assert ipc.get_focused_window()["id"] == ids[0]
                # Client death keeps the lock: activation cannot reveal a hidden
                # workspace even when there is no longer a lock surface.
                dying = subprocess.Popen([str(tmp / "fixture"), "lock"], env=env,
                    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                clients.append(dying)
                expect_line(dying, "locked")
                dying.kill()
                dying.wait(timeout=5)
                subprocess.run([str(tmp / "fixture"), "workspaces", "9"], env=env,
                    check=True, capture_output=True, text=True, timeout=15)
                assert locked(ipc), "activation unlocked after lock-client death"
                assert process.poll() is None
                print("PASS: workspace IPC/protocol lock guards, unlock layout and lock-client death", flush=True)
        except Exception:
            print((tmp / "compositor.log").read_text()[-6000:])
            raise
        finally:
            for child in clients: stop_process(child)
            stop_process(process)
            log.close()


def xwayland_routing():
    with tempfile.TemporaryDirectory(prefix="rediwm-workspace-x11-") as directory:
        tmp = Path(directory)
        outputs = int(os.getenv("REDIWM_TEST_OUTPUTS", "1"))
        config = '[compositor]\ndesktop_mode = "tiling"\n'
        if outputs > 1 and os.getenv("REDIWM_TEST_NEGATIVE") == "1":
            config += '\n[[outputs]]\nname = "HEADLESS-1"\nx = 0\ny = 0\n[[outputs]]\nname = "HEADLESS-2"\nx = -1280\ny = -120\n'
        process, log = spawn_compositor(tmp, outputs=str(outputs), config_content=config,
            renderer=os.getenv("REDIWM_TEST_RENDERER", "gles2"),
            scale=os.getenv("REDIWM_TEST_SCALE", "1"), env_extra={"DBUS_SESSION_BUS_ADDRESS": ""})
        children = []
        try:
            with IPCClient(tmp, timeout=15) as ipc:
                display = ipc.query("get_runtime_info")["xwayland_display"]
                assert display
                env = dict(os.environ, DISPLAY=display, XDG_RUNTIME_DIR=str(tmp), GDK_BACKEND="x11")
                env.pop("WAYLAND_DISPLAY", None)
                def chord(key, shift=False):
                    ipc.key(125, True)
                    if shift: ipc.key(42, True)
                    ipc.key_press(key)
                    if shift: ipc.key(42, False)
                    ipc.key(125, False)
                def move(x, y):
                    out = next(o for o in ipc.get_outputs() if o["x"] <= x < o["x"] + o["logical_width"] and
                        o["y"] <= y < o["y"] + o["logical_height"])
                    ipc.move_cursor(round(x - out["x"]), round(y - out["y"]), output=out["name"])
                def launch(index):
                    path = tmp / f"gtk-{index}.log"
                    before = {w["id"] for w in ipc.get_windows()}
                    with path.open("w") as stream:
                        child = subprocess.Popen([sys.executable, str(Path(__file__).with_name("xwayland_gtk_client.py"))], env=env, stdin=subprocess.PIPE, stdout=stream, stderr=stream, text=True)
                    children.append(child)
                    top = wait_for(lambda: next((w for w in ipc.get_windows() if w["id"] not in before), None), "GTK map")
                    wait_for(lambda: ipc.get_window_debug(top["id"])["client_box"]["width"] > ipc.get_outputs()[0]["logical_width"] * .8, "GTK automatic tile")
                    return top["id"], child, path
                one, client_one, log_one = launch(1)
                chord("2")
                two, client_two, log_two = launch(2)
                # X11 carries position and size in the same configure. Exercise
                # both a swap and a live divider resize before testing real clicks.
                chord("1", shift=True)
                def rect(id):
                    box = ipc.get_window_debug(id)["chrome_box"]
                    return tuple(box[k] for k in ("x", "y", "width", "height"))
                wait_for(lambda: rect(one)[0] < rect(two)[0] and rect(one)[2] < 900, "two GTK tiles")
                for id in (one, two): ipc.wait_for("window_geometry_settled", window_id=id, timeout_ms=5000)
                before_one, before_two = rect(one), rect(two)
                ipc.action("tiling_action", {"action": "swap_right", "id": one})
                wait_for(lambda: rect(one)[0] == before_two[0], "X11 tile swap")
                # Tiles glide to their new places, and input follows what is shown.
                for id in (one, two): ipc.wait_for("window_geometry_settled", window_id=id, timeout_ms=5000)
                ipc.focus_window(two)
                box = ipc.get_window_debug(two)["client_box"]
                x, y = box["x"] + 80, box["y"] + 70
                move(x, y)
                ipc.key(125, True)
                ipc.pointer_button(0x111, True)
                assert ipc.get_input_state()["cursor_mode"] == "resize"
                move(x + 60, y)
                wait_for(lambda: rect(two)[2] > before_one[2], "X11 split resize")
                ipc.key_press("Escape")
                ipc.pointer_button(0x111, False)
                ipc.key(125, False)
                wait_for(lambda: rect(two) == before_one, "X11 split resize cancellation")
                chord("2", shift=True)
                wait_for(lambda: rect(two)[2] > 1000, "X11 transfer reflow")
                for key, top, child, path in [("2", two, client_two, log_two), ("1", one, client_one, log_one)]:
                    chord(key)
                    ipc.wait_for("window_geometry_settled", window_id=top, timeout_ms=5000)
                    box = ipc.get_window_debug(top)["client_box"]
                    move(box["x"] + 70, box["y"] + 80)
                    ipc.pointer_button(0x111, True)
                    ipc.pointer_button(0x111, False)
                    wait_for(lambda: "popup" in path.read_text(), "X11 click reached wrong workspace")
                    child.stdin.write("popdown\n")
                    child.stdin.flush()
                assert log_two.read_text().splitlines().count("popup") == 1
                print(f"PASS: actual GTK Xwayland clicks route to the visible workspace ({outputs} outputs)", flush=True)
        finally:
            for child in children: stop_process(child)
            stop_process(process)
            log.close()

def persistence_controls():
    """Rules, Settings, shared IPC, duplicate matching and restart split recovery."""
    import json
    with tempfile.TemporaryDirectory(prefix="rediwm-workspace-persistence-") as directory:
        tmp = Path(directory)
        build_client(tmp)
        state = tmp / "state"
        saved_path = state / "rediwm" / "workspace-layout.json"
        config = '''[compositor]
 desktop_mode = "canvas"
 focus_zoom = "keep"
 floating_apps = ["utility*"]
 [keybinds.workspace]
 "Super+F9" = "save_layout checkpoint"
 "Super+F10" = "restore_layout checkpoint"
 [[window_rules]]
 app_id = "rule-app"
 floating = true
'''
        apps = tmp / "data/applications"
        apps.mkdir(parents=True)
        (apps / "tab-persist.desktop").write_text('[Desktop Entry]\nType=Application\nName=Persisted tabs\n'
            f'Exec=env REDIWM_TEST_DECORATION=server {tmp}/client --app-id tab-persist --title GroupNew\n')
        config = config.replace('focus_zoom = "keep"', 'focus_zoom = "keep"\nwindow_tab_apps = ["tab-persist"]')
        outputs = int(os.getenv("REDIWM_TEST_OUTPUTS", "1"))
        if outputs > 1 and os.getenv("REDIWM_TEST_NEGATIVE") == "1":
            config += '\n[[outputs]]\nname = "HEADLESS-1"\nx = 0\ny = 0\n[[outputs]]\nname = "HEADLESS-2"\nx = -1280\ny = -120\n' 
        expected = {}
        canvas_positions = {}
        for phase in (1, 2):
            runtime = tmp / f"run{phase}"
            runtime.mkdir()
            content = config if phase == 1 else config.replace('desktop_mode = "canvas"', 'desktop_mode = "tiling"')
            process, log = spawn_compositor(runtime, outputs=outputs, config_content=content,
                renderer=os.getenv("REDIWM_TEST_RENDERER", "gles2"), scale=os.getenv("REDIWM_TEST_SCALE", "1"),
                env_extra={"DBUS_SESSION_BUS_ADDRESS": "", "XDG_STATE_HOME": str(state), "XDG_DATA_HOME": str(tmp / "data"), "REDIWM_FILES_DEVICES": "0"})
            clients = []
            try:
                with IPCClient(runtime, timeout=15) as ipc:
                    ipc.wait_for("wallpaper_presented", timeout_ms=10000)
                    display = next(p.name for p in runtime.glob("wayland-*") if not p.name.endswith(".lock"))
                    env = dict(os.environ, XDG_RUNTIME_DIR=str(runtime), XDG_STATE_HOME=str(state),
                        WAYLAND_DISPLAY=display, REDIWM_TEST_DECORATION="server")
                    def launch(app, title):
                        child = subprocess.Popen([str(tmp / "client"), "--app-id", app, "--title", title], env=env,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                        clients.append(child)
                        return wait_for(lambda: next((w for w in ipc.get_windows() if w["app_id"] == app and w["title"] == title), None), "map " + title)["id"]
                    def window(id): return next(w for w in ipc.get_windows() if w["id"] == id)
                    def frame(id):
                        box = ipc.get_window_debug(id)["chrome_box"]
                        return tuple(box[k] for k in ("x", "y", "width", "height"))
                    def chord(key):
                        ipc.key(125, True); ipc.key_press(key); ipc.key(125, False)
                    def click_global(x, y):
                        out = next(o for o in ipc.get_outputs() if o["x"] <= x < o["x"] + o["logical_width"] and o["y"] <= y < o["y"] + o["logical_height"])
                        ipc.click_at(round(x - out["x"]), round(y - out["y"]), output=out["name"])
                    if phase == 1:
                        ids = {title: launch("duplicate-app", title) for title in ("First", "Second")}
                        for index, (title, id) in enumerate(ids.items()):
                            ipc.action("move_window_to", {"id": id, "x": 90 + index * 200, "y": 100 + index * 80})
                            canvas_positions[title] = (window(id)["x"], window(id)["y"])
                        ipc.action("set_desktop_mode", {"mode": "tiling", "persist": True})
                        for id in ids.values(): ipc.action("move_to_workspace", {"id": id, "workspace": 1})
                        wait_for(lambda: all(window(id)["placement"] == "automatic" for id in ids.values()), "initial tiles")
                        utility = launch("utility-editor", "Utility")
                        rule = launch("rule-app", "Rule")
                        assert window(utility)["placement"] == "floating"
                        assert window(rule)["placement"] == "floating"
                        ipc.action("tiling_action", {"id": rule, "action": "toggle_floating"})
                        wait_for(lambda: window(rule)["placement"] == "automatic", "rule manual override")
                        ipc.action("tiling_action", {"id": rule, "action": "toggle_floating"})
                        ipc.action("set_workspace_layout", {"workspace": 2, "automatic": False})
                        ipc.action("move_to_workspace", {"id": utility, "workspace": 2})
                        target_name = next(w for w in ipc.get_workspaces() if w["id"] == 2)["output"]
                        target_output = next(o for o in ipc.get_outputs() if o["name"] == target_name)
                        ipc.action("move_window_to", {"id": utility, "x": target_output["x"] + 220, "y": target_output["y"] + 160})
                        if outputs > 1: ipc.action("switch_workspace", {"workspace": 3})
                        ipc.action("switch_workspace", {"workspace": 1})
                        group_first = launch("tab-persist", "GroupFirst")
                        ipc.wait_for("catalog_published", timeout_ms=10000)
                        ipc.focus_window(group_first)
                        widget = next(w for w in ipc.get_widget_tree(f"window/{group_first}")["widgets"] if w["name"] == "tab_new")
                        box = widget["global_box"]
                        click_global(box["x"] + box["width"] // 2, box["y"] + box["height"] // 2)
                        group_new = wait_for(lambda: next((w for w in ipc.get_windows() if w["app_id"] == "tab-persist" and w["title"] == "GroupNew"), None), "new persisted tab")["id"]
                        wait_for(lambda: window(group_first)["tab_group"] == window(group_new)["tab_group"], "persisted tab group")
                        ipc.action("tiling_action", {"id": ids["First"], "action": "toggle_split"})
                        ipc.action("tiling_action", {"id": ids["First"], "action": "resize_split_down"})
                        ipc.action("set_window_gap", {"gap": 12, "persist": True})
                        wait_for(lambda: ipc.get_workspaces()[0]["window_gap"] == 12, "gap setting")
                        def settled():
                            # Tiles glide to a new split: wait until they rest.
                            first = {title: frame(id) for title, id in ids.items()}
                            time.sleep(.2)
                            return first if first == {title: frame(id) for title, id in ids.items()} else None
                        expected = wait_for(settled, "tiles at rest")
                        chord("F9")
                        checkpoint = runtime / "layouts" / "checkpoint.toml"
                        wait_for(checkpoint.exists, "named workspace save")
                        assert json.loads(checkpoint.read_text())["version"] == 3
                        ipc.action("set_workspace_layout", {"workspace": 1, "automatic": False})
                        wait_for(lambda: window(ids["First"])["placement"] == "floating", "floating layout")
                        chord("F10")
                        try: wait_for(lambda: all(frame(id) == expected[title] for title, id in ids.items()), "named split restore")
                        except AssertionError: raise AssertionError(("named split restore", expected, {title: frame(id) for title, id in ids.items()})) from None
                        # Settings uses the same setters; toggle a per-app exception.
                        ipc.action("open_control_center")
                        settings = wait_for(lambda: next((w for w in ipc.get_windows() if w["app_id"] == "rediwm-settings"), None), "Settings map")["id"]
                        if outputs > 1: ipc.action("move_to_workspace", {"id": settings, "workspace": 3})
                        ipc.action("maximize_window", {"id": settings})
                        time.sleep(.3)
                        def click(widget):
                            box = widget["box"]; panel = ipc.get_shell_state()["control_center"]["box"]
                            click_global(panel["x"] + box["x"] + box["width"] / 2, panel["y"] + box["y"] + box["height"] / 2)
                        desktop = wait_for(lambda: next((w for w in ipc.get_widget_tree("control_center")["widgets"] if w["label"] == "Desktop"), None), "Desktop navigation")
                        click(desktop)
                        tree = ipc.get_widget_tree("control_center")["widgets"]
                        assert any((w["path"] or "").endswith("/workspace_layout") for w in tree)
                        assert any((w["path"] or "").endswith("/workspace_gap") for w in tree)
                        assert any("floating_app:utility*" in (w["path"] or "") for w in tree)
                        from ui_driver import UIDriver
                        ui = UIDriver(ipc)
                        item = ui.scroll_into_view("floating_app:rule-app")
                        ui.click(item)
                        wait_for(lambda: '"rule-app"' in (runtime / "rediwm-config.toml").read_text().split("floating_apps =", 1)[1].splitlines()[0], "Settings floating app save")
                        ui.click(ui.find("floating_app:rule-app", panel="control_center"))
                        wait_for(lambda: '"rule-app"' not in (runtime / "rediwm-config.toml").read_text().split("floating_apps =", 1)[1].splitlines()[0], "Settings floating app removal")
                        ipc.action("close_panel", {"panel": "control_center"})
                        time.sleep(.3)
                        wait_for(lambda: all(frame(id) == expected[title] for title, id in ids.items()), "Settings closure restores tiles")
                        wait_for(saved_path.exists, "workspace autosave", timeout=15)
                        snapshot = json.loads(saved_path.read_text())
                        assert len([w for w in snapshot["windows"] if w["app_id"] == "duplicate-app"]) == 2
                        assert [w["ordinal"] for w in snapshot["windows"] if w["app_id"] == "duplicate-app"] == [0, 1]
                        assert snapshot["version"] == 3
                        assert next(w for w in snapshot["workspaces"] if w["id"] == 2)["layout"] == "floating"
                    else:
                        # Launch in reverse title order: membership is consumed once,
                        # and saved split order does not become the focus stack.
                        ipc.action("set_window_gap", {"gap": 12, "persist": False})
                        wait_for(lambda: any(w["id"] == 2 and not w["automatic"] for w in ipc.get_workspaces()), "empty startup workspace preferences")
                        original_snapshot = saved_path.read_bytes()
                        time.sleep(9)  # Cross the first autosave tick before apps map.
                        assert saved_path.read_bytes() == original_snapshot, "autosave erased pending startup matches"
                        ids = {title: launch("duplicate-app", title) for title in ("Second", "First")}
                        utility = launch("utility-editor", "Utility")
                        group_new = launch("tab-persist", "GroupNew")
                        group_first = launch("tab-persist", "GroupFirst")
                        wait_for(lambda: window(group_first)["tab_group"] == window(group_new)["tab_group"], "restart tab group")
                        assert window(group_new)["tab_active"] and not window(group_first)["tab_active"]
                        assert (ipc.get_focused_window() or {}).get("id") != group_first
                        wait_for(lambda: window(utility)["workspace_id"] == 2, "hidden saved membership")
                        assert (ipc.get_focused_window() or {}).get("id") != utility
                        wait_for(lambda: all(frame(id) == expected[title] for title, id in ids.items()), "restart exact split geometry")
                        rule = launch("rule-app", "Rule")
                        assert window(rule)["placement"] == "floating" and window(rule)["floating_override"] is True
                        ipc.action("tiling_action", {"id": rule, "action": "toggle_floating"})
                        wait_for(lambda: window(rule)["placement"] == "automatic", "restored floating exception can retile")
                        ipc.action("undo")
                        wait_for(lambda: window(rule)["placement"] == "floating", "restored floating override undo")
                        ipc.close_window(group_new)
                        wait_for(lambda: window(group_first)["tab_active"], "saved tab fallback after active closes")
                        new = launch("duplicate-app", "Third")
                        assert window(new)["workspace_id"] == 1
                        ipc.action("move_to_workspace", {"id": ids["First"], "workspace": 3})
                        later = launch("unmatched-app", "Later")
                        time.sleep(2.2)
                        assert window(ids["First"])["workspace_id"] == 3, "startup restore fought a user transfer"
                        ipc.action("set_desktop_mode", {"mode": "canvas", "persist": False})
                        wait_for(lambda: ipc.get_workspaces()[0]["name"] == "Canvas", "canvas transition")
                        for title, id in ids.items():
                            wait_for(lambda: (window(id)["x"], window(id)["y"]) == canvas_positions[title], "saved canvas state")
                    assert process.poll() is None
            finally:
                stop_process(process)
                for child in clients: stop_process(child)
                log.close()
        print("PASS: floating rules, Settings/IPC, named saves, duplicate matching, restart splits and saved canvas", flush=True)

if __name__ == "__main__":
    if "--acceptance-only" in sys.argv:
        rollout_acceptance()
        sys.exit(0)
    if "--persistence-only" in sys.argv:
        persistence_controls()
        sys.exit(0)
    persistence_controls()
    manual_controls()
    if "--controls-only" in sys.argv: sys.exit(0)
    automatic_layout()
    rollout_acceptance()
    if "--automatic-only" not in sys.argv: run(int(os.getenv("REDIWM_TEST_OUTPUTS", "1")))
    if os.getenv("REDIWM_TEST_XWAYLAND") == "1": xwayland_routing()

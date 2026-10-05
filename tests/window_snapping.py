#!/usr/bin/env python3
"""Window snapping: titlebar double-click, drag-to-edge tiles and maximize,
drag-to-restore, Super+Shift+arrow tiling and undo of a snap.

Headless, one 1280x720 output, the zoom_client.c toplevel with server-side
decorations. Geometry is checked in layout space through window_debug's
chrome box and the camera offset.
"""
import os
from pathlib import Path
import subprocess
import tempfile
import time

from desktop_zoom import build_client, wait_for
from ipc_client import IPCClient, spawn_compositor, stop_process

BTN_LEFT = 0x110
KEY_SUPER = 125
KEY_SHIFT = 42
KEY_Z = 44
ARROWS = {"left": 105, "right": 106, "up": 103, "down": 108}
GAP = 8


def run():
    with tempfile.TemporaryDirectory(prefix="rediwm-snapping-") as directory:
        tmp = Path(directory)
        build_client(tmp)
        # A [keybinds] section replaces the defaults, so bind what is used.
        config = f'''[compositor]
window_gap = {GAP}

[keybinds]
"super+z" = "undo"
"super+shift+left" = "tile_left"
"super+shift+right" = "tile_right"
"super+shift+up" = "tile_up"
"super+shift+down" = "tile_down"
'''
        process, log = spawn_compositor(tmp, config_content=config)
        client = None
        try:
            with IPCClient(tmp, timeout=15) as ipc:
                ipc.wait_for("wallpaper_presented", timeout_ms=10000)
                display = next(p.name for p in tmp.glob("wayland-*") if not p.name.endswith(".lock"))
                env = dict(os.environ, XDG_RUNTIME_DIR=str(tmp), WAYLAND_DISPLAY=display, REDIWM_TEST_DECORATION="server")
                client = subprocess.Popen([str(tmp / "client")], env=env)
                win_id = wait_for(lambda: next(iter(ipc.get_windows()), None), "window did not map")["id"]

                output = ipc.get_outputs()[0]
                out_w, out_h = output["logical_width"], output["logical_height"]
                taskbar = next(p for p in ipc.list_panels()["panels"] if p.get("name") == "taskbar")
                usable_h = out_h - taskbar["box"]["height"]

                def frame():
                    debug = ipc.get_window_debug(win_id)
                    camera = ipc.get_state()["camera"]
                    box = debug["chrome_box"]
                    return {
                        "x": round(box["x"] - camera["x"]),
                        "y": round(box["y"] - camera["y"]),
                        "width": box["width"],
                        "height": box["height"],
                        "client": (debug["client_box"]["width"], debug["client_box"]["height"]),
                        "maximized": debug["maximized"],
                    }

                def settled_frame():
                    # Moves and resizes animate; wait for two identical reads.
                    last = None
                    deadline = time.monotonic() + 10
                    while time.monotonic() < deadline:
                        current = frame()
                        if current == last:
                            return current
                        last = current
                        time.sleep(0.15)
                    raise AssertionError(f"window never settled: {last}")

                def title_point():
                    tree = ipc.get_widget_tree(f"window/{win_id}")
                    title = next(w for w in tree["widgets"] if w["path"] == f"window/{win_id}/titlebar")
                    box = title["global_box"]
                    return round(box["x"] + box["width"] * 0.4), round(box["y"] + box["height"] / 2)

                def drag_title(to_x, to_y, steps=8):
                    # The widget tree reports logical geometry; press only
                    # once the animated frame is really there.
                    settled_frame()
                    x, y = title_point()
                    ipc.move_cursor(x, y)
                    ipc.pointer_button(BTN_LEFT, True)
                    for i in range(1, steps + 1):
                        ipc.move_cursor(round(x + (to_x - x) * i / steps), round(y + (to_y - y) * i / steps))
                    ipc.pointer_button(BTN_LEFT, False)

                def chord(*codes):
                    for code in codes:
                        ipc.key(code, True)
                    for code in reversed(codes):
                        ipc.key(code, False)

                def expect_rect(rect, message):
                    def check():
                        current = settled_frame()
                        got = (current["x"], current["y"], current["width"], current["height"])
                        return current if got == rect else None
                    try:
                        return wait_for(check, message, timeout=10)
                    except AssertionError:
                        raise AssertionError(f"{message}: want {rect}, have {frame()}") from None

                inner_w = out_w - 3 * GAP
                left = (GAP, GAP, inner_w // 2, usable_h - 2 * GAP)
                right = (2 * GAP + inner_w // 2, GAP, inner_w - inner_w // 2, usable_h - 2 * GAP)
                inner_h = usable_h - 3 * GAP
                top_left = (GAP, GAP, inner_w // 2, inner_h // 2)
                top_right = (right[0], GAP, right[2], inner_h // 2)

                floating = settled_frame()
                assert not floating["maximized"], floating
                floating_size = floating["client"]

                # 1. Two slow clicks are not a double-click.
                x, y = title_point()
                ipc.move_cursor(x, y)
                ipc.click()
                time.sleep(0.6)
                ipc.click()
                time.sleep(0.3)
                assert not frame()["maximized"], "two slow clicks maximized the window"

                # 2. Double-click maximizes, and again restores.
                ipc.click()
                ipc.click()
                wait_for(lambda: frame()["maximized"], "titlebar double-click did not maximize")
                expect_rect((0, 0, out_w, usable_h), "double-click maximize fills the usable area")
                x, y = title_point()
                ipc.move_cursor(x, y)
                ipc.click()
                ipc.click()
                wait_for(lambda: not frame()["maximized"], "second double-click did not restore")
                wait_for(lambda: frame()["client"] == floating_size, "double-click restore lost the size")
                print("PASS: titlebar double-click maximizes and restores", flush=True)

                # 3. Dragging to the left edge tiles the left half.
                before_drag = settled_frame()
                drag_title(0, out_h // 2)
                expect_rect(left, "drag to the left edge did not tile")
                print("PASS: drag to the left edge tiles the left half", flush=True)

                # 4. Dragging a tile away restores its floating size under the pointer.
                x, y = title_point()
                drag_title(x + 150, y + 120)
                restored = wait_for(
                    lambda: (lambda f: f if f["client"] == floating_size else None)(settled_frame()),
                    "dragging a tile away did not restore its size",
                )
                tx, ty = title_point()
                assert abs(tx - (x + 150)) < 200 and abs(ty - (y + 120)) < 20, (tx, ty, x, y, restored)
                print("PASS: dragging a tile away floats it at its size", flush=True)

                # 5. Top edge maximizes; dragging down restores.
                drag_title(out_w // 2, 0)
                wait_for(lambda: frame()["maximized"], "drag to the top edge did not maximize")
                x, y = title_point()
                drag_title(x, y + 200)
                wait_for(lambda: not frame()["maximized"], "dragging a maximized window did not restore it")
                wait_for(lambda: frame()["client"] == floating_size, "drag-to-restore lost the size")
                print("PASS: top edge maximizes, dragging down restores", flush=True)

                # 6. Top-left corner selects a quarter; a drop in the middle does nothing.
                drag_title(0, 4)
                expect_rect(top_left, "drag to the top-left corner did not tile a quarter")
                x, y = title_point()
                drag_title(out_w // 2, out_h // 2)
                wait_for(lambda: frame()["client"] == floating_size, "quarter did not float again")
                still = settled_frame()
                assert not still["maximized"] and still["width"] < out_w // 2 + 100, still
                print("PASS: corners tile quarters; the middle leaves windows floating", flush=True)

                # 7. Super+Shift+arrows step through halves, quarters and back.
                float_frame = settled_frame()
                chord(KEY_SUPER, KEY_SHIFT, ARROWS["right"])
                expect_rect(right, "Super+Shift+Right did not tile right")
                chord(KEY_SUPER, KEY_SHIFT, ARROWS["up"])
                expect_rect(top_right, "Super+Shift+Up did not tile the top-right quarter")
                chord(KEY_SUPER, KEY_SHIFT, ARROWS["left"])
                expect_rect(top_left, "Super+Shift+Left did not move to the top-left quarter")
                chord(KEY_SUPER, KEY_SHIFT, ARROWS["down"])
                expect_rect(left, "Super+Shift+Down did not join the left half")
                chord(KEY_SUPER, KEY_SHIFT, ARROWS["right"])
                expect_rect(
                    (float_frame["x"], float_frame["y"], float_frame["width"], float_frame["height"]),
                    "Super+Shift+Right from the left half did not restore the window",
                )
                print("PASS: Super+Shift+arrows walk tiles and restore", flush=True)

                # 8. Undo puts a snapped window back where the drag started.
                time.sleep(0.7)  # outside undo's 600 ms coalescing window
                before_drag = settled_frame()
                drag_title(out_w - 1, out_h // 2)
                expect_rect(right, "drag to the right edge did not tile")
                time.sleep(0.7)
                chord(KEY_SUPER, KEY_Z)
                expect_rect(
                    (before_drag["x"], before_drag["y"], before_drag["width"], before_drag["height"]),
                    "undo did not return the snapped window",
                )
                # The tile is gone, not just moved: a drag keeps the size.
                x, y = title_point()
                drag_title(x + 40, y + 40)
                time.sleep(0.3)
                assert settled_frame()["client"] == floating_size, "undo left the window tiled"
                print("PASS: undo returns a snapped window to its floating place", flush=True)

                # 9. A keyboard maximize is undoable as well (xdg acks it a commit later).
                time.sleep(0.7)
                before = settled_frame()
                chord(KEY_SUPER, KEY_SHIFT, ARROWS["up"])
                wait_for(lambda: frame()["maximized"], "Super+Shift+Up did not maximize a floating window")
                time.sleep(0.7)
                chord(KEY_SUPER, KEY_Z)
                wait_for(lambda: not frame()["maximized"], "undo did not leave maximize")
                expect_rect(
                    (before["x"], before["y"], before["width"], before["height"]),
                    "undo of a keyboard maximize did not restore the window",
                )
                print("PASS: undo reverses a keyboard maximize", flush=True)
        finally:
            if client is not None:
                client.terminate()
                try:
                    client.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    client.kill()
            stop_process(process)
            log.close()


if __name__ == "__main__":
    run()

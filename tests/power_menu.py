#!/usr/bin/env python3
"""Power-menu selection motion and cancellation in an isolated headless session.

Only Log Out is exercised: completing it terminates this test's compositor.
No host lock, restart or shutdown actions are invoked.
"""
import argparse
import os
from pathlib import Path
import tempfile

from PIL import Image, ImageChops
from ipc_client import IPCClient, spawn_compositor, stop_process


def run(scale):
    with tempfile.TemporaryDirectory(prefix="rediwm-power-test-") as directory:
        tmp = Path(directory)
        process, log = spawn_compositor(tmp, scale=scale,
            config_content='[theme]\nwindow_bg = "rgba(24,30,40,0.70)"\n', env_extra={
            "DBUS_SESSION_BUS_ADDRESS": "", "XDG_CACHE_HOME": directory,
        })
        try:
            with IPCClient(tmp, timeout=15) as ipc:
                ipc.wait_for("wallpaper_presented", timeout_ms=10000)

                def at(ms):
                    ipc.action('set_anim_time', {"ms": ms})
                    ipc.wait_for_frame()

                def rows():
                    return [w for w in ipc.get_widget_tree("power_menu")["widgets"] if w["role"] == "row"]

                def capture(name):
                    path = tmp / f"{cancel}-{name}.png"
                    ipc.screenshot(str(path))
                    with Image.open(path) as image:
                        return image.convert("RGB")

                for cancel in (True, False):
                    at(1000)
                    closed = capture("closed")
                    ipc.action('open_power_menu')
                    at(2000)
                    box = ipc.get_shell_state()["power_menu"]["box"]
                    cards = rows()
                    assert len(cards) == 5
                    card = next(w for w in cards if w["semantic_id"] == "row_1")["box"]
                    assert not any(w["is_focused"] for w in cards), "default selection"
                    assert 0.8 * 956 <= box["width"] <= 0.85 * 956, box
                    assert 0.8 * 268 <= box["height"] <= 0.85 * 268, box
                    opened = capture("open")
                    s = float(scale)
                    # Sample clear padding after the opening animation settles:
                    # Configured chrome tint/opacity over the wallpaper and
                    # the 45% scrim, independent of the shell glass alpha.
                    point = (round((box["x"] + 20) * s),
                             round((box["y"] + box["height"] / 2) * s))
                    behind = closed.getpixel(point)
                    actual = opened.getpixel(point)
                    expected = tuple(round(bg * .55 * .30 + tint * .70)
                                     for bg, tint in zip(behind, (24, 30, 40)))
                    assert max(abs(a - b) for a, b in zip(actual, expected)) <= 3, (actual, expected)
                    # Both logical pixels of the idle border must be visible.
                    x = round((box["x"] + card["x"] + card["width"] / 2) * s)
                    top = box["y"] + card["y"]
                    for offset in (.5, 1.5):
                        point = (x, int((top + offset) * s))
                        edge = opened.getpixel(point)
                        tint_only = tuple(round(bg * .55 * .30 + tint * .70)
                                          for bg, tint in zip(closed.getpixel(point), (24, 30, 40)))
                        assert min(a - b for a, b in zip(edge, tint_only)) >= 4, (edge, tint_only)
                    if cancel and (preview := os.environ.get("REDIWM_POWER_PREVIEW")):
                        opened.save(preview)
                    # One red outline follows the pointer with the chrome
                    # spring, passes through intermediate positions, then
                    # fades away without leaving pixels in recycled buffers.
                    first = cards[0]["box"]
                    def hover(target):
                        ipc.move_cursor(box["x"] + target["x"] + target["width"] // 2,
                                        box["y"] + target["y"] + target["height"] // 2)

                    def outline_left(image):
                        y = round((box["y"] + first["y"] + 1) * s)
                        start = round(box["x"] * s)
                        end = round((box["x"] + box["width"]) * s)
                        points = [x for x in range(start, end)
                                  if (lambda rgb: rgb[0] > 180 and rgb[0] > rgb[1] + 50)(image.getpixel((x, y)))]
                        assert points, "hover outline not visible"
                        return min(points)

                    hover(first)
                    at(2600)
                    origin = outline_left(capture("hover-first"))
                    hover(card)
                    at(2660)
                    middle_x = outline_left(capture("hover-gliding"))
                    at(3300)
                    destination = outline_left(capture("hover-second"))
                    assert origin < middle_x < destination, (origin, middle_x, destination)
                    assert abs(destination - origin - (card["x"] - first["x"]) * s) <= 2
                    ipc.move_cursor(box["x"] - 10, box["y"] - 10)
                    at(4000)
                    # Only the menu: the taskbar clock may tick over meanwhile.
                    menu = tuple(round(v * s) for v in (box["x"], box["y"], box["x"] + box["width"], box["y"] + box["height"]))
                    assert ImageChops.difference(opened.crop(menu), capture("hover-left").crop(menu)).getbbox() is None
                    ipc.key_down_up(28)  # Enter without a selection does nothing.
                    assert len(rows()) == 5
                    if cancel:
                        # Navigation starts at either end and wraps both ways.
                        for key, expected in ((105, "row_4"), (106, "row_0"),
                                              (105, "row_4"), (106, "row_0"), (106, "row_1")):
                            ipc.key_down_up(key)
                            focused = [w["semantic_id"] for w in rows() if w["is_focused"]]
                            assert focused == [expected], focused
                        ipc.key_down_up(28)
                    else:
                        ipc.key_down_up(106)
                        ipc.move_cursor(box["x"] + 10, box["y"] + 10)
                        assert not any(w["is_focused"] for w in rows()), "pointer did not clear keyboard focus"
                        ipc.click_at(box["x"] + card["x"] + card["width"] // 2,
                                     box["y"] + card["y"] + card["height"] // 2)
                    at(4000)
                    assert len(rows()) == 1, "unselected cards remain visible"
                    start = capture("start")
                    at(4090)
                    middle = rows()[0]["box"]
                    assert card["x"] < middle["x"] < (box["width"] - card["width"]) / 2
                    assert ipc.get_shell_state()["power_menu"]["box"] == box
                    assert ImageChops.difference(start, capture("moving")).getbbox()
                    at(4180)
                    end = rows()[0]["box"]
                    assert abs(end["x"] + end["width"] / 2 - box["width"] / 2) <= 1
                    assert abs(end["y"] + end["height"] / 2 - box["height"] / 2) <= 1
                    assert ipc.get_shell_state()["power_menu"]["box"] == box
                    assert process.poll() is None, "action ran before the centered frame"
                    # Clicking the moving card again must not queue another action.
                    ipc.click_at(box["x"] + end["x"] + end["width"] // 2,
                                 box["y"] + end["y"] + end["height"] // 2)
                    if cancel:
                        ipc.key_down_up(1)
                        at(5000)
                        assert ipc.get_shell_state()["power_menu"] is None
                        assert process.poll() is None, "dismissed selection still executed"
                    else:
                        ipc.action('set_anim_time', {"ms": 4300})
                        assert process.wait(timeout=5) == 0
            print(f"PASS: power-menu keyboard navigation, motion, cancellation and delayed logout at scale {scale}")
        finally:
            stop_process(process)
            log.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scale", default="1")
    run(parser.parse_args().scale)

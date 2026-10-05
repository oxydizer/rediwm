#!/usr/bin/env python3
"""Settings → Displays arrangement: drag screens into place, select, main display.

Two headless outputs, one rotated to portrait. Dragging a screen moves the
real outputs (normalized to start at 0,0), saves them, and carries windows
along; clicking selects the display the page edits; one output hides the card.
"""
import os
from pathlib import Path
import re
import tempfile
import time

from ipc_client import IPCClient, spawn_compositor, stop_process
from ui_driver import UIDriver

CONFIG = """[compositor]
xwayland = false
[[outputs]]
name = "HEADLESS-2"
transform = "90"
"""


def wait(predicate, what, timeout=8):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(.05)
    raise AssertionError("timed out waiting for " + what)


def move_to(ipc, x, y):
    """Warp to layout point (x, y); MoveCursor takes output-local coordinates."""
    for out in ipc.get_outputs():
        if out["x"] <= x < out["x"] + out["logical_width"] and out["y"] <= y < out["y"] + out["logical_height"]:
            return ipc.move_cursor(x - out["x"], y - out["y"], output=out["name"])
    raise AssertionError(f"{x},{y} is on no output")


def drag(ipc, start, end, steps=8):
    """Press at `start`, glide to `end` in steps, release (layout points)."""
    move_to(ipc, *start)
    ipc.pointer_button(272, True)
    for i in range(1, steps + 1):
        move_to(ipc, round(start[0] + (end[0] - start[0]) * i / steps), round(start[1] + (end[1] - start[1]) * i / steps))
    ipc.pointer_button(272, False)


def center(widget):
    box = widget["global_box"]
    return box["x"] + box["width"] // 2, box["y"] + box["height"] // 2


def run_two_outputs():
    with tempfile.TemporaryDirectory(prefix="rediwm-arrangement-") as directory:
        tmp = Path(directory)
        process, log = spawn_compositor(tmp, outputs="2", config_content=CONFIG,
                                        renderer=os.environ.get("REDIWM_TEST_RENDERER", "pixman"))
        try:
            with IPCClient(tmp, timeout=15) as ipc:
                ipc.wait_for("wallpaper_presented", timeout_ms=10000)
                ui = UIDriver(ipc)

                def outputs():
                    return {o["name"]: o for o in ipc.get_outputs()}

                def tiles():
                    return {w["name"]: w for w in ui.widgets() if w["role"] == "arrangement_item"}

                def settings_box():
                    return ipc.get_shell_state()["control_center"]["box"]

                def capture(name):
                    if dest := os.environ.get("REDIWM_SETTINGS_PREVIEW"):
                        Path(dest).mkdir(parents=True, exist_ok=True)
                        path = Path(dest) / f"arrangement-{name}.png"
                        path.unlink(missing_ok=True)
                        ipc.screenshot(str(path))

                start = wait(lambda: outputs() if len(outputs()) == 2 else None, "two outputs")
                # A portrait screen beside a landscape one.
                assert (start["HEADLESS-2"]["logical_width"], start["HEADLESS-2"]["logical_height"]) == (720, 1280), start
                # Automatic placement: side by side in creation order.
                L, R = sorted(start, key=lambda name: start[name]["x"])
                lw, lh = start[L]["logical_width"], start[L]["logical_height"]
                rw, rh = start[R]["logical_width"], start[R]["logical_height"]
                assert (start[L]["x"], start[R]["x"]) == (0, lw), start

                # Settings opens on the output under the cursor: the left one.
                ipc.move_cursor(200, 200)
                ipc.open_control_center()
                ui.wait_settled("control_center")
                ui.click(ui.find("Displays"))
                wait(lambda: ipc.get_shell_state()["control_center"]["category"] == "displays", "displays page")
                ui.wait_settled("control_center")
                arrangement = wait(lambda: next((w for w in ui.widgets() if w["role"] == "arrangement"), None), "arrangement")
                assert arrangement["visible"], arrangement
                found = tiles()
                assert set(found) == {L, R}, found
                # Drawn to scale, side by side, with the settings output selected.
                a, b = found[L]["global_box"], found[R]["global_box"]
                assert b["x"] > a["x"] + a["width"] - 4 and abs(b["y"] - a["y"]) <= 2, (a, b)
                assert abs(b["width"] / a["width"] - rw / lw) < .05, (a, b)
                assert found[L]["selected"] and not found[R]["selected"]
                capture("initial")

                # A click without motion moves nothing.
                ui.click(found[L])
                ipc.wait_for_frame()
                assert outputs()[R]["x"] == lw

                # Drag the right screen to the left of the other: the layout is
                # normalized to 0,0, so the left output moves right and the
                # settings window on it comes along.
                before = settings_box()
                drag(ipc, center(found[R]), (a["x"] - b["width"] // 2 - 10, b["y"] + b["height"] // 2))
                moved = wait(lambda: outputs() if outputs()[R]["x"] == 0 else None, "rearranged outputs")
                assert (moved[R]["x"], moved[R]["y"]) == (0, 0), moved
                assert (moved[L]["x"], moved[L]["y"]) == (rw, 0), moved
                after = wait(lambda: settings_box() if settings_box()["x"] != before["x"] else None, "settings window carried")
                assert (after["x"] - before["x"], after["y"] - before["y"]) == (rw, 0), (before, after)
                saved = (tmp / "rediwm-config.toml").read_text()
                for name, x in ((L, rw), (R, 0)):
                    section = saved.split(f'name = "{name}"', 1)[1].split("[[", 1)[0]
                    assert re.search(rf"^x = {x}$", section, re.M) and re.search(r"^y = 0$", section, re.M), saved
                ui.wait_settled("control_center")
                found = tiles()
                # The dropped screen is selected, so the page now edits it.
                assert found[R]["selected"], found
                assert found[R]["global_box"]["x"] < found[L]["global_box"]["x"]
                capture("left")

                # Make it the main display; the offer goes away.
                ui.click(ui.find("make_main"))
                wait(lambda: re.search(rf'name = "{R}"[^\[]*primary = true', (tmp / "rediwm-config.toml").read_text()), "primary saved")
                wait(lambda: not any(w["name"] == "make_main" for w in ui.widgets()), "make_main hidden")

                # Select the other screen by clicking it.
                ui.click(tiles()[L])
                wait(lambda: tiles()[L]["selected"], L + " selected")
                assert any(w["name"] == "make_main" for w in ui.widgets())

                # Drag the first screen under the other; it stays in contact
                # and the arrangement is renormalized to the other's corner.
                ui.wait_settled("control_center")
                found = tiles()
                a, b = found[L]["global_box"], found[R]["global_box"]
                before = settings_box()
                drag(ipc, center(found[R]), (a["x"] + a["width"] // 2, a["y"] + a["height"] + b["height"] // 2))
                below = wait(lambda: outputs() if outputs()[R]["y"] != 0 else None, "stacked outputs")
                top, under = below[L], below[R]
                assert top["y"] == 0 and under["y"] == lh, below
                assert min(top["x"], under["x"]) == 0, below
                overlap = min(top["x"] + lw, under["x"] + rw) - max(top["x"], under["x"])
                assert overlap >= min(lw, rw) // 4, below
                # The landscape screen centres under the portrait one.
                assert under["x"] + rw // 2 == top["x"] + lw // 2, below
                after = wait(lambda: settings_box() if settings_box()["x"] != before["x"] else None, "settings window carried back")
                assert (after["x"] - before["x"], after["y"] - before["y"]) == (top["x"] - moved[L]["x"], 0), (before, after)
                capture("below")
                assert ipc.get_perf()["output_failed_commits"] == 0
            print("PASS: display arrangement drags, saves, carries windows, selects and sets the main display")
        except Exception:
            log.flush()
            print((tmp / "compositor.log").read_text()[-5000:])
            raise
        finally:
            stop_process(process)
            log.close()


def run_one_output():
    with tempfile.TemporaryDirectory(prefix="rediwm-arrangement-") as directory:
        tmp = Path(directory)
        process, log = spawn_compositor(tmp, outputs="1", config_content="[compositor]\nxwayland = false\n")
        try:
            with IPCClient(tmp, timeout=15) as ipc:
                ipc.wait_for("wallpaper_presented", timeout_ms=10000)
                ui = UIDriver(ipc)
                ipc.open_control_center()
                ui.wait_settled("control_center")
                ui.click(ui.find("Displays"))
                wait(lambda: ipc.get_shell_state()["control_center"]["category"] == "displays", "displays page")
                ui.wait_settled("control_center")
                assert any(w["label"] == "Resolution" for w in ui.widgets())
                assert not any(w["role"] == "arrangement" for w in ui.widgets())
            print("PASS: one display shows no arrangement")
        except Exception:
            log.flush()
            print((tmp / "compositor.log").read_text()[-5000:])
            raise
        finally:
            stop_process(process)
            log.close()


if __name__ == "__main__":
    run_two_outputs()
    run_one_output()

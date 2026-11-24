#!/usr/bin/env python3
"""HDR phase 2 (docs/plans/hdr.md): linear blending on a headless output.

With `[[outputs]] hdr = "on"` a headless output blends in linear light into a
kept FP16 image and encodes it back to sRGB. Checks, by IPC screenshots:

* turning it on live reports `hdr_linear`, and opaque content (the wallpaper)
  comes back as before, within the few levels FP16 costs saturated colours;
* turning it off again gives back exactly the frame from before (off means off);
* after menus, typing and pointer motion, which redraw only damage into the
  kept image, the screen equals a full linear redraw of the same scene.

Creates its own headless session; never connects to the host desktop.
Set REDIWM_TEST_SCALE (1 by default) to repeat at a fractional scale.
"""
import os
from pathlib import Path
import tempfile
import time

from PIL import Image, ImageChops

from ipc_client import IPCClient, spawn_compositor, stop_process
from ui_driver import UIDriver

OUTPUT = "HEADLESS-1"


def output(ipc):
    return next(o for o in ipc.get_outputs() if o["name"] == OUTPUT)


def settle(ipc):
    # A few frames: a switch repaints the whole output once.
    for _ in range(3):
        ipc.wait_for_frame(output=OUTPUT)
        time.sleep(0.15)


def shot(ipc, tmp, name):
    path = tmp / f"{name}.png"
    ipc.screenshot(str(path))
    with Image.open(path) as image:
        return image.convert("RGB")


def set_hdr(ipc, value):
    ipc.request(query="set_output_config", params={"output": OUTPUT, "hdr": value})
    settle(ipc)


def worst(a, b, box=None):
    if box:
        a, b = a.crop(box), b.crop(box)
    return max(max(p) for p in ImageChops.difference(a, b).get_flattened_data())


def run():
    scale = os.environ.get("REDIWM_TEST_SCALE", "1")
    with tempfile.TemporaryDirectory(prefix="rediwm-hdr-linear-") as directory:
        tmp = Path(directory)
        process, _ = spawn_compositor(tmp, scale=scale, renderer=os.environ.get("REDIWM_TEST_RENDERER", "gles2"))
        try:
            with IPCClient(tmp, timeout=15) as ipc:
                ipc.wait_for("wallpaper_presented", timeout_ms=10000)
                ui = UIDriver(ipc)
                ipc.move_cursor(5, 5, output=OUTPUT)
                settle(ipc)
                out = output(ipc)
                assert (out["hdr"], out["hdr_linear"], out["hdr_active"]) == ("off", False, False), out
                sdr = shot(ipc, tmp, "sdr")

                set_hdr(ipc, "on")
                out = output(ipc)
                # Headless cannot carry the signal: linear blending only.
                assert out["hdr_linear"] and not out["hdr_active"] and not out["hdr_supported"], out
                assert not out["hdr_refused"], out
                linear = shot(ipc, tmp, "linear")
                # The wallpaper above the taskbar is opaque: only saturated
                # channels near zero move, by at most three levels.
                width, height = sdr.size
                wallpaper = (width // 2, 0, width, height // 3)
                # Exact comparisons leave out the taskbar, whose clock may tick.
                above_taskbar = (0, 0, width, height * 85 // 100)
                assert worst(sdr, linear, wallpaper) <= 3, worst(sdr, linear, wallpaper)

                set_hdr(ipc, "off")
                assert not output(ipc)["hdr_linear"]
                assert worst(sdr, shot(ipc, tmp, "sdr_again"), above_taskbar) == 0, "hdr off is not the frame from before"

                set_hdr(ipc, "on")
                for x, y in ((100, 100), (400, 300), (900, 200), (640, 600)):
                    ipc.move_cursor(x, y, output=OUTPUT)
                    ipc.wait_for_frame(output=OUTPUT)
                ipc.action("open_start_menu")
                ui.wait_settled("start_menu")
                ipc.type_text("term")
                ui.wait_settled("start_menu")
                ipc.key_press("Escape")
                time.sleep(0.6)
                ipc.action("open_start_menu")
                ui.wait_settled("start_menu")
                settle(ipc)
                incremental = shot(ipc, tmp, "incremental")
                # Off and on again: the kept image is drawn whole.
                set_hdr(ipc, "off")
                set_hdr(ipc, "on")
                assert output(ipc)["hdr_linear"]
                full = shot(ipc, tmp, "full")
                assert worst(incremental, full, above_taskbar) == 0, "damage-only linear frames differ from a full redraw"
        finally:
            stop_process(process)
            log = tmp / "compositor.log"
            text = log.read_text() if log.exists() else ""
            assert "panic:" not in text and "cannot blend in linear light" not in text, text[-4000:]
    print(f"PASS: linear blending switches live, keeps opaque content and off frames, damage-only frames exact (scale {scale})")


if __name__ == "__main__":
    run()

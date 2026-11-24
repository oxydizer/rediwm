#!/usr/bin/env python3
"""Linear blending and SDR capture on a headless output.

With `[[outputs]] hdr = "on"` a headless output blends in linear light into a
kept FP16 image and encodes it back to sRGB. Checks, by IPC screenshots:

* turning it on live reports `hdr_linear`, and opaque content (the wallpaper)
  comes back as before, within the few levels FP16 costs saturated colours;
* turning it off again gives back exactly the frame from before (off means off);
* after menus, typing and pointer motion, which redraw only damage into the
  kept image, the screen equals a full linear redraw of the same scene;
* captures (phase 5) come from the image's sRGB encode, as they would on an
  HDR output whose own buffer holds PQ: wlr-screencopy (tests/
  wlr_protocols_client.c), ext-image-copy-capture in shm and dmabuf buffers
  (tests/capture_client.c), and grim match the screen, and the
  `capture_sdr_copies` counter shows that path served them; with HDR off it
  does not.

Creates its own headless session; never connects to the host desktop.
Set REDIWM_TEST_SCALE (1 by default) to repeat at a fractional scale.
"""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile
import time

from PIL import Image, ImageChops

from desktop_zoom import wait_for
from ipc_client import IPCClient, spawn_compositor, stop_process
from ui_driver import UIDriver
import capture as capture_test
import wlr_protocols

OUTPUT = "HEADLESS-1"
RGB10_FORMATS = tuple(int.from_bytes(name, "little") for name in (b"XR30", b"AR30", b"XB30", b"AB30"))


def capture_rgb(fmt, octets):
    if fmt not in RGB10_FORMATS:
        return capture_test.rgba(fmt, *octets)[:3]
    word = int.from_bytes(bytes(map(int, octets)), "little")
    lo, green, hi = (((word >> shift & 1023) * 255 + 511) // 1023 for shift in (0, 10, 20))
    return (hi, green, lo) if fmt in RGB10_FORMATS[:2] else (lo, green, hi)


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


def copies(ipc):
    return ipc.request(query="get_performance_stats").get("capture_sdr_copies", 0)


def captures(hdr, deep=False):
    """Each capture protocol against an output with `hdr`; returns the SDR copies made."""
    with tempfile.TemporaryDirectory(prefix="rediwm-hdr-capture-") as directory:
        tmp = Path(directory)
        (tmp / "ext").mkdir()
        (tmp / "sc").mkdir()
        capture_test.build_client(tmp / "ext")
        wlr_protocols.compile_fixture(tmp / "sc")
        private = {}
        if deep:
            hook = tmp / "hdr-capture-format.so"
            flags = subprocess.check_output(["pkg-config", "--cflags", "--libs", "wlroots-0.20", "libdrm"], text=True)
            subprocess.run(["cc", "-shared", "-fPIC", str(Path(__file__).with_name("hdr_capture_format.c")),
                            "-o", str(hook), *flags.split(), "-ldl"], check=True)
            private["LD_PRELOAD"] = str(hook)
        config = f'[compositor]\nxwayland = false\n[animations]\nenabled = false\n[[outputs]]\nname = "{OUTPUT}"\nhdr = "{hdr}"\n'
        process, _ = spawn_compositor(tmp, scale="1", renderer=os.environ.get("REDIWM_TEST_RENDERER", "gles2"),
                                      config_content=config, env_extra=private)
        client = None
        try:
            with IPCClient(tmp, timeout=15) as ipc:
                ipc.wait_for("wallpaper_presented", timeout_ms=10000)
                display = next(p.name for p in tmp.glob("wayland-*") if not p.name.endswith(".lock"))
                env = dict(os.environ, XDG_RUNTIME_DIR=str(tmp), WAYLAND_DISPLAY=display)
                env.pop("REDIWM_SOCKET", None)
                assert output(ipc)["hdr_linear"] == (hdr == "on")
                ipc.request(action="reset_performance_stats")

                # wlr-screencopy.
                copy = subprocess.run([str(tmp / "sc" / "fixture"), "screencopy"], env=env, capture_output=True,
                                      text=True, timeout=20).stdout.split()
                assert copy[:3] == ["ready", "1280", "720"] and int(copy[3].split("=")[1]) > 0, copy
                if deep:
                    fmt = int(copy[4].split("=")[1])
                    assert fmt in RGB10_FORMATS, f"screencopy did not negotiate 10-bit shm: {fmt:#x}"
                screencopy_copies = copies(ipc)

                # grim, whichever protocol it prefers, against the screen.
                subprocess.run(["grim", "-o", OUTPUT, str(tmp / "grim.png")], env=env, check=True, timeout=20)
                screen = shot(ipc, tmp, "screen")
                with Image.open(tmp / "grim.png") as image:
                    grabbed = image.convert("RGB")
                width, height = screen.size
                assert worst(screen, grabbed, (0, 0, width, height * 85 // 100)) <= (1 if deep else 0), "grim differs from the screen"

                # ext-image-copy-capture, shm and dmabuf (a fresh fixture each,
                # as capture.py runs it), against the compositor's own read.
                for command in ("capture", "capture_dmabuf"):
                    log_path = tmp / f"{command}.log"
                    with log_path.open("w") as log:
                        client = subprocess.Popen([str(tmp / "ext" / "client")], stdin=subprocess.PIPE, stdout=log,
                                                  stderr=log, text=True, env=env)
                    wait_for(lambda: "presented\n" in log_path.read_text(), "capture fixture did not present")
                    win = wait_for(lambda: next((w for w in ipc.get_windows() if w["app_id"] == "rediwm.capture-fixture"), None),
                                   "capture fixture did not map")
                    ipc.action("move_window_to", {"id": win["id"], "x": 0, "y": 0})
                    settle(ipc)
                    client.stdin.write(command + "\n")
                    client.stdin.flush()
                    ready = wait_for(lambda: next((l for l in log_path.read_text().splitlines() if l.startswith("ready")), None),
                                     f"{command}: no frame")
                    fmt = int(ready.split()[3])
                    if deep:
                        assert fmt in RGB10_FORMATS, f"{command} did not negotiate a 10-bit buffer: {fmt:#x}"
                    client.stdin.write("sample 50 50\n")
                    client.stdin.flush()
                    line = wait_for(lambda: next((l for l in log_path.read_text().splitlines() if l.startswith("pixel 50 50")), None),
                                    f"{command}: no sample")
                    got = capture_rgb(fmt, line.split()[3:7])
                    argb = ipc.action("sample_pixels", {"output": OUTPUT, "x": 50, "y": 50})["pixels"][0]  # 0xAARRGGBB
                    expected = ((argb >> 16) & 255, (argb >> 8) & 255, argb & 255)
                    # The 8-bit and native 10-bit SDR encodes round independently.
                    assert max(abs(a-b) for a, b in zip(got, expected)) <= (1 if deep else 0), (command, got, expected)
                    client.stdin.write("quit\n")
                    client.stdin.flush()
                    client.wait(timeout=10)
                    wait_for(lambda: not any(w["app_id"] == "rediwm.capture-fixture" for w in ipc.get_windows()),
                             "capture fixture did not unmap")
                total = copies(ipc)
        finally:
            if client and client.poll() is None:
                stop_process(client)
            stop_process(process)
        return screencopy_copies, total


def run_captures(deep=False):
    screencopy_copies, total = captures("on", deep)
    # Screencopy, grim, and the two ext copies all came from the SDR encode.
    assert screencopy_copies >= 1 and total >= screencopy_copies + 3, (screencopy_copies, total)
    if not deep:
        assert captures("off") == (0, 0), "an output without HDR used the SDR copies"
    print("PASS: captures of a linear output come from its sRGB encode and match the screen")


def run_mixed():
    """Two outputs, HDR on the first only: the second draws as without HDR."""
    with tempfile.TemporaryDirectory(prefix="rediwm-hdr-mixed-") as directory:
        tmp = Path(directory)
        process, _ = spawn_compositor(tmp, scale="1", outputs="2", renderer=os.environ.get("REDIWM_TEST_RENDERER", "gles2"))
        try:
            with IPCClient(tmp, timeout=15) as ipc:
                ipc.wait_for("wallpaper_presented", timeout_ms=10000)
                ipc.move_cursor(5, 5, output=OUTPUT)
                for name in (OUTPUT, "HEADLESS-2"):
                    ipc.wait_for_frame(output=name)
                time.sleep(0.3)
                second = tmp / "second_sdr.png"
                ipc.screenshot(str(second), output="HEADLESS-2")
                ipc.request(query="set_output_config", params={"output": OUTPUT, "hdr": "on"})
                settle(ipc)
                ipc.wait_for_frame(output="HEADLESS-2")
                outs = {o["name"]: o for o in ipc.get_outputs()}
                assert outs[OUTPUT]["hdr_linear"] and not outs["HEADLESS-2"]["hdr_linear"], outs
                after = tmp / "second_after.png"
                ipc.screenshot(str(after), output="HEADLESS-2")
                with Image.open(second) as a, Image.open(after) as b:
                    a, b = a.convert("RGB"), b.convert("RGB")
                    width, height = a.size
                    assert worst(a, b, (0, 0, width, height * 85 // 100)) == 0, "HDR on one output changed the other"
        finally:
            stop_process(process)
    print("PASS: HDR on one output leaves the other as it was")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ten-bit-capture", action="store_true", help="exercise capture on a real 10-bit headless swapchain")
    if parser.parse_args().ten_bit_capture:
        run_captures(deep=True)
    else:
        run()
        run_captures()
        run_mixed()

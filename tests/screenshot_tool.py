#!/usr/bin/env python3
"""Native screenshot picker, PNG clipboard and clean capture regression checks.
Uses only a private headless session. Requires Pillow and wl-paste.
"""
import os
from pathlib import Path
import subprocess
import tempfile
import time
from PIL import Image, ImageChops
from ipc_client import IPCClient, spawn_compositor, stop_process


def wait_for(check, message):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        result = check()
        if result:
            return result
        time.sleep(.03)
    raise AssertionError(message)


def assert_pixels(actual, expected, message):
    # GLES redraws can differ by one channel level at fractional wallpaper
    # sample boundaries. Keep software comparisons exact; neither tolerance
    # permits the picker tint, border, or toolbar to leak into a saved image.
    tolerance = 1 if os.environ.get("REDIWM_TEST_RENDERER") == "gles2" else 0
    difference = ImageChops.difference(actual, expected)
    assert max(high for low, high in difference.getextrema()) <= tolerance, (message, difference.getbbox(), difference.getextrema())


def run(scale, displays="1"):
    with tempfile.TemporaryDirectory(prefix="rediwm-screenshot-") as directory:
        tmp = Path(directory)
        process, log = spawn_compositor(tmp, scale=str(scale), outputs=displays, renderer=os.environ.get("REDIWM_TEST_RENDERER", "pixman"), env_extra={"HOME": str(tmp), "WLR_RENDERER_ALLOW_SOFTWARE": "1"})
        try:
            with IPCClient(socket_path=tmp, timeout=15) as ipc:
                ipc.wait_for("wallpaper_presented", timeout_ms=10000)
                ipc.wait_for_frame()
                time.sleep(.3)
                display = next(p.name for p in tmp.glob("wayland-*") if not p.name.endswith(".lock"))
                env = dict(os.environ, XDG_RUNTIME_DIR=str(tmp), WAYLAND_DISPLAY=display)

                output = ipc.get_outputs()[-1]
                def move(x, y):
                    ipc.move_cursor(x, y, output=output["name"])
                move(200, 200)

                def image(name):
                    path = tmp / (name + ".png")
                    ipc.screenshot(path=str(path), output=output["name"])
                    return Image.open(path).convert("RGB")

                def open_picker():
                    ipc.key(29, True)
                    ipc.key(42, True)
                    ipc.key_down_up(31)
                    ipc.key(42, False)
                    ipc.key(29, False)
                    ipc.wait_for_frame()

                def click(x, y):
                    move(x, y)
                    ipc.pointer_button(272, True)
                    ipc.pointer_button(272, False)

                def files():
                    return sorted((tmp / "Screenshots").glob("*.png"))

                def clipboard_matches(path):
                    result = subprocess.run(["wl-paste", "--no-newline", "--type", "image/png"], env=env, capture_output=True, timeout=3)
                    return result.returncode == 0 and result.stdout == path.read_bytes()

                clean = image("before")
                open_picker()
                move(501, 401)
                ipc.pointer_button(272, True)
                move(601, 450)
                ipc.wait_for_frame()  # Import the retained border textures first.
                move(101, 201)  # reversed drag after upload, odd fractional phase
                overlay = image("selection")
                if scale == 1:
                    assert overlay.getpixel((101, 201)) == (255, 255, 255), "white corner missing"
                    assert overlay.getpixel((96, 201))[0] == 255, "red corner rim missing"
                    assert overlay.getpixel((122, 201)) == (255, 255, 255), "white dash gap missing"
                    assert overlay.getpixel((126, 201))[0] == 255, "red dash missing"
                ipc.pointer_button(272, False)
                wait_for(lambda: len(files()) == 1, "region was not saved")
                region = files()[0]
                wait_for(lambda: clipboard_matches(region), "PNG clipboard differs from saved region")
                crop = Image.open(region).convert("RGB")
                # wlroots rounds edges independently, including half-pixel phases.
                edge = lambda v: int(v * scale + .5)
                expected = clean.crop((edge(101), edge(201), edge(501), edge(401)))
                assert crop.size == expected.size, (crop.size, expected.size)
                assert_pixels(crop, expected, "overlay leaked into region PNG")

                open_picker()
                ipc.key_press("Escape")
                click(200, 300)
                assert len(files()) == 1, "Escape saved an image"
                open_picker()
                click(300, 300)  # zero-size selections stay open
                ipc.key_press("Escape")
                assert len(files()) == 1

                open_picker()
                ipc.pointer_button(273, True)
                ipc.pointer_button(273, False)
                assert len(files()) == 1
                open_picker()
                click((round(clean.width / scale) - 360) // 2 + 335, 45)
                assert len(files()) == 1

                # Wait for the success toast to leave before comparing full output.
                time.sleep(4)
                before_full = image("before-full")
                open_picker()
                width = round(clean.width / scale)
                click((width - 360) // 2 + 220, 45)
                wait_for(lambda: len(files()) == 2, "Full Screen was not saved")
                full = next(p for p in files() if p != region)
                wait_for(lambda: clipboard_matches(full), "full-screen clipboard differs from PNG")
                shot = Image.open(full).convert("RGB")
                assert shot.size == clean.size
                # Exclude the clock/taskbar from the exact check.
                assert_pixels(shot.crop((0, 100, 700, 500)), before_full.crop((0, 100, 700, 500)), "picker leaked into Full Screen")
                # A receiver that stops reading must not block input/capture,
                # and clipboard replacement must not invalidate its PNG bytes.
                receiver = subprocess.Popen(["wl-paste", "--no-newline", "--type", "image/png"], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                try:
                    time.sleep(.1)
                    ipc.key_press("Print")
                    wait_for(lambda: len(files()) == 3, "blocked clipboard receiver stalled capture")
                    data, err = receiver.communicate(timeout=5)
                    assert receiver.returncode == 0, err
                    assert data == full.read_bytes(), "clipboard replacement changed an in-flight PNG"
                    latest = next(p for p in files() if p not in (region, full))
                    wait_for(lambda: clipboard_matches(latest), "Print did not update PNG clipboard")
                finally:
                    if receiver.poll() is None:
                        receiver.kill()
                        receiver.wait()

                # Shell panels survive the picker, cancellation, and saved
                # captures. Their focused key handlers must allow shortcuts.
                ipc.set_dnd(True)
                time.sleep(4)
                for panel, action in (("start_menu", "OpenStartMenu"),
                                      ("control_center", "OpenControlCenter"),
                                      ("power_menu", "OpenPowerMenu")):
                    move(200, 200)
                    ipc.action(action)
                    time.sleep(.6)
                    state = ipc.get_shell_state(output["name"])[panel]
                    assert state and state["state"] == "open", (panel, state)
                    before_panel = image("before-" + panel)
                    open_picker()
                    assert ipc.get_shell_state(output["name"])[panel]["state"] == "open", panel
                    height = round(clean.height / scale)
                    move(100, 180)
                    ipc.pointer_button(272, True)
                    move(300, height - 20)
                    selection = image("over-taskbar-" + panel)
                    edge = lambda v: int(v * scale + .5)
                    assert selection.getpixel((edge(300), edge(height - 20))) == (255, 255, 255), "taskbar covered selection corner"
                    ipc.key_press("Escape")
                    ipc.pointer_button(272, False)
                    assert ipc.get_shell_state(output["name"])[panel]["state"] == "open", panel
                    previous = set(files())
                    open_picker()
                    click((width - 360) // 2 + 220, 45)
                    saved = wait_for(lambda: set(files()) - previous, "panel screenshot was not saved")
                    shot = Image.open(saved.pop()).convert("RGB")
                    box = state["box"]
                    x, y = box["x"] - output["x"], box["y"] - output["y"]
                    bounds = (edge(x), edge(y), edge(x + box["width"]), edge(y + box["height"]))
                    assert_pixels(shot.crop(bounds), before_panel.crop(bounds), panel + " changed in saved screenshot")
                    assert ipc.get_shell_state(output["name"])[panel]["state"] == "open", panel
                    previous = set(files())
                    ipc.key_press("Print")
                    saved = wait_for(lambda: set(files()) - previous, "panel swallowed Print")
                    shot = Image.open(saved.pop()).convert("RGB")
                    assert_pixels(shot.crop(bounds), before_panel.crop(bounds), panel + " changed on Print")
                    ipc.key_press("Escape")
                    time.sleep(.4)
                assert process.poll() is None
                print(f"screenshot tool scale {scale}, displays {displays}: passed")
        except Exception:
            log.flush()
            print((tmp / "compositor.log").read_text()[-6000:])
            raise
        finally:
            stop_process(process)
            log.close()


if __name__ == "__main__":
    run(1)
    run(1.5)
    run(1, "2")

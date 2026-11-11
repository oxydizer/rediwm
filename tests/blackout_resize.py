"""Interactive corner feedback checks, called by the Blackout visual suite."""
import os
import subprocess
import time

from desktop_zoom import build_client, wait_for
from ipc_client import stop_process


def check_narrow(ipc, scale, tmp, capture, crop):
    """An outline that no longer fits must match the ordinary frame fallback."""
    config_path = tmp / "rediwm-config.toml"
    original = config_path.read_text()
    # Files has a 360 px minimum. Use the existing resizable xdg fixture to
    # exercise smaller frames, including the grouped titlebar in the report.
    build_client(tmp)
    display = next(p.name for p in tmp.glob("wayland-*") if not p.name.endswith(".lock"))
    client = subprocess.Popen([str(tmp / "client"), "--app-id", "blackout-narrow", "--title", "Narrow"],
        env=dict(os.environ, XDG_RUNTIME_DIR=str(tmp), WAYLAND_DISPLAY=display,
                 REDIWM_TEST_DECORATION="server", REDIWM_TEST_RESIZE="1"),
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        window = wait_for(lambda: next((w for w in ipc.get_windows()
                                        if w["app_id"] == "blackout-narrow"), None), "narrow client")
        wid = window["id"]
        ipc.set_zoom(wid, 100)
        ipc.action("move_window_to", {"id": wid, "x": 80, "y": 80})
        ipc.focus_window(wid)
        ipc.move_cursor(10, 10)
        for grouped in (False, True):
            config = original.replace('[compositor]', '[compositor]\nwindow_tab_apps = ["blackout-narrow"]', 1) if grouped else original
            config_path.write_text(config)
            ipc.reload_config()
            for width in (360, 294, 293, 278, 270, 250, 210, 360):
                ipc.action("set_window_size", {"id": wid, "width": width, "height": 300})
                wait_for(lambda: ipc.get_window_debug(wid)["client_box"]["width"] == width,
                         f"narrow resize to {width}")
                ipc.wait_for("window_geometry_settled", window_id=wid)
                box = ipc.get_window_debug(wid)["chrome_box"]
                rect = (0, 0, box["width"], ipc.get_window_debug(wid)["titlebar_height"])
                actual = capture()
                actual.save(f"/tmp/blackout-narrow-{width}-{scale}.png")
                config_path.write_text(config + '\nwindow_shape = ""\n')
                ipc.reload_config()
                ipc.wait_for_frame()
                fallback = capture()
                same = crop(actual, box, rect).tobytes() == crop(fallback, box, rect).tobytes()
                # The raised step and the right chamfer need 297.5 logical px,
                # including the two 2 px borders around the client.
                assert same == (box["width"] < 297.5), (grouped, width, box, same)
                config_path.write_text(config)
                ipc.reload_config()
                ipc.wait_for_frame()
    finally:
        stop_process(client)
        wait_for(lambda: not any(w["app_id"] == "blackout-narrow" for w in ipc.get_windows()), "narrow client closed")
        config_path.write_text(original)
        ipc.reload_config()


def check_resize(ipc, wid, scale, tmp, capture, crop, yellow):
    config_path = tmp / "rediwm-config.toml"
    original = config_path.read_text()
    animated = original.replace('[animations]\nenabled = false',
                                '[animations]\nenabled = true\nreduced_motion = "off"')
    now = int(time.monotonic() * 1000) + 10000

    def step(ms):
        ipc.action("set_anim_time", {"ms": now + ms})
        ipc.wait_for_frame()

    def length():
        image = capture()
        box = ipc.get_window_debug(wid)["chrome_box"]
        strip = crop(image, box, (0, box["height"] - 4, 80, 3))
        return max((x for x in range(strip.width)
                    if any(yellow(strip.getpixel((x, y))) for y in range(strip.height))), default=0)

    def begin():
        box = ipc.get_window_debug(wid)["chrome_box"]
        x, y = box["x"] + box["width"] + 2, box["y"] + box["height"] // 2
        ipc.move_cursor(x, y)
        ipc.pointer_button(272, True)
        ipc.wait_for_frame()
        assert ipc.get_input_state()["cursor_mode"] == "resize", ipc.get_input_state()
        return x, y

    try:
        step(0)
        config_path.write_text(animated)
        ipc.reload_config()
        ipc.wait_for_frame()
        resting = length()
        old_width = ipc.get_window_debug(wid)["client_box"]["width"]
        x, y = begin()
        step(35)
        growing = length()
        step(160)
        extended = length()
        assert resting < growing < extended, (resting, growing, extended)
        assert 16 * scale <= extended - resting <= 20 * scale, (resting, extended)
        # The held grab lights the corners before any size change, and the
        # length survives an actual client configure/commit during the drag.
        ipc.move_cursor(x + 40, y)
        wait_for(lambda: ipc.get_window_debug(wid)["client_box"]["width"] > old_width, "resize commit")
        assert length() == extended
        capture().save(f"/tmp/blackout-resizing-{scale}.png")
        ipc.pointer_button(272, False)
        ipc.wait_for_frame()
        step(195)
        shrinking = length()
        step(400)
        assert resting < shrinking < extended, (resting, shrinking, extended)
        assert length() == resting

        # Hiding a window interrupts a resize even while its button is held.
        begin()
        step(600)
        assert length() == extended
        ipc.minimize(wid)
        assert ipc.get_input_state()["cursor_mode"] == "passthrough"
        ipc.pointer_button(272, False)
        step(850)
        ipc.restore(wid)
        step(1850)
        ipc.move_cursor(10, 10)
        assert length() == resting, "corner feedback stuck after an interrupted resize"

        # Reduced motion keeps the feedback, but reaches both endpoints immediately.
        config_path.write_text(animated.replace('reduced_motion = "off"', 'reduced_motion = "on"'))
        ipc.reload_config()
        begin()
        assert length() == extended, "reduced-motion resize did not extend immediately"
        ipc.pointer_button(272, False)
        ipc.wait_for_frame()
        assert length() == resting, "reduced-motion release did not restore immediately"
        # Pack defaults can be overridden by config: both timing and the
        # easing curve must change, as well as the endpoint length.
        config_path.write_text(animated + '\nwindow_corner_resize_extra = 30\n'
                               'window_corner_resize_ms = 400\nwindow_corner_restore_ms = 350\n'
                               'window_corner_resize_ease = "in_out_sine"\n')
        ipc.reload_config()
        step(2000)
        begin()
        step(2100)
        slow = length()
        assert resting < slow < resting + 10 * scale, (resting, slow)
        step(2450)
        longer = length()
        assert 28 * scale <= longer - resting <= 32 * scale, (resting, longer)
        ipc.pointer_button(272, False)
        ipc.wait_for_frame()
        step(2700)
        assert resting < length() < longer, "configured restore duration was ignored"
        step(2850)
        assert length() == resting
    finally:
        ipc.pointer_button(272, False)
        config_path.write_text(original)
        ipc.reload_config()
        ipc.action("set_anim_time", {"ms": None})
        ipc.move_cursor(10, 10)
        ipc.wait_for_frame()

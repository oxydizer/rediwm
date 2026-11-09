"""Interactive corner feedback checks, called by the Blackout visual suite."""
import time

from desktop_zoom import wait_for


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

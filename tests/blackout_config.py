"""Verify decoration rendering depends on theme data, including live overrides."""
from pathlib import Path
import tomllib

from desktop_zoom import wait_for


def check_config(ipc, wid, scale, tmp, capture, crop, yellow):
    config_path = tmp / "rediwm-config.toml"
    original = config_path.read_text()
    # The same pack under an unrelated ID must retain all decoration features.
    source = Path(__file__).resolve().parents[1] / "assets/themes/blackout.toml"
    pack = tmp / "data/rediwm/themes/config-audit"
    pack.mkdir(parents=True)
    manifest = source.read_text().replace('id = "blackout"', 'id = "config-audit"', 1)
    manifest = manifest.replace('name = "Blackout"', 'name = "Config audit"', 1)
    (pack / "theme.toml").write_text(manifest)
    try:
        ipc.action("theme.apply", {"id": "config-audit"})
        ipc.wait_for_frame()
        assert tomllib.loads(config_path.read_text())["theme"]["base"] == "config-audit"
        check_border(ipc, wid, scale, tmp, capture)
        before = capture()
        box = ipc.get_window_debug(wid)["chrome_box"]
        sample = (round((box["x"] + 80) * scale), round((box["y"] + 8) * scale))
        assert yellow(before.getpixel(sample)), "title plate depends on pack name"
        check_power_menu(ipc, scale, capture, crop, yellow)
        body = ipc.get_window_debug(wid)["client_box"]
        track_box = (body["width"] - 18, 120, 18, 160)
        old_track = crop(before, body, track_box).tobytes()
        values = {
            "window_title_plate_inset": 10,
            "window_title_plate_bevel": 2,
            "window_title_plate_slant": 0.25,
            "window_title_plate_control_gap": 20,
            "window_title_plate_text_padding": 12,
            "window_corner_inset": 1,
            "window_corner_end_padding": 8,
            "scrollbar_track_stripe_period": 16,
            "scrollbar_track_stripe_width": 3,
            "scrollbar_track_stripe_slope": 0.5,
        }
        overrides = "\n".join(f"{key} = {value}" for key, value in values.items())
        config_path.write_text(config_path.read_text().replace("[theme]", "[theme]\n" + overrides, 1))
        ipc.reload_config()
        tokens = ipc.action("get_theme")["tokens"]
        for key, value in values.items():
            assert abs(tokens[key] - value) < .001, (key, tokens[key], value)

        def changed():
            image = capture()
            if yellow(image.getpixel(sample)):
                return None
            if crop(image, body, track_box).tobytes() == old_track:
                return None
            return image

        after = wait_for(changed, "live plate/stripe geometry overrides")
        def endpoint(image):
            strip = crop(image, box, (0, box["height"] - 4, 80, 3))
            return max((x for x in range(strip.width)
                        if any(yellow(strip.getpixel((x, y))) for y in range(strip.height))), default=0)
        assert 5 * scale <= endpoint(before) - endpoint(after) <= 7 * scale, "corner padding ignored"
    finally:
        config_path.write_text(original)
        ipc.reload_config()
        ipc.wait_for_frame()


def check_border(ipc, wid, scale, tmp, capture):
    """The hover ring occupies the reserved frame width, including on reload."""
    config_path = tmp / "rediwm-config.toml"
    original = config_path.read_text()
    client = ipc.get_window_debug(wid)["client_box"]
    try:
        for border in (2, 1, 2):
            config_path.write_text(original + f"\nwindow_border_width = {border}\n")
            ipc.reload_config()
            ipc.wait_for("window_geometry_settled", window_id=wid)
            debug = ipc.get_window_debug(wid)
            body, frame = debug["client_box"], debug["chrome_box"]
            assert debug["frame_border"] == debug["footer_height"] == border, debug
            assert (body["width"], body["height"]) == (client["width"], client["height"]), debug
            assert body["x"] == frame["x"] + border, debug
            assert frame["width"] == body["width"] + 2 * border, debug
            assert frame["height"] == body["height"] + debug["titlebar_height"] + border, debug
            ipc.move_cursor(body["x"] + body["width"] // 2, body["y"] + body["height"] // 2)
            image = capture()
            x = round((frame["x"] + frame["width"] / 2) * scale)
            bottom = round((frame["y"] + frame["height"]) * scale)
            for offset in range(int(border * scale + .5)):
                pixel = image.getpixel((x, bottom - 1 - offset))
                assert max(abs(a - b) for a, b in zip(pixel, (115, 124, 104))) <= 3, (border, offset, pixel)
        image.save(f"/tmp/blackout-border-{scale}.png")
    finally:
        config_path.write_text(original)
        ipc.reload_config()
        ipc.move_cursor(10, 10)


def check_power_menu(ipc, scale, capture, crop, yellow):
    """Hover and keyboard focus use the pack's yellow for outline and icon."""
    ipc.move_cursor(10, 10)
    ipc.action("open_power_menu")
    ipc.wait_for_frame()
    try:
        box = ipc.get_shell_state()["power_menu"]["box"]
        cards = [w for w in ipc.get_widget_tree("power_menu")["widgets"] if w["role"] == "row"]

        def check(card):
            image = capture()
            x, y, w, h = (card[k] for k in ("x", "y", "width", "height"))
            border = crop(image, box, (x + 16, y, w - 32, 4))
            icon = crop(image, box, (x + 8, y + 8, w - 16, h - 16))
            assert sum(yellow(p) for p in border.getdata()) > 30 * scale, "power-menu outline is not yellow"
            assert sum(yellow(p) for p in icon.getdata()) > 20 * scale, "power-menu icon is not yellow"

        # Lock and Log Out are available without a logind service. Only hover:
        # the test never activates a session action.
        for card in cards[:2]:
            target = card["box"]
            ipc.move_cursor(box["x"] + target["x"] + target["width"] // 2,
                            box["y"] + target["y"] + target["height"] // 2)
            check(target)
        ipc.move_cursor(10, 10)
        ipc.key_down_up(106)
        check(cards[0]["box"])
        capture().save(f"/tmp/blackout-power-menu-{scale}.png")
    finally:
        ipc.key_down_up(1)
        ipc.wait_for("power_menu_closed")
        ipc.move_cursor(10, 10)

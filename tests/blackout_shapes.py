"""Beveled chrome controls and both Start panel variants, including live reload."""
import math


def check_shapes(ipc, wid, scale, tmp, capture):
    config_path = tmp / "rediwm-config.toml"
    original = config_path.read_text()
    assert ipc.action("get_theme")["tokens"]["scrollbar_width"] == 10

    def override(name, value):
        config_path.write_text(original + f"\n{name} = {value}\n")
        ipc.reload_config()
        ipc.wait_for_frame()

    def pixel(image, x, y):
        return image.getpixel((math.floor(x * scale), math.floor(y * scale)))

    try:
        for name in ("minimize", "maximize", "close"):
            control = next(w for w in ipc.get_widget_tree(f"window/{wid}")["widgets"] if w["name"] == name)
            box = control["global_box"]
            ipc.move_cursor(box["x"] + box["width"] // 2, box["y"] + box["height"] // 2)
            beveled = capture()
            override("chrome_button_bevel", 0)
            rounded = capture()
            x, y = box["x"] + 1.5, box["y"] + 1.5
            assert max(abs(a - b) for a, b in zip(pixel(beveled, x, y), (17, 21, 22))) <= 2, (name, pixel(beveled, x, y))
            assert max(abs(a - b) for a, b in zip(pixel(beveled, x, y), pixel(rounded, x, y))) > 10, name
            x = box["x"] + box["width"] / 2
            assert pixel(beveled, x, y) == pixel(rounded, x, y), name
            override("chrome_button_bevel", 7)
        capture().save(f"/tmp/blackout-beveled-controls-{scale}.png")
        config_path.write_text(original)
        ipc.reload_config()
        ipc.move_cursor(10, 10)

        for launcher in (False, True):
            closed = capture()
            if launcher:
                ipc.key(125, True)
                ipc.key_down_up(57)
                ipc.key(125, False)
            else:
                ipc.action("open_start_menu")
            ipc.wait_for("menu_opened")
            box = ipc.get_shell_state()["start_menu"]["box"]
            points = [(box["x"] + dx, box["y"] + dy)
                      for dx in (3.5, box["width"] - 3.5)
                      for dy in (8.5, box["height"] - 8.5)]

            def check_cuts(image):
                for x, y in points:
                    assert pixel(image, x, y) == pixel(closed, x, y), (launcher, x, y, pixel(image, x, y), pixel(closed, x, y))
                assert pixel(image, box["x"] + 11.5, box["y"] + 11.5) == (21, 25, 26)

            check_cuts(capture())
            override("start_menu_bevel", 0)
            rounded = capture()
            assert any(pixel(rounded, x, y) != pixel(closed, x, y) for x, y in points)
            override("start_menu_bevel", 16)
            check_cuts(capture())
            capture().save(f"/tmp/blackout-beveled-menu-{launcher}-{scale}.png")
            ipc.key_down_up(1)
            ipc.wait_for("menu_closed")
    finally:
        config_path.write_text(original)
        ipc.reload_config()
        ipc.move_cursor(10, 10)

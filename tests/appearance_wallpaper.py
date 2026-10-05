#!/usr/bin/env python3
"""Appearance > Wallpaper: lists the bundled wallpaper plus images in
$XDG_DATA_HOME/rediwm/wallpapers, switches live (PNG and GdkPixbuf-decoded
JPEG), persists `[compositor] wallpaper`, follows hand edits to a path, and
falls back to the bundled image when the chosen file is missing. A scrolling
strip of thumbnails with a tick box on the current image selects too, shows
the folder a path wallpaper lives in, and "Choose folder" picks another."""
from pathlib import Path
import tempfile
import time
import tomllib

from PIL import Image

from desktop_zoom import wait_for
from ipc_client import IPCClient, spawn_compositor, stop_process

AQUA = (20, 200, 190)
STRIPES = (200, 60, 30)
OUTSIDE = (90, 40, 160)


def run():
    with tempfile.TemporaryDirectory(prefix="rediwm-wallpaper-") as directory:
        tmp = Path(directory)
        user_dir = tmp / "data/rediwm/wallpapers"
        user_dir.mkdir(parents=True)
        Image.new("RGB", (64, 36), AQUA).save(user_dir / "aqua.png")
        Image.new("RGB", (64, 36), STRIPES).save(user_dir / "zebra_stripes.jpg", quality=95)
        (user_dir / "notes.txt").write_text("not an image\n")
        outside = tmp / "elsewhere.png"
        Image.new("RGB", (64, 36), OUTSIDE).save(outside)
        pictures = tmp / "pictures"
        pictures.mkdir()
        colors = [(10 + 20 * i, 240 - 15 * i, 60 + 10 * i) for i in range(12)]
        for i, colour in enumerate(colors):
            Image.new("RGB", (64, 36), colour).save(pictures / f"img{i:02d}.png")
        config_path = tmp / "rediwm-config.toml"
        proc, log = spawn_compositor(
            tmp, config_content="[compositor]\nxwayland = false\nwindow_gap = 12\n",
            env_extra={"XDG_DATA_HOME": str(tmp / "data"), "HOME": str(tmp), "DBUS_SESSION_BUS_ADDRESS": ""})
        try:
            with IPCClient(tmp, timeout=15) as ipc:
                ipc.wait_for("wallpaper_presented", timeout_ms=10000)

                shots = iter(range(1_000_000))

                def pixel():
                    # Top-left corner: clear of the control center and taskbar.
                    path = tmp / f"shot-{next(shots)}.png"
                    ipc.screenshot(str(path))
                    with Image.open(path) as image:
                        return image.convert("RGB").getpixel((6, 6))

                def near(actual, expected, tolerance=6):
                    return all(abs(a - e) <= tolerance for a, e in zip(actual, expected))

                def wait_color(expected, what):
                    try:
                        wait_for(lambda: near(pixel(), expected), what)
                    except AssertionError:
                        raise AssertionError(f"{what}: wallpaper is {pixel()}, want {expected}") from None

                default = pixel()
                assert not near(default, AQUA), default

                ipc.action('open_control_center')
                time.sleep(.3)

                def widgets():
                    return ipc.get_widget_tree("control_center")["widgets"]

                def click(widget):
                    panel = ipc.get_shell_state()["control_center"]["box"]
                    box = widget["box"]
                    ipc.click_at(round(panel["x"] + box["x"] + box["width"] / 2),
                                 round(panel["y"] + box["y"] + box["height"] / 2))
                    time.sleep(.2)

                def named(name):
                    return next(w for w in widgets() if w["name"] == name)

                def saved():
                    return tomllib.loads(config_path.read_text())["compositor"].get("wallpaper")

                def prefixed(prefix):
                    return sorted((w for w in widgets() if (w["name"] or "").startswith(prefix)),
                                  key=lambda w: int(w["name"].rsplit("_", 1)[1]))

                def ticked():
                    return [w["name"] for w in prefixed("wallpaper_check_") if w["checked"]]

                def centre(widget):
                    panel = ipc.get_shell_state()["control_center"]["box"]
                    box = widget["box"]
                    return (round(panel["x"] + box["x"] + box["width"] / 2),
                            round(panel["y"] + box["y"] + box["height"] / 2))

                def pixel_at(x, y):
                    path = tmp / f"shot-{next(shots)}.png"
                    ipc.screenshot(str(path))
                    with Image.open(path) as image:
                        return image.convert("RGB").getpixel((x, y))

                def pick(downs):
                    click(named("wallpaper"))
                    ipc.key_press("Home")
                    for _ in range(downs):
                        ipc.key_press("Down")
                    ipc.key_press("Return")
                    time.sleep(.4)

                click(next(w for w in widgets() if w["label"] == "Appearance"))
                assert ipc.get_shell_state()["control_center"]["box"]["x"] > 12
                assert not named("wallpaper")["is_disabled"]
                assert not prefixed("wallpaper_preview")
                tile = named("wallpaper_tile_0")["box"]
                check = named("wallpaper_check_0")["box"]
                assert tile["width"] == 166 and tile["height"] == 96, tile
                assert check["x"] == tile["x"] + tile["width"] - 29, (tile, check)
                assert check["y"] == tile["y"] + tile["height"] - 29, (tile, check)
                assert not named("wallpaper_folder")["is_disabled"]
                # The strip lists the same images as the dropdown, ticking the
                # bundled default; a tile or its tick box selects.
                assert len(prefixed("wallpaper_tile_")) == 3
                assert ticked() == ["wallpaper_check_0"], ticked()
                click(named("wallpaper_tile_1"))
                assert saved() == "aqua.png", config_path.read_text()
                wait_color(AQUA, "strip tile")
                wait_for(lambda: ticked() == ["wallpaper_check_1"], "tick follows the tile")
                click(named("wallpaper_check_2"))
                assert saved() == "zebra_stripes.jpg"
                wait_color(STRIPES, "strip tick box")
                click(named("wallpaper_check_2"))
                assert saved() == "zebra_stripes.jpg"
                wait_for(lambda: ticked() == ["wallpaper_check_2"], "ticking the current image keeps it ticked")
                click(named("wallpaper_tile_0"))
                assert saved() == ""
                wait_color(default, "bundled default from the strip")
                # RediWM's own, then the user's by label: Aqua, Zebra stripes.
                pick(1)
                assert saved() == "aqua.png", config_path.read_text()
                wait_color(AQUA, "user PNG")
                wait_for(lambda: ticked() == ["wallpaper_check_1"], "dropdown moves the tick")
                pick(2)
                assert saved() == "zebra_stripes.jpg"
                wait_color(STRIPES, "user JPEG")
                pick(0)
                assert saved() == ""
                wait_color(default, "bundled default")
                assert tomllib.loads(config_path.read_text())["compositor"]["window_gap"] == 12

                # Hand edits: a path outside the wallpaper directories, then a
                # missing file, which falls back to the bundled image.
                config_path.write_text(f'[compositor]\nxwayland = false\nwallpaper = "{outside}"\n')
                wait_color(OUTSIDE, "configured path")
                # A path wallpaper shows its own folder: a scrolling row, the
                # current image ticked and scrolled into view.
                config_path.write_text(f'[compositor]\nxwayland = false\nwallpaper = "{pictures}/img07.png"\n')
                wait_color(colors[7], "picture in another folder")
                wait_for(lambda: ticked() == ["wallpaper_check_7"], "current picture ticked")
                assert len(prefixed("wallpaper_tile_")) == 12
                strip = named("wallpaper_strip")
                assert strip["content_size"] > strip["box"]["width"], strip
                offset = strip["scroll_offset"]
                assert offset > 0, strip
                tile = named("wallpaper_tile_6")
                x, y = centre(tile)
                wait_for(lambda: near(pixel_at(x, y), colors[6], 8), "thumbnail decoded")
                click(tile)
                assert saved() == f"{pictures}/img06.png", config_path.read_text()
                wait_color(colors[6], "picture from the strip")
                wait_for(lambda: ticked() == ["wallpaper_check_6"], "tick moves within the folder")
                assert abs(named("wallpaper_strip")["scroll_offset"] - offset) < 1, "strip keeps its place"
                x, y = centre(named("wallpaper_strip"))
                ipc.move_cursor(x, y)
                ipc.scroll(0, 200)
                wait_for(lambda: abs(named("wallpaper_strip")["scroll_offset"] - offset) > 20, "wheel scrolls the strip sideways")

                # "Choose folder" runs Files as a folder chooser; the folder it
                # returns fills the strip, without changing the wallpaper.
                config_path.write_text('[compositor]\nxwayland = false\n')
                wait_color(default, "default wallpaper again")
                wait_for(lambda: len(prefixed("wallpaper_tile_")) == 3, "wallpaper directories listed again")

                # Below the fold: wheel the page over the wallpaper selector until it shows.
                x, y = centre(named("wallpaper"))
                ipc.move_cursor(x, y)
                for _ in range(20):
                    if not named("wallpaper_folder")["clipped"]:
                        break
                    ipc.scroll(0, -200)  # natural scrolling: negative moves down
                    time.sleep(.3)
                    x, y = centre(named("wallpaper"))
                    ipc.move_cursor(x, y)
                assert not named("wallpaper_folder")["clipped"]
                click(named("wallpaper_folder"))

                def chooser():
                    return next((w for w in ipc.get_windows() if w["app_id"] == "rediwm-file-chooser"), None)

                window = wait_for(chooser, "folder chooser")
                assert named("wallpaper_folder")["is_disabled"], "one chooser at a time"
                ipc.focus_window(window["id"])
                time.sleep(.3)
                ipc.key(29, True)
                ipc.key_down_up(38)  # Ctrl+L
                ipc.key(29, False)
                time.sleep(.2)
                ipc.type_text(str(pictures))
                ipc.key_press("Return")
                time.sleep(.5)
                ipc.key_press("Return")
                wait_for(lambda: chooser() is None, "chooser accepted")
                wait_for(lambda: len(prefixed("wallpaper_tile_")) == 12, "chosen folder's images listed")
                assert ticked() == [], ticked()
                assert not named("wallpaper_folder")["is_disabled"]
                assert saved() is None, config_path.read_text()
                assert any(w["label"] == "Images in ~/pictures" for w in widgets()), [w["label"] for w in widgets() if w["label"]]
                x, y = centre(named("wallpaper_tile_3"))
                wait_for(lambda: near(pixel_at(x, y), colors[3], 8), "chosen folder thumbnails")
                click(named("wallpaper_tile_3"))
                assert saved() == f"{pictures}/img03.png", config_path.read_text()
                wait_color(colors[3], "picture from the chosen folder")
                wait_for(lambda: ticked() == ["wallpaper_check_3"], "chosen folder's tick")
                config_path.write_text('[compositor]\nxwayland = false\nwallpaper = "missing.png"\n')
                wait_color(default, "missing file fallback")
                assert "missing.png" in (tmp / "compositor.log").read_text()
            stop_process(proc)
            assert proc.returncode == 0, (tmp / "compositor.log").read_text()
        finally:
            if proc.poll() is None:
                stop_process(proc)
            log.close()
    print("PASS: wallpaper discovery, live switch, persistence, paths and fallback")


if __name__ == "__main__":
    run()

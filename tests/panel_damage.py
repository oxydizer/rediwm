#!/usr/bin/env python3
"""Isolated panel invalidation and repaint-history checks, including fractional scale."""
import argparse
from pathlib import Path
import tempfile
import time

from PIL import Image, ImageChops
from ipc_client import IPCClient, spawn_compositor, stop_process
from ui_driver import UIDriver


def settings_glide(scale):
    """Keep the pinned-clock glide fixture in its own compositor."""
    with tempfile.TemporaryDirectory(prefix="rediwm-settings-glide-") as directory:
        tmp = Path(directory)
        process, log = spawn_compositor(tmp, scale=scale, env_extra={"DBUS_SESSION_BUS_ADDRESS": ""})
        try:
            with IPCClient(tmp, timeout=15) as ipc:
                ipc.wait_for("wallpaper_presented", timeout_ms=10000)
                # Settings uses the start-menu curves for hover and selection.
                ipc.action('set_anim_time', {"ms": 1000})
                ipc.open_control_center()
                ipc.action('set_anim_time', {"ms": 2000})
                ipc.wait_for_frame()
                ui = UIDriver(ipc)
                ipc.move_cursor(2, 2)

                def navigation_image(name):
                    nav = ui.find("nav", panel="control_center")["global_box"]
                    path = tmp / ("nav-" + name + ".png")
                    ipc.screenshot(str(path))
                    with Image.open(path) as image:
                        return image.convert("RGB").crop(tuple(round(v * float(scale)) for v in (
                            nav["x"], nav["y"], nav["x"] + nav["width"], nav["y"] + nav["height"])))

                before_hover = navigation_image("baseline")
                ui.hover("Input", panel="control_center")
                ipc.action('set_anim_time', {"ms": 3000})
                ipc.wait_for_frame()
                first_hover = navigation_image("input")
                assert ImageChops.difference(before_hover, first_hover).getbbox()
                ui.hover("Displays", panel="control_center")
                ipc.action('set_anim_time', {"ms": 3020})
                ipc.wait_for_frame()
                moving = next(a for a in ipc.action('get_animations') if a["site"] == "control_center.hover")
                assert 1 < moving["value"] < 2 and not moving["settled"], moving
                midway = navigation_image("mid-glide")
                assert ImageChops.difference(first_hover, midway).getbbox()
                ipc.action('reset_panel_stats')
                for _ in range(3):
                    ipc.wait_for_frame()
                assert ipc.action('get_panel_stats')["paints"] == 0, "frozen hover repainted identical pixels"
                ipc.move_cursor(2, 2)
                ipc.action('set_anim_time', {"ms": 4000})
                ipc.wait_for_frame()
                assert ImageChops.difference(before_hover, navigation_image("left")).getbbox() is None
                ui.click("Displays", panel="control_center")
                ipc.action('set_anim_time', {"ms": 4020})
                ipc.wait_for_frame()
                moving = next(a for a in ipc.action('get_animations') if a["site"] == "control_center.selection")
                assert 0 < moving["value"] < 2 and moving["target"] == 2, moving
                # Live motion also settles immediately when disabled mid-glide.
                (tmp / "rediwm-config.toml").write_text("[input]\ninvert_scroll = false\n[animations]\nenabled = false\n")
                ipc.reload_config()
                ipc.wait_for_frame()
                ui.wait_settled("control_center")
                moving = next((a for a in ipc.action('get_animations') if a["site"] == "control_center.selection"), None)
                assert moving is None or (moving["settled"] and moving["value"] == 2), moving
            print(f"PASS: Settings hover and selection glides at scale {scale}")
        finally:
            stop_process(process)
            log.close()


def settings_resize(ipc, tmp, scale):
    """Resize once per frame, including navigation and page breakpoints."""
    ui = UIDriver(ipc)
    ipc.open_control_center()
    ui.wait_settled("control_center")
    window = next(w for w in ipc.get_windows() if w.get("app_id") == "rediwm-settings")
    ipc.move_cursor(2, 2)
    for page in ("General", "Appearance", "Input", "Desktop", "Keyboard Shortcuts", "Network", "Bluetooth"):
        ui.click(ui.find(page, panel="control_center"), panel="control_center")
        ipc.move_cursor(2, 2)
        ui.wait_settled("control_center")
        # Warm both released-buffer slots at the largest size first.
        for width in (1120, 1119, 1120):
            ipc.action("set_window_size", {"id": window["id"], "width": width, "height": 560})
            ui.wait_settled("control_center")
        ipc.action("reset_panel_stats")
        sizes = (1100, 1050, 1020, 990, 920, 890, 770, 740, 670, 650, 630, 660, 760, 900, 1000, 1100)
        for width in sizes:
            ipc.action("set_window_size", {"id": window["id"], "width": width, "height": 540})
            ui.wait_settled("control_center")
        stats = ipc.action("get_panel_stats")
        assert stats["paints"] <= len(sizes), (page, "duplicate resize paints", stats)
        assert stats["allocated_bytes"] == 0, (page, "resize discarded reusable storage", stats)
        box = ipc.get_shell_state()["control_center"]["box"]
        assert box["width"] == 1100 and box["height"] == 540, (page, box)
        def pixels(name):
            path = tmp / (page + "-" + name + ".png")
            ipc.screenshot(str(path))
            with Image.open(path) as image:
                return image.convert("RGB").crop(tuple(round(v * float(scale)) for v in (
                    box["x"], box["y"], box["x"] + box["width"], box["y"] + box["height"])))
        retained = pixels("resized")
        # Selecting the same page forces a complete tree rebuild. Its pixels
        # must match the tree retained through all the resize breakpoints.
        ui.click(ui.find(page, panel="control_center"), panel="control_center")
        ipc.move_cursor(2, 2)
        ui.wait_settled("control_center")
        assert ImageChops.difference(retained, pixels("rebuilt")).getbbox() is None, (page, "resize differs from fresh layout")
    ipc.close_window(window["id"])
    ui.wait_absent("control_center")


def run(scale):
    with tempfile.TemporaryDirectory(prefix="rediwm-panel-damage-") as directory:
        tmp = Path(directory)
        process, log = spawn_compositor(tmp, scale=scale, config_content="[input]\ninvert_scroll = false\n", env_extra={"DBUS_SESSION_BUS_ADDRESS": ""})
        try:
            with IPCClient(tmp, timeout=15) as ipc:
                ipc.wait_for("catalog_published", timeout_ms=10000)
                ipc.wait_for("wallpaper_presented", timeout_ms=10000)
                settings_resize(ipc, tmp, scale)
                ipc.action('set_anim_time', {"ms": 1000})
                for panel, action in (("start_menu", "open_start_menu"), ("control_center", "open_control_center"), ("power_menu", "open_power_menu")):
                    ipc.action(action)
                    ipc.action('set_anim_time', {"ms": 2000})
                    ipc.wait_for_frame()
                    box = ipc.get_shell_state()[panel]["box"]
                    padding = (box["x"] + 10, box["y"] + 10)
                    ipc.move_cursor(*padding)
                    # Allow the real icon worker to finish; animation time is
                    # frozen independently of wall time.
                    time.sleep(.8)

                    def stats():
                        return ipc.action('get_panel_stats')["paints"]

                    def capture(name):
                        path = tmp / f"{panel}-{name}.png"
                        ipc.screenshot(str(path))
                        with Image.open(path) as image:
                            s = float(scale)
                            return image.convert("RGB").crop(tuple(round(v * s) for v in (
                                box["x"], box["y"], box["x"] + box["width"], box["y"] + box["height"])))

                    baseline = capture("baseline")
                    ipc.action('reset_panel_stats')
                    for n in range(30):
                        ipc.move_cursor(padding[0] + n % 3, padding[1])
                        time.sleep(.005)
                    ipc.move_cursor(*padding)
                    time.sleep(.1)
                    assert stats() == 0, (panel, "unchanged padding repainted", stats())
                    assert ImageChops.difference(baseline, capture("padding")).getbbox() is None, (panel, "unchanged padding pixels differ")

                    # Traverse controls/rows and reverse to the original
                    # state using recycled buffers with different histories.
                    for fraction in (.25, .5, .75, .5, .25):
                        ipc.move_cursor(round(box["x"] + box["width"] * (.3 if panel == "power_menu" else .5)),
                                        round(box["y"] + box["height"] * fraction))
                        time.sleep(.04)
                        ipc.move_cursor(*padding)
                        time.sleep(.04)
                    restored = capture("restored")
                    assert ImageChops.difference(baseline, restored).getbbox() is None, (panel, "hover left stale pixels")
                    if panel != "control_center":
                        assert stats() > 0, (panel, "hover fixture did not change any controls")
                    if panel != "power_menu":
                        ipc.action('reset_panel_stats')
                        ipc.scroll(0, -40)
                        time.sleep(.1)
                        assert stats() == 0, (panel, "clamped scroll repainted")
                        for delta in (40, 80, -80, -40):
                            ipc.scroll(0, delta)
                            time.sleep(.05)
                        assert ImageChops.difference(baseline, capture("scroll-restored")).getbbox() is None, (panel, "scroll left stale pixels")
                    ipc.key_down_up(1)  # Escape
                    ipc.action('set_anim_time', {"ms": 3000})
                    ipc.wait_for_frame()
                    ipc.action('set_anim_time', {"ms": 1000})
                assert ipc.get_perf()["output_failed_commits"] == 0
            print(f"PASS: panel no-op motion and exact repaint history at scale {scale}")
        except Exception:
            log.flush()
            print((tmp / "compositor.log").read_text()[-3000:])
            raise
        finally:
            stop_process(process)
            log.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scale", default="1")
    scale = parser.parse_args().scale
    settings_glide(scale)
    run(scale)

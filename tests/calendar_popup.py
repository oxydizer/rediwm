#!/usr/bin/env python3
"""Clock popup navigation and dismissal, isolated from the host desktop."""
import argparse
from pathlib import Path
import tempfile
import time
import tomllib
from ui_driver import UIDriver
from PIL import Image, ImageChops
from ipc_client import IPCClient, spawn_compositor, stop_process


def run(scale):
    with tempfile.TemporaryDirectory(prefix="rediwm-calendar-") as directory:
        tmp = Path(directory)
        # Pixel equality checks need a settled popup, not its opening slide.
        process, log = spawn_compositor(tmp, scale=scale, config_content='[compositor]\nxwayland = false\n[animations]\nenabled = false\n',
                                        env_extra={"DBUS_SESSION_BUS_ADDRESS": "", "XDG_CACHE_HOME": directory})
        try:
            with IPCClient(tmp, timeout=15) as ipc:
                ipc.wait_for("wallpaper_presented", timeout_ms=10000)
                bar = ipc.get_shell_state()["taskbars"][0]["box"]
                clock = (bar["x"] + bar["width"] - 40, bar["y"] + bar["height"] // 2)
                assert ipc.hit_test(*clock)["widget"] == "clock"
                ipc.click_at(*clock)
                ipc.wait_for_frame()
                point = (clock[0], bar["y"] - 50)
                hit = ipc.hit_test(*point)
                assert hit["target_type"] == "calendar", hit
                origin = (point[0] - hit["local_x"], point[1] - hit["local_y"])

                def capture():
                    ipc.wait_for_frame()
                    path = tmp / f"calendar-{time.monotonic_ns()}.png"
                    ipc.screenshot(str(path))
                    with Image.open(path) as image:
                        return image.convert("RGB").copy()

                original = capture()
                ipc.key_down_up(106)
                following = capture()
                assert ImageChops.difference(original, following).getbbox(), "month did not change"
                ipc.key_down_up(105)
                assert not ImageChops.difference(original, capture()).getbbox(), "previous month did not restore calendar"
                # Mouse arrows, then header to return to today's month.
                ipc.click_at(origin[0] + 330, origin[1] + 132)
                assert ImageChops.difference(original, capture()).getbbox()
                ipc.click_at(origin[0] + 100, origin[1] + 50)
                assert not ImageChops.difference(original, capture()).getbbox()
                # Save an isolated output preview for visual inspection.
                preview = Path(f"/tmp/rediwm-calendar-{scale}.png")
                preview.unlink(missing_ok=True)
                ipc.screenshot(str(preview))
                for dismiss in (lambda: ipc.key_down_up(1), lambda: ipc.click_at(*clock), lambda: ipc.click_at(20, 20)):
                    dismiss()
                    ipc.wait_for_frame()
                    assert ipc.hit_test(*point)["target_type"] != "calendar"
                    ipc.click_at(*clock)
                    ipc.wait_for_frame()
                    assert ipc.hit_test(*point)["target_type"] == "calendar"
                ipc.key_down_up(1)
                ui = UIDriver(ipc)
                ipc.action("open_control_center")
                ui.wait_settled("control_center")
                ui.click("region", panel="control_center")
                ui.wait_settled("control_center")
                assert not any(w["label"] == "Preferred Languages" for w in ui.widgets())
                assert ui.find("first_day_of_week", panel="control_center")["selected_index"] == 0
                ui.click(ui.scroll_into_view("first_day_of_week"), panel="control_center")
                ipc.key_down_up(108)  # Sunday -> Monday
                ipc.key_down_up(28)
                ui.wait_settled("control_center")
                cfg_path = tmp / "rediwm-config.toml"
                assert tomllib.loads(cfg_path.read_text())["region"]["first_day_of_week"] == "monday"
                ui.click(ui.scroll_into_view("clock_24h"), panel="control_center")
                ui.wait_settled("control_center")
                assert tomllib.loads(cfg_path.read_text())["region"]["clock_24h"] is True
                assert any(w["label"] == "15:24" for w in ui.widgets())
                window = next(w for w in ipc.get_windows() if w["app_id"] == "rediwm-settings")
                # Cross the layout breakpoint and keep the dropdown usable in
                # a narrow window, including its scroll position after rebuild.
                ipc.action("set_window_size", {"id": window["id"], "width": 760, "height": 580})
                ui.wait_settled("control_center")
                assert ui.scroll_into_view("first_day_of_week")["selected_index"] == 1
                ipc.maximize(window["id"])
                ui.wait_settled("control_center")
                settings_preview = Path(f"/tmp/rediwm-region-{scale}.png")
                settings_preview.unlink(missing_ok=True)
                ipc.screenshot(str(settings_preview))
                ipc.close_window(window["id"])
                ui.wait_absent("control_center")
                ipc.click_at(*clock)
                ipc.wait_for_frame()
                monday = capture()
                hit = ipc.hit_test(*point)
                monday_origin = (point[0] - hit["local_x"], point[1] - hit["local_y"])

                def crop(image, xy, rect):
                    x, y, w, h = rect
                    return image.crop(tuple(round(v * float(scale)) for v in
                                            (xy[0] + x, xy[1] + y, xy[0] + x + w, xy[1] + y + h)))

                # The calendar heading AND dates must move, not just the label
                # in Settings. Compare interior pixels away from its glass edge.
                assert ImageChops.difference(crop(original, origin, (20, 158, 329, 30)),
                                            crop(monday, monday_origin, (20, 158, 329, 30))).getbbox()
                assert ImageChops.difference(crop(original, origin, (20, 190, 329, 180)),
                                            crop(monday, monday_origin, (20, 190, 329, 180))).getbbox()
                assert ImageChops.difference(crop(original, origin, (24, 17, 300, 44)),
                                            crop(monday, monday_origin, (24, 17, 300, 44))).getbbox()
                # A file edit must update an already-open popup immediately.
                cfg_path.write_text(cfg_path.read_text().replace('"monday"', '"sunday"').replace('clock_24h = true', 'clock_24h = false'))
                ipc.reload_config()
                ipc.wait_for_frame()
                restored = capture()
                hit = ipc.hit_test(*point)
                restored_origin = (point[0] - hit["local_x"], point[1] - hit["local_y"])
                assert not ImageChops.difference(crop(original, origin, (20, 158, 329, 210)),
                                                crop(restored, restored_origin, (20, 158, 329, 210))).getbbox()
                ipc.key_down_up(1)
                ipc.action("open_control_center")
                ui.wait_settled("control_center")
                ui.click("region", panel="control_center")
                ui.wait_settled("control_center")
                assert ui.find("first_day_of_week", panel="control_center")["selected_index"] == 0
                assert any(w["label"] == "3:24 PM" for w in ui.widgets())
                print(f"PASS: calendar navigation, preferences, live reload and dismissal at scale {scale}")
        finally:
            stop_process(process)
            log.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scale", default="1")
    run(parser.parse_args().scale)

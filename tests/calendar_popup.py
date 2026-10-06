#!/usr/bin/env python3
"""Clock popup navigation and dismissal, isolated from the host desktop."""
import argparse
import json
import locale
import os
import sys
from hardware_keys import wait
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
        process, log = spawn_compositor(tmp, scale=scale, renderer=os.environ.get("REDIWM_TEST_RENDERER", "pixman"), config_content='[compositor]\nxwayland = false\n[animations]\nenabled = false\n',
                                        env_extra={"DBUS_SESSION_BUS_ADDRESS": "", "XDG_CACHE_HOME": directory, "TZ": "Pacific/Auckland", "LC_ALL": "C", "LANGUAGE": "en"})
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
                assert ui.find("clock_show_seconds")["on"] is False
                assert ui.find("clock_show_day")["on"] is True
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
                assert any("session only; system defaults are unchanged" in (w["label"] or "") for w in ui.widgets())
                wait(lambda: not ui.find("language")["is_disabled"], "installed locales")
                for name in ("language", "formats"):
                    ui.click(ui.scroll_into_view(name), panel="control_center")
                    ipc.key_press("Home")
                    ipc.key_press("Down")
                    ipc.key_press("Return")
                    ui.wait_settled("control_center")
                    assert tomllib.loads(cfg_path.read_text())["region"][name] == "C"
                # UTC is the last sorted zone. Changing it must refresh the
                # existing clock without modifying the host's timezone files.
                before_zone = capture()
                ui.click(ui.scroll_into_view("timezone"), panel="control_center")
                ipc.key_press("End")
                ipc.key_press("Return")
                ui.wait_settled("control_center")
                assert tomllib.loads(cfg_path.read_text())["region"]["timezone"] == "UTC"
                after_zone = capture()
                clock_crop = tuple(round(v * float(scale)) for v in
                                   (bar["x"] + bar["width"] - 100, bar["y"],
                                    bar["x"] + bar["width"], bar["y"] + bar["height"]))
                assert ImageChops.difference(before_zone.crop(clock_crop), after_zone.crop(clock_crop)).getbbox(), "clock did not follow timezone"
                marker = tmp / "child-env.json"
                script = "import json,os; from pathlib import Path; Path(" + repr(str(marker)) + ").write_text(json.dumps(dict(os.environ)))"
                ipc.action("spawn", {"argv": [sys.executable, "-c", script]})
                wait(marker.exists, "new app environment")
                child_env = json.loads(marker.read_text())
                assert child_env["TZ"] == "UTC", child_env
                assert child_env["LANG"] == child_env["LC_MESSAGES"] == "C"
                assert child_env["LC_TIME"] == child_env["LC_NUMERIC"] == child_env["LC_MONETARY"] == "C"
                assert "LC_ALL" not in child_env and "LANGUAGE" not in child_env
                # Reopen Settings to prove that choices survive its arenas.
                window = next(w for w in ipc.get_windows() if w["app_id"] == "rediwm-settings")
                ipc.close_window(window["id"])
                ui.wait_absent("control_center")
                ipc.open_control_center()
                ui.wait_settled("control_center")
                ui.click("region", panel="control_center")
                wait(lambda: not ui.find("language")["is_disabled"], "locales after reopen")
                for name in ("timezone", "language", "formats"):
                    assert ui.find(name)["selected_index"] > 0
                    ui.click(ui.scroll_into_view(name), panel="control_center")
                    ipc.key_press("Home")
                    ipc.key_press("Return")
                    ui.wait_settled("control_center")
                    assert tomllib.loads(cfg_path.read_text())["region"][name] == ""

                def clock_image():
                    box = next(i["box"] for i in ipc.get_shell_state()["taskbars"][0]["right_items"]
                               if i["name"] == "clock")
                    return capture().crop(tuple(round(v * float(scale)) for v in
                                                (box["x"], box["y"], box["x"] + box["width"], box["y"] + box["height"])))

                def ink(image):
                    return image.convert("L").point(lambda value: 255 if value > 150 else 0).getbbox()

                # A two-line clock centers both runs in its fitted column.
                shown = clock_image()
                split = shown.height // 2
                for line in (shown.crop((0, 0, shown.width, split)), shown.crop((0, split, shown.width, shown.height))):
                    bounds = ink(line)
                    assert bounds and abs((bounds[0] + bounds[2]) / 2 - shown.width / 2) <= 2 * float(scale), bounds

                ui.click(ui.scroll_into_view("clock_show_seconds"))
                ui.wait_settled("control_center")
                assert any(w["label"] == "3:24:00 PM" for w in ui.widgets())
                before = ipc.get_perf()["taskbar_clock_frame_requests"]
                first_second = clock_image()
                time.sleep(2.2)
                assert ipc.get_perf()["taskbar_clock_frame_requests"] - before >= 2, "seconds did not rearm the clock timer"
                assert ImageChops.difference(first_second, clock_image()).getbbox(), "seconds did not repaint"

                ui.click(ui.scroll_into_view("clock_show_day"))
                ui.wait_settled("control_center")
                prefs = tomllib.loads(cfg_path.read_text())["region"]
                assert prefs["clock_show_seconds"] is True and prefs["clock_show_day"] is False
                single_line = clock_image()
                bounds = ink(single_line)
                assert bounds and abs((bounds[1] + bounds[3]) / 2 - single_line.height / 2) <= 2 * float(scale), bounds
                assert bounds[3] - bounds[1] < 22 * float(scale), "date line remained visible"

                window = next(w for w in ipc.get_windows() if w["app_id"] == "rediwm-settings")
                ipc.close_window(window["id"])
                ui.wait_absent("control_center")
                ipc.reload_config()
                ipc.open_control_center()
                ui.wait_settled("control_center")
                ui.click("region", panel="control_center")
                ui.wait_settled("control_center")
                assert ui.find("clock_show_seconds")["on"] is True
                assert ui.find("clock_show_day")["on"] is False
                ui.click(ui.scroll_into_view("clock_show_seconds"))
                ui.wait_settled("control_center")
                before = ipc.get_perf()["taskbar_clock_frame_requests"]
                time.sleep(2.2)
                assert ipc.get_perf()["taskbar_clock_frame_requests"] - before <= 1, "disabled seconds still wake every second"
                ui.click(ui.scroll_into_view("clock_show_day"))
                ui.wait_settled("control_center")

                # Check that the taskbar itself follows the regional date,
                # when a second installed locale is available on the test host.
                try:
                    locale.setlocale(locale.LC_TIME, "en_NZ.utf8")
                except locale.Error:
                    pass
                else:
                    baseline_config = cfg_path.read_text()
                    cfg_path.write_text(baseline_config.replace('formats = ""', 'formats = "C"'))
                    ipc.reload_config()
                    us_date = clock_image()
                    cfg_path.write_text(baseline_config.replace('formats = ""', 'formats = "en_NZ.utf8"'))
                    ipc.reload_config()
                    nz_date = clock_image()
                    # The C format has a two-digit year; en_NZ uses four.
                    assert us_date.size != nz_date.size or ImageChops.difference(us_date, nz_date).getbbox(), "taskbar date ignored regional format"
                    cfg_path.write_text(baseline_config)
                    ipc.reload_config()
                print(f"PASS: calendar, region/language/timezone, centered clock, seconds/day toggles, persistence and child environment at scale {scale}")
        except Exception:
            log.flush()
            print((tmp / "compositor.log").read_text()[-5000:])
            raise
        finally:
            stop_process(process)
            log.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scale", default="1")
    run(parser.parse_args().scale)

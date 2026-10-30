#!/usr/bin/env python3
"""Battery popup with fake sysfs and a private PowerProfiles bus."""
import argparse
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

from PIL import Image, ImageChops
from ipc_client import IPCClient, spawn_compositor, stop_process
from power_profiles import start_fake, stop_fake, read_line, command, wait_for, log_text


def run(scale, gold=False, top=False):
    with tempfile.TemporaryDirectory(prefix="rediwm-battery-") as directory:
        root = Path(directory)
        hook = root / "battery.so"
        subprocess.run(["cc", "-shared", "-fPIC", "-Wall", "-Wextra", "-Werror", str(Path(__file__).with_name("battery_hook.c")), "-ldl", "-o", str(hook)], check=True)
        for state, percent, details in (("Full", 100, True), ("Discharging", 10, False), ("Charging", 72, True)):
            tmp = root / state
            tmp.mkdir(mode=0o700)
            supply = tmp / "power_supply" / "BAT0"
            supply.mkdir(parents=True)
            (supply / "scope").write_text("System\n")
            readings = f"POWER_SUPPLY_TYPE=Battery\nPOWER_SUPPLY_CAPACITY={percent}\nPOWER_SUPPLY_STATUS={state}\n" + (
                "POWER_SUPPLY_ENERGY_FULL=57000000\nPOWER_SUPPLY_ENERGY_FULL_DESIGN=90000000\nPOWER_SUPPLY_CYCLE_COUNT=482\n" if details else "")
            if state == "Charging":
                readings += "POWER_SUPPLY_ENERGY_NOW=40000000\nPOWER_SUPPLY_POWER_NOW=12000000\n"
            elif state == "Discharging":
                readings += "POWER_SUPPLY_CHARGE_NOW=3000000\nPOWER_SUPPLY_CURRENT_NOW=2000000\n"
            (supply / "uevent").write_text(readings)
            config = '[compositor]\nxwayland = false\ntaskbar_position = "' + ('top' if top else 'bottom') + '"\n'
            if gold:
                config += '[theme]\nbase = "gold"\n'
            fake = start_fake()
            process, log = spawn_compositor(tmp, outputs=int(os.environ.get("REDIWM_TEST_OUTPUTS", "1")), scale=scale, renderer=os.environ.get("REDIWM_TEST_RENDERER", "gles2"), config_content=config, env_extra={
                "LD_PRELOAD": str(hook), "REDIWM_TEST_BATTERY_DIR": str(supply.parent),
                "DBUS_SYSTEM_BUS_ADDRESS": os.environ["DBUS_SESSION_BUS_ADDRESS"],
                "DBUS_SESSION_BUS_ADDRESS": "", "XDG_CACHE_HOME": str(tmp),
            })
            try:
                with IPCClient(tmp, timeout=15) as ipc:
                    ipc.wait_for("wallpaper_presented", timeout_ms=10000)
                    wait_for(lambda: "active profile balanced" in log_text(tmp), "power profile baseline")
                    warnings = [n for n in ipc.get_notifications()["history"] if n["summary"] == "Low battery"]
                    assert len(warnings) == (1 if state == "Discharging" else 0), warnings
                    if warnings:
                        assert warnings[0]["body"] == "Battery is at 10%. Plug in your charger."
                        assert warnings[0]["urgency"] == 2
                        ipc.dismiss_notification(warnings[0]["id"])
                    bar = ipc.get_shell_state()["taskbars"][0]
                    boxes = {item["name"]: item["box"] for item in bar["right_items"]}

                    def center(box):
                        return box["x"] + box["width"] // 2, box["y"] + box["height"] // 2

                    battery, clock = center(boxes["battery"]), center(boxes["clock"])
                    assert ipc.hit_test(*battery)["widget"] == "battery"
                    ipc.click_at(*battery)
                    time.sleep(0.35)  # Let the panel slide/fade finish before pixel comparisons.
                    ipc.wait_for_frame()
                    point = battery[0], bar["box"]["y"] + bar["box"]["height"] + 40 if top else bar["box"]["y"] - 40
                    hit = ipc.hit_test(*point)
                    assert hit["target_type"] == "battery_popup", hit
                    origin = point[0] - hit["local_x"], point[1] - hit["local_y"]
                    output_height = ipc.get_outputs()[0]["logical_height"] if top else bar["box"]["y"] + bar["box"]["height"]
                    factor = min(1, (bar["box"]["width"] - 24) / 368, (output_height - bar["box"]["height"] - 24) / 536)

                    def row(index):
                        return round(origin[0] + 180 * factor), round(origin[1] + (382 + index * 32) * factor)

                    def capture(name):
                        ipc.wait_for_frame()
                        path = tmp / (name + ".png")
                        ipc.screenshot(str(path))
                        with Image.open(path) as image:
                            return image.convert("RGB").copy()

                    initial = capture("initial")
                    initial.save(f"/tmp/rediwm-battery-{state}-{scale}{'-gold' if gold else ''}{'-top' if top else ''}.png")
                    if gold:
                        raster = float(scale)
                        x, y = round((origin[0] + 24 * factor) * raster), round((origin[1] + 295 * factor) * raster)
                        red, green, blue = initial.getpixel((x, y))
                        assert red > 190 and green > 180 and blue > 155, ("Gold detail card", (red, green, blue))

                    if state == "Charging":
                        # Rate changes with the same percentage must repaint an open
                        # popup on the existing minute tick, without input/events.
                        (supply / "uevent").write_text(readings.replace("POWER_SUPPLY_POWER_NOW=12000000", "POWER_SUPPLY_POWER_NOW=24000000"))
                        time.sleep(60 - time.time() % 60 + 0.2)
                        refreshed = capture("estimate-refreshed")
                        pixelscale = initial.width / bar["box"]["width"]
                        estimate_box = tuple(round(v * pixelscale) for v in (
                            origin[0] + 125 * factor, origin[1] + 38 * factor,
                            origin[0] + 345 * factor, origin[1] + 58 * factor))
                        assert ImageChops.difference(initial.crop(estimate_box), refreshed.crop(estimate_box)).getbbox(), "time estimate did not refresh on the minute tick"

                    # Click selection and external changes both update the check.
                    ipc.click_at(*row(2))
                    assert read_line(fake) == {"set": "performance"}
                    wait_for(lambda: "changed to performance" in log_text(tmp), "selection confirmed")
                    changed = capture("selected")
                    pixelscale = initial.width / bar["box"]["width"]
                    check_box = tuple(round(v * pixelscale) for v in (
                        origin[0] + 27 * factor, origin[1] + 403 * factor,
                        origin[0] + 47 * factor, origin[1] + 425 * factor))
                    assert ImageChops.difference(initial.crop(check_box), changed.crop(check_box)).getbbox(), "checkbox did not move"
                    command(fake, "external", "balanced")
                    wait_for(lambda: "changed to balanced" in log_text(tmp), "external update")
                    assert not ImageChops.difference(initial.crop(check_box), capture("external").crop(check_box)).getbbox(), "external change did not restore checkbox"

                    # Keyboard navigation uses the same confirmed selection path.
                    ipc.key_down_up(103)  # Up from the focused performance row.
                    ipc.key_down_up(103)  # Power Saver.
                    ipc.key_down_up(28)
                    assert read_line(fake) == {"set": "power-saver"}

                    # Disabled choices cannot submit a request after service restart.
                    stop_fake(fake)
                    wait_for(lambda: "service left the bus" in log_text(tmp), "service loss")
                    rows_box = tuple(round(v * pixelscale) for v in (
                        origin[0] + 20 * factor, origin[1] + 366 * factor,
                        origin[0] + 348 * factor, origin[1] + 462 * factor))
                    assert ImageChops.difference(initial.crop(rows_box), capture("lost").crop(rows_box)).getbbox(), "no notice when the service is gone"
                    fake = start_fake(offered="power-saver,balanced")
                    wait_for(lambda: log_text(tmp).count("active profile balanced") == 2, "restarted service")
                    ipc.click_at(*row(2))
                    ipc.click_at(*row(0))
                    assert read_line(fake) == {"set": "power-saver"}, "unsupported profile was requested"

                    for dismiss in (lambda: ipc.key_down_up(1), lambda: ipc.click_at(*battery), lambda: ipc.click_at(20, 20)):
                        dismiss()
                        assert ipc.hit_test(*point)["target_type"] != "battery_popup"
                        ipc.click_at(*battery)
                        assert ipc.hit_test(*point)["target_type"] == "battery_popup"
                    ipc.click_at(*clock)
                    assert ipc.hit_test(*point)["target_type"] != "battery_popup"
                    ipc.click_at(*battery)
                    assert ipc.hit_test(*point)["target_type"] == "battery_popup"
                    # Hiding the taskbar anchor on reload closes its popup.
                    (tmp / "rediwm-config.toml").write_text('[compositor]\nxwayland = false\ntaskbar_items = ["-battery", "volume", "network", "clock"]\n')
                    wait_for(lambda: ipc.hit_test(*point)["target_type"] != "battery_popup", "hidden battery closes popup")
                    print(f"PASS: {state}, details={details}, scale={scale}: popup, checkbox, keyboard, service loss and dismissal")
            finally:
                stop_process(process)
                log.close()
                stop_fake(fake)


if __name__ == "__main__":
    if not os.environ.get("REDIWM_BATTERY_PRIVATE_BUS"):
        os.execvpe("dbus-run-session", ["dbus-run-session", "--", sys.executable, __file__, *sys.argv[1:]], {**os.environ, "REDIWM_BATTERY_PRIVATE_BUS": "1"})
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scale", default="1")
    parser.add_argument("--gold", action="store_true")
    parser.add_argument("--top", action="store_true")
    args = parser.parse_args()
    os.umask(0o077)
    run(args.scale, args.gold, args.top)

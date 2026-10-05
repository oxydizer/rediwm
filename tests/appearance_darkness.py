#!/usr/bin/env python3
"""Appearance > Window chrome darkness: the slider shades the chrome tint
toward black without touching its opacity, updates live, persists to
[theme] window_bg, and is what an opaque titlebar actually shows."""
from pathlib import Path
import re
import tempfile
import time
import tomllib

from ipc_client import IPCClient, spawn_compositor, stop_process
from ui_driver import UIDriver

STOCK = (38, 45, 55)


def luma(rgb):
    return 0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2]


def parse_rgba(raw: str):
    m = re.match(r"rgba\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*([0-9.]+)\s*\)", raw)
    assert m, f"invalid rgba string: {raw}"
    return (int(m.group(1)), int(m.group(2)), int(m.group(3))), float(m.group(4))


def darkness_of(rgb):
    return 1 - luma(rgb) / luma(STOCK)


def run():
    with tempfile.TemporaryDirectory(prefix="rediwm-darkness-") as directory:
        tmp = Path(directory)
        config = ('[input]\npointer_speed = 0.4\n[theme]\nfont = "Manrope"\nmono_font = "JetBrains Mono"\n'
                  'window_bg = "rgba(38,45,55,0.910)"\n')
        theme_path = tmp / "rediwm-config.toml"
        process, log = spawn_compositor(tmp, config_content=config, env_extra={"DBUS_SESSION_BUS_ADDRESS": ""})
        try:
            with IPCClient(tmp, timeout=15) as ipc:
                ipc.action('open_control_center')
                time.sleep(0.3)

                def widgets():
                    return ipc.get_widget_tree("control_center")["widgets"]

                def click(widget):
                    panel = ipc.get_shell_state()["control_center"]["box"]
                    box = widget["box"]
                    ipc.click_at(round(panel["x"] + box["x"] + box["width"] / 2),
                                 round(panel["y"] + box["y"] + box["height"] / 2))
                    time.sleep(0.2)

                def slider(name):
                    return UIDriver(ipc).scroll_into_view(name)

                def click_at_fraction(name, fraction):
                    target = slider(name)
                    panel = ipc.get_shell_state()["control_center"]["box"]
                    box = target["box"]
                    # The far end of the track is a hair inside its box.
                    x = box["width"] - 2 if fraction >= 1 else box["width"] * fraction
                    ipc.click_at(round(panel["x"] + box["x"] + x),
                                 round(panel["y"] + box["y"] + box["height"] / 2))
                    time.sleep(0.3)

                def saved():
                    return parse_rgba(tomllib.loads(theme_path.read_text())["theme"]["window_bg"])

                def has_label(text):
                    return any(w.get("label") == text for w in widgets())

                click(next(w for w in widgets() if w["label"] == "Appearance"))

                # Both sliders live in the chrome card; darkness starts at 0% on the stock tint.
                assert slider("chrome_opacity") is not None, "opacity slider missing"
                assert slider("chrome_darkness") is not None, "darkness slider missing"
                assert has_label("Window chrome darkness"), "darkness label missing"
                assert has_label("0%"), "initial 0% darkness not shown"
                assert has_label("91%"), "initial 91% opacity not shown"

                # 50%: darker, same hue, opacity untouched.
                click_at_fraction("chrome_darkness", 0.5)
                rgb, alpha = saved()
                assert 0.40 <= darkness_of(rgb) <= 0.60, f"expected about 50% darkness, got {darkness_of(rgb):.2f} for {rgb}"
                assert abs(alpha - 0.91) < 0.01, f"darkness changed the opacity: {alpha}"
                assert rgb[0] < STOCK[0] and rgb[2] < STOCK[2]
                assert rgb[2] > rgb[1] > rgb[0], f"hue lost: {rgb}"
                assert has_label(f"{round(darkness_of(rgb) * 100)}%"), "darkness readout not updated"
                assert has_label("91%"), "opacity readout changed"

                # All the way: black, still translucent as configured.
                click_at_fraction("chrome_darkness", 1.0)
                rgb, alpha = saved()
                assert sum(rgb) <= 3, f"expected near-black at 100%, got {rgb}"
                assert abs(alpha - 0.91) < 0.01

                # Opacity moves alone; the tint stays put.
                click_at_fraction("chrome_opacity", 1.0)
                rgb, alpha = saved()
                assert abs(alpha - 1.0) < 0.02, f"expected opaque, got {alpha}"
                assert sum(rgb) <= 3, f"opacity moved the tint: {rgb}"

                # Coming back up from black recovers the hue: opaque and dark, not grey.
                click_at_fraction("chrome_darkness", 0.25)
                rgb, alpha = saved()
                assert 0.15 <= darkness_of(rgb) <= 0.35, f"expected about 25% darkness, got {darkness_of(rgb):.2f} for {rgb}"
                assert rgb[2] > rgb[1] > rgb[0], f"hue lost coming back from black: {rgb}"
                assert abs(alpha - 1.0) < 0.02, f"darkness changed the opacity: {alpha}"
                shown = f"{round(darkness_of(rgb) * 100)}%"

                # The opaque titlebar really is that colour (no backdrop mixes in).
                windows = [w for w in ipc.get_windows() if w.get("app_id") == "rediwm-settings"]
                assert windows, f"settings window not found in {ipc.get_windows()}"
                frame = windows[0]
                # The titlebar's top padding band: no title text or controls, clear of the corners.
                y = frame["y"] + 4
                x = round(frame["x"] + frame["width"] * 0.6)
                sample = ipc.sample_pixels(x, y, 1, 1)
                argb = sample["pixels"][0]  # packed 0xAARRGGBB
                got = ((argb >> 16) & 255, (argb >> 8) & 255, argb & 255)
                assert all(abs(g - e) <= 3 for g, e in zip(got, rgb)), f"titlebar shows {got}, saved tint is {rgb} (frame {frame})"

                # Persists across reopening.
                ipc.close_panel("control_center")
                ipc.wait_for("control_center_closed", timeout_ms=5000)
                ipc.action('open_control_center')
                time.sleep(0.3)
                click(next(w for w in widgets() if w["label"] == "Appearance"))
                _ = slider("chrome_darkness")
                assert has_label(shown), f"persisted {shown} darkness not shown on reopen"

            stop_process(process)
            assert process.returncode == 0, (tmp / "compositor.log").read_text()
        finally:
            stop_process(process)


if __name__ == "__main__":
    run()
    print("PASS: window chrome darkness slider shades the tint, keeps opacity, persists and renders")

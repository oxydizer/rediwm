#!/usr/bin/env python3
"""Appearance > Window chrome opacity: slider controls titlebar opacity,
updates live, and persists to [theme] window_bg."""
from pathlib import Path
import tempfile
import time
import tomllib
import re

from ipc_client import IPCClient, spawn_compositor, stop_process
from ui_driver import UIDriver


def parse_alpha(rgba_str: str) -> float:
    # Matches rgba(r,g,b,alpha)
    m = re.match(r"rgba\(\s*\d+\s*,\s*\d+\s*,\s*\d+\s*,\s*([0-9.]+)\s*\)", rgba_str)
    assert m, f"invalid rgba string: {rgba_str}"
    return float(m.group(1))


def run(external_theme: bool):
    with tempfile.TemporaryDirectory(prefix="rediwm-opacity-") as directory:
        tmp = Path(directory)
        config = '[input]\npointer_speed = 0.4\n[theme]\nfont = "Manrope"\nmono_font = "JetBrains Mono"\nwindow_bg = "rgba(16,18,21,0.980)"\n'
        env = {"DBUS_SESSION_BUS_ADDRESS": ""}
        if external_theme:
            theme_path = tmp / "theme.toml"
            theme_path.write_text('[theme]\nfont = "Manrope"\nmono_font = "JetBrains Mono"\nwindow_bg = "rgba(16,18,21,0.980)"\n')
            env["REDIWM_THEME"] = str(theme_path)
        else:
            theme_path = tmp / "rediwm-config.toml"

        process, log = spawn_compositor(tmp, config_content=config, env_extra=env)
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

                def appearance():
                    click(next(w for w in widgets() if w["label"] == "Appearance"))

                def opacity_slider():
                    return UIDriver(ipc).scroll_into_view("chrome_opacity")

                def saved_window_bg():
                    raw = tomllib.loads(theme_path.read_text())["theme"]["window_bg"]
                    return parse_alpha(raw)

                appearance()

                # Verify label and initial 98%
                slider = opacity_slider()
                assert slider is not None, "chrome_opacity slider not found"
                assert any(w.get("label") == "Window chrome opacity" for w in widgets()), "Label not found"
                assert any(w.get("label") == "98%" for w in widgets()), "Initial 98% not found"
                assert abs(saved_window_bg() - 0.98) < 0.02

                # Click at ~50% of the slider track width
                panel = ipc.get_shell_state()["control_center"]["box"]
                sbox = slider["box"]
                target_x = round(panel["x"] + sbox["x"] + sbox["width"] * 0.5)
                target_y = round(panel["y"] + sbox["y"] + sbox["height"] / 2)
                ipc.click_at(target_x, target_y)
                time.sleep(0.3)

                alpha_50 = saved_window_bg()
                assert 0.40 <= alpha_50 <= 0.60, f"Expected around 0.50, got {alpha_50}"
                assert any(w.get("label") == f"{round(alpha_50 * 100)}%" for w in widgets()), "50% label not found"

                # Click at ~75% of the slider track width
                target_x_75 = round(panel["x"] + sbox["x"] + sbox["width"] * 0.75)
                ipc.click_at(target_x_75, target_y)
                time.sleep(0.3)

                alpha_75 = saved_window_bg()
                assert 0.70 <= alpha_75 <= 0.80, f"Expected around 0.75, got {alpha_75}"
                assert any(w.get("label") == f"{round(alpha_75 * 100)}%" for w in widgets()), "75% label not found"

                # Drag all the way to 100%
                target_x_100 = round(panel["x"] + sbox["x"] + sbox["width"] - 2)
                ipc.click_at(target_x_100, target_y)
                time.sleep(0.3)

                alpha_100 = saved_window_bg()
                assert abs(alpha_100 - 1.0) < 0.02, f"Expected 1.0, got {alpha_100}"
                assert any(w.get("label") == "100%" for w in widgets()), "100% label not found"

                # Close and reopen Control Center, ensure setting persists
                ipc.close_panel("control_center")
                ipc.wait_for("control_center_closed", timeout_ms=5000)
                ipc.action('open_control_center')
                time.sleep(0.3)
                appearance()
                _ = opacity_slider()
                assert any(w.get("label") == "100%" for w in widgets()), "Persisted 100% label not found on reopen"

            stop_process(process)
            assert process.returncode == 0, (tmp / "compositor.log").read_text()
        finally:
            stop_process(process)


if __name__ == "__main__":
    print("Testing internal config.toml theme...")
    run(external_theme=False)
    print("Testing external REDIWM_THEME...")
    run(external_theme=True)
    print("PASS: window chrome opacity slider controls, live updates and persistence")

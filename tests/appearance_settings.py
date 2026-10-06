#!/usr/bin/env python3
"""Appearance settings: window chrome opacity, inactive window opacity, file-drag dodge and animations controls.

Verifies UI controls, live compositor updates, and persistence to config.toml.
"""
from pathlib import Path
import tempfile
import time
import tomllib
import re

from ipc_client import IPCClient, spawn_compositor, stop_process
from ui_driver import UIDriver
from desktop_zoom import wait_for
from PIL import Image


def parse_alpha(rgba_str: str) -> float:
    m = re.match(r"rgba\(\s*\d+\s*,\s*\d+\s*,\s*\d+\s*,\s*([0-9.]+)\s*\)", rgba_str)
    assert m, f"invalid rgba string: {rgba_str}"
    return float(m.group(1))


def test_appearance_settings():
    with tempfile.TemporaryDirectory(prefix="rediwm-appearance-") as directory:
        tmp = Path(directory)
        config_path = tmp / "rediwm-config.toml"
        initial_config = (
            "[input]\npointer_speed = 0.4\n"
            "[compositor]\ninactive_opacity = 0.8\n"
            "[animations]\nenabled = true\nspeed = 1.0\nreduced_motion = \"auto\"\n"
            "[theme]\nfont = \"Manrope\"\nmono_font = \"JetBrains Mono\"\nwindow_bg = \"rgba(16,18,21,0.980)\"\n"
        )
        env = {"DBUS_SESSION_BUS_ADDRESS": "", "DBUS_SYSTEM_BUS_ADDRESS": "unix:path=/nonexistent",
               "REDIWM_FILES_DEVICES": "0", "XDG_DATA_HOME": str(tmp / "data"),
               "XDG_CACHE_HOME": str(tmp / "cache")}

        process, log = spawn_compositor(tmp, config_content=initial_config, env_extra=env)
        try:
            with IPCClient(tmp, timeout=15) as ipc:
                ipc.action('open_control_center')
                time.sleep(0.3)

                ui = UIDriver(ipc)

                def widgets():
                    return ipc.get_widget_tree("control_center")["widgets"]

                def click_widget(widget, fraction=0.5):
                    panel = ipc.get_shell_state()["control_center"]["box"]
                    box = widget["box"]
                    if fraction >= 1.0:
                        target_x = panel["x"] + box["x"] + box["width"] - 1
                    else:
                        target_x = panel["x"] + box["x"] + box["width"] * fraction
                    ipc.click_at(
                        round(target_x),
                        round(panel["y"] + box["y"] + box["height"] * 0.5)
                    )
                    time.sleep(0.2)

                def appearance_page():
                    click_widget(next(w for w in widgets() if w.get("label") == "Appearance"))

                def read_config():
                    return tomllib.loads(config_path.read_text())

                # A field formerly omitted by themeEql must repaint the UI
                # even when no window_bg/font/accent value changed.
                config_path.write_text(config_path.read_text() + 'shell_on_accent = "#12ab34"\ncontrol_thumb = "#12ab34"\nsettings_radius = 6\napp_text_size = 15\napp_bg = "#123456"\n')
                ipc.reload_config()
                ipc.wait_for_frame()
                tokens = ipc.action("get_theme")["tokens"]
                assert abs(tokens["control_thumb"][1] - 171 / 255) < 0.001
                assert tokens["settings_radius"] == 6
                assert tokens["app_text_size"] == 15
                ipc.move_cursor(2, 2)
                ipc.wait_for_panel_settled("control_center")
                capture = tmp / "themed-settings.png"
                ipc.screenshot(str(capture))
                with Image.open(capture) as image:
                    assert sum(n for n, color in image.convert("RGB").getcolors(image.width * image.height) if color == (18, 52, 86)) > 20, "app_bg reload did not repaint Settings"
                appearance_page()

                # Pick a real image through Files, persist a long path, and
                # check the taskbar's pixels before and after restoring R.
                logo_dir = tmp / ("custom logo " + "a" * 140)
                logo_dir.mkdir()
                logo = logo_dir / "logo.png"
                Image.new("RGBA", (32, 32), (18, 231, 73, 255)).save(logo)

                def chooser():
                    return next((w for w in ipc.get_windows() if w["app_id"] == "rediwm-file-chooser"), None)

                logo_shots = iter(range(10000))

                def logo_visible():
                    shot = tmp / f"logo-shot-{next(logo_shots)}.png"
                    ipc.screenshot(str(shot))
                    with Image.open(shot) as image:
                        colors = image.convert("RGB").crop((0, image.height - 80, 100, image.height)).getdata()
                        return sum(1 for c in colors if c == (18, 231, 73)) > 100

                assert ui.scroll_into_view("start_logo_reset")["is_disabled"]
                click_widget(ui.scroll_into_view("start_logo_choose"))
                window = wait_for(chooser, "logo file chooser")
                assert next(w for w in widgets() if w["name"] == "start_logo_choose")["is_disabled"]
                ipc.focus_window(window["id"])
                time.sleep(.3)
                ipc.key(29, True)
                ipc.key_down_up(38)  # Ctrl+L
                ipc.key(29, False)
                ipc.type_text(str(logo_dir))
                ipc.key_press("Return")
                time.sleep(.5)
                ipc.key_press("Home")
                ipc.key_press("Return")
                wait_for(lambda: chooser() is None, "logo chooser accepted")
                wait_for(lambda: read_config()["theme"].get("start_button_icon") == str(logo), "saved logo path")
                wait_for(logo_visible, "custom taskbar logo")
                ipc.reload_config()
                ipc.wait_for_panel_settled("control_center")
                assert not ui.scroll_into_view("start_logo_reset")["is_disabled"]

                click_widget(ui.scroll_into_view("start_logo_choose"))
                window = wait_for(chooser, "logo chooser reopened")
                ipc.focus_window(window["id"])
                time.sleep(.3)
                ipc.key_press("Escape")
                wait_for(lambda: chooser() is None, "logo chooser cancelled")
                assert read_config()["theme"]["start_button_icon"] == str(logo)
                assert logo_visible()

                click_widget(ui.scroll_into_view("start_logo_reset"))
                wait_for(lambda: not read_config()["theme"].get("start_button_icon"), "default logo saved")
                wait_for(lambda: not logo_visible(), "default logo restored")
                assert ui.scroll_into_view("start_logo_reset")["is_disabled"]
                ipc.reload_config()
                ipc.wait_for_panel_settled("control_center")
                assert not logo_visible()

                focus_zoom = ui.scroll_into_view("focus_zoom")
                assert focus_zoom.get("selected_index") == 1, "boost should be the default"
                for index, mode in ((0, "keep"), (2, "camera"), (1, "boost")):
                    click_widget(ui.scroll_into_view("focus_zoom"), fraction=(index + 0.5) / 3)
                    assert read_config()["compositor"]["focus_zoom"] == mode
                    assert ui.scroll_into_view("focus_zoom").get("selected_index") == index

                # --- 1. Window chrome opacity slider ---
                chrome_slider = ui.scroll_into_view("chrome_opacity")
                assert chrome_slider is not None
                assert any(w.get("label") == "Window chrome opacity" for w in widgets())
                assert any(w.get("label") == "98%" for w in widgets())
                assert abs(parse_alpha(read_config()["theme"]["window_bg"]) - 0.98) < 0.02

                # Click ~50%
                click_widget(chrome_slider, fraction=0.5)
                time.sleep(0.2)
                alpha_50 = parse_alpha(read_config()["theme"]["window_bg"])
                assert 0.40 <= alpha_50 <= 0.60
                saved_theme = read_config()["theme"]
                assert saved_theme["control_thumb"].startswith("rgba(18,171,52,")
                assert saved_theme["shell_on_accent"].startswith("rgba(18,171,52,")
                assert saved_theme["settings_radius"] == 6
                assert saved_theme["app_text_size"] == 15
                assert any(w.get("label") == f"{round(alpha_50 * 100)}%" for w in widgets())

                # --- 2. Inactive window opacity slider ---
                inactive_slider = ui.scroll_into_view("inactive_opacity")
                assert inactive_slider is not None
                assert any(w.get("label") == "Inactive window opacity" for w in widgets())
                assert any(w.get("label") == "80%" for w in widgets()), "Initial 80% not found"
                assert abs(read_config()["compositor"]["inactive_opacity"] - 0.8) < 0.02

                # Click at ~60% of the slider track width
                click_widget(inactive_slider, fraction=0.6)
                time.sleep(0.2)
                inact_val = read_config()["compositor"]["inactive_opacity"]
                assert 0.50 <= inact_val <= 0.70
                assert any(w.get("label") == f"{round(inact_val * 100)}%" for w in widgets())

                # Drag / click at 100%
                click_widget(inactive_slider, fraction=1.0)
                time.sleep(0.2)
                assert abs(read_config()["compositor"]["inactive_opacity"] - 1.0) < 0.02
                assert any(w.get("label") == "100%" for w in widgets())

                # --- 3. Animations toggle ---
                anim_toggle = ui.scroll_into_view("animations")
                assert anim_toggle is not None
                assert anim_toggle.get("on") is True
                assert read_config()["animations"]["enabled"] is True

                # Toggle animations off
                click_widget(anim_toggle)
                time.sleep(0.2)
                assert read_config()["animations"]["enabled"] is False
                anim_toggle = ui.scroll_into_view("animations")
                assert anim_toggle.get("on") is False

                # Toggle animations back on
                click_widget(anim_toggle)
                time.sleep(0.2)
                assert read_config()["animations"]["enabled"] is True
                anim_toggle = ui.scroll_into_view("animations")
                assert anim_toggle.get("on") is True

                # --- 3b. Move file manager aside while dragging (default on) ---
                dodge_toggle = ui.scroll_into_view("dodge_file_drags")
                assert dodge_toggle is not None
                assert dodge_toggle.get("on") is True, "the setting should default to on"
                assert "dodge_file_drags" not in read_config()["compositor"], "an untouched default is not written"
                click_widget(dodge_toggle)
                assert read_config()["compositor"]["dodge_file_drags"] is False
                dodge_toggle = ui.scroll_into_view("dodge_file_drags")
                assert dodge_toggle.get("on") is False
                click_widget(dodge_toggle)
                assert read_config()["compositor"]["dodge_file_drags"] is True
                assert ui.scroll_into_view("dodge_file_drags").get("on") is True

                # --- 4. Animation speed segmented control ---
                # Options: 0.5× (idx 0), 1.0× (idx 1), 1.5× (idx 2), 2.0× (idx 3)
                speed_seg = ui.scroll_into_view("anim_speed")
                assert speed_seg is not None
                assert speed_seg.get("selected_index") == 1  # 1.0× default

                # Click 1.5× (idx 2, fraction = 2.5 / 4 = 0.625)
                click_widget(speed_seg, fraction=0.625)
                time.sleep(0.2)
                assert abs(read_config()["animations"]["speed"] - 1.5) < 0.01
                speed_seg = ui.scroll_into_view("anim_speed")
                assert speed_seg.get("selected_index") == 2

                # Click 0.5× (idx 0, fraction = 0.5 / 4 = 0.125)
                click_widget(speed_seg, fraction=0.125)
                time.sleep(0.2)
                assert abs(read_config()["animations"]["speed"] - 0.5) < 0.01
                speed_seg = ui.scroll_into_view("anim_speed")
                assert speed_seg.get("selected_index") == 0

                # --- 5. Reduced motion segmented control ---
                # Options: Auto (idx 0), On (idx 1), Off (idx 2)
                motion_seg = ui.scroll_into_view("reduced_motion")
                assert motion_seg is not None
                assert motion_seg.get("selected_index") == 0  # Auto default

                # Click On (idx 1, fraction = 1.5 / 3 = 0.5)
                click_widget(motion_seg, fraction=0.5)
                time.sleep(0.2)
                assert read_config()["animations"]["reduced_motion"] == "on"
                motion_seg = ui.scroll_into_view("reduced_motion")
                assert motion_seg.get("selected_index") == 1

                # Click Off (idx 2, fraction = 2.5 / 3 = 0.833)
                click_widget(motion_seg, fraction=0.833)
                time.sleep(0.2)
                assert read_config()["animations"]["reduced_motion"] == "off"
                motion_seg = ui.scroll_into_view("reduced_motion")
                assert motion_seg.get("selected_index") == 2

                # --- 6. Persistence across Control Center close & reopen ---
                ipc.close_panel("control_center")
                ipc.wait_for("control_center_closed", timeout_ms=5000)
                ipc.action('open_control_center')
                time.sleep(0.3)
                appearance_page()

                # Verify speed is still 0.5x
                assert ui.scroll_into_view("focus_zoom").get("selected_index") == 1
                speed_seg = ui.scroll_into_view("anim_speed")
                assert speed_seg.get("selected_index") == 0

                # Verify reduced motion is still Off
                motion_seg = ui.scroll_into_view("reduced_motion")
                assert motion_seg.get("selected_index") == 2

                # Verify inactive opacity is still 100%
                _ = ui.scroll_into_view("inactive_opacity")
                assert any(w.get("label") == "100%" for w in widgets())

                # Bundled themes replace the palette live and persist their
                # optional overrides; returning to Dark clears those overrides.
                click_widget(ui.scroll_into_view("theme"))
                ipc.key_press("Home")
                ipc.key_press("Down")
                ipc.key_press("Return")
                ipc.wait_for_panel_settled("control_center")
                assert ui.scroll_into_view("theme")["selected_index"] == 1
                tokens = ipc.action("get_theme")["tokens"]
                for name, expected in {
                    "window_bg": [246 / 255, 247 / 255, 249 / 255, 0.75],
                    "window_fg": [31 / 255, 36 / 255, 48 / 255, 1],
                    "app_bg": [244 / 255, 246 / 255, 248 / 255, 1],
                    "shell_accent": [14 / 255, 165 / 255, 160 / 255, 1],
                    "scrollbar_thumb_active": [152 / 255, 164 / 255, 178 / 255, 1],
                    "shadow": [0, 0, 0, 0.12],
                    "window_close_hover": [14 / 255, 165 / 255, 160 / 255, 1],
                    "danger": [22 / 255, 133 / 255, 121 / 255, 1],
                    "accent_3": [107 / 255, 191 / 255, 138 / 255, 1],
                    "file_broken": [22 / 255, 133 / 255, 121 / 255, 1],
                    "battery_critical": [22 / 255, 133 / 255, 121 / 255, 1],
                    "desktop_notice_bg": [8 / 255, 42 / 255, 36 / 255, 0.95],
                    "app_item_selected": [217 / 255, 240 / 255, 237 / 255, 1],
                    "app_nav_selected": [199 / 255, 233 / 255, 228 / 255, 1],
                    "start_menu_selected_border": [14 / 255, 165 / 255, 160 / 255, 0.28],
                    "start_button_logo_color": [31 / 255, 36 / 255, 48 / 255, 1],
                }.items():
                    assert all(abs(a - b) < 0.001 for a, b in zip(tokens[name], expected)), (name, tokens[name])
                for name, alpha in {
                    "start_menu_selected_marker": 1, "switcher_border": 0.65,
                    "switcher_selected_border": 1, "screenshot_border": 1,
                    "desktop_selected": 0.12, "desktop_selection": 0.15,
                    "desktop_selection_border": 1, "desktop_drop_border": 0.8,
                }.items():
                    assert all(abs(a - b) < 0.001 for a, b in zip(
                        tokens[name], [14 / 255, 165 / 255, 160 / 255, alpha])), (name, tokens[name])
                assert abs(tokens["selection_alpha"] - 0.22) < 0.001
                assert abs(ui.scroll_into_view("chrome_opacity")["value"] - 0.75) < 0.01
                ipc.move_cursor(2, 2)
                ipc.wait_for_frame()
                taskbar = ipc.get_shell_state()["taskbars"][0]["box"]
                capture = tmp / "light-taskbar.png"
                ipc.screenshot(str(capture))
                with Image.open(capture) as image:
                    pixel = image.convert("RGB").getpixel((taskbar["x"] + taskbar["width"] // 2,
                                                          taskbar["y"] + taskbar["height"] // 2))
                    assert min(pixel) > 200, ("taskbar did not adopt Light", pixel)
                    logo = image.convert("RGB").crop((taskbar["x"] + 8, taskbar["y"] + 8,
                                                      taskbar["x"] + 40, taskbar["y"] + 38))
                    assert sum(max(logo.getpixel((x, y))) < 100 for y in range(logo.height) for x in range(logo.width)) > 100, "Light R logo is not dark"
                light_theme = read_config()["theme"]
                assert light_theme["shell_accent"].startswith("rgba(14,165,160,")
                for name in ("caret", "selection", "selection_fg", "field_border_focus"):
                    assert name not in light_theme

                # A taskbar theme recolours only the bar: Dark on a Light desktop.
                def taskbar_pixel(name):
                    ipc.move_cursor(2, 2)
                    ipc.wait_for_frame()
                    box = ipc.get_shell_state()["taskbars"][0]["box"]
                    shot = tmp / name
                    ipc.screenshot(str(shot))
                    with Image.open(shot) as image:
                        return image.convert("RGB").getpixel((box["x"] + box["width"] // 2,
                                                              box["y"] + box["height"] // 2))

                assert ui.scroll_into_view("taskbar_theme")["selected_index"] == 0
                click_widget(ui.scroll_into_view("taskbar_theme"))
                ipc.key_press("Home")
                ipc.key_press("Down")
                ipc.key_press("Return")
                ipc.wait_for_panel_settled("control_center")
                assert ui.scroll_into_view("taskbar_theme")["selected_index"] == 1
                assert max(taskbar_pixel("dark-taskbar.png")) < 90, "taskbar did not take the Dark taskbar theme"
                tokens = ipc.action("get_theme")["tokens"]
                assert all(abs(a - b) < 0.001 for a, b in zip(tokens["taskbar_bg"], [241 / 255, 244 / 255, 247 / 255, 0.94]))
                assert all(abs(a - b) < 0.001 for a, b in zip(tokens["window_fg"], [31 / 255, 36 / 255, 48 / 255, 1]))
                assert ui.scroll_into_view("theme")["selected_index"] == 1
                assert read_config()["taskbar_theme"] == {}
                assert read_config()["theme"]["shell_accent"].startswith("rgba(14,165,160,")
                ipc.reload_config()
                ipc.close_panel("control_center")
                ipc.wait_for("control_center_closed", timeout_ms=5000)
                ipc.action("open_appearance")
                ipc.wait_for_panel_settled("control_center")
                assert ui.scroll_into_view("taskbar_theme")["selected_index"] == 1
                assert max(taskbar_pixel("dark-taskbar-reloaded.png")) < 90
                click_widget(ui.scroll_into_view("taskbar_theme"))
                ipc.key_press("Home")
                ipc.key_press("Return")
                ipc.wait_for_panel_settled("control_center")
                assert ui.scroll_into_view("taskbar_theme")["selected_index"] == 0
                assert "taskbar_theme" not in read_config()
                assert min(taskbar_pixel("light-taskbar-again.png")) > 200, "taskbar did not return to the main theme"

                ipc.reload_config()
                ipc.close_panel("control_center")
                ipc.wait_for("control_center_closed", timeout_ms=5000)
                ipc.action("open_appearance")
                ipc.wait_for_panel_settled("control_center")
                assert ui.scroll_into_view("theme")["selected_index"] == 1
                # Redi Blue applies every supplied token and survives reload.
                click_widget(ui.scroll_into_view("theme"))
                ipc.key_press("End")
                ipc.key_press("Return")
                ipc.wait_for_panel_settled("control_center")
                assert ui.scroll_into_view("theme")["selected_index"] == 2
                blue_theme = tomllib.loads((Path(__file__).resolve().parents[1] /
                                           "src/assets/themes/redi-blue.toml").read_text())["theme"]

                def check_blue():
                    tokens = ipc.action("get_theme")["tokens"]
                    for name, value in blue_theme.items():
                        if isinstance(value, str):
                            if value.startswith("#"):
                                expected = [int(value[i:i + 2], 16) / 255 for i in (1, 3, 5)] + [1]
                            else:
                                parts = [float(v) for v in value[5:-1].split(",")]
                                expected = [v / 255 for v in parts[:3]] + parts[3:]
                            assert all(abs(a - b) < 0.001 for a, b in zip(tokens[name], expected)), (name, tokens[name])
                        else:
                            assert abs(tokens[name] - value) < 0.001, (name, tokens[name])
                    for name in ("caret", "selection", "selection_fg", "field_border_focus", "start_button_logo_color"):
                        assert name not in read_config()["theme"]

                check_blue()
                ipc.reload_config()
                ipc.close_panel("control_center")
                ipc.wait_for("control_center_closed", timeout_ms=5000)
                ipc.action("open_appearance")
                ipc.wait_for_panel_settled("control_center")
                assert ui.scroll_into_view("theme")["selected_index"] == 2
                check_blue()
                click_widget(ui.scroll_into_view("theme"))
                ipc.key_press("Home")
                ipc.key_press("Return")
                ipc.wait_for_panel_settled("control_center")
                assert ui.scroll_into_view("theme")["selected_index"] == 0
                assert "shell_accent" not in read_config()["theme"]
                assert "scrollbar_thumb_active" not in read_config()["theme"]
                assert "start_button_logo_color" not in read_config()["theme"]
                tokens = ipc.action("get_theme")["tokens"]
                assert all(abs(a - b) < 0.001 for a, b in zip(
                    tokens["window_bg"], [7.6 / 255, 9 / 255, 11 / 255, 0.80]))
                assert abs(ui.scroll_into_view("chrome_opacity")["value"] - 0.80) < 0.01
                assert abs(ui.scroll_into_view("chrome_darkness")["value"] - 0.80) < 0.01


                # Radius presets update numeric tokens across controls and frames.
                defaults = ipc.action("get_theme")["tokens"]
                radius_keys = [name for name in defaults if name.startswith("radius") or name.endswith("_radius")]
                for index in (0, 2, 1, 2, 1):
                    click_widget(ui.scroll_into_view("radius"), fraction=(index + 0.5) / 3)
                    ipc.reload_config()
                    ipc.wait_for_panel_settled("control_center")
                    tokens = ipc.action("get_theme")["tokens"]
                    for name in radius_keys:
                        expected = min(defaults[name], 4) if index == 0 else defaults[name] * (1.3 if index == 2 else 1)
                        assert abs(tokens[name] - expected) < 0.001, (index, name, tokens[name], expected)
                    assert ui.scroll_into_view("radius")["selected_index"] == index
                    assert abs(read_config()["theme"]["radius_lg"] - tokens["radius_lg"]) < 0.001
                # A legacy compositor value cannot override an explicit theme radius.
                config_path.write_text(config_path.read_text().replace("radius_lg = 10", "radius_lg = 2.5") +
                                       "\n[compositor]\nborder_radius = 24\n")
                ipc.reload_config()
                ipc.wait_for_panel_settled("control_center")
                assert ipc.action("get_theme")["tokens"]["radius_lg"] == 2.5
                click_widget(ui.scroll_into_view("radius"), fraction=0.5)
                ipc.reload_config()
                ipc.wait_for_panel_settled("control_center")
                assert ipc.action("get_theme")["tokens"]["radius_lg"] == 10

            stop_process(process)
            assert process.returncode == 0, (tmp / "compositor.log").read_text()
        finally:
            stop_process(process)


if __name__ == "__main__":
    test_appearance_settings()
    print("PASS: appearance settings (chrome opacity, inactive opacity, animations controls, bundled themes)")

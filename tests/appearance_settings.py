#!/usr/bin/env python3
"""Appearance settings: window chrome opacity, inactive window opacity, file-drag dodge, flame effect toggles, animations controls, Start button logo preview and Start menu size.

Verifies UI controls, live compositor updates, and persistence to config.toml.
"""
from pathlib import Path
import tempfile
import time
import tomllib
import re
import os
import json
import subprocess
import sys

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

                def logo_preview():
                    """(green pixels, pixels differing from the tile colour) inside Settings' logo preview."""
                    ipc.wait_for_frame()
                    box = ui.scroll_into_view("start_logo_tile")["global_box"]
                    shot = tmp / f"preview-shot-{next(logo_shots)}.png"
                    ipc.screenshot(str(shot))
                    with Image.open(shot) as image:
                        crop = image.convert("RGB").crop((box["x"] + 6, box["y"] + 6, box["x"] + box["width"] - 6, box["y"] + box["height"] - 6))
                    pixels = list(crop.getdata())
                    return sum(1 for c in pixels if c == (18, 231, 73)), sum(1 for c in pixels if c != pixels[0])

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
                wait_for(lambda: logo_preview()[0] > 100, "Settings previews the chosen logo")
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
                wait_for(lambda: logo_preview()[0] == 0 and logo_preview()[1] > 50, "Settings previews the default logo")

                def menu_slider(name, fraction):
                    box = ui.scroll_into_view(name)["global_box"]
                    ipc.click_at(round(box["x"] + min(box["width"] - 1, box["width"] * fraction)), round(box["y"] + box["height"] / 2))
                    ipc.wait_for_panel_settled("control_center")

                # Untouched, the menu is sized to the output (start_menu/size.zig):
                # 560x600 from about 1706x1066 logical pixels up, the same share
                # of the screen below that, never under 400x360.
                output = ipc.get_outputs()[0]
                auto_w = round(min(560, max(400, 560 * output["logical_width"] / 1706)))
                auto_h = round(min(600, max(360, 600 * output["logical_height"] / 1066)))
                assert ui.scroll_into_view("start_menu_width")["value"] == auto_w
                assert ui.scroll_into_view("start_menu_height")["value"] == auto_h
                assert ui.scroll_into_view("start_menu_size_auto")["is_disabled"]
                assert "start_menu_width" not in read_config()["theme"]

                def start_menu_box():
                    ipc.action("open_start_menu")
                    ipc.wait_for("menu_opened", timeout_ms=5000)
                    box = ipc.get_shell_state()["start_menu"]["box"]
                    ipc.close_panel("start_menu")
                    ipc.wait_for("menu_closed", timeout_ms=5000)
                    return box["width"], box["height"]

                assert start_menu_box() == (auto_w, auto_h)
                for fraction, width, height in ((0, 400, 360), (1, 900, 900)):
                    menu_slider("start_menu_width", fraction)
                    menu_slider("start_menu_height", fraction)
                    saved = read_config()["theme"]
                    assert saved["start_menu_width"] == width and saved["start_menu_max_height"] == height, saved
                    assert ui.scroll_into_view("start_menu_width")["value"] == width
                    assert ui.scroll_into_view("start_menu_height")["value"] == height
                    if fraction == 0:
                        # Exactly the chosen size: it is below any output's cap.
                        ipc.action("open_start_menu")
                        ipc.wait_for("menu_opened", timeout_ms=5000)
                        box = ipc.get_shell_state()["start_menu"]["box"]
                        assert (box["width"], box["height"]) == (width, height), box
                        ipc.close_panel("start_menu")
                        ipc.wait_for("menu_closed", timeout_ms=5000)

                # Size to screen hands both back to the output.
                assert not ui.scroll_into_view("start_menu_size_auto")["is_disabled"]
                click_widget(ui.scroll_into_view("start_menu_size_auto"))
                ipc.wait_for_panel_settled("control_center")
                theme_saved = read_config()["theme"]
                assert "start_menu_width" not in theme_saved and "start_menu_max_height" not in theme_saved, theme_saved
                assert ui.scroll_into_view("start_menu_width")["value"] == auto_w
                assert ui.scroll_into_view("start_menu_height")["value"] == auto_h
                assert ui.scroll_into_view("start_menu_size_auto")["is_disabled"]
                assert start_menu_box() == (auto_w, auto_h)

                focus_zoom = ui.scroll_into_view("focus_zoom")
                assert focus_zoom.get("selected_index") == 1, "boost should be the default"
                for index, mode in ((0, "keep"), (2, "camera"), (1, "boost")):
                    click_widget(ui.scroll_into_view("focus_zoom"), fraction=(index + 0.5) / 3)
                    assert read_config()["compositor"]["focus_zoom"] == mode
                    assert ui.scroll_into_view("focus_zoom").get("selected_index") == index

                assert ui.scroll_into_view("switcher_style").get("selected_index") == 0
                for index, style in ((1, "circular"), (0, "linear"), (1, "circular")):
                    click_widget(ui.scroll_into_view("switcher_style"), fraction=(index + 0.5) / 2)
                    assert read_config()["compositor"]["switcher_style"] == style
                    ipc.reload_config()
                    ipc.wait_for_panel_settled("control_center")
                    assert ui.scroll_into_view("switcher_style").get("selected_index") == index

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

                # --- 2b. Terminal opacity slider (unset until moved) ---
                assert "terminal_opacity" not in read_config()["compositor"]
                terminal_slider = ui.scroll_into_view("terminal_opacity")
                assert terminal_slider is not None
                assert any(w.get("label") == "Terminal opacity (new windows)" for w in widgets())
                click_widget(terminal_slider, fraction=0.5)
                time.sleep(0.2)
                terminal_val = read_config()["compositor"]["terminal_opacity"]
                assert 0.40 <= terminal_val <= 0.60
                assert any(w.get("label") == f"{round(terminal_val * 100)}%" for w in widgets())

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

                # --- 3c. Dim inactive windows (default on) ---
                dim_toggle = ui.scroll_into_view("inactive_dim")
                assert dim_toggle is not None
                assert dim_toggle.get("on") is True, "the setting should default to on"
                assert "inactive_dim" not in read_config()["compositor"], "an untouched default is not written"
                click_widget(dim_toggle)
                assert read_config()["compositor"]["inactive_dim"] is False
                dim_toggle = ui.scroll_into_view("inactive_dim")
                assert dim_toggle.get("on") is False
                click_widget(dim_toggle)
                assert read_config()["compositor"]["inactive_dim"] is True
                assert ui.scroll_into_view("inactive_dim").get("on") is True

                # --- 3d. Flame effects: off by default, independent, saved as they run ---
                names = ("effect_window_move", "effect_window_resize", "effect_window_minimize")
                for name in names:
                    toggle = ui.scroll_into_view(name)
                    assert toggle is not None, name
                    assert toggle.get("on") is False, f"{name} should default to off"
                assert "effects" not in read_config(), "untouched defaults are not written"
                click_widget(ui.scroll_into_view("effect_window_resize"))
                effects = read_config()["effects"]
                assert effects["window_resize"]["enabled"] is True
                assert "window_move" not in effects and "window_minimize" not in effects, effects
                assert [ui.scroll_into_view(n).get("on") for n in names] == [False, True, False]
                # Turning movement on must not drag minimizing along with it.
                click_widget(ui.scroll_into_view("effect_window_move"))
                effects = read_config()["effects"]
                assert effects["window_move"]["enabled"] is True
                assert effects["window_resize"]["enabled"] is True
                assert effects["window_minimize"]["enabled"] is False, effects
                assert [ui.scroll_into_view(n).get("on") for n in names] == [True, True, False]
                for name in names:
                    if ui.scroll_into_view(name).get("on"):
                        click_widget(ui.scroll_into_view(name))
                effects = read_config()["effects"]
                assert not any(effects[k]["enabled"] for k in ("window_move", "window_resize", "window_minimize")), effects
                assert [ui.scroll_into_view(n).get("on") for n in names] == [False, False, False]

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
                assert ui.scroll_into_view("switcher_style").get("selected_index") == 1
                speed_seg = ui.scroll_into_view("anim_speed")
                assert speed_seg.get("selected_index") == 0

                # Verify reduced motion is still Off
                motion_seg = ui.scroll_into_view("reduced_motion")
                assert motion_seg.get("selected_index") == 2

                # Verify inactive opacity is still 100%
                _ = ui.scroll_into_view("inactive_opacity")
                assert any(w.get("label") == "100%" for w in widgets())

                # Picking a theme preserves personal edits, including the
                # opacity set above. Only Reset discards those overrides.
                # IPC lists every pack; the picker leaves out the retired ones (picker_hidden)
                # unless one is active, so positions are counted over the rest.
                shown_packs = [pack for pack in ipc.query("theme.list")["packs"] if pack["id"] not in ("redi-mocha", "gold")]
                theme_indices = {pack["id"]: i for i, pack in enumerate(shown_packs)}
                light_index = theme_indices["rediwm-light"]
                dark_index = theme_indices["rediwm-dark"]
                before_switch = read_config()
                previous_tokens = ipc.action("get_theme")["tokens"]
                click_widget(ui.scroll_into_view("theme"))
                ipc.key_press("Home")
                for _ in range(light_index):
                    ipc.key_press("Down")
                ipc.key_press("Return")
                ipc.wait_for_panel_settled("control_center")
                assert ui.scroll_into_view("theme")["selected_index"] == light_index
                expected_config = dict(before_switch, theme=dict(before_switch["theme"], base="rediwm-light"))
                actual_config = read_config()
                assert actual_config == expected_config, (actual_config, expected_config)
                assert ipc.action("get_theme")["tokens"]["window_bg"] == previous_tokens["window_bg"]
                click_widget(ui.scroll_into_view("theme_reset"))
                ipc.wait_for_panel_settled("control_center")
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
                assert light_theme == {"base": "rediwm-light"}, light_theme
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
                for _ in range(dark_index + 1):
                    ipc.key_press("Down")
                ipc.key_press("Return")
                ipc.wait_for_panel_settled("control_center")
                assert ui.scroll_into_view("taskbar_theme")["selected_index"] == dark_index + 1
                assert max(taskbar_pixel("dark-taskbar.png")) < 90, "taskbar did not take the Dark taskbar theme"
                tokens = ipc.action("get_theme")["tokens"]
                assert all(abs(a - b) < 0.001 for a, b in zip(tokens["taskbar_bg"], [241 / 255, 244 / 255, 247 / 255, 0.94]))
                assert all(abs(a - b) < 0.001 for a, b in zip(tokens["window_fg"], [31 / 255, 36 / 255, 48 / 255, 1]))
                assert ui.scroll_into_view("theme")["selected_index"] == light_index
                assert read_config()["taskbar_theme"] == {}
                assert read_config()["theme"] == {"base": "rediwm-light"}
                ipc.reload_config()
                ipc.close_panel("control_center")
                ipc.wait_for("control_center_closed", timeout_ms=5000)
                ipc.action("open_appearance")
                ipc.wait_for_panel_settled("control_center")
                assert ui.scroll_into_view("taskbar_theme")["selected_index"] == dark_index + 1
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
                assert ui.scroll_into_view("theme")["selected_index"] == light_index
                # Redi Blue applies every supplied token and survives reload.
                blue_index = theme_indices["redi-blue"]
                click_widget(ui.scroll_into_view("theme"))
                ipc.key_press("Home")
                for _ in range(blue_index):
                    ipc.key_press("Down")
                ipc.key_press("Return")
                ipc.wait_for_panel_settled("control_center")
                assert ui.scroll_into_view("theme")["selected_index"] == blue_index
                blue_theme = tomllib.loads((Path(__file__).resolve().parents[1] /
                                           "assets/themes/redi-blue.toml").read_text())["theme"]

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
                assert ui.scroll_into_view("theme")["selected_index"] == blue_index
                check_blue()
                click_widget(ui.scroll_into_view("theme"))
                ipc.key_press("Home")
                for _ in range(dark_index):
                    ipc.key_press("Down")
                ipc.key_press("Return")
                ipc.wait_for_panel_settled("control_center")
                assert ui.scroll_into_view("theme")["selected_index"] == dark_index
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
                    assert abs(read_config()["theme"].get("radius_lg", defaults["radius_lg"]) - tokens["radius_lg"]) < 0.001
                # A legacy compositor value cannot override an explicit theme radius.
                config_path.write_text(config_path.read_text().replace('base = "rediwm-dark"', 'base = "rediwm-dark"\nradius_lg = 2.5') +
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


def test_gold_settings_palette():
    """Light app content and dark chrome/sidebar must keep separate palettes."""
    with tempfile.TemporaryDirectory(prefix="rediwm-settings-palette-") as directory:
        tmp = Path(directory)
        env = {"DBUS_SESSION_BUS_ADDRESS": "", "REDIWM_FILES_DEVICES": "0",
               "XDG_CONFIG_HOME": str(tmp / "config"), "XDG_DATA_HOME": str(tmp / "data"),
               "XDG_CACHE_HOME": str(tmp / "cache")}
        process, log = spawn_compositor(tmp, config_content='[compositor]\nxwayland = false\n[animations]\nenabled = false\n', env_extra=env)
        try:
            with IPCClient(tmp, timeout=15) as ipc:
                ui = UIDriver(ipc)
                ipc.action("open_appearance")
                ipc.wait_for_panel_settled("control_center")
                ipc.action("theme.apply", {"id": "gold"})

                def capture():
                    ipc.move_cursor(2, 2)
                    ipc.wait_for_panel_settled("control_center")
                    ipc.wait_for_frame()
                    shot = tmp / "settings.png"
                    shot.unlink(missing_ok=True)
                    ipc.screenshot(str(shot))
                    with Image.open(shot) as image:
                        return image.convert("RGB")

                def contains_color(image, widget, color):
                    assert widget["visible"] and not widget["clipped"], widget
                    b = widget["global_box"]
                    crop = image.crop((b["x"], b["y"], b["x"] + b["width"], b["y"] + b["height"]))
                    count = sum(n for n, pixel in crop.getcolors(crop.width * crop.height)
                                if max(abs(a - b) for a, b in zip(pixel, color)) <= 2)
                    assert count > 10, (widget["name"], widget["label"], color, count)

                for reload in (False, True):
                    if reload:
                        ipc.reload_config()
                    ui.scroll_into_view("theme")
                    image = capture()
                    contains_color(image, ui.find("Theme", role="text"), (57, 51, 46))
                    contains_color(image, ui.find("theme", role="select"), (57, 51, 46))
                    contains_color(image, ui.find("general", role="row"), (241, 231, 219))
                    contains_color(image, ui.find("appearance", role="row"), (116, 92, 72))
                    ui.scroll_into_view("apply_gtk_colors")
                    image = capture()
                    contains_color(image, ui.find("apply_gtk_colors"), (57, 51, 46))
        finally:
            stop_process(process)
            log.close()
    print("PASS: Gold Settings content, controls and sidebar colors, live and reloaded")


def test_app_colors():
    with tempfile.TemporaryDirectory(prefix="rediwm-app-colors-") as directory:
        tmp = Path(directory)
        config = tmp / "custom, config"
        helpers = tmp / "bin"
        helpers.mkdir()
        for name in ("qt5ct", "qt6ct"):
            helper = helpers / name
            helper.write_text("#!/bin/sh\nexit 0\n")
            helper.chmod(0o700)
        gtk_original = "/* User CSS survives */\nlabel.user-rule { color: red; }\n"
        for version in ("gtk-3.0", "gtk-4.0"):
            (config / version).mkdir(parents=True)
            (config / version / "gtk.css").write_text(gtk_original)
        qt_original = "# User preferences\n[Appearance]\ncustom_palette=false\nstyle=Old\n[Fonts]\ngeneral=Example\n[Other]\ncustom_palette=false\n"
        for version in ("qt5ct", "qt6ct"):
            (config / version).mkdir()
            (config / version / (version + ".conf")).write_text(qt_original)
        theme = ('[compositor]\nxwayland = false\n[theme]\napp_bg = "#123456"\nwindow_fg = "#e1e2e3"\n'
                 'app_toolbar = "#234567"\napp_sidebar = "#345678"\nshell_accent = "#abcdef"\n'
                 '[taskbar_theme]\nwindow_fg = "#010203"\nstart_menu_selected_marker = "#ff0000"\n')
        env = {"HOME": str(tmp / "home"), "XDG_CONFIG_HOME": str(config),
               "XDG_DATA_HOME": str(tmp / "custom-data"), "XDG_DATA_DIRS": str(tmp / "empty-data"),
               "XDG_CACHE_HOME": str(tmp / "cache"), "DBUS_SESSION_BUS_ADDRESS": "",
               "PATH": str(helpers), "QT_QPA_PLATFORMTHEME": "gtk3",
               "QT_STYLE_OVERRIDE": "kvantum", "REDIWM_FILES_DEVICES": "0"}
        process, log = spawn_compositor(tmp, config_content=theme, env_extra=env)
        try:
            with IPCClient(tmp, timeout=15) as ipc:
                ui = UIDriver(ipc)
                ipc.action("open_appearance")
                ui.wait_settled("control_center")

                def message():
                    return " ".join((w.get("label") or "") for w in ui.widgets("control_center") if (w.get("name") or "").startswith("app_colors_status_"))

                def apply(name, expected):
                    ui.click(ui.scroll_into_view(name))
                    wait_for(lambda: expected in message(), expected)

                apply("apply_gtk_colors", "GTK colors applied")
                apply("apply_gtk_colors", "GTK colors applied")
                for version in ("gtk-3.0", "gtk-4.0"):
                    css = (config / version / "gtk.css").read_text()
                    assert css.count("BEGIN REDIWM APP COLORS") == 1
                    assert css.endswith(gtk_original), css
                    assert (config / version / "gtk.css.rediwm-backup").read_text() == gtk_original
                    assert "window_bg_color #123456" in (config / version / "rediwm-colors.css").read_text()

                apply("apply_qt_colors", "Qt 5 and Qt 6 colors applied")
                for version in ("qt5ct", "qt6ct"):
                    settings = (config / version / (version + ".conf")).read_text()
                    assert "style=Fusion" in settings and "[Fonts]\ngeneral=Example" in settings
                    assert "[Other]\ncustom_palette=false" in settings
                    assert (config / version / (version + ".conf.rediwm-backup")).read_text() == qt_original
                    palette = (config / version / "colors/rediwm.conf").read_text()
                    for line in palette.splitlines()[1:]:
                        assert len(line.split("=", 1)[1].split(",")) == 22
                assert "qt=true" in (config / "rediwm/app-colors.conf").read_text()
                if preview := os.environ.get("REDIWM_SETTINGS_PREVIEW"):
                    Path(preview).mkdir(parents=True, exist_ok=True)
                    ui.scroll_into_view("apply_gtk_colors")
                    ui.wait_settled("control_center")
                    capture = Path(preview) / "app-colors.png"
                    capture.unlink(missing_ok=True)
                    ipc.screenshot(str(capture))

                # Check the environment delivered to a newly launched app.
                received = tmp / "child-env.json"
                probe = tmp / "env.py"
                probe.write_text("""import os,json,sys
from pathlib import Path
keys = ('HOME', 'XDG_RUNTIME_DIR', 'XDG_CONFIG_HOME', 'XDG_DATA_HOME',
        'XDG_DATA_DIRS', 'XDG_CACHE_HOME', 'WAYLAND_DISPLAY', 'DISPLAY',
        'DBUS_SESSION_BUS_ADDRESS', 'DBUS_SYSTEM_BUS_ADDRESS',
        'QT_QPA_PLATFORMTHEME', 'QT_QPA_PLATFORMTHEME_QT6', 'QT_STYLE_OVERRIDE',
        'PATH', 'LANG', 'LC_ALL', 'XDG_CURRENT_DESKTOP', 'XDG_SESSION_TYPE')
Path(sys.argv[1]).write_text(json.dumps({k: os.environ[k] for k in keys if k in os.environ}))
""")
                ipc.action("spawn", {"argv": [sys.executable, str(probe), str(received)]})
                wait_for(received.exists, "app environment")
                child_env = json.loads(received.read_text())
                assert child_env["QT_QPA_PLATFORMTHEME"] == "qt5ct", child_env
                assert child_env["QT_STYLE_OVERRIDE"] == "Fusion", child_env

                # These clients use real toolkit loaders, on the private display.
                root = Path(__file__).resolve().parent
                for package, source, compiler, extra in (
                        ("gtk+-3.0", "app_colors_gtk_client.c", "cc", []),
                        ("gtk4", "app_colors_gtk_client.c", "cc", []),
                        ("libadwaita-1", "app_colors_gtk_client.c", "cc", ["-DUSE_ADWAITA"]),
                        ("Qt5Widgets", "app_colors_qt_client.cpp", "c++", ["-fPIC"]),
                        ("Qt6Widgets", "app_colors_qt_client.cpp", "c++", ["-fPIC"])):
                    if subprocess.run(["pkg-config", "--exists", package]).returncode:
                        print("SKIP: app palette probe for", package)
                        continue
                    binary = tmp / package
                    flags = subprocess.check_output(["pkg-config", "--cflags", "--libs", package], text=True).split()
                    subprocess.run([compiler, str(root / source), "-o", str(binary), *extra, *flags], check=True, capture_output=True)
                    result = subprocess.run([str(binary)], env=child_env, text=True, capture_output=True, timeout=20, check=True)
                    assert "Theme parser error" not in result.stderr and "Theme parsing error" not in result.stderr, result.stderr
                    colors = json.loads(result.stdout)
                    assert colors["bg"] == "#123456" and colors["fg"] == "#e1e2e3", (package, colors, result.stderr)
                    if "accent" in colors:
                        assert colors["accent"] == "#abcdef" and colors["on_accent"] == "#000000", colors
                        assert colors["disabled"] != colors["fg"], colors
                    if "qt6_accent" in colors:
                        assert colors["qt6_accent"] == "#abcdef", colors

                # A symlinked gtk.css becomes a regular file with its content merged.
                gtk4_css = config / "gtk-4.0/gtk.css"
                gtk4_css.unlink()
                external = tmp / "external.css"
                external.write_text("/* external */\n")
                gtk4_css.symlink_to(external)
                apply("apply_gtk_colors", "GTK colors applied")
                wait_for(lambda: not gtk4_css.is_symlink(), "gtk.css replaced")
                assert "/* external */" in gtk4_css.read_text() and "rediwm-colors.css" in gtk4_css.read_text()
                assert external.read_text() == "/* external */\n"
                gtk4_css.unlink()
                (config / "qt6ct/qt6ct.conf").unlink()
                (config / "qt6ct/qt6ct.conf").mkdir()
                apply("apply_qt_colors", "Could not apply app colors")
                assert "InvalidFile" in message(), message()
                for name in ("qt5ct", "qt6ct"):
                    (helpers / name).unlink()
                apply("apply_qt_colors", "Install qt5ct")

            stop_process(process)
            assert process.returncode == 0, (tmp / "compositor.log").read_text()
        finally:
            stop_process(process)
            log.close()
        # The Qt opt-in survives compositor restart, including launches before
        # Settings has ever been opened.
        process, log = spawn_compositor(tmp, config_content=theme, env_extra=env)
        try:
            received.unlink()
            with IPCClient(tmp) as ipc:
                ipc.action("spawn", {"argv": [sys.executable, str(probe), str(received)]})
                wait_for(received.exists, "persisted app environment")
                assert json.loads(received.read_text())["QT_QPA_PLATFORMTHEME"] == "qt5ct"
        finally:
            stop_process(process)
            log.close()
        print("PASS: app colors buttons, GTK/Qt palettes, preservation, failures and launch environment")


if __name__ == "__main__":
    if "--app-colors-only" not in sys.argv:
        test_gold_settings_palette()
        test_appearance_settings()
        print("PASS: appearance settings (chrome opacity, inactive opacity, animations controls, bundled themes)")
    test_app_colors()

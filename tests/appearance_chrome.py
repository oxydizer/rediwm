#!/usr/bin/env python3
"""Live chrome geometry, icon/glyph pixels, hit targets and saved settings."""
import math
import os
from pathlib import Path
import subprocess
import tempfile
import tomllib

from PIL import Image
from desktop_zoom import build_client, wait_for
from ipc_client import IPCClient, spawn_compositor, stop_process
from ui_driver import UIDriver


def rounded(value):
    return math.floor(value + .5)


def run(scale, external_theme=False):
    with tempfile.TemporaryDirectory(prefix="rediwm-chrome-") as directory:
        tmp = Path(directory)
        build_client(tmp)
        data = tmp / "data"
        apps = data / "applications"
        apps.mkdir(parents=True)
        icon = tmp / "icon.png"
        Image.new("RGBA", (128, 128), (255, 0, 255, 255)).save(icon)
        (apps / "chrome-test.desktop").write_text(
            f"[Desktop Entry]\nType=Application\nName=Chrome test\nExec=true\nIcon={icon}\n")
        config = ('[compositor]\nxwayland = false\nfocus_zoom = "keep"\n'
                  '[desktop]\nenabled = false\n'
                  '[animations]\nenabled = false\n'
                  '[theme]\nwindow_bg = "#101215"\nshadow = "#00000000"\n')
        theme_path = tmp / ("theme.toml" if external_theme else "rediwm-config.toml")
        if external_theme:
            theme_path.write_text('[theme]\n')
        env_extra = {"DBUS_SESSION_BUS_ADDRESS": "", "XDG_DATA_HOME": str(data),
                     "REDIWM_NO_GLASS": "1"}
        if external_theme:
            env_extra["REDIWM_THEME"] = str(theme_path)
        process, log = spawn_compositor(
            tmp, scale=str(scale), config_content=config,
            renderer=os.environ.get("REDIWM_TEST_RENDERER", "pixman"),
            env_extra=env_extra)
        client = None
        focus_client = None
        try:
            with IPCClient(tmp, timeout=15) as ipc:
                display = wait_for(lambda: next((p.name for p in tmp.glob("wayland-*")
                                                if not p.name.endswith(".lock")), None), "display")
                with (tmp / "client.log").open("w") as client_log:
                    client = subprocess.Popen(
                        [str(tmp / "client"), "--app-id", "chrome-test", "--title", "Chrome test"],
                        env=dict(os.environ, XDG_RUNTIME_DIR=str(tmp), WAYLAND_DISPLAY=display,
                                 REDIWM_TEST_DECORATION="server", REDIWM_TEST_RESIZE="1"),
                        stdout=client_log, stderr=client_log)
                win = wait_for(lambda: next((w for w in ipc.get_windows()
                                            if w["app_id"] == "chrome-test"), None), "client map")
                win_id = win["id"]
                assert ipc.get_window_debug(win_id)["titlebar_height"] == 46
                ui = UIDriver(ipc)

                def check_taskbar_edge():
                    before = ipc.get_window_debug(win_id)["chrome_box"]
                    path = tmp / "rediwm-config.toml"
                    original = path.read_text()
                    height = ipc.get_shell_state()["taskbars"][0]["box"]["height"]
                    path.write_text(original.replace('[compositor]', '[compositor]\ntaskbar_position = "top"', 1))
                    ipc.reload_config()
                    wait_for(lambda: ipc.get_window_debug(win_id)["chrome_box"]["y"] == before["y"] + height,
                             "top taskbar moves fixed window below its reserved strip")
                    moved = ipc.get_window_debug(win_id)["chrome_box"]
                    assert moved["width"] == before["width"] and moved["height"] == before["height"], (before, moved)
                    path.write_text(original)
                    ipc.reload_config()
                    wait_for(lambda: ipc.get_window_debug(win_id)["chrome_box"] == before,
                             "bottom taskbar restores fixed window geometry")

                def open_appearance():
                    ipc.action('open_appearance')
                    ipc.wait_for_panel_settled("control_center")

                def slider(name, fraction):
                    widget = ui.scroll_into_view(name)
                    box = widget["global_box"]
                    ipc.click_at(rounded(box["x"] + min(box["width"] - 1, box["width"] * fraction)),
                                 rounded(box["y"] + box["height"] / 2))
                    ipc.wait_for_panel_settled("control_center")

                def close_settings():
                    ipc.close_panel("control_center")
                    ipc.wait_for("control_center_closed")
                    ipc.action("set_camera", {"x": 0, "y": 0})
                    ipc.action("move_window_to", {"id": win_id, "x": 80, "y": 80})
                    ipc.set_zoom(win_id, 100)
                    ipc.focus_window(win_id)
                    ipc.move_cursor(10, 10)
                    ipc.wait_for_frame()

                def controls():
                    return {w["name"]: w for w in ipc.get_widget_tree(f"window/{win_id}")["widgets"]}

                open_appearance()
                assert ui.scroll_into_view("chrome_height")["value"] == 46
                assert ui.scroll_into_view("chrome_control_gap")["value"] == 4
                close_settings()

                def title_ink(height, name):
                    widgets = controls()
                    icon_size = rounded(22 * height / 55 * 1.11)
                    left = 80 + rounded(18 * height / 55) + icon_size + rounded(10 * height / 55)
                    right = widgets["minimize"]["global_box"]["x"]
                    path = tmp / f"title-{name}.png"
                    ipc.wait_for_frame()
                    ipc.screenshot(str(path))
                    with Image.open(path) as image:
                        crop = image.convert("RGB").crop(tuple(rounded(v * scale) for v in
                            (left, 80, right, 80 + height - 1)))
                    pixels = crop.load()
                    mask = Image.new("L", crop.size)
                    mask.putdata([255 if min(pixels[x, y]) > 180 else 0
                                  for y in range(crop.height) for x in range(crop.width)])
                    bounds = mask.getbbox()
                    assert bounds, "missing title text"
                    return bounds[3] - bounds[1], sum(mask.getpixel((x, y)) > 0
                        for y in range(crop.height) for x in range(crop.width))

                glyph_widths = []
                title_heights = []
                for fraction, height, gap_fraction, gap in ((0, 28, 0, 0), (1, 84, 1, 24)):
                    open_appearance()
                    slider("chrome_height", fraction)
                    slider("chrome_control_gap", gap_fraction)
                    saved = tomllib.loads(theme_path.read_text())["theme"]
                    assert saved["chrome_height"] == height, saved
                    assert saved["chrome_control_gap"] == gap, saved
                    assert tomllib.loads((tmp / "rediwm-config.toml").read_text())["compositor"]["focus_zoom"] == "keep"
                    close_settings()
                    debug = ipc.get_window_debug(win_id)
                    assert debug["titlebar_height"] == height, debug
                    assert debug["client_box"]["y"] == debug["chrome_box"]["y"] + height, debug
                    widgets = controls()
                    for name in ("minimize", "maximize", "close"):
                        box = widgets[name]["box"]
                        assert box["width"] == box["height"] == rounded(34 * height / 55), box
                        assert abs(2 * box["y"] + box["height"] - height) <= 1, box
                    for left, right in (("minimize", "maximize"), ("maximize", "close")):
                        a, b = widgets[left]["box"], widgets[right]["box"]
                        assert b["x"] - a["x"] - a["width"] == gap, (a, b)

                    # The custom magenta app icon exposes both a stale raster
                    # size and incorrect vertical centering after live changes.
                    screenshot = tmp / f"chrome-{height}.png"
                    def capture_icon():
                        ipc.screenshot(str(screenshot))
                        with Image.open(screenshot) as image:
                            image = image.convert("RGB")
                        crop = image.crop((rounded(80 * scale), rounded(80 * scale),
                                           rounded(150 * scale), rounded((80 + height) * scale)))
                        mask = Image.new("L", crop.size)
                        pixels = crop.load()
                        mask.putdata([255 if pixels[x, y][0] > 240 and pixels[x, y][1] < 20 and pixels[x, y][2] > 240 else 0
                                      for y in range(crop.height) for x in range(crop.width)])
                        return mask.getbbox()
                    bounds = wait_for(capture_icon, "titlebar icon")
                    expected_icon = rounded(rounded(22 * height / 55 * 1.11) * scale)
                    assert abs(bounds[2] - bounds[0] - expected_icon) <= 1, bounds
                    assert abs(bounds[3] - bounds[1] - expected_icon) <= 1, bounds
                    assert abs(bounds[1] + bounds[3] - rounded(height * scale)) <= 2, bounds
                    with Image.open(screenshot) as image:
                        b = widgets["minimize"]["global_box"]
                        crop = image.convert("RGB").crop(tuple(rounded(v * scale) for v in
                            (b["x"], b["y"], b["x"] + b["width"], b["y"] + b["height"])))
                    mask = Image.new("L", crop.size)
                    pixels = crop.load()
                    mask.putdata([255 if min(pixels[x, y]) > 40 else 0
                                  for y in range(crop.height) for x in range(crop.width)])
                    bounds = mask.getbbox()
                    assert bounds, ("missing minimize glyph", height, b, crop.getextrema())
                    glyph_widths.append(bounds[2] - bounds[0])
                    title_heights.append(title_ink(height, str(height))[0])
                assert glyph_widths[1] > glyph_widths[0] * 2, glyph_widths
                assert abs(title_heights[0] - title_heights[1]) <= 1, title_heights

                # Focus changes alter title weight even without a title commit.
                active_ink = title_ink(84, "active")[1]
                with (tmp / "focus-client.log").open("w") as client_log:
                    focus_client = subprocess.Popen(
                        [str(tmp / "client"), "--app-id", "chrome-focus", "--title", "Other window"],
                        env=dict(os.environ, XDG_RUNTIME_DIR=str(tmp), WAYLAND_DISPLAY=display,
                                 REDIWM_TEST_DECORATION="server"), stdout=client_log, stderr=client_log)
                peer = wait_for(lambda: next((w for w in ipc.get_windows()
                                             if w["app_id"] == "chrome-focus"), None), "focus client map")
                ipc.action("move_window_to", {"id": peer["id"], "x": 850, "y": 300})
                ipc.focus_window(peer["id"])
                inactive_ink = title_ink(84, "inactive")[1]
                assert active_ink > inactive_ink, (active_ink, inactive_ink)
                ipc.focus_window(win_id)
                assert title_ink(84, "reactivated")[1] == active_ink
                ipc.close_window(peer["id"])
                wait_for(lambda: not any(w["id"] == peer["id"] for w in ipc.get_windows()), "focus peer close")

                # The scaled buttons must remain usable through real input.
                ui.click(controls()["maximize"])
                wait_for(lambda: ipc.get_window_debug(win_id)["chrome_box"]["width"] > 402, "maximize hit target")
                assert ipc.get_window_debug(win_id)["maximized"]
                maximized = ipc.get_window_debug(win_id)
                theme_path.write_text(theme_path.read_text().replace("chrome_height = 84", "chrome_height = 28"))
                ipc.action("reload_config")
                wait_for(lambda: ipc.get_window_debug(win_id)["titlebar_height"] == 28 and
                         ipc.get_window_debug(win_id)["chrome_box"] == maximized["chrome_box"],
                         "height reload must preserve maximized frame")
                assert ipc.get_window_debug(win_id)["client_box"]["height"] == maximized["client_box"]["height"] + 56
                check_taskbar_edge()
                ui.click(controls()["maximize"])
                wait_for(lambda: ipc.get_window_debug(win_id)["chrome_box"]["width"] == 402, "restore hit target")
                assert not ipc.get_window_debug(win_id)["maximized"]

                ipc.focus_window(win_id)
                for code in (125, 42, 106):  # Super+Shift+Right tiles the window.
                    ipc.key(code, True)
                for code in (106, 42, 125):
                    ipc.key(code, False)
                wait_for(lambda: ipc.get_window_debug(win_id)["chrome_box"]["width"] > 402, "tile")
                check_taskbar_edge()
                tiled = ipc.get_window_debug(win_id)
                theme_path.write_text(theme_path.read_text().replace("chrome_height = 28", "chrome_height = 84"))
                ipc.action("reload_config")
                wait_for(lambda: ipc.get_window_debug(win_id)["titlebar_height"] == 84 and
                         ipc.get_window_debug(win_id)["chrome_box"] == tiled["chrome_box"],
                         "height reload must preserve tiled frame")
                assert ipc.get_window_debug(win_id)["client_box"]["height"] == tiled["client_box"]["height"] - 56
                ui.click(controls()["minimize"])
                wait_for(lambda: ipc.get_window_debug(win_id)["minimized"], "minimize hit target")
                ipc.restore(win_id)
                ipc.wait_for_frame()
                ui.click(controls()["close"])
                wait_for(lambda: not any(w["id"] == win_id for w in ipc.get_windows()), "close hit target")

                open_appearance()
                assert ui.scroll_into_view("chrome_height")["value"] == 84
                assert ui.scroll_into_view("chrome_control_gap")["value"] == 24
            print(f"PASS: chrome height/gap, pixels and controls (scale={scale}, external={external_theme})")
        finally:
            if focus_client is not None:
                stop_process(focus_client)
            if client is not None:
                stop_process(client)
            stop_process(process)
            log.close()


if __name__ == "__main__":
    os.environ.pop("REDIWM_THEME", None)
    run(1)
    run(1.5, external_theme=True)

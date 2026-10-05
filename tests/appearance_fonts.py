#!/usr/bin/env python3
"""UI font selection, live rendering and persistence in isolated compositors."""
from pathlib import Path
import os
import subprocess
import tempfile
import time
import tomllib

from PIL import Image, ImageChops
from ipc_client import IPCClient, ROOT, spawn_compositor, stop_process
from ui_driver import UIDriver


def run(external_theme):
    with tempfile.TemporaryDirectory(prefix="rediwm-fonts-") as directory:
        tmp = Path(directory)
        config = '[compositor]\nfocus_zoom = "keep"\n[input]\npointer_speed = 0.4\n[theme]\nfont = "Manrope"\nmono_font = "JetBrains Mono"\n'
        browse = tmp / "FontSample"
        browse.mkdir()
        (browse / "example.txt").write_text("font sample")
        env = {"DBUS_SESSION_BUS_ADDRESS": "", "REDIWM_FILES_DEVICES": "0"}
        if external_theme:
            theme_path = tmp / "theme.toml"
            theme_path.write_text('[theme]\nfont = "Manrope"\nmono_font = "JetBrains Mono"\n')
            env["REDIWM_THEME"] = str(theme_path)
        else:
            theme_path = tmp / "rediwm-config.toml"
        process, log = spawn_compositor(tmp, config_content=config, env_extra=env)
        files = None
        try:
            with IPCClient(tmp, timeout=15) as ipc:
                display = next(p.name for p in tmp.glob("wayland-*") if not p.name.endswith(".lock"))
                files_env = dict(os.environ, **env, XDG_RUNTIME_DIR=str(tmp),
                                 XDG_STATE_HOME=str(tmp / "state"),
                                 REDIWM_CONFIG=str(tmp / "rediwm-config.toml"),
                                 WAYLAND_DISPLAY=display)

                def start_files():
                    with (tmp / "files.log").open("a") as files_log:
                        app = subprocess.Popen([str(ROOT / "zig-out/bin/rediwm-files"), str(browse)],
                                               env=files_env, stdout=files_log, stderr=files_log)
                    ipc.wait_for("window_mapped", app_id="rediwm-files")
                    return app

                def capture_files(name):
                    win = next(w for w in ipc.get_windows() if w["app_id"] == "rediwm-files")
                    ipc.action("move_window_to", {"id": win["id"], "x": 20, "y": 40})
                    ipc.action("set_camera", {"x": 0, "y": 0})
                    ipc.action("focus_window", {"id": win["id"]})
                    ipc.move_cursor(1200, 680)
                    time.sleep(.3)
                    win = next(w for w in ipc.get_windows() if w["app_id"] == "rediwm-files")
                    box = ipc.get_window_debug(win["id"])["client_box"]
                    path = tmp / (name + ".png")
                    ipc.screenshot(str(path))
                    with Image.open(path) as image:
                        # Static sidebar labels, clear of hover and content updates.
                        body = image.convert("RGB").crop((box["x"] + 20, box["y"] + 60,
                                                          box["x"] + 170, box["y"] + 300))
                        chrome = image.convert("RGB").crop((win["x"] + 48, win["y"] + 8,
                                                            win["x"] + 320, win["y"] + 38))
                    return body, chrome

                def open_settings():
                    ipc.action("open_control_center")
                    win = next(w for w in ipc.get_windows() if w["app_id"] == "rediwm-settings")
                    ipc.action("move_window_to", {"id": win["id"], "x": 200, "y": 40})
                    ipc.action("set_camera", {"x": 0, "y": 0})

                def close_settings():
                    win = next((w for w in ipc.get_windows() if w["app_id"] == "rediwm-settings"), None)
                    if win is not None:
                        ipc.action("close_window", {"id": win["id"]})
                        ipc.wait_for("window_closed", window_id=win["id"])

                files = start_files()
                time.sleep(1.3)  # Let the app icon and initial theme arrive.
                before_files, before_chrome = capture_files("files-before")
                open_settings()
                time.sleep(.3)

                def widgets():
                    return ipc.get_widget_tree("control_center")["widgets"]

                def click(widget):
                    panel = ipc.get_shell_state()["control_center"]["box"]
                    box = widget["box"]
                    ipc.click_at(round(panel["x"] + box["x"] + box["width"] / 2),
                                 round(panel["y"] + box["y"] + box["height"] / 2))
                    time.sleep(.2)

                def appearance():
                    click(next(w for w in widgets() if w["label"] == "Appearance"))

                def font_select():
                    return UIDriver(ipc).scroll_into_view("font")

                def saved_font():
                    return tomllib.loads(theme_path.read_text())["theme"].get("font", "Manrope")

                def capture_header(name):
                    # The first navigation label: UI font, and it never scrolls.
                    path = tmp / (name + ".png")
                    ipc.screenshot(str(path))
                    panel = ipc.get_shell_state()["control_center"]["box"]
                    with Image.open(path) as image:
                        header = image.convert("RGB").crop((panel["x"] + 24, panel["y"] + 24,
                                                            panel["x"] + 240, panel["y"] + 76))
                        win = next(w for w in ipc.get_windows() if w["app_id"] == "rediwm-settings")
                        chrome = image.convert("RGB").crop((win["x"] + 48, win["y"] + 8,
                                                            win["x"] + 320, win["y"] + 38))
                        return header, chrome

                appearance()
                before, settings_chrome = capture_header("before")
                assert not font_select()["is_disabled"]
                click(font_select())
                ipc.key_press("Down")
                ipc.key_press("Return")
                time.sleep(.4)
                selected = saved_font()
                assert selected != "Manrope", selected
                assert tomllib.loads(theme_path.read_text())["theme"].get("mono_font", "JetBrains Mono") == "JetBrains Mono"
                assert tomllib.loads((tmp / "rediwm-config.toml").read_text())["input"]["pointer_speed"] == .4
                after, changed_settings_chrome = capture_header("after")
                assert ImageChops.difference(before, after).getbbox(), "UI font did not repaint live"
                assert ImageChops.difference(settings_chrome, changed_settings_chrome).getbbox(), "Focused window chrome font did not repaint live"

                # Reopening must retain the saved selection. Escape cancels
                # navigation, and Home offers the bundled default again.
                ipc.key_press("Escape")
                close_settings()
                # Files' worker applies the persisted theme on its next wake.
                time.sleep(1.3)
                after_files, after_chrome = capture_files("files-after")
                assert ImageChops.difference(before_files, after_files).getbbox(), "Files font did not repaint live"
                assert ImageChops.difference(before_chrome, after_chrome).getbbox(), "Window chrome font did not repaint live"
                win = next(w for w in ipc.get_windows() if w["app_id"] == "rediwm-files")
                ipc.action("close_window", {"id": win["id"]})
                ipc.wait_for("window_closed", window_id=win["id"])
                files.wait(timeout=5)
                files = start_files()
                startup_files, startup_chrome = capture_files("files-startup")
                assert not ImageChops.difference(after_files, startup_files).getbbox(), "Files lost the saved font at startup"
                assert not ImageChops.difference(after_chrome, startup_chrome).getbbox(), "New window chrome differs from the updated font"
                open_settings()
                time.sleep(.3)
                appearance()
                click(font_select())
                ipc.key_press("Home")
                ipc.key_press("Escape")
                assert saved_font() == selected
                click(font_select())
                ipc.key_press("Home")
                ipc.key_press("Return")
                time.sleep(.4)
                assert saved_font() == "Manrope"
                ipc.key_press("Escape")
                close_settings()
                time.sleep(1.3)
                default_files, default_chrome = capture_files("files-default")
                assert not ImageChops.difference(before_files, default_files).getbbox(), "Files did not restore the default font"
                assert not ImageChops.difference(before_chrome, default_chrome).getbbox(), "Chrome did not restore the default font"
            print(f"PASS: UI, Files and chrome font selection, live repaint and persistence ({'theme file' if external_theme else 'config'})")
        finally:
            if files is not None:
                stop_process(files)
            stop_process(process)
            log.close()


if __name__ == "__main__":
    os.environ.pop("REDIWM_THEME", None)
    run(False)
    run(True)

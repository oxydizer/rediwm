#!/usr/bin/env python3
"""Taskbar auto-hide: the Settings toggle and reload, the strip a maximized
window gets, the edge reveal and its delays, holding on the bar, no reveal while
a button is held, and the start menu keeping the bar out.

`shown()` asks the compositor what is under the bar's centre: a parked bar has
its tree disabled, so the window beneath takes the hit."""
import os
from pathlib import Path
import subprocess
import tempfile
import time
import tomllib

from desktop_zoom import build_client, wait_for
from ipc_client import IPCClient, spawn_compositor, stop_process
from ui_driver import UIDriver

BTN_LEFT = 0x110
# taskbar/reveal.zig: reveal_delay_ms, hide_delay_ms.
REVEAL_DELAY = .12
HIDE_DELAY = .4


def run():
    with tempfile.TemporaryDirectory(prefix="rediwm-taskbar-auto-hide-") as directory:
        tmp = Path(directory)
        build_client(tmp)
        config_path = tmp / "rediwm-config.toml"
        config = ('[compositor]\nxwayland = false\nfocus_zoom = "keep"\ndock_enabled = false\n'
                  '[desktop]\nenabled = false\n[animations]\nenabled = false\n')
        env_extra = {"DBUS_SESSION_BUS_ADDRESS": "", "XDG_CONFIG_HOME": str(tmp / "config"),
                     "XDG_DATA_HOME": str(tmp / "data"), "XDG_CACHE_HOME": str(tmp / "cache"),
                     "XDG_STATE_HOME": str(tmp / "state")}
        process, log = spawn_compositor(tmp, config_content=config, env_extra=env_extra)
        client = None
        try:
            with IPCClient(tmp, timeout=15) as ipc:
                ipc.wait_for("wallpaper_presented", timeout_ms=10000)
                ui = UIDriver(ipc)
                info = ipc.get_outputs()[0]
                width, height = info["logical_width"], info["logical_height"]
                bar = ipc.get_shell_state()["taskbars"][0]["box"]
                assert bar["y"] + bar["height"] == height, bar
                center = (bar["x"] + bar["width"] // 2, bar["y"] + bar["height"] // 2)
                middle = (width // 2, height // 3)

                def shown():
                    return ipc.hit_test(*center)["target_type"] == "taskbar"

                def hidden():
                    return not shown()

                display = wait_for(lambda: next((p.name for p in tmp.glob("wayland-*")
                                                 if not p.name.endswith(".lock")), None), "display")
                with (tmp / "client.log").open("w") as client_log:
                    client = subprocess.Popen(
                        [str(tmp / "client"), "--app-id", "autohide", "--title", "Auto hide"],
                        env=dict(os.environ, XDG_RUNTIME_DIR=str(tmp), WAYLAND_DISPLAY=display,
                                 REDIWM_TEST_DECORATION="server", REDIWM_TEST_RESIZE="1"),
                        stdout=client_log, stderr=client_log)
                win = wait_for(lambda: next((w for w in ipc.get_windows() if w["app_id"] == "autohide"), None), "client map")
                win_id = win["id"]
                ipc.maximize(win_id)
                wait_for(lambda: next(w for w in ipc.get_windows() if w["id"] == win_id).get("is_maximized") is True, "maximize")

                def window_bottom():
                    ipc.wait_for("window_geometry_settled", window_id=win_id)
                    box = ipc.get_window_debug(win_id)["chrome_box"]
                    return box["y"] + box["height"]

                # Off (the default): the bar is in place and reserves its strip.
                ipc.move_cursor(*middle)
                ipc.wait_for_frame()
                assert shown(), "a bar that never hides was not hit-testable"
                wait_for(lambda: window_bottom() == height - bar["height"], "maximized window did not leave the strip")

                # Fullscreen must suppress the bar, and leaving fullscreen
                # must restore it when auto-hide is disabled.
                ipc.fullscreen(win_id)
                wait_for(lambda: ipc.get_window_debug(win_id)["fullscreen"], "window did not enter fullscreen")
                wait_for(hidden, "taskbar remained above a fullscreen window with auto-hide off")
                ipc.fullscreen(win_id)
                wait_for(lambda: not ipc.get_window_debug(win_id)["fullscreen"], "window did not leave fullscreen")
                wait_for(shown, "taskbar did not return after fullscreen with auto-hide off")

                # Settings turns it on, saves it, and windows take the whole edge.
                ipc.action("open_appearance")
                ipc.wait_for_panel_settled("control_center")
                toggle = ui.scroll_into_view("taskbar_auto_hide")
                assert toggle["on"] is False, toggle
                box = toggle["global_box"]
                ipc.click_at(box["x"] + box["width"] // 2, box["y"] + box["height"] // 2)
                wait_for(lambda: tomllib.loads(config_path.read_text())["compositor"].get("taskbar_auto_hide") is True,
                         "Settings toggle did not save taskbar_auto_hide")
                ipc.close_panel("control_center")
                ipc.move_cursor(*middle)
                wait_for(hidden, "bar did not hide once auto-hide was on")
                wait_for(lambda: window_bottom() == height, "maximized window did not take the freed strip")
                assert ipc.get_shell_state()["taskbars"][0]["box"] == bar, "the resting box moved"

                # The edge reveals it, after the delay rather than at once.
                started = time.monotonic()
                ipc.move_cursor(center[0], height - 1)
                early = shown()
                if time.monotonic() - started < REVEAL_DELAY / 2:
                    assert not early, "bar revealed without waiting for the delay"
                wait_for(shown, "edge did not reveal the bar", timeout=5)

                # A revealed auto-hide bar must also yield to fullscreen.
                ipc.fullscreen(win_id)
                wait_for(lambda: ipc.get_window_debug(win_id)["fullscreen"], "window did not enter fullscreen with auto-hide on")
                wait_for(hidden, "revealed taskbar remained above a fullscreen window")
                ipc.fullscreen(win_id)
                wait_for(lambda: not ipc.get_window_debug(win_id)["fullscreen"], "window did not leave fullscreen with auto-hide on")
                wait_for(shown, "revealed taskbar did not return after fullscreen")

                # On the bar it stays out.
                ipc.move_cursor(*center)
                time.sleep(HIDE_DELAY + .3)
                assert shown(), "bar hid with the pointer on it"

                # Leaving waits for the hide delay, then the bar goes.
                started = time.monotonic()
                ipc.move_cursor(*middle)
                early = shown()
                if time.monotonic() - started < HIDE_DELAY / 2:
                    assert early, "bar hid without waiting for the delay"
                wait_for(hidden, "bar did not hide after the pointer left", timeout=5)

                # A held button (a drag or selection) never raises it.
                ipc.pointer_button(BTN_LEFT, True)
                ipc.move_cursor(center[0], height - 1)
                time.sleep(REVEAL_DELAY + .4)
                assert hidden(), "bar revealed while a button was held"
                ipc.pointer_button(BTN_LEFT, False)
                ipc.move_cursor(center[0] + 1, height - 1)
                wait_for(shown, "edge did not reveal the bar after the release", timeout=5)
                ipc.move_cursor(*middle)
                wait_for(hidden, "bar did not hide again", timeout=5)

                # The start menu brings the bar out and keeps it there while open.
                ipc.open_start_menu()
                wait_for(shown, "start menu did not reveal the bar", timeout=5)
                ipc.move_cursor(*middle)
                time.sleep(HIDE_DELAY + .3)
                assert shown(), "bar hid under an open start menu"
                ipc.close_panel("start_menu")
                wait_for(hidden, "bar did not hide once the start menu closed", timeout=5)

                # A reload that turns it off brings the bar back and reserves the strip.
                text = config_path.read_text().replace("taskbar_auto_hide = true", "taskbar_auto_hide = false")
                assert "taskbar_auto_hide = false" in text, text
                config_path.write_text(text)
                ipc.reload_config()
                wait_for(shown, "bar did not return when auto-hide was turned off", timeout=5)
                wait_for(lambda: window_bottom() == height - bar["height"], "maximized window did not give the strip back")
                time.sleep(HIDE_DELAY + .3)
                assert shown(), "bar hid with auto-hide off"
                # Settings reads the reloaded value back.
                ipc.action("open_appearance")
                ipc.wait_for_panel_settled("control_center")
                assert ui.scroll_into_view("taskbar_auto_hide")["on"] is False
        finally:
            if client:
                client.terminate()
                try:
                    client.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    client.kill()
            stop_process(process)
            log.close()
    print("taskbar_auto_hide: ok")


if __name__ == "__main__":
    run()

#!/usr/bin/env python3
"""Explicit + grouping, independent launches, chrome controls and Settings.

Uses the existing real xdg client. All processes, app entries and state live
inside a private headless compositor; no host app is launched.
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import tomllib

from desktop_zoom import build_client, wait_for
from ipc_client import IPCClient, spawn_compositor, stop_process
from ui_driver import UIDriver


def run():
    with tempfile.TemporaryDirectory(prefix="rediwm-window-tabs-") as directory:
        tmp = Path(directory)
        build_client(tmp)
        apps = tmp / "data/applications"
        apps.mkdir(parents=True)
        (apps / "tab-fixture.desktop").write_text(
            '[Desktop Entry]\nType=Application\nName=Tab fixture\n'
            f'Exec=env REDIWM_TEST_DECORATION=server REDIWM_TEST_RESIZE=1 {tmp}/client --app-id tab-fixture --title New-tab\n')
        state = tmp / "state/rediwm"
        state.mkdir(parents=True)
        (state / "window_tab_apps").write_text(json.dumps([
            "com.transmissionbt.transmission_55_136902",
            "com.transmissionbt.transmission_56_136902",
            "rediwm-files", "rediwm-editor",
        ]))
        config = ('[compositor]\nxwayland = false\nfocus_zoom = "keep"\n'
                  '[desktop]\nenabled = false\n[animations]\nenabled = false\n')
        process, log = spawn_compositor(tmp, config_content=config,
            scale=os.environ.get("REDIWM_TEST_SCALE", "1"),
            renderer=os.environ.get("REDIWM_TEST_RENDERER", "pixman"),
            env_extra={"DBUS_SESSION_BUS_ADDRESS": "", "XDG_DATA_HOME": str(tmp / "data")})
        clients = []
        try:
            with IPCClient(tmp, timeout=15) as ipc:
                display = wait_for(lambda: next((p.name for p in tmp.glob("wayland-*")
                    if not p.name.endswith(".lock")), None), "display")
                env = dict(os.environ, XDG_RUNTIME_DIR=str(tmp), WAYLAND_DISPLAY=display,
                    REDIWM_TEST_DECORATION="server", REDIWM_TEST_RESIZE="1")

                def windows():
                    return [w for w in ipc.get_windows() if w["app_id"] == "tab-fixture"]

                def window(wid):
                    return next((w for w in windows() if w["id"] == wid), None)

                marker = tmp / "refuse-close"
                marker.touch()

                def spawn(title):
                    f = (tmp / f"{title}.log").open("w")
                    child = subprocess.Popen([str(tmp / "client"), "--app-id", "tab-fixture", "--title", title], env=dict(env, **({"REDIWM_TEST_CLOSE_MARKER": str(marker)} if title == "First" else {})), stdout=f, stderr=f)
                    f.close()
                    clients.append(child)
                    return wait_for(lambda: next((w for w in windows() if w["title"] == title), None), title)["id"]

                def widgets(wid):
                    return ipc.get_widget_tree(f"window/{wid}")["widgets"]

                def click(wid, name):
                    ipc.focus_window(wid)
                    ipc.wait_for_frame()
                    widget = next(w for w in widgets(wid) if w["name"] == name)
                    box = widget["global_box"]
                    # Tab centre can overlap its close target in a tiny frame;
                    # use the label/icon side for selection.
                    dx = min(30, box["width"] // 2) if name.startswith("tab/") and not name.endswith("/close") else box["width"] // 2
                    ipc.click_at(box["x"] + dx, box["y"] + box["height"] // 2)
                    ipc.wait_for_frame()

                def active(group):
                    return next((w for w in windows() if w.get("tab_group") == group and w.get("tab_active")), None)

                def plus(wid):
                    before = {w["id"] for w in windows()}
                    click(wid, "tab_new")
                    new = wait_for(lambda: next((w for w in windows() if w["id"] not in before), None), "new tab map")
                    wait_for(lambda: window(new["id"]).get("tab_group") == window(wid).get("tab_group"), "new tab grouped")
                    return new["id"]

                first, separate = spawn("First"), spawn("Separate")
                assert all("tab_group" not in w for w in windows())
                ipc.action('open_appearance')
                ipc.wait_for_panel_settled("control_center")
                ui = UIDriver(ipc)
                names = [w["name"] for w in ui.widgets() if (w["name"] or "").startswith("window_tabs:")]
                assert names.count("window_tabs:com.transmissionbt.transmission") == 1, names
                assert not any(n.startswith("window_tabs:rediwm-") or "136902" in n for n in names), names
                checkbox = ui.scroll_into_view("window_tabs:tab-fixture")
                b = checkbox["global_box"]
                ipc.click_at(b["x"] + b["width"] - 24, b["y"] + b["height"] // 2)
                wait_for(lambda: all(w.get("tab_group") for w in windows()), "enabled tabs")
                saved = tomllib.loads((tmp / "rediwm-config.toml").read_text())
                assert saved["compositor"]["window_tab_apps"] == ["tab-fixture"], saved
                ipc.close_panel("control_center")
                ipc.wait_for("control_center_closed")
                assert window(first)["tab_group"] != window(separate)["tab_group"], windows()
                ipc.action("move_window_to", {"id": first, "x": 60, "y": 60})
                ipc.set_zoom(first, 100)
                group = window(first)["tab_group"]
                second = plus(first)
                assert active(group)["id"] == second, windows()
                assert not window(first)["tab_active"]
                assert not widgets(first)[0]["visible"]
                assert window(first)["is_minimized"] is False
                assert (window(second)["x"], window(second)["y"]) == (60, 60)
                # A close request to an inactive tab must reveal its native
                # confirmation dialog, and refusing close keeps the tab alive.
                ipc.action('close_window', {"id": first})
                dialog = wait_for(lambda: next((w for w in windows() if w["title"] == "Confirm close"), None), "close confirmation")
                assert "tab_group" not in dialog
                assert active(group)["id"] == first and window(second)
                assert widgets(dialog["id"])[0]["visible"]
                ipc.focus_window(second)
                wait_for(lambda: not widgets(dialog["id"])[0]["visible"], "inactive tab hides its dialog")
                ipc.focus_window(dialog["id"])
                wait_for(lambda: active(group)["id"] == first and widgets(dialog["id"])[0]["visible"], "dialog activation selects its parent")
                ipc.action('close_window', {"id": dialog["id"]})
                wait_for(lambda: window(dialog["id"]) is None, "cancel confirmation")
                marker.unlink()
                independent = spawn("Independent")
                assert window(independent)["tab_group"] != group
                second_group = window(independent)["tab_group"]
                independent_tab = plus(independent)
                assert window(independent_tab)["tab_group"] == second_group
                assert len([w for w in windows() if w["tab_group"] == group]) == 2
                click(second, f"tab/{first}")
                wait_for(lambda: active(group)["id"] == first, "tab click switches")
                # External activation selects an inactive member.
                ipc.focus_window(second)
                wait_for(lambda: active(group)["id"] == second, "external activation")
                # Geometry belongs to the group across a switch.
                ipc.action("move_window_to", {"id": second, "x": 150, "y": 120})
                click(second, f"tab/{first}")
                assert (window(first)["x"], window(first)["y"]) == (150, 120)
                click(first, "maximize")
                wait_for(lambda: window(first)["is_maximized"], "maximize")
                click(first, f"tab/{second}")
                wait_for(lambda: window(second)["is_maximized"], "shared maximize")
                click(second, "maximize")
                wait_for(lambda: not window(second)["is_maximized"], "unmaximize")
                click(second, "minimize")
                wait_for(lambda: window(second)["is_minimized"], "minimize")
                assert not widgets(first)[0]["visible"] and not widgets(second)[0]["visible"]
                ipc.focus_window(first)
                wait_for(lambda: active(group)["id"] == first and widgets(first)[0]["visible"], "restore hidden member")
                ipc.action("fullscreen_window", {"id": first})
                wait_for(lambda: ipc.get_window_debug(first)["fullscreen"], "fullscreen group")
                assert not any(w["name"] == "tab_new" for w in widgets(first))
                ipc.focus_window(second)
                wait_for(lambda: ipc.get_window_debug(second)["fullscreen"], "fullscreen follows selected member")
                ipc.action("fullscreen_window", {"id": second})
                wait_for(lambda: not ipc.get_window_debug(second)["fullscreen"], "leave fullscreen")
                wait_for(lambda: any(w["name"] == "tab_new" for w in widgets(second)), "tabs return after fullscreen")
                # Overflow keeps navigation and + reachable.
                third = plus(second)
                fourth = plus(third)
                assert any(w["name"] == "tab_previous" for w in widgets(fourth))
                click(fourth, "tab_previous")
                wait_for(lambda: active(group)["id"] != fourth, "overflow navigation")
                current = active(group)["id"]
                click(current, f"tab/{current}/close")
                wait_for(lambda: window(current) is None, "close active tab")
                assert active(group) is not None
                ipc.screenshot(os.environ.get("REDIWM_TABS_PREVIEW", str(tmp / "tabs.png")))
                # Outer close closes this group only.
                click(active(group)["id"], "close")
                wait_for(lambda: not any(w.get("tab_group") == group for w in windows()), "close group")
                assert window(separate) and window(independent) and window(independent_tab)
                # A normal launch command that exits without a new surface must
                # clear pending feedback and leave the group untouched.
                desktop = apps / "tab-fixture.desktop"
                desktop.write_text('[Desktop Entry]\nType=Application\nName=Tab fixture\nExec=/bin/true\n')
                click(separate, "tab_new")
                wait_for(lambda: not next(w for w in widgets(separate) if w["name"] == "tab_new")["is_disabled"], "failed launch clears pending", timeout=15)
                assert len(windows()) == 3
                click(separate, f"tab/{separate}/close")
                wait_for(lambda: window(separate) is None, "last tab closes frame")
                # Turning off restores all remaining clients as ordinary windows.
                ipc.action('open_appearance')
                ipc.wait_for_panel_settled("control_center")
                checkbox = ui.scroll_into_view("window_tabs:tab-fixture")
                b = checkbox["global_box"]
                # Navigate to the checkbox with the keyboard and toggle it.
                for _ in range(80):
                    node = next(w for w in ui.widgets() if w["name"] == "window_tabs:tab-fixture")
                    if node["is_focused"]:
                        break
                    ipc.key_down_up(15)  # Tab
                else:
                    raise AssertionError("checkbox not reachable with Tab")
                ipc.key_down_up(57)  # Space
                wait_for(lambda: all("tab_group" not in w for w in windows()), "disable tabs")
                assert len(windows()) == 2
                assert all(widgets(w["id"])[0]["visible"] for w in windows())
                assert (tmp / "state/rediwm/window_tab_apps").exists()
                print("PASS: + groups, independent windows, Settings/keyboard, dialogs, fullscreen, geometry, controls, overflow, launch failure and disabling")
        except Exception:
            print((tmp / "compositor.log").read_text() if (tmp / "compositor.log").exists() else "")
            raise
        finally:
            for child in clients:
                stop_process(child)
            stop_process(process)
            log.close()


if __name__ == "__main__":
    run()

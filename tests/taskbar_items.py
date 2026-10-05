#!/usr/bin/env python3
"""Move/hide taskbar items through Settings; check live geometry and persistence.

Uses private headless compositors and temporary config files, never the host UI.
"""
import tempfile
import time
import tomllib
from pathlib import Path

from ipc_client import IPCClient, spawn_compositor, stop_process
from ui_driver import UIDriver


def wait(predicate, message):
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(.05)
    raise AssertionError(message)


def run(scale):
    with tempfile.TemporaryDirectory(prefix="rediwm-taskbar-items-") as directory:
        root = Path(directory)
        config = '# preserve me\n[compositor]\nxwayland = false\n[input]\ninvert_scroll = false\n'
        expected = None
        for restart in range(2):
            runtime = root / str(restart)
            runtime.mkdir()
            process, log = spawn_compositor(runtime, scale=scale, config_content=config, env_extra={
                "DBUS_SESSION_BUS_ADDRESS": "unix:path=/nonexistent/rediwm-test-bus",
                "PULSE_SERVER": "unix:/nonexistent/rediwm-test-audio",
                "REDIWM_THEME": "",
                "XDG_CACHE_HOME": str(runtime),
            })
            try:
                with IPCClient(runtime, timeout=15) as ipc:
                    ipc.wait_for("wallpaper_presented", timeout_ms=10000)

                    def items():
                        return ipc.get_shell_state()["taskbars"][0]["right_items"]

                    def state():
                        return [(item["name"], item["visible"]) for item in items()]

                    def validate():
                        visible = [item for item in items() if item["box"] is not None]
                        for a, b in zip(visible, visible[1:]):
                            assert a["box"]["x"] + a["box"]["width"] <= b["box"]["x"], visible
                        for item in visible:
                            box = item["box"]
                            hit = ipc.hit_test(box["x"] + box["width"] // 2, box["y"] + box["height"] // 2)
                            want = {"clock": "clock", "volume": "tray", "network": "tray", "battery": "battery"}[item["name"]]
                            assert hit.get("widget") == want, (item, hit)

                    def check_position(top):
                        bar = ipc.get_shell_state()["taskbars"][0]["box"]
                        output = ipc.get_outputs()[0]
                        assert bar["y"] == (output["y"] if top else output["y"] + output["logical_height"] - bar["height"]), bar

                    if restart:
                        check_position(True)
                        assert state() == expected, (state(), expected)
                        validate()
                        # Hide every item through a config reload, then restore the defaults.
                        path = runtime / "rediwm-config.toml"
                        path.write_text('[compositor]\nxwayland = false\ntaskbar_items = ["-clock", "-battery", "-network", "-volume"]\n')
                        wait(lambda: all(not i["visible"] and i["box"] is None for i in items()), "hide all on reload")
                        path.write_text('[compositor]\nxwayland = false\n')
                        wait(lambda: state() == [(n, True) for n in ("battery", "network", "volume", "clock")], "restore defaults on reload")
                        check_position(False)
                        validate()
                        continue

                    assert state() == [(n, True) for n in ("battery", "network", "volume", "clock")]
                    validate()
                    ipc.action('open_appearance')

                    def widgets():
                        return ipc.get_widget_tree("control_center")["widgets"]

                    def row_control(name, control):
                        # Scroll until the row is fully inside the settings viewport.
                        for _ in range(30):
                            tree = widgets()
                            row = next(w for w in tree if w["role"] == "text" and w["label"] == name)
                            box = ipc.get_shell_state()["control_center"]["box"]
                            center = row["box"]["y"] + row["box"]["height"] / 2
                            if 140 < center < box["height"] - 35:
                                candidates = [w for w in tree if abs(w["box"]["y"] + w["box"]["height"] / 2 - center) < 5]
                                return next(w for w in candidates if (w["role"] == "toggle" if control == "toggle" else w["role"] == "button" and w["label"] == control))
                            ipc.move_cursor(box["x"] + box["width"] - 20, box["y"] + box["height"] - 90)
                            ipc.scroll(0, 130 if center >= box["height"] - 35 else -130)
                            time.sleep(.1)
                        raise AssertionError(f"could not scroll to {name}")

                    def click(name, control):
                        widget = row_control(name, control)
                        box = ipc.get_shell_state()["control_center"]["box"]
                        rect = widget["box"]
                        ipc.click_at(round(box["x"] + rect["x"] + rect["width"] / 2), round(box["y"] + rect["y"] + rect["height"] / 2))
                        time.sleep(.25)

                    def handle_point(name):
                        widget = row_control(name, "Drag to reorder")
                        box = ipc.get_shell_state()["control_center"]["box"]
                        rect = widget["box"]
                        return (round(box["x"] + rect["x"] + rect["width"] / 2),
                                round(box["y"] + rect["y"] + rect["height"] / 2))

                    def drag(name, target, down=False, cancel=False, outside=False):
                        # Ensure both rows are visible, then read their final positions.
                        handle_point(name)
                        tx, ty = handle_point(target)
                        sx, sy = handle_point(name)
                        ipc.move_cursor(sx, sy)
                        ipc.pointer_button(0x110, True)
                        before = state()
                        ipc.move_cursor(tx, ty + (3 if down else -3))
                        assert state() == before, "drag must persist only on release"
                        tree = widgets()
                        rows = [w["label"] for w in sorted(tree, key=lambda w: w["box"]["y"])
                                if w["role"] == "text" and w["label"] in {"Battery", "Network", "Volume", "Clock"}]
                        assert rows.index(name) == [i["name"] for i in items()].index(target.lower()), rows
                        if outside:
                            box = ipc.get_shell_state()["control_center"]["box"]
                            ipc.move_cursor(box["x"] + box["width"] + 20, ty + (3 if down else -3))
                        if cancel:
                            ipc.key_down_up(1)  # Escape restores the saved order.
                        ipc.pointer_button(0x110, False)
                        time.sleep(.25)
                        if cancel:
                            assert state() == before, "Escape must cancel reordering"

                    click("Clock", "Drag to reorder")
                    assert state() == [(n, True) for n in ("battery", "network", "volume", "clock")]
                    drag("Clock", "Battery", cancel=True)
                    drag("Clock", "Battery")
                    wait(lambda: items()[0]["name"] == "clock", "drag last to first")
                    drag("Clock", "Volume", down=True, outside=True)
                    wait(lambda: items()[-1]["name"] == "clock", "drag first to last")
                    click("Network", "toggle")
                    wait(lambda: not next(i for i in items() if i["name"] == "network")["visible"], "hide network")
                    drag("Clock", "Volume")
                    wait(lambda: [i["name"] for i in items()] == ["battery", "network", "clock", "volume"], "move clock left")
                    drag("Network", "Clock", down=True)
                    wait(lambda: [i["name"] for i in items()] == ["battery", "clock", "network", "volume"], "move hidden network")
                    ipc.key_down_up(103)  # Up, then Down on the focused handle.
                    wait(lambda: items()[1]["name"] == "network", "keyboard reorder up")
                    ipc.key_down_up(108)
                    wait(lambda: items()[2]["name"] == "network", "keyboard reorder down")
                    click("Network", "toggle")
                    wait(lambda: all(i["visible"] for i in items()), "show network")
                    click("Volume", "toggle")
                    expected = [("battery", True), ("clock", True), ("network", True), ("volume", False)]
                    wait(lambda: state() == expected, "hide volume")
                    ui = UIDriver(ipc)
                    for index in (0, 1, 0):
                        widget = ui.scroll_into_view("taskbar_position")
                        rect = widget["global_box"]
                        ipc.click_at(round(rect["x"] + rect["width"] * (index + .5) / 2), round(rect["y"] + rect["height"] / 2))
                        time.sleep(.25)
                        check_position(index == 0)
                        assert ui.scroll_into_view("taskbar_position")["selected_index"] == index
                        assert tomllib.loads((runtime / "rediwm-config.toml").read_text())["compositor"]["taskbar_position"] == ("top" if index == 0 else "bottom")
                    preview = Path(f"/tmp/rediwm-taskbar-items-{scale}.png")
                    preview.unlink(missing_ok=True)
                    ipc.screenshot(str(preview))
                    ipc.close_panel("control_center")
                    wait(lambda: ipc.get_shell_state().get("control_center") is None, "close settings")
                    validate()
                    # Menus open below a top taskbar and remain interactive.
                    bar = ipc.get_shell_state()["taskbars"][0]
                    clock = next(i["box"] for i in items() if i["name"] == "clock")
                    ipc.click_at(clock["x"] + clock["width"] // 2, clock["y"] + clock["height"] // 2)
                    time.sleep(.25)
                    output = ipc.get_outputs()[0]
                    hit = ipc.hit_test(output["x"] + output["logical_width"] - 50, bar["box"]["y"] + bar["box"]["height"] + 50)
                    assert hit["target_type"] == "calendar", hit
                    ipc.key_down_up(1)
                    start = bar["start_button_box"]
                    ipc.click_at(start["x"] + start["width"] // 2, start["y"] + start["height"] // 2)
                    time.sleep(.25)
                    menu = ipc.get_shell_state()["start_menu"]["box"]
                    assert menu["y"] >= bar["box"]["y"] + bar["box"]["height"], menu
                    ipc.key_down_up(1)
                    config = (runtime / "rediwm-config.toml").read_text()
                    saved = tomllib.loads(config)
                    assert saved["compositor"]["taskbar_items"] == ["battery", "clock", "network", "-volume"], saved
                    assert "# preserve me" in config and saved["input"]["invert_scroll"] is False
                    assert ipc.get_perf()["output_failed_commits"] == 0
            except Exception:
                log.flush()
                print((runtime / "compositor.log").read_text()[-4000:])
                raise
            finally:
                stop_process(process)
                log.close()
        print(f"PASS scale {scale}: taskbar move/hide, hit targets, reload and restart persistence")


if __name__ == "__main__":
    for scale in (1, 1.5):
        run(scale)

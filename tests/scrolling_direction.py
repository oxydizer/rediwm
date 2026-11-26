"""Scrolling direction per display (plan stage 4): vertical strips on a
portrait output, the arrow keys along them, the `scroll_direction` setting
from IPC and Settings, and a strip moved between displays of different
directions."""
from pathlib import Path
import tempfile
import tomllib

from desktop_zoom import build_client, wait_for
from output_reconnect import hotplug, hotplug_environment
from scrolling_outputs import visible_workspace
from ui_driver import UIDriver


def saved_direction(s, name):
    config = tomllib.loads((s.tmp / "rediwm-config.toml").read_text())
    return next((out.get("scroll_direction") for out in config.get("outputs", []) if out["name"] == name), None)


def outputs(s):
    return {out["name"]: out for out in s.ipc.get_outputs()}


def check_vertical_strip(s, tall):
    """Rows stacked down a portrait output; arrows act along and across them."""
    ipc = s.ipc
    ipc.move_cursor(100, 100, output=tall["name"])
    a = s.launch("row-a")
    b = s.launch("row-b")
    c = s.launch("row-c")
    s.settle_all()
    ws = s.window(a)["workspace_id"]
    assert s.workspace(ws)["output"] == tall["name"]

    def order(id):
        return s.window(id)["workspace_order"]

    def rows():
        return [[m["id"] for m in col["members"]] for col in s.workspace(ws)["columns"]]

    strip = s.workspace(ws)
    assert strip["layout"] == "scrolling" and strip["direction"] == "vertical", strip
    assert rows() == [[order(a)], [order(b)], [order(c)]], strip
    fa, fb, fc = (s.frame(id) for id in (a, b, c))
    # Full-width rows, each half the height, one below the other.
    assert fa[0] == fb[0] == fc[0] and fa[2] == fb[2] == fc[2] > tall["logical_width"] * 0.9, (fa, fb, fc)
    assert fa[1] < fb[1] < fc[1] and fa[3] == fb[3] == fc[3] < tall["logical_height"] * 0.6, (fa, fb, fc)
    # The view followed the newest row down; the first scrolled off the top.
    assert strip["view"] > 0 and fa[1] + fa[3] <= tall["y"], (strip, fa)
    wait_for(lambda: ipc.get_window_debug(a)["outputs"] == [], "row above the view is culled")

    # Up and Down walk the strip; Left and Right stay within a row.
    s.chord("Up")
    assert ipc.get_focused_window()["id"] == b
    s.chord("Right")
    assert ipc.get_focused_window()["id"] == b, "a row of one has nothing beside it"
    s.chord("Up")
    s.settle_all()
    assert ipc.get_focused_window()["id"] == a and s.workspace(ws)["view"] == 0
    wait_for(lambda: ipc.get_window_debug(a)["outputs"] == [tall["name"]], "revealed row shows again")
    s.chord("Down")
    assert ipc.get_focused_window()["id"] == b

    # Super+[ joins the row above; the two share it side by side.
    s.chord("bracketleft")
    wait_for(lambda: rows() == [[order(a), order(b)], [order(c)]], "b joins a's row")
    s.settle_all()
    fa, fb = s.frame(a), s.frame(b)
    assert fa[1] == fb[1] and fa[0] < fb[0], (fa, fb)
    s.chord("Left")
    assert ipc.get_focused_window()["id"] == a
    s.chord("Right")
    assert ipc.get_focused_window()["id"] == b
    # Shift+Left reorders within the row, Shift+Down moves the row.
    s.chord("Left", shift=True)
    wait_for(lambda: rows() == [[order(b), order(a)], [order(c)]], "b moves before a")
    s.chord("Down", shift=True)
    wait_for(lambda: rows() == [[order(c)], [order(b), order(a)]], "the row moves down")
    # Ctrl+Down makes the row taller; Ctrl+Right widens b within it.
    s.chord("Down", ctrl=True)
    wait_for(lambda: s.workspace(ws)["columns"][1]["width"] > 0.5, "Super+Ctrl+Down grows the row")
    s.chord("Right", ctrl=True)
    wait_for(lambda: s.workspace(ws)["columns"][1]["members"][0]["weight"] > 1, "Super+Ctrl+Right widens b")
    s.settle_all()
    fb, fa = s.frame(b), s.frame(a)
    assert fb[2] > fa[2] and fb[1] == fa[1], (fb, fa)
    return ws, (a, b, c)


def check_setting(s, ws, tall, windows):
    """`scroll_direction` transposes the strip in place and is saved."""
    ipc = s.ipc
    a, b, c = windows
    columns = s.workspace(ws)["columns"]
    assert outputs(s)[tall["name"]]["scroll_direction"] == "auto"
    ipc.action("set_output_config", {"output": tall["name"], "scroll_direction": "horizontal"})
    wait_for(lambda: s.workspace(ws)["direction"] == "horizontal", "strip turns sideways")
    s.settle_all()
    assert s.workspace(ws)["columns"] == columns, (columns, s.workspace(ws)["columns"])
    out = outputs(s)[tall["name"]]
    assert (out["scroll_direction"], out["scroll_direction_resolved"]) == ("horizontal", "horizontal"), out
    assert saved_direction(s, tall["name"]) == "horizontal"
    # Columns now: c, then b above a.
    fa, fb, fc = (s.frame(id) for id in (a, b, c))
    assert fc[0] < fb[0] and fb[0] == fa[0] and fb[1] < fa[1], (fa, fb, fc)
    focused = ipc.get_focused_window()["id"]
    x, y, w, h = s.frame(focused)
    assert tall["x"] <= x and x + w <= tall["x"] + tall["logical_width"], ("focus stays in view", s.frame(focused))

    ipc.action("set_output_config", {"output": tall["name"], "scroll_direction": "auto"})
    wait_for(lambda: s.workspace(ws)["direction"] == "vertical", "auto turns it back")
    s.settle_all()
    assert s.workspace(ws)["columns"] == columns
    assert outputs(s)[tall["name"]]["scroll_direction_resolved"] == "vertical"
    assert saved_direction(s, tall["name"]) == "auto"


def check_settings_row(s, wide):
    """Settings → Displays offers the direction for the display it edits."""
    ipc = s.ipc
    ui = UIDriver(ipc)
    ipc.move_cursor(200, 200, output=wide["name"])
    ipc.open_control_center()
    ui.wait_settled("control_center")
    # Settings opens as a half-width column; floating gives it its own size.
    settings = wait_for(lambda: ipc.get_focused_window(), "Settings focused")["id"]
    ipc.action("tiling_action", {"action": "toggle_floating", "id": settings})
    s.settled(settings)
    ui.wait_settled("control_center")
    ui.click(ui.find("Displays"))
    wait_for(lambda: ipc.get_shell_state()["control_center"]["category"] == "displays", "displays page")
    ui.wait_settled("control_center")
    assert ui.scroll_into_view("scroll_direction")["selected_index"] == 0
    ui.click(ui.scroll_into_view("scroll_direction"), panel="control_center")
    ui.wait_settled("control_center")
    ipc.key_down_up(102)  # Home
    ipc.key_down_up(108)  # Down
    ipc.key_down_up(108)  # Down
    ipc.key_down_up(28)  # Return
    wait_for(lambda: saved_direction(s, wide["name"]) == "vertical", "Settings saves Vertical")
    wait_for(lambda: outputs(s)[wide["name"]]["scroll_direction_resolved"] == "vertical", "landscape output scrolls vertically")
    ui.wait_settled("control_center")
    assert ui.scroll_into_view("scroll_direction")["selected_index"] == 2
    ipc.close_panel("control_center")
    ipc.action("set_output_config", {"output": wide["name"], "scroll_direction": "auto"})
    wait_for(lambda: outputs(s)[wide["name"]]["scroll_direction_resolved"] == "horizontal", "wide back to auto")


def check_rehome(s, ws, wide, tall, windows):
    """A vertical strip moved to a landscape display runs sideways, and comes
    back as it was."""
    ipc = s.ipc
    a, b, c = windows
    commands = s.tmp / "hotplug"
    ipc.focus_window(a)
    s.settle_all()
    before = s.workspace(ws)
    hotplug(commands, "unplug " + tall["name"])
    wait_for(lambda: len(ipc.get_outputs()) == 1 and s.workspace(ws)["output"] == wide["name"],
             "strip migrated to the landscape display")
    ipc.action("switch_workspace", {"workspace": ws})
    s.settle_all()
    moved = s.workspace(ws)
    assert moved["direction"] == "horizontal" and moved["columns"] == before["columns"], (before, moved)
    fa, fc = s.frame(a), s.frame(c)
    assert fc[0] < fa[0] and wide["x"] <= fa[0] and fa[0] + fa[2] <= wide["x"] + wide["logical_width"], (fa, fc)
    hotplug(commands, "replug " + tall["name"])
    wait_for(lambda: len(ipc.get_outputs()) == 2 and s.workspace(ws)["output"] == tall["name"],
             "strip returned to the portrait display")
    s.settle_all()
    after = s.workspace(ws)
    assert after["direction"] == "vertical" and after["columns"] == before["columns"], (before, after)
    assert after["view"] == before["view"], (before["view"], after["view"])
    assert s.frame(a)[1] >= tall["y"] and s.frame(c)[1] < s.frame(a)[1]


def direction_strip():
    from scrolling import BASE, MOTION_OFF, Session
    with tempfile.TemporaryDirectory(prefix="rediwm-strip-direction-") as directory:
        tmp = Path(directory)
        build_client(tmp)
        # The landscape display at the origin: the UI driver's cursor moves
        # use layout coordinates on the output under the cursor.
        config = BASE.format(mode="scrolling") + MOTION_OFF + '''[[outputs]]
name = "HEADLESS-1"
x = 0
y = 0
[[outputs]]
name = "HEADLESS-2"
x = 1280
y = 0
transform = "90"
'''
        s = Session(tmp, config, outputs=2, env_extra=hotplug_environment(tmp))
        try:
            tall = next(out for out in s.ipc.get_outputs() if out["name"] == "HEADLESS-2")
            wide = next(out for out in s.ipc.get_outputs() if out["name"] == "HEADLESS-1")
            assert tall["logical_height"] > tall["logical_width"] and wide["logical_width"] > wide["logical_height"], (tall, wide)
            assert (wide["scroll_direction"], wide["scroll_direction_resolved"]) == ("auto", "horizontal"), wide
            assert (tall["scroll_direction"], tall["scroll_direction_resolved"]) == ("auto", "vertical"), tall
            ws, windows = check_vertical_strip(s, tall)
            check_setting(s, ws, tall, windows)
            check_settings_row(s, wide)
            check_rehome(s, ws, wide, tall, windows)
            assert visible_workspace(s, tall)["id"] == ws
        except Exception:
            s.dump_log()
            raise
        finally:
            s.stop()
    print("PASS: per-display scroll direction: vertical strips, arrow roles, setting, Settings row and rehoming")


if __name__ == "__main__":
    direction_strip()

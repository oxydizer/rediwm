"""Stage 5 of the scrolling layout: swipes, two-finger scrolling, the wheel,
drag resizing, insertion drops and edge scrolling on a strip."""
from pathlib import Path
import tempfile
import time

from desktop_zoom import build_client, wait_for

GAP = 48
PAN_SPEED = 2  # [input] pan_speed default: a swipe moves the view twice the finger


def gestures():
    from scrolling import BASE, Session
    with tempfile.TemporaryDirectory(prefix="rediwm-strip-gestures-") as directory:
        tmp = Path(directory)
        build_client(tmp)
        # Wide gaps leave empty strip to scroll two fingers over.
        s = Session(tmp, BASE.format(mode="scrolling").replace("window_gap = 8", f"window_gap = {GAP}"))
        try:
            ids = [s.launch(name) for name in ("pan-a", "pan-b", "pan-c", "pan-d")]
            s.settle_all()
            check_swipes(s, ids)
            check_fingers(s, ids)
            check_wheel(s, ids)
            check_resize(s, ids)
            check_drops(s, ids)
        except Exception:
            s.dump_log()
            raise
        finally:
            s.stop()
    print("PASS: strip swipes, fling, rubber band, two fingers, wheel steps, drag resize, insertion and edge scrolling")


def strip(s):
    return s.workspace(1)


def columns(s):
    return [[m["id"] for m in col["members"]] for col in strip(s)["columns"]]


def order(s, id):
    return s.window(id)["workspace_order"]


def output(s):
    return s.ipc.get_outputs()[0]


def snap_points(s):
    """Views where some column's leading or trailing edge meets the view's."""
    out = output(s)
    view = strip(s)["view"]
    lo, hi = out["x"] + GAP, out["x"] + out["logical_width"] - GAP
    return {round(view + x - lo) for x, _, w, _ in map(s.frame, (w["id"] for w in s.ipc.get_windows()))} | \
        {round(view + x + w - hi) for x, _, w, _ in map(s.frame, (w["id"] for w in s.ipc.get_windows()))}


def shown(s, id):
    out = output(s)
    x, _, w, _ = s.frame(id)
    return out["x"] <= x and x + w <= out["x"] + out["logical_width"]


def swipe(s, steps, dx, pause=0.0, settle=True):
    ipc = s.ipc
    ipc.action("swipe", {"phase": "begin", "fingers": 3})
    for _ in range(steps):
        ipc.action("swipe", {"phase": "update", "dx": dx, "dy": 7})
        if pause: time.sleep(pause)
    return lambda: (ipc.action("swipe", {"phase": "end"}), s.settle_all() if settle else None)


def check_swipes(s, ids):
    ipc = s.ipc
    a, b, c, d = ids
    ipc.focus_window(a)
    s.settle_all()
    assert strip(s)["view"] == 0 and columns(s) == [[order(s, i)] for i in ids], strip(s)
    # D keeps neither gaining nor losing focus: it hears nothing (plan fix 1).
    serial = ipc.get_window_debug(d)["configure_serial"]
    bx = s.frame(b)[0]
    # 1:1 with the fingers, across the strip only; windows follow at the next frame.
    release = swipe(s, 4, -100)
    assert strip(s)["view"] == 4 * 100 * PAN_SPEED, strip(s)
    ipc.wait_for_frame()
    assert s.frame(b)[0] == bx - 800, (bx, s.frame(b))
    # Held still, then lifted: the nearest column edge, and focus moves to it.
    time.sleep(0.15)
    release()
    view = strip(s)["view"]
    assert view > 0 and view in snap_points(s), (view, snap_points(s))
    assert ipc.get_focused_window()["id"] == b and shown(s, b), ipc.get_focused_window()
    assert ipc.get_window_debug(d)["configure_serial"] == serial
    # A fling carries on to the end of the strip.
    swipe(s, 6, -40, pause=0.016)()
    end = strip(s)["view"]
    assert end > view and end in snap_points(s) and shown(s, d), (view, end)
    assert shown(s, ipc.get_focused_window()["id"])
    # Past the end the view gives way, and springs back.
    serials = {id: ipc.get_window_debug(id)["configure_serial"] for id in ids}
    release = swipe(s, 3, -100)
    assert end < strip(s)["view"] < end + 600, strip(s)["view"]
    time.sleep(0.15)
    release()
    assert strip(s)["view"] == end
    assert {id: ipc.get_window_debug(id)["configure_serial"] for id in ids} == serials


def check_fingers(s, ids):
    ipc = s.ipc
    a, b, c, d = ids
    ipc.focus_window(a)
    s.settle_all()
    assert strip(s)["view"] == 0
    # Over a window, two fingers are the client's.
    x, y, w, h = s.frame(a)
    ipc.move_cursor(x + w // 2, y + h // 2)
    ipc.action("scroll", {"dx": -60, "dy": 0, "finger": True})
    ipc.action("scroll", {"dx": 0, "dy": 0, "finger": True})
    assert strip(s)["view"] == 0
    # In the gap between columns they move the strip, even once a window
    # slides under them, until they lift.
    gap_x = x + w + GAP // 2
    ipc.move_cursor(gap_x, y + h // 2)
    assert ipc.hit_test(gap_x, y + h // 2)["window_id"] is None
    for _ in range(3):
        ipc.action("scroll", {"dx": -100, "dy": 0, "finger": True})
    assert strip(s)["view"] == 600, strip(s)
    time.sleep(0.15)
    ipc.action("scroll", {"dx": 0, "dy": 0, "finger": True})
    s.settle_all()
    assert strip(s)["view"] in snap_points(s) and strip(s)["view"] > 0
    assert shown(s, ipc.get_focused_window()["id"])


def check_wheel(s, ids):
    ipc = s.ipc
    a, b, c, d = ids
    # A second workspace to cycle to.
    ipc.action("switch_workspace", {"workspace": 2})
    ipc.action("switch_workspace", {"workspace": 1})
    ipc.focus_window(a)
    s.settle_all()
    out = output(s)
    ipc.move_cursor(out["logical_width"] // 2, out["logical_height"] // 2)
    # Super+Shift+wheel and Super+horizontal wheel step through columns.
    ipc.key(125, True)
    ipc.key(42, True)
    ipc.scroll(0, 40)
    ipc.key(42, False)
    assert ipc.get_focused_window()["id"] == b
    ipc.scroll(40, 0)
    assert ipc.get_focused_window()["id"] == c
    ipc.scroll(-80, 0)
    assert ipc.get_focused_window()["id"] == a
    # Plain Super+wheel still changes workspace.
    ipc.scroll(0, 40)
    ipc.key(125, False)
    wait_for(lambda: next(w for w in ipc.get_workspaces() if w["is_focused"])["id"] == 2, "Super+wheel cycles workspaces")
    ipc.key(125, True)
    ipc.scroll(0, -40)
    ipc.key(125, False)
    wait_for(lambda: next(w for w in ipc.get_workspaces() if w["is_focused"])["id"] == 1, "and back")
    s.settle_all()


def begin_drag(s, id, fx, fy, button):
    """Super+button on window `id` at a fraction of its frame."""
    ipc = s.ipc
    ipc.focus_window(id)
    s.settle_all()
    x, y, w, h = s.frame(id)
    px, py = round(x + w * fx), round(y + h * fy)
    ipc.move_cursor(px, py)
    ipc.key(125, True)
    ipc.pointer_button(button, True)
    assert ipc.get_input_state()["cursor_mode"] == ("resize" if button == 0x111 else "move")
    return px, py


def end_drag(s, button, cancel=False):
    ipc = s.ipc
    if cancel: ipc.key_press("Escape")
    ipc.pointer_button(button, False)
    ipc.key(125, False)
    assert ipc.get_input_state()["cursor_mode"] == "passthrough"
    s.settle_all()


def check_resize(s, ids):
    ipc = s.ipc
    a, b, c, d = ids

    def width(id):
        index = next(i for i, col in enumerate(strip(s)["columns"]) if order(s, id) in [m["id"] for m in col["members"]])
        return strip(s)["columns"][index]["width"]

    before = s.frame(b)
    # The trailing edge: live, and Escape puts it back.
    x, y = begin_drag(s, b, 0.8, 0.3, 0x111)
    ipc.move_cursor(x + 90, y)
    wait_for(lambda: s.frame(b)[2] > before[2], "live column resize")
    end_drag(s, 0x111, cancel=True)
    assert s.frame(b)[2] == before[2] and width(b) == 0.5
    x, y = begin_drag(s, b, 0.8, 0.3, 0x111)
    ipc.move_cursor(x + 90, y)
    end_drag(s, 0x111)
    assert width(b) > 0.5 and s.frame(b)[2] == before[2] + 90, (width(b), s.frame(b))
    s.chord("z")
    wait_for(lambda: width(b) == 0.5, "undo the dragged width")
    s.settle_all()
    # The leading edge grows it to the left; its trailing edge stays put.
    right = s.frame(b)[0] + s.frame(b)[2]
    x, y = begin_drag(s, b, 0.2, 0.3, 0x111)
    ipc.move_cursor(x - 60, y)
    end_drag(s, 0x111)
    assert s.frame(b)[2] == before[2] + 60 and abs(s.frame(b)[0] + s.frame(b)[2] - right) <= 1, (s.frame(b), right)
    s.chord("z")
    wait_for(lambda: width(b) == 0.5, "undo the leading-edge width")
    # Within a column, the edge across the strip sets the height.
    ipc.focus_window(c)
    s.chord("bracketleft")
    wait_for(lambda: [order(s, b), order(s, c)] in columns(s), "c joins b")
    s.settle_all()
    tall = s.frame(b)[3]
    x, y = begin_drag(s, b, 0.5, 0.8, 0x111)
    ipc.move_cursor(x, y + 70)
    end_drag(s, 0x111)
    assert s.frame(b)[3] > tall and s.frame(c)[3] < tall, (s.frame(b), s.frame(c))
    s.chord("z")
    wait_for(lambda: s.frame(b)[3] == tall, "undo the height")
    # Back to a column each.
    ipc.focus_window(c)
    s.chord("bracketright")
    wait_for(lambda: len(columns(s)) == 4, "c leaves b's column")
    s.settle_all()


def check_drops(s, ids):
    ipc = s.ipc
    a, b, c, d = ids
    ipc.focus_window(a)
    s.settle_all()
    assert columns(s) == [[order(s, i)] for i in ids], columns(s)
    ax, ay, aw, ah = s.frame(a)
    # Near a column's leading edge: a column of its own there.
    begin_drag(s, b, 0.5, 0.2, 0x110)
    ipc.move_cursor(ax + 20, ay + ah // 2)
    end_drag(s, 0x110)
    assert columns(s) == [[order(s, b)], [order(s, a)], [order(s, c)], [order(s, d)]], columns(s)
    # Over the lower half of a column: into it, below.
    bx, by, bw, bh = s.frame(b)
    begin_drag(s, a, 0.5, 0.2, 0x110)
    ipc.move_cursor(bx + bw // 2, by + bh - 40)
    end_drag(s, 0x110)
    assert columns(s)[0] == [order(s, b), order(s, a)], columns(s)
    fa, fb = s.frame(a), s.frame(b)
    assert fa[0] == fb[0] and fa[1] > fb[1]
    # Held at the end of the display while dragging, the strip scrolls.
    ipc.focus_window(b)
    s.settle_all()
    view = strip(s)["view"]
    out = output(s)
    begin_drag(s, b, 0.5, 0.2, 0x110)
    ipc.move_cursor(out["logical_width"] - 4, out["logical_height"] // 2)
    wait_for(lambda: strip(s)["view"] > view + 200, "drag near the edge scrolls the strip")
    end_drag(s, 0x110, cancel=True)
    assert columns(s)[0] == [order(s, b), order(s, a)]


if __name__ == "__main__":
    gestures()

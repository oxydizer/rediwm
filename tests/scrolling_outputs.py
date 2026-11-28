"""Multi-output integration cases for the horizontal scrolling layout."""
from pathlib import Path
import re
import subprocess
import tempfile

from PIL import Image

from desktop_zoom import wait_for
from input_protocols import Peer, compile_client
from ipc_client import stop_process
from output_reconnect import hotplug, hotplug_environment
from output_scale import build_client as build_scale_client
from wlr_protocols import compile_fixture


def image_on(s, out):
    path = s.tmp / (out["name"] + ".png")
    path.unlink(missing_ok=True)
    s.ipc.screenshot(path=str(path), output=out["name"])
    with Image.open(path) as shot:
        return shot.convert("RGB")


def sample(s, out, x, y):
    scale = out["scale"]
    return image_on(s, out).getpixel((round((x - out["x"]) * scale), round((y - out["y"]) * scale)))


def visible_workspace(s, out):
    return next(ws for ws in s.ipc.get_workspaces() if ws["is_visible"] and ws["output"] == out["name"])


def check_strip_edge(s, left, right):
    ipc = s.ipc
    seam = right["x"]
    y = min(left["logical_height"], right["logical_height"]) * 3 // 4
    left_log = s.tmp / "left.log"
    ipc.move_cursor(100, 100, output=left["name"])
    with left_log.open("w") as log:
        witness = s.launch("resident", stdout=log)
    s.chord("w")  # the only column fills the left output
    s.settled(witness)

    ipc.move_cursor(100, 100, output=right["name"])
    a = s.launch("across-edge", REDIWM_TEST_EDGE="1")
    b = s.launch("next-column")
    s.settle_all()
    x, _, width, _ = s.frame(a)
    assert x + width // 2 < seam < x + width - 40, (s.frame(a), right)
    assert ipc.get_window_debug(a)["outputs"] == [right["name"]]
    home = sample(s, right, seam + 32, y)
    neighbor = sample(s, left, seam - 32, y)
    assert home[0] > home[2] + 100, (home, s.frame(a))
    assert neighbor[2] > neighbor[0] + 100, ("column overpainted the other output", neighbor)
    x = seam - 32 - left["x"]
    assert ipc.hit_test(x, y, output=left["name"])["window_id"] == witness
    ipc.click_at(x, y, output=left["name"])
    wait_for(lambda: "button 272 1" in left_log.read_text(), "click reached the left client")

    for action, flag in ((ipc.maximize, "maximized"), (ipc.fullscreen, "fullscreen")):
        ipc.focus_window(b)
        s.settle_all()
        x, _, w, _ = s.frame(a)
        assert x + w // 2 < seam < x + w
        action(a)
        wait_for(lambda: ipc.get_window_debug(a)[flag], flag)
        s.settle_all()
        # Expanding a background tile leaves focus and the view on its peer.
        assert ipc.get_focused_window()["id"] == b and s.frame(a)[0] < seam
        ipc.focus_window(a)
        s.settle_all()
        x, _, w, _ = s.frame(a)
        assert x == seam and w == right["logical_width"], (flag, s.frame(a))
        wait_for(lambda: ipc.get_window_debug(a)["outputs"] == [right["name"]], "expanded tile stays on its output")
        ipc.restore(a)
        wait_for(lambda: not ipc.get_window_debug(a)[flag], "restore " + flag)
        s.settle_all()
    return a, b


def check_popups(s, right):
    ipc = s.ipc
    constraints = s.tmp / "wide.constraints"
    constraints.write_text(f'{right["logical_width"] + 400} 0 0 0\n')
    path = s.tmp / "wide.log"
    with path.open("w") as log:
        wide = s.launch("wide-popup-parent", stdout=log, stdin=subprocess.PIPE, REDIWM_TEST_CONSTRAINTS=str(constraints),
                        REDIWM_TEST_COMMANDS="1", REDIWM_TEST_XDG_VERSION="3",
                        REDIWM_TEST_POPUP_AT="20,140", REDIWM_TEST_POPUP_SLIDE="1")
    s.settled(wide)
    box = ipc.get_window_debug(wide)["client_box"]
    seam = right["x"]
    assert box["x"] + 120 < seam < box["x"] + box["width"]
    ipc.click_at(80, 180, button=273, output=right["name"])
    match = wait_for(lambda: re.search(r"^popup (-?\d+) (-?\d+) (\d+) (\d+)", path.read_text(), re.M),
                     "oversized parent opened its popup")
    dx, dy, w, h = map(int, match.groups())
    x, y = box["x"] + dx, box["y"] + dy
    assert seam <= x <= seam + right["logical_width"] - w, (box, match.group(), right)
    ipc.move_cursor(round(x - seam + w / 2), round(y + h / 2), output=right["name"])
    wait_for(lambda: "enter popup " in path.read_text(), "constrained popup received pointer enter")
    # Move the mapped menu down, still requesting an anchor on the peer.
    # The configure following the protocol token must constrain it again.
    child = s.clients["wide-popup-parent"]
    child.stdin.write(b"reposition 40 240\n")
    child.stdin.flush()
    moved = wait_for(lambda: re.search(r"^repositioned 1\npopup (-?\d+) (-?\d+) (\d+) (\d+)", path.read_text(), re.M),
                     "popup repositioned and configured with token 1")
    rx, ry, rw, rh = map(int, moved.groups())
    assert ry == 240 and ry != dy and (rw, rh) == (w, h), moved.group()
    assert seam <= box["x"] + rx <= seam + right["logical_width"] - rw, (box, moved.group(), right)
    s.close("wide-popup-parent")
    wait_for(lambda: all(win["id"] != wide for win in ipc.get_windows()), "popup parent closed")

    children = []
    try:
        app = Peer(s.tmp, s.env, children, "field", "scroll-field")
        ime = Peer(s.tmp, s.env, children, "candidate", "ime")
        ime.send("method")
        app.expect("text-enter\n")
        field = next(win["id"] for win in ipc.get_windows() if win["app_id"] == "scroll-field")
        s.settled(field)
        bx = ipc.get_window_debug(field)["client_box"]["x"]
        app.send(f"caret {round(seam - bx - 50)} 120")
        ime.send("popup")

        def candidate():
            return next((p for p in ipc.query("get_text_input")["popups"] if p["visible"]), None)
        popup = wait_for(candidate, "IME displayed its candidate")
        assert popup["output"] == right["name"] and popup["x"] >= seam, popup
    finally:
        for child in children:
            stop_process(child)


def check_density(s, left, right):
    """The scale-aware client's surface crosses the edge into a denser output."""
    ipc = s.ipc
    path = s.tmp / "density.log"
    ipc.move_cursor(200, 200, output=right["name"])
    with path.open("w") as log:
        proc = subprocess.Popen([str(s.tmp / "scale-client")], env=s.env, stdout=log)
    s.clients["scale"] = proc
    target = wait_for(lambda: next((w["id"] for w in ipc.get_windows() if w["app_id"] == "rediwm-scale-test"), None),
                      "scale client maps")
    wait_for(lambda: f'enter {right["name"]}' in path.read_text(), "scale client entered its home output")
    # Float the 400 px client across the seam while it belongs to the right workspace.
    ipc.action("tiling_action", {"action": "toggle_floating", "id": target})
    ipc.action("move_window_to", {"id": target, "x": right["x"] - 150, "y": 170})
    s.settled(target)
    box = ipc.get_window_debug(target)["client_box"]
    assert box["x"] < right["x"] < box["x"] + box["width"]
    assert f'enter {left["name"]}' not in path.read_text(), path.read_text()
    density = round(right["scale"] * 120)
    draws = [l for l in path.read_text().splitlines() if l.startswith("draw ")]
    assert draws[-1].split()[1] == str(density), draws
    # On Canvas the same surface spans both displays and uses the higher density.
    s.set_mode("canvas")
    ipc.action("move_window_to", {"id": target, "x": right["x"] - 150, "y": 170})
    s.settled(target)
    wait_for(lambda: f'enter {left["name"]}' in path.read_text(), "Canvas surface entered the left output")
    wait_for(lambda: ipc.get_window_debug(target)["buffer_width"] == round(400 * left["scale"]),
             "Canvas surface used the higher output density")
    s.set_mode("scrolling")
    s.close("scale")
    wait_for(lambda: all(w["id"] != target for w in ipc.get_windows()), "density client closed")


def check_slide(s, right, b):
    """During a switch, the right edge of the blue client moves horizontally."""
    ipc = s.ipc
    ipc.focus_window(b)
    s.settle_all()
    workspace = s.window(b)["workspace_id"]
    y = round(right["logical_height"] * .75 * right["scale"])

    def blue_edge():
        image = image_on(s, right)
        return next((x for x in range(image.width - 1, 0, -1)
                     if image.getpixel((x, y)) == (0, 0, 255)), 0)

    before = blue_edge()
    assert before > right["buffer_width"] * .8, before
    ipc.action("switch_workspace", {"workspace": 20})
    wait_for(lambda: 0 < blue_edge() < before - 20, "leaving workspace slides sideways", timeout=3)
    ipc.action("switch_workspace", {"workspace": workspace})
    s.settle_all()


def check_reconnect(s, left, right, b):
    ipc = s.ipc
    commands = s.tmp / "hotplug"
    # The survivor was displaying its second native workspace. Remember it
    # when temporarily showing the borrowed strip while the connector is gone.
    ipc.move_cursor(100, 100, output=left["name"])
    left_ws = 17
    ipc.action("switch_workspace", {"workspace": left_ws})
    assert visible_workspace(s, left)["id"] == left_ws
    ws = s.window(b)["workspace_id"]
    before = s.workspace(ws)
    hotplug(commands, "unplug " + right["name"])
    wait_for(lambda: len(ipc.get_outputs()) == 1 and s.workspace(ws)["output"] == left["name"],
             "strip migrated to the survivor")
    assert visible_workspace(s, left)["id"] == left_ws
    ipc.action("switch_workspace", {"workspace": ws})
    s.settle_all()
    assert s.workspace(ws)["columns"] == before["columns"]
    assert s.frame(b)[0] < left["x"] + left["logical_width"]
    hotplug(commands, "replug " + right["name"])
    wait_for(lambda: len(ipc.get_outputs()) == 2 and s.workspace(ws)["output"] == right["name"],
             "strip returned to its reconnected display")
    s.settle_all()
    after = s.workspace(ws)
    selections = (visible_workspace(s, left)["id"], visible_workspace(s, right)["id"])
    assert selections == (left_ws, ws), (selections, (left_ws, ws))
    assert after["columns"] == before["columns"] and after["view"] == before["view"], (before, after)
    assert s.frame(b)[0] >= right["x"]


def check_dialog_transfer(s, left, right, first, last):
    ipc = s.ipc
    ipc.focus_window(last)
    s.settle_all()
    proc = subprocess.Popen([str(s.tmp / "fixture"), "xdg-dialog", "modal"],
                            env=s.env, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL)
    s.clients["modal"] = proc

    def by_app(app):
        return next((win["id"] for win in ipc.get_windows() if win["app_id"] == app), None)

    owner = wait_for(lambda: by_app("rediwm.dialog-owner"), "owner maps")
    dialog = wait_for(lambda: by_app("rediwm.dialog"), "dialog maps")
    s.settle_all()

    def offset():
        ox, oy, _, _ = s.frame(owner)
        x, y, _, _ = s.frame(dialog)
        return x - ox, y - oy

    relative = offset()
    ipc.focus_window(first)
    s.settle_all()
    assert s.frame(owner)[0] >= right["x"] + right["logical_width"], s.frame(owner)
    for out in (left, right):
        ws = visible_workspace(s, out)["id"]
        ipc.action("move_to_workspace", {"id": owner, "workspace": ws})
        s.settle_all()
        assert s.window(owner)["workspace_id"] == ws == s.window(dialog)["workspace_id"]
        assert offset() == relative, (relative, offset(), out["name"])
        x, y, w, h = s.frame(dialog)
        hit = ipc.hit_test(x - out["x"] + w // 2, y - out["y"] + h // 2, output=out["name"])
        assert hit["window_id"] == dialog, hit
    s.close("modal")
    wait_for(lambda: by_app("rediwm.dialog") is None, "dialog closes")


def multi_output_strip():
    from scrolling import BASE, Session
    with tempfile.TemporaryDirectory(prefix="rediwm-strip-outputs-") as directory:
        tmp = Path(directory)
        compile_client(tmp)
        compile_fixture(tmp)
        build_scale_client(tmp)
        config = BASE.format(mode="scrolling") + '''scroll_column_width = 0.8
inactive_dim = false
desktop_switch_ms = 1250
[[outputs]]
name = "HEADLESS-1"
x = 0
y = 0
scale = 1.5
[[outputs]]
name = "HEADLESS-2"
x = 1280
y = 0
scale = 1
[animations]
enabled = true
reduced_motion = "off"
'''
        s = Session(tmp, config, outputs=2, env_extra=hotplug_environment(tmp), scale="auto")
        try:
            left, right = sorted(s.ipc.get_outputs(), key=lambda out: out["x"])
            assert right["x"] == left["x"] + left["logical_width"], (left, right)
            a, b = check_strip_edge(s, left, right)
            check_popups(s, right)
            check_density(s, left, right)
            check_dialog_transfer(s, left, right, a, b)
            check_slide(s, right, b)
            check_reconnect(s, left, right, b)
        except Exception:
            s.dump_log()
            raise
        finally:
            s.stop()
    print("PASS: two scrolling outputs isolate pixels, clicks, client scale and popups, slide sideways, and rehome on reconnect")


if __name__ == "__main__":
    multi_output_strip()

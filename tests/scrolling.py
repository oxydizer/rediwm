#!/usr/bin/env python3
"""The scrolling desktop mode, and the tiled layout kept across mode switches."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

from desktop_zoom import build_client, wait_for
from ipc_client import IPCClient, spawn_compositor, stop_process
from wlr_protocols import compile_fixture


class Session:
    """One headless compositor with the test client built beside it."""

    def __init__(self, tmp, config, outputs=1, state=None, binary=None, env_extra=None, scale=None):
        self.tmp = tmp
        self.clients = {}
        private = {key: str(tmp / key) for key in ("HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME")}
        self.process, self.log = spawn_compositor(tmp, outputs=str(outputs), config_content=config, binary=binary,
            renderer=os.getenv("REDIWM_TEST_RENDERER", "gles2"), scale=scale or os.getenv("REDIWM_TEST_SCALE", "1"),
            env_extra={**private, "DBUS_SESSION_BUS_ADDRESS": "unix:path=/nonexistent-scroll-bus",
                       "XDG_STATE_HOME": str(state or tmp / "state"), **(env_extra or {})})
        self.ipc = IPCClient(tmp, timeout=15).__enter__()
        self.ipc.wait_for("wallpaper_presented", timeout_ms=10000)
        display = next(p.name for p in tmp.glob("wayland-*") if not p.name.endswith(".lock"))
        self.env = dict(os.environ, XDG_RUNTIME_DIR=str(tmp), WAYLAND_DISPLAY=display,
            XDG_STATE_HOME=str(state or tmp / "state"), REDIWM_TEST_DECORATION="server")

    def launch(self, name, stdout=subprocess.DEVNULL, stdin=None, **env):
        child = subprocess.Popen([str(self.tmp / "client"), "--app-id", name], env={**self.env, **env},
            stdin=stdin, stdout=stdout, stderr=subprocess.DEVNULL)
        self.clients[name] = child
        return wait_for(lambda: next((w["id"] for w in self.ipc.get_windows() if w["app_id"] == name), None), "map " + name)

    def close(self, name):
        stop_process(self.clients.pop(name))

    def window(self, id):
        return next(w for w in self.ipc.get_windows() if w["id"] == id)

    def frame(self, id):
        box = self.ipc.get_window_debug(id)["chrome_box"]
        return tuple(round(box[k]) for k in ("x", "y", "width", "height"))

    def workspace(self, id):
        return next(w for w in self.ipc.get_workspaces() if w["id"] == id)

    def settled(self, id):
        self.ipc.wait_for("window_geometry_settled", window_id=id, timeout_ms=10000)

    def settle_all(self):
        for window in self.ipc.get_windows():
            self.settled(window["id"])

    def shown(self, id):
        output = self.ipc.get_outputs()[0]
        x, _, width, _ = self.frame(id)
        return x < output["x"] + output["logical_width"] and x + width > output["x"]

    def set_mode(self, mode):
        self.ipc.action("set_desktop_mode", {"mode": mode, "persist": False})
        layout = {"canvas": None, "workspaces": "split", "scrolling": "scrolling"}[mode]
        wait_for(lambda: self.ipc.get_workspaces()[0]["name"] == "Canvas" if layout is None
                 else self.ipc.get_workspaces()[0]["layout"] == layout, "mode " + mode)
        self.ipc.wait_for_frame()

    def chord(self, key, shift=False, ctrl=False):
        self.ipc.key(125, True)
        if shift: self.ipc.key(42, True)
        if ctrl: self.ipc.key(29, True)
        self.ipc.key_press(key)
        if ctrl: self.ipc.key(29, False)
        if shift: self.ipc.key(42, False)
        self.ipc.key(125, False)

    def stop(self):
        for child in self.clients.values(): stop_process(child)
        self.clients = {}
        self.ipc.__exit__(None, None, None)
        stop_process(self.process)
        self.log.close()

    def dump_log(self):
        print((self.tmp / "compositor.log").read_text()[-6000:])


BASE = '''[compositor]
xwayland = false
desktop_mode = "{mode}"
window_gap = 8
'''
MOTION_OFF = '''[animations]
enabled = false
'''


def mode_memory():
    """Switching to Canvas and back keeps the tiled layout (plan fix 7)."""
    with tempfile.TemporaryDirectory(prefix="rediwm-mode-memory-") as directory:
        tmp = Path(directory)
        build_client(tmp)
        s = Session(tmp, BASE.format(mode="workspaces") + MOTION_OFF)
        try:
            ipc = s.ipc
            a = s.launch("memory-a")
            b = s.launch("memory-b")
            wait_for(lambda: s.frame(a)[0] < s.frame(b)[0], "two tiles")
            ipc.action("tiling_action", {"action": "resize_split_right", "id": a})
            ipc.action("tiling_action", {"action": "resize_split_right", "id": a})
            wait_for(lambda: s.frame(a)[2] > s.frame(b)[2], "a wider than b")
            c = s.launch("memory-c")
            ipc.action("move_to_workspace", {"id": c, "workspace": 2})
            ipc.action("set_workspace_layout", {"workspace": 4, "layout": "floating"})
            ipc.action("set_workspace_layout", {"workspace": 3, "layout": "scrolling"})
            ipc.action("switch_workspace", {"workspace": 1})
            for id in (a, b): s.settled(id)
            before = {id: s.frame(id) for id in (a, b)}
            nodes = s.workspace(1)["nodes"]
            ipc.action("switch_workspace", {"workspace": 2})
            s.settled(c)
            c_before = s.frame(c)

            s.set_mode("canvas")
            assert all(w["workspace_id"] == 1 for w in ipc.get_windows())
            d = s.launch("memory-d")
            s.launch("memory-e")
            s.close("memory-e")
            wait_for(lambda: all(w["app_id"] != "memory-e" for w in ipc.get_windows()), "e closed")

            # Super+Shift+W returns to the tiled mode used last, as it was.
            s.chord("w", shift=True)
            wait_for(lambda: ipc.get_workspaces()[0]["name"] != "Canvas", "back to workspaces")
            assert ipc.get_workspaces()[0]["layout"] == "split"
            assert next(w["id"] for w in ipc.get_workspaces() if w["is_focused"]) == 2
            assert s.window(c)["workspace_id"] == 2 and s.window(a)["workspace_id"] == 1 == s.window(b)["workspace_id"]
            assert s.workspace(4)["layout"] == "floating" and s.workspace(3)["layout"] == "scrolling", ipc.get_workspaces()
            # The window opened on the canvas joins the shown workspace as a new tile.
            assert s.window(d)["workspace_id"] == 2, s.window(d)
            wait_for(lambda: s.frame(c)[2] < c_before[2], "new window shares workspace 2")
            ipc.action("switch_workspace", {"workspace": 1})
            for id in (a, b): s.settled(id)
            assert {id: s.frame(id) for id in (a, b)} == before, (before, {id: s.frame(id) for id in (a, b)})
            assert s.workspace(1)["nodes"] == nodes, (nodes, s.workspace(1)["nodes"])

            # Each tiled mode is remembered: Scrolling comes back from Canvas too.
            s.set_mode("scrolling")
            assert s.workspace(1)["layout"] == "scrolling" and s.workspace(4)["layout"] == "floating"
            s.chord("w", shift=True)
            wait_for(lambda: ipc.get_workspaces()[0]["name"] == "Canvas", "canvas again")
            s.chord("w", shift=True)
            wait_for(lambda: ipc.get_workspaces()[0].get("layout") == "scrolling", "back to scrolling")
            assert s.process.poll() is None
        except Exception:
            s.dump_log()
            raise
        finally:
            s.stop()
    print("PASS: tiled layout kept across Canvas", flush=True)


def mode_entry():
    """An existing stack joins the strip except where settings opt out."""
    with tempfile.TemporaryDirectory(prefix="rediwm-scroll-entry-") as directory:
        tmp = Path(directory)
        build_client(tmp)
        hints = tmp / "fixed.hints"
        hints.write_text("240 160 240 160")
        config = BASE.format(mode="canvas") + 'floating_apps = ["entry-app-float"]\n' + MOTION_OFF + '''
[keybinds]
"Super+F11" = "tile_left"
[[window_rules]]
app_id = "entry-rule-float"
floating = true
'''
        s = Session(tmp, config)
        try:
            ipc = s.ipc
            snapped = s.launch("entry-snapped")
            s.chord("F11")
            maximized = s.launch("entry-maximized")
            ipc.maximize(maximized)
            fullscreen = s.launch("entry-fullscreen")
            ipc.fullscreen(fullscreen)
            fixed = s.launch("entry-fixed", REDIWM_TEST_CONSTRAINTS=str(hints))
            floats = [s.launch(name) for name in ("entry-app-float", "entry-rule-float")]
            s.settle_all()
            original = {snapped: "manual", maximized: "maximized", fullscreen: "fullscreen"}
            assert all(s.window(id)["placement"] == value for id, value in original.items())

            def check_strip():
                ids = [snapped, maximized, fullscreen, fixed]
                wait_for(lambda: all(s.window(id)["placement"] == "automatic" for id in ids), "existing windows join the strip")
                s.settle_all()
                frames = sorted((s.frame(id), id) for id in ids)
                assert all(a[0] + a[2] <= b[0] for (a, _), (b, _) in zip(frames, frames[1:])), frames
                assert all(s.window(id)["placement"] == "floating" for id in floats)
                box = ipc.get_window_debug(fixed)["client_box"]
                assert (box["width"], box["height"]) == (240, 160), box
                ipc.focus_window(frames[0][1])
                for _, id in frames[1:]:
                    s.chord("Right")
                    assert ipc.get_focused_window()["id"] == id
                s.settle_all()
                assert s.shown(frames[-1][1])

            s.set_mode("scrolling")
            check_strip()
            s.set_mode("canvas")
            s.settle_all()
            assert all(s.window(id)["placement"] == value for id, value in original.items())

            s.set_mode("workspaces")
            floating_workspace = s.launch("entry-floating-workspace")
            ipc.action("move_to_workspace", {"id": floating_workspace, "workspace": 2})
            ipc.action("set_workspace_layout", {"workspace": 2, "layout": "floating"})
            ipc.action("move_window_to", {"id": fixed, "x": 12, "y": 12})
            s.set_mode("scrolling")
            check_strip()
            assert s.workspace(2)["layout"] == "floating" and s.window(floating_workspace)["placement"] == "floating"
        except Exception:
            s.dump_log()
            raise
        finally:
            s.stop()
    print("PASS: existing windows join the strip and configured floats stay out", flush=True)


def entry_keys():
    with tempfile.TemporaryDirectory(prefix="rediwm-scroll-entry-keys-") as directory:
        tmp = Path(directory)
        build_client(tmp)
        s = Session(tmp, BASE.format(mode="workspaces") + MOTION_OFF)
        try:
            s.launch("entry-first")
            middle = s.launch("entry-middle")
            last = s.launch("entry-last")
            s.settle_all()
            assert s.ipc.get_focused_window()["id"] == last

            # Send the mode switch and Super+Left in one IPC dispatch, before
            # the Wayland event loop can run the scheduled tiling reflow.
            requests = [
                ("set_desktop_mode", {"mode": "scrolling", "persist": False}),
                ("key", {"keycode": 125, "pressed": True}),  # Super
                ("key", {"keycode": 105, "pressed": True}),  # Left
                ("key", {"keycode": 105, "pressed": False}),
                ("key", {"keycode": 125, "pressed": False}),
                ("focused_window", {}),
            ]
            lines = [json.dumps({"version": 1, "command": cmd, "params": params}) for cmd, params in requests]
            replies = [s.ipc.send_raw("\n".join(lines))]
            replies.extend(json.loads(s.ipc.reader.readline()) for _ in lines[1:])
            assert all("Ok" in reply for reply in replies), replies
            focused = replies[-1]["Ok"]["FocusedWindow"]
            assert focused["id"] == middle, focused
        except Exception:
            s.dump_log()
            raise
        finally:
            s.stop()
    print("PASS: the first arrow after switching mode uses the new strip", flush=True)


def workspace_entry():
    with tempfile.TemporaryDirectory(prefix="rediwm-scroll-workspace-entry-") as directory:
        tmp = Path(directory)
        build_client(tmp)
        config = BASE.format(mode="workspaces") + 'floating_apps = ["entry-float"]\n' + MOTION_OFF + '''
[keybinds.workspace]
"Super+F11" = "tile_left"
'''
        s = Session(tmp, config)
        try:
            floating = s.launch("entry-float")
            ids = [s.launch(name) for name in ("entry-first", "entry-middle", "entry-last")]
            for id in ids:
                s.ipc.focus_window(id)
                s.chord("F11")
            s.settle_all()
            snapped = [s.frame(id) for id in ids]
            assert all(s.window(id)["placement"] == "manual" for id in ids)
            assert snapped[0] == snapped[1] == snapped[2], snapped

            def enter_scrolling():
                s.ipc.action("set_workspace_layout", {"workspace": 1, "layout": "scrolling"})
                s.ipc.wait_for_frame()
                columns = [[m["id"] for m in c["members"]] for c in s.workspace(1)["columns"]]
                assert columns == [[s.window(id)["workspace_order"]] for id in ids], columns
                assert s.window(floating)["placement"] == "floating"

            enter_scrolling()
            s.chord("z")
            s.settle_all()
            assert s.workspace(1)["layout"] == "split"
            assert all(s.window(id)["placement"] == "manual" for id in ids)
            assert [s.frame(id) for id in ids] == snapped

            s.ipc.focus_window(ids[-1])
            enter_scrolling()
            for id in reversed(ids[:-1]):
                s.chord("Left")
                assert s.ipc.get_focused_window()["id"] == id
        except Exception:
            s.dump_log()
            raise
        finally:
            s.stop()
    print("PASS: snapped windows join a scrolling workspace and undo restores their snaps", flush=True)


def keyboard_strip():
    """Columns, the view following focus, strip-order keys and culling."""
    with tempfile.TemporaryDirectory(prefix="rediwm-scrolling-") as directory:
        tmp = Path(directory)
        compile_fixture(tmp)
        s = Session(tmp, BASE.format(mode="scrolling"))
        try:
            ipc = s.ipc

            def strip():
                return s.workspace(1)

            def order(id):
                return s.window(id)["workspace_order"]

            def columns():
                return [[m["id"] for m in c["members"]] for c in strip()["columns"]]

            a = s.launch("strip-a")
            b = s.launch("strip-b")
            c = s.launch("strip-c")
            s.settle_all()
            # Each window opens as a column after the focused one; none resize.
            assert columns() == [[order(a)], [order(b)], [order(c)]], strip()
            assert strip()["layout"] == "scrolling" and strip()["direction"] == "horizontal"
            assert all(col["width"] == 0.5 for col in strip()["columns"])
            assert s.frame(a)[2] == s.frame(b)[2] == s.frame(c)[2]
            # The view followed the newest column; the first one left the screen
            # and is culled (its surface is on no output), yet keeps its place.
            assert strip()["view"] > 0 and s.shown(c) and not s.shown(a), (strip(), s.frame(a))
            wait_for(lambda: ipc.get_window_debug(a)["outputs"] == [], "culled column leaves the output")
            assert s.window(a)["workspace_id"] == 1

            # Super+Left walks the strip; the view scrolls only when it must.
            view = strip()["view"]
            s.chord("Left")
            assert ipc.get_focused_window()["id"] == b and strip()["view"] == view
            s.chord("Left")
            s.settle_all()
            assert ipc.get_focused_window()["id"] == a and strip()["view"] == 0 and s.shown(a)
            wait_for(lambda: ipc.get_window_debug(a)["outputs"] != [], "revealed column shows again")
            assert not s.shown(c)

            # Fix 1: scrolling moves windows without configuring them.
            d = s.launch("strip-d")
            s.settle_all()
            assert columns() == [[order(a)], [order(d)], [order(b)], [order(c)]], strip()
            ipc.focus_window(c)
            s.settle_all()
            assert strip()["view"] > 0
            serials = {id: ipc.get_window_debug(id)["configure_serial"] for id in (b, d)}
            positions = {id: s.frame(id)[0] for id in (b, d)}
            ipc.focus_window(a)
            s.settle_all()
            assert strip()["view"] == 0
            for id in (b, d):
                assert s.frame(id)[0] > positions[id]
                assert ipc.get_window_debug(id)["configure_serial"] == serials[id]

            # Width presets and manual steps act on the focused column.
            s.chord("w")
            wait_for(lambda: strip()["columns"][0]["width"] > 0.66, "Super+W widens")
            s.chord("Right", ctrl=True)
            wait_for(lambda: strip()["columns"][0]["width"] > 0.67, "Super+Ctrl+Right steps wider")
            s.settled(a)
            width = s.frame(a)[2]
            s.chord("z")
            wait_for(lambda: s.frame(a)[2] < width, "undo the manual width")

            # D was inserted immediately after A. Consume it into A, then
            # expel it to the right and swap its column with B.
            ipc.focus_window(d)
            s.chord("bracketleft")
            wait_for(lambda: columns()[0] == [order(a), order(d)], "d joins a's column")
            s.settle_all()
            assert s.frame(a)[0] == s.frame(d)[0] and s.frame(a)[1] < s.frame(d)[1]
            s.chord("Up")
            assert ipc.get_focused_window()["id"] == a
            s.chord("Down")
            assert ipc.get_focused_window()["id"] == d
            s.chord("bracketright")
            wait_for(lambda: columns()[:2] == [[order(a)], [order(d)]], "d leaves for a column of its own")
            s.chord("Right", shift=True)
            wait_for(lambda: columns() == [[order(a)], [order(b)], [order(d)], [order(c)]], "column moved right")

            # Fix 8: a floating window stays above the strip when a tile takes focus.
            s.settle_all()
            ipc.action("tiling_action", {"action": "toggle_floating", "id": d})
            wait_for(lambda: s.window(d)["placement"] == "floating", "d floats")
            ipc.action("move_window_to", {"id": d, "x": 100, "y": 100})
            s.settle_all()
            ipc.focus_window(a)
            s.settle_all()
            fx, fy, fw, fh = s.frame(d)
            ax, ay, aw, ah = s.frame(a)
            x, y = max(fx, ax) + 10, max(fy, ay) + 40
            assert x < min(fx + fw, ax + aw) and y < min(fy + fh, ay + ah), (s.frame(d), s.frame(a))
            assert ipc.hit_test(x, y).get("window_id") == d, ipc.hit_test(x, y)
            # It stays put while the strip scrolls.
            ipc.focus_window(c)
            s.settle_all()
            assert strip()["view"] > 0 and s.frame(d)[:2] == (fx, fy)

            # A newly mapped tile also starts underneath an existing float.
            e = s.launch("strip-e")
            s.settle_all()
            ex, ey, _, _ = s.frame(e)
            ipc.action("move_window_to", {"id": d, "x": ex + 20, "y": ey + 40})
            s.settle_all()
            assert ipc.get_focused_window()["id"] == e
            assert ipc.hit_test(ex + 55, ey + 95).get("window_id") == d

            # A suspended column keeps its slot; a maximized tile covers the
            # float, and the float is above it again once restored.
            saved_columns = columns()
            ipc.maximize(e)
            wait_for(lambda: s.window(e)["is_maximized"], "e acknowledges maximize")
            s.settle_all()
            assert columns() == saved_columns, (columns(), saved_columns)
            assert ipc.hit_test(ex + 55, ey + 95).get("window_id") == e

            check_reveal_behind_maximized(s, a, c, e)
            ipc.focus_window(e)
            assert ipc.hit_test(ex + 55, ey + 95).get("window_id") == e

            ipc.restore(e)
            wait_for(lambda: not s.window(e)["is_maximized"], "e acknowledges restore")
            s.settle_all()
            assert columns() == saved_columns, (columns(), saved_columns)
            assert ipc.hit_test(ex + 55, ey + 95).get("window_id") == d

            # Mapping on a different workspace leaves this one's view alone.
            before_view = strip()["view"]
            ipc.action("switch_workspace", {"workspace": 2})
            s.launch("other-workspace")
            assert strip()["view"] == before_view
            ipc.action("switch_workspace", {"workspace": 1})
            s.settle_all()
            assert strip()["view"] == before_view

            check_dialog(s, a)
            assert s.process.poll() is None
        except Exception:
            s.dump_log()
            raise
        finally:
            s.stop()
    print("PASS: strip columns, view, keys, culling, move-only scrolls and the floating layer", flush=True)


def check_reveal_behind_maximized(s, first, last, maximized):
    """Keyboard reveals stay visible after a maximized window loses focus,
    and arrows still stop at the maximized window's column (right of `last`)."""
    s.ipc.focus_window(last)
    assert s.workspace(1)["view"] > 0
    s.chord("Left")
    s.chord("Left")
    s.settle_all()
    assert s.ipc.get_focused_window()["id"] == first and s.workspace(1)["view"] == 0
    x, y, width, height = s.frame(first)
    assert s.ipc.hit_test(x + width // 2, y + height // 2).get("window_id") == first
    assert s.window(maximized)["is_maximized"]

    s.ipc.focus_window(last)
    s.chord("Right")
    s.settle_all()
    assert s.ipc.get_focused_window()["id"] == maximized and s.window(maximized)["is_maximized"]
    s.chord("Left")
    s.settle_all()
    assert s.ipc.get_focused_window()["id"] == last and s.shown(last)
    s.ipc.focus_window(first)
    s.settle_all()


def check_dialog(s, first):
    """Focusing a culled modal dialog reveals its owner and keeps their offset."""
    ipc = s.ipc
    dialog_client = subprocess.Popen([str(s.tmp / "fixture"), "xdg-dialog", "modal"],
        env=s.env, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL)
    s.clients["dialogs"] = dialog_client

    def by_app(app_id):
        return next((w["id"] for w in ipc.get_windows() if w["app_id"] == app_id), None)

    dialog = wait_for(lambda: by_app("rediwm.dialog"), "dialog maps")
    owner = by_app("rediwm.dialog-owner")
    wait_for(lambda: ipc.get_focused_window()["id"] == dialog, "dialog has focus")

    def offset():
        ox, oy, _, _ = s.frame(owner)
        dx, dy, _, _ = s.frame(dialog)
        return dx - ox, dy - oy

    s.settle_all()
    relative = offset()
    ipc.focus_window(first)
    s.settle_all()
    assert not s.shown(owner) and offset() == relative
    ipc.focus_window(dialog)
    s.settle_all()
    assert s.shown(owner) and s.shown(dialog) and offset() == relative

    # Canvas and back keeps the columns and their widths.
    before = s.workspace(1)["columns"]
    s.set_mode("canvas")
    s.set_mode("scrolling")
    s.settle_all()
    assert s.workspace(1)["columns"] == before, (before, s.workspace(1)["columns"])
    assert offset() == relative, (relative, offset())


def strip_restart():
    """Real window identities, column sizes, cross weights and view survive a restart."""
    with tempfile.TemporaryDirectory(prefix="rediwm-scrolling-restart-") as directory:
        tmp = Path(directory)
        build_client(tmp)
        names = ("restart-a", "restart-b", "restart-c", "restart-d")
        expected = None
        for phase, mode in enumerate(("scrolling", "canvas", "scrolling")):
            run = tmp / f"run{phase}"
            run.mkdir()
            (run / "client").symlink_to(tmp / "client")
            s = Session(run, BASE.format(mode=mode) + MOTION_OFF, state=tmp / "state")
            try:
                ids = {name: s.launch(name) for name in (names if phase == 0 else reversed(names))}
                if phase == 0:
                    c, d = ids["restart-c"], ids["restart-d"]
                    s.ipc.focus_window(d)
                    s.chord("bracketleft")
                    wait_for(lambda: len(s.workspace(1)["columns"]) == 3, "two members in trailing column")
                    s.ipc.focus_window(c)
                    s.chord("w")
                    s.chord("Right", ctrl=True)
                    s.chord("Down", ctrl=True)
                elif mode == "canvas":
                    s.chord("w", shift=True)
                    wait_for(lambda: s.workspace(1).get("layout") == "scrolling", "restore last tiled mode after login")

                def snapshot():
                    ws = s.workspace(1)
                    return ws["columns"], ws["view"], {name: s.window(id)["workspace_order"] for name, id in ids.items()}

                for id in ids.values():
                    s.settled(id)
                if phase == 0:
                    expected = snapshot()
                    cols, view, _ = expected
                    assert view > 0 and cols[-1]["width"] > 0.67 and cols[-1]["members"][0]["weight"] != 1, expected
                else:
                    assert snapshot() == expected, (mode, expected, snapshot())
                    assert s.ipc.get_focused_window()["app_id"] == "restart-c", (mode, s.ipc.get_focused_window())
                if phase < 2:
                    s.set_mode("canvas")  # flush the workspace snapshot with the clients still mapped
            except Exception:
                s.dump_log()
                raise
            finally:
                s.stop()
    print("PASS: restart keeps scrolling mode, columns, widths, weights and view", flush=True)


if __name__ == "__main__":
    only = sys.argv[1] if len(sys.argv) > 1 else None
    if only in (None, "memory"): mode_memory()
    if only in (None, "entry"): mode_entry()
    if only in (None, "entry-keys"): entry_keys()
    if only in (None, "workspace-entry"): workspace_entry()
    if only in (None, "keyboard"): keyboard_strip()
    if only in (None, "restart"): strip_restart()
    if only in (None, "outputs"):
        from scrolling_outputs import multi_output_strip
        multi_output_strip()
    if only in (None, "direction"):
        from scrolling_direction import direction_strip
        direction_strip()
    if only in (None, "gestures"):
        from scrolling_gestures import gestures
        gestures()
    if only in (None, "polish"):
        from scrolling_polish import polish
        polish()
    if only == "x11" or (only is None and os.getenv("REDIWM_TEST_XWAYLAND") == "1"):
        from scrolling_xwayland import x11_strip_clicks
        x11_strip_clicks()

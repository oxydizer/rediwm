#!/usr/bin/env python3
"""Input sources: keyboard layouts and Fcitx5 input methods.

Runs on a private dbus-run-session (the session bus Fcitx would use), with a
fake org.fcitx.Fcitx5 controller; the host's real Fcitx and buses are never
reached. Covers:
- Layout labels (registry language codes, a configured override), the
  automatic taskbar item, its click menu, Super+Shift+Space, IPC switching,
  scrolling over the item and the `rediwm-msg` commands.
- Fcitx read and switch only: its group's methods join the list (keyboards
  left out), switching calls SetCurrentIM / Deactivate, a change made inside
  Fcitx follows from any signal it emits, a group change re-reads the list,
  and the methods go when Fcitx leaves the bus. RediWM never calls a method
  that writes Fcitx's configuration.
- Settings → Input → Input Sources: add from the registry search, reorder
  (the active layout keeps its place by identity), remove, "Show in taskbar".
Requires PyGObject and dbus-run-session.
"""
import json
import os
from pathlib import Path
import re
import select
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
from ipc_client import IPCClient, IPCError, ROOT, spawn_compositor, stop_process
from ui_driver import UIDriver

FAKE_FCITX = r'''
import json, sys, warnings
warnings.simplefilter("ignore", DeprecationWarning)
from gi.repository import Gio, GLib

NAME = "org.fcitx.Fcitx5"
XML = """<node><interface name='org.fcitx.Fcitx.Controller1'>
<method name='CurrentInputMethod'><arg type='s' direction='out'/></method>
<method name='SetCurrentIM'><arg type='s' direction='in'/></method>
<method name='Activate'/><method name='Deactivate'/><method name='Toggle'/>
<method name='State'><arg type='i' direction='out'/></method>
<method name='CurrentInputMethodGroup'><arg type='s' direction='out'/></method>
<method name='InputMethodGroupInfo'><arg type='s' direction='in'/><arg type='s' direction='out'/><arg type='a(ss)' direction='out'/></method>
<method name='AvailableInputMethods'><arg type='a(ssssssb)' direction='out'/></method>
<method name='SetInputMethodGroupInfo'><arg type='s' direction='in'/><arg type='s' direction='in'/><arg type='a(ss)' direction='in'/></method>
<method name='AddInputMethodGroup'><arg type='s' direction='in'/></method>
<signal name='InputMethodGroupsChanged'/>
</interface></node>"""
TRAY = "<node><interface name='org.kde.StatusNotifierItem'><signal name='NewIcon'/></interface></node>"

state = {"current": "keyboard-us", "group": ["keyboard-us", "mozc", "pinyin"]}
AVAILABLE = [
    ("keyboard-us", "English (US)", "", "input-keyboard", "us", "en", True),
    ("mozc", "Mozc", "Mozc", "fcitx-mozc", "あ", "ja", True),
    ("pinyin", "Pinyin", "拼音", "fcitx-pinyin", "", "zh_CN", True),
]
conn = Gio.bus_get_sync(Gio.BusType.SESSION)

def emit(path, iface, member):
    conn.emit_signal(None, path, iface, member, None)
    conn.flush_sync()

def call(c, sender, path, iface, method, params, invocation):
    print(json.dumps({"call": method, "args": list(params.unpack())}), flush=True)
    if method == "CurrentInputMethod":
        invocation.return_value(GLib.Variant("(s)", (state["current"],)))
    elif method == "SetCurrentIM":
        state["current"] = params.unpack()[0]
        invocation.return_value(None)
        emit("/StatusNotifierItem", "org.kde.StatusNotifierItem", "NewIcon")
    elif method == "Deactivate":
        state["current"] = state["group"][0]
        invocation.return_value(None)
        emit("/StatusNotifierItem", "org.kde.StatusNotifierItem", "NewIcon")
    elif method == "State":
        invocation.return_value(GLib.Variant("(i)", (1,)))
    elif method == "CurrentInputMethodGroup":
        invocation.return_value(GLib.Variant("(s)", ("Default",)))
    elif method == "InputMethodGroupInfo":
        invocation.return_value(GLib.Variant("(sa(ss))", ("us", [(name, "") for name in state["group"]])))
    elif method == "AvailableInputMethods":
        invocation.return_value(GLib.Variant("(a(ssssssb))", (AVAILABLE,)))
    else:
        invocation.return_value(None)

def on_stdin(channel, cond):
    line = sys.stdin.readline()
    if not line:
        return False
    req = json.loads(line)
    if req["action"] == "external":
        state["current"] = req["method"]
        emit("/StatusNotifierItem", "org.kde.StatusNotifierItem", "NewIcon")
    elif req["action"] == "group":
        state["group"] = req["methods"]
        emit("/controller", "org.fcitx.Fcitx.Controller1", "InputMethodGroupsChanged")
    print(json.dumps({"done": req["action"]}), flush=True)
    return True

GLib.io_add_watch(sys.stdin.fileno(), GLib.IO_IN, on_stdin)
conn.register_object("/controller", Gio.DBusNodeInfo.new_for_xml(XML).interfaces[0], call, None, None)
conn.register_object("/StatusNotifierItem", Gio.DBusNodeInfo.new_for_xml(TRAY).interfaces[0], None, None, None)
Gio.bus_own_name_on_connection(conn, NAME, Gio.BusNameOwnerFlags.NONE, lambda *_: print("ready", flush=True), None)
GLib.MainLoop().run()
'''

KEY_LEFTMETA, KEY_LEFTSHIFT, KEY_SPACE = 125, 42, 57
WRITES = {"SetInputMethodGroupInfo", "AddInputMethodGroup"}
ANSI_RE = re.compile(r'\x1b\[[0-9;]*[mK]')


def wait_for(predicate, description, timeout=5.0, interval=0.05):
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        last = predicate()
        if last:
            return last
        time.sleep(interval)
    raise AssertionError(f"timed out waiting for {description}")


class Fake:
    def __init__(self):
        self.process = subprocess.Popen([sys.executable, "-c", FAKE_FCITX], stdout=subprocess.PIPE, stdin=subprocess.PIPE, text=True)
        assert select.select([self.process.stdout], [], [], 5)[0], "fake Fcitx did not start"
        assert self.process.stdout.readline().strip() == "ready"
        self.calls = []

    def drain(self, timeout=0.0):
        while select.select([self.process.stdout], [], [], timeout)[0]:
            line = self.process.stdout.readline()
            if not line:
                break
            value = json.loads(line)
            if "call" in value:
                self.calls.append(value)
            timeout = 0.0
        return self.calls

    def called(self, method, arg=None):
        def check():
            self.drain(0.05)
            return any(c["call"] == method and (arg is None or c["args"] == [arg]) for c in self.calls)
        return check

    def command(self, action, **fields):
        self.process.stdin.write(json.dumps({"action": action, **fields}) + "\n")
        self.process.stdin.flush()
        while True:
            assert select.select([self.process.stdout], [], [], 5)[0], "no reply from fake Fcitx"
            value = json.loads(self.process.stdout.readline())
            if "call" in value:
                self.calls.append(value)
            elif value == {"done": action}:
                return

    def stop(self):
        self.drain()
        self.process.terminate()
        self.process.wait(timeout=5)


def sources(ipc):
    return ipc.query("get_input_sources")


def indicator(ipc):
    widgets = ipc.get_widget_tree("taskbar").get("widgets", [])
    return next((w for w in widgets if w.get("path") == "taskbar/input_source"), None)


def super_shift_space(ipc):
    for code, pressed in ((KEY_LEFTMETA, True), (KEY_LEFTSHIFT, True), (KEY_SPACE, True), (KEY_SPACE, False), (KEY_LEFTSHIFT, False), (KEY_LEFTMETA, False)):
        ipc.key(code, pressed)
        time.sleep(0.02)


def active_is(ipc, index, label=None):
    def check():
        data = sources(ipc)
        if data["active"] != index:
            return False
        widget = indicator(ipc)
        return label is None or (widget is not None and widget.get("label") == label)
    return check


def test_switching(tmp):
    config = '[input]\nxkb_layout = "us,de,jp"\nxkb_labels = ",,JP"\n'
    process, log = spawn_compositor(tmp, config_content=config)
    fake = None
    try:
        with IPCClient(tmp, timeout=15) as ipc:
            ipc.wait_for("wallpaper_presented", timeout_ms=10000)
            ui = UIDriver(ipc)
            # The registry loads on a worker; labels settle when it is done.
            data = wait_for(lambda: (lambda d: d if [s["label"] for s in d["sources"]] == ["EN", "DE", "JP"] else None)(sources(ipc)), "layout labels")
            assert [s["kind"] for s in data["sources"]] == ["xkb"] * 3 and data["active"] == 0, data
            assert data["sources"][1]["id"] == "de" and data["sources"][1]["name"] == "German", data
            assert data["fcitx_running"] is False
            assert wait_for(lambda: indicator(ipc), "automatic indicator")["label"] == "EN"

            # The taskbar item opens the list; a row switches.
            ipc.click_widget(path="taskbar/input_source")
            ipc.wait_for_widget_present("input_sources/source_1")
            assert ui.find("input_settings", panel="input_sources")
            ipc.click_widget(path="input_sources/source_1")
            wait_for(active_is(ipc, 1, "DE"), "menu switch to DE")
            ipc.wait_for_widget_absent("input_sources/source_1")

            super_shift_space(ipc)
            wait_for(active_is(ipc, 2, "JP"), "shortcut to JP")
            super_shift_space(ipc)
            wait_for(active_is(ipc, 0, "EN"), "shortcut wraps to EN")
            ipc.action("switch_input_source", {"source": "prev"})
            wait_for(active_is(ipc, 2), "IPC prev")
            try:
                ipc.action("switch_input_source", {"source": 9})
                raise AssertionError("an out-of-range source was accepted")
            except IPCError as err:
                assert "InvalidSourceIndex" in str(err), err

            # Scrolling over the item steps through the sources.
            box = indicator(ipc)["global_box"]
            ipc.move_cursor(box["x"] + box["width"] // 2, box["y"] + box["height"] // 2)
            ipc.scroll(0, 120)
            wait_for(lambda: sources(ipc)["active"] != 2, "scroll switches")

            cli = [str(ROOT / "zig-out/bin/rediwm-msg"), "--socket", str(next(tmp.glob("rediwm-*.sock")))]
            assert json.loads(subprocess.check_output(cli + ["--json", "input-sources"], text=True)) == sources(ipc)
            subprocess.run(cli + ["switch-input-source", "1"], check=True, capture_output=True)
            wait_for(active_is(ipc, 1), "CLI switch")

            # Fcitx joins: its non-keyboard methods follow the layouts.
            fake = Fake()
            data = wait_for(lambda: (lambda d: d if len(d["sources"]) == 5 else None)(sources(ipc)), "Fcitx methods listed")
            assert data["fcitx_running"] is True
            assert [s["id"] for s in data["sources"][3:]] == ["mozc", "pinyin"], data
            assert [s["label"] for s in data["sources"][3:]] == ["あ", "ZH"], data
            assert data["active"] == 1, "keyboard-us in Fcitx keeps RediWM's layout active"

            ipc.action("switch_input_source", {"source": 3})
            wait_for(fake.called("SetCurrentIM", "mozc"), "SetCurrentIM mozc")
            wait_for(active_is(ipc, 3, "あ"), "Mozc active")
            assert sources(ipc)["active_layout"] == 1
            ipc.action("switch_input_source", {"source": 0})
            wait_for(fake.called("Deactivate"), "Deactivate for a layout")
            wait_for(active_is(ipc, 0, "EN"), "layout after Mozc")

            # A switch made inside Fcitx (its own hotkey or tray menu).
            fake.command("external", method="pinyin")
            wait_for(active_is(ipc, 4, "ZH"), "external Fcitx change")
            fake.command("group", methods=["keyboard-us", "mozc"])
            wait_for(lambda: len(sources(ipc)["sources"]) == 4, "group change re-read")
            assert sources(ipc)["active"] == 0, "the vanished method falls back to the layout"

            fake.stop()
            assert not (WRITES & {c["call"] for c in fake.calls}), fake.calls
            fake = None
            data = wait_for(lambda: (lambda d: d if not d["fcitx_running"] else None)(sources(ipc)), "Fcitx gone")
            assert len(data["sources"]) == 3 and data["active"] == 0, data
            assert process.poll() is None
    except Exception:
        print(ANSI_RE.sub("", (tmp / "compositor.log").read_text())[-6000:])
        raise
    finally:
        if fake is not None:
            fake.stop()
        stop_process(process)
        log.close()
    print("input_sources: labels, menu, shortcut, IPC, scroll, CLI and Fcitx read/switch")


def config_value(tmp, key):
    match = re.search(r'^' + key + r'\s*=\s*"([^"]*)"', (tmp / "rediwm-config.toml").read_text(), re.M)
    return match.group(1) if match else None


def test_settings(tmp):
    process, log = spawn_compositor(tmp, config_content='[input]\nxkb_layout = "us"\n')
    try:
        with IPCClient(tmp, timeout=15) as ipc:
            ipc.wait_for("wallpaper_presented", timeout_ms=10000)
            ui = UIDriver(ipc)

            def press(name):
                ui.wait_settled("control_center")
                ui.click(ui.scroll_into_view(name), panel="control_center")

            assert indicator(ipc) is None, "one layout shows no automatic indicator"
            ipc.action("open_control_center")
            ui.wait_settled("control_center")
            ui.click("Input", panel="control_center")
            ui.wait_settled("control_center")
            ui.scroll_into_view("input_source_add")
            assert ui.find("input_source_0", panel="control_center")
            assert ui.find("input_source_remove_0", panel="control_center")["is_disabled"] is True

            press("input_source_add")
            ipc.wait_for_widget_present("control_center/input_source_search")
            ipc.type_text("de(nodeadkeys)")
            ipc.wait_for_widget_present("control_center/input_source_result_0")
            ipc.wait_for_widget_absent("control_center/input_source_result_1")
            press("input_source_result_0")
            wait_for(lambda: config_value(tmp, "xkb_layout") == "us,de", "layout saved")
            assert config_value(tmp, "xkb_variant") == ",nodeadkeys"
            wait_for(lambda: len(sources(ipc)["sources"]) == 2, "reloaded with two layouts")
            wait_for(lambda: indicator(ipc), "indicator appears with a second layout")

            # The active layout keeps its place by identity across a reorder.
            ipc.action("switch_input_source", {"source": 1})
            wait_for(active_is(ipc, 1), "German active")
            press("input_source_up_1")
            wait_for(lambda: config_value(tmp, "xkb_layout") == "de,us", "reorder saved")
            assert config_value(tmp, "xkb_variant") == "nodeadkeys,"
            wait_for(lambda: sources(ipc)["sources"][0]["id"] == "de(nodeadkeys)", "reorder reloaded")
            assert sources(ipc)["active"] == 0, sources(ipc)

            press("input_source_remove_0")
            wait_for(lambda: config_value(tmp, "xkb_layout") == "us", "removal saved")
            wait_for(lambda: indicator(ipc) is None, "indicator hides again")

            # "Show in taskbar" → Always keeps it for a single layout.
            press("input_source_show")
            time.sleep(0.2)
            ipc.key_press("Down")
            ipc.key_press("Return")
            wait_for(lambda: '"right:input_source"' in (tmp / "rediwm-config.toml").read_text(), "taskbar item saved as always")
            assert wait_for(lambda: indicator(ipc), "indicator always shown")["label"] == "EN"
            assert process.poll() is None
    except Exception:
        print(ANSI_RE.sub("", (tmp / "compositor.log").read_text())[-6000:])
        raise
    finally:
        stop_process(process)
        log.close()
    print("input_sources: Settings add, reorder by identity, remove and taskbar visibility")


def main():
    if "--private" not in sys.argv:
        sys.exit(subprocess.call(["dbus-run-session", "--", sys.executable, __file__, "--private"]))
    for test in (test_switching, test_settings):
        with tempfile.TemporaryDirectory(prefix="rediwm-input-sources-") as directory:
            test(Path(directory))


if __name__ == "__main__":
    main()

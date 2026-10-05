#!/usr/bin/env python3
"""Real Wayland/X11 attention requests, IPC state/events and taskbar pixels."""
import json
import os
from pathlib import Path
import queue
import subprocess
import tempfile
import threading

from input_protocols import compile_client
from xwayland import ROOT, build_client, start_compositor, ipc_connect, request, wayland_display_name


class Peer:
    def __init__(self, args, env):
        self.process = subprocess.Popen(args, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.STDOUT, text=True)
        self.messages = queue.Queue()
        def collect():
            for line in self.process.stdout: self.messages.put(line.rstrip())
        threading.Thread(target=collect, daemon=True).start()

    def send(self, command):
        self.process.stdin.write(command + "\n")
        self.process.stdin.flush()

    def command(self, command):
        self.send(command)
        lines = []
        while True:
            line = self.messages.get(timeout=10)
            lines.append(line)
            if line == "ack " + command: return lines

    def token(self):
        return next(line.split()[1] for line in self.command("token-empty") if line.startswith("token "))

    def close(self):
        self.process.terminate()
        self.process.wait(timeout=5)


def main():
    with tempfile.TemporaryDirectory(prefix="rediwm-urgency-") as directory:
        tmp = Path(directory)
        compile_client(tmp)
        build_client(tmp)
        compositor, log = start_compositor(tmp, '[compositor]\nxwayland = true\n[animations]\nenabled = false\n')
        peers, connections = [], []
        try:
            sock, reader = ipc_connect(tmp)
            connections += [reader, sock]
            def req(value): return request(sock, reader, value)
            def act(name, **params): return req({"version": 1, "command": name, "params": params})
            def win(wid): return next(w for w in req({'version': 1, 'command': 'windows'})["Windows"] if w["id"] == wid)
            def focus(wid): act("focus_window", id=wid)
            stream, events = ipc_connect(tmp)
            connections += [events, stream]
            request(stream, events, {'version': 1, 'command': 'event_stream', 'params': {"events": ["window_opened", "window_closed", "window_changed", "window_urgency_changed"]}})
            assert "StateSnapshot" in json.loads(events.readline())
            pending = []
            def event(name, check=lambda _: True):
                while True:
                    obj = json.loads(events.readline())
                    if "WindowUrgencyChanged" in obj: pending.append(obj["WindowUrgencyChanged"])
                    if name in obj and check(obj[name]): return obj[name]
            def urgency(wid, value):
                event("WindowUrgencyChanged")
                changed = pending.pop(0)
                assert changed["id"] == wid and changed["urgent"] is value, changed
                assert not pending, pending
                assert win(wid)["is_urgent"] is value
                return changed
            env = dict(os.environ, XDG_RUNTIME_DIR=str(tmp), WAYLAND_DISPLAY=wayland_display_name(tmp))
            for name in ("urgency.first", "urgency.second"):
                peer = Peer([str(tmp / "protocol-client"), name], env)
                peers.append(peer)
                opened = event("WindowOpened", lambda e: e["window"]["app_id"] == name)["window"]
                assert opened["is_urgent"] is False
                peer.wid = opened["id"]
            first, second = peers
            focus(second.wid)
            act("move_cursor", x=1000, y=100)
            def chip():
                shell = req({'version': 1, 'command': 'get_shell_state', 'params': {}})["ShellState"]
                return next(c for tb in shell["taskbars"] for c in tb["chips"] if c["window_id"] == first.wid)
            def border_pixels():
                act("wait_for_frame")
                box = chip()["box"]
                return act("sample_pixels", x=box["x"] + box["width"] // 2 - 10,
                           y=box["y"], width=20, height=3)["SamplePixels"]["pixels"]
            idle_pixels = border_pixels()
            first.command("activate " + first.token())
            urgency(first.wid, True)
            assert win(second.wid)["is_focused"] and chip()["is_urgent"]
            assert border_pixels() != idle_pixels, "urgent taskbar border was not repainted"
            cli = [str(ROOT / "zig-out/bin/rediwm-msg"), "--socket", str(next(tmp.glob("rediwm-*.sock")))]
            assert "[urgent]" in subprocess.check_output(cli + ["windows"], text=True)

            state = req({'version': 1, 'command': 'get_state'})["State"]
            assert next(w for w in state["windows"] if w["id"] == first.wid)["is_urgent"]
            # New subscribers learn existing urgency from the snapshot.
            filtered_sock, filtered = ipc_connect(tmp)
            connections += [filtered, filtered_sock]
            request(filtered_sock, filtered, {"version": 1, "command": 'event_stream', "params": {"events": ["window_urgency_changed"], "window_id": first.wid}})
            snapshot = json.loads(filtered.readline())["StateSnapshot"]
            assert next(w for w in snapshot["windows"] if w["id"] == first.wid)["is_urgent"]
            # Duplicate attention requests must not generate another transition.
            first.command("activate " + first.token())
            focus(first.wid)
            urgency(first.wid, False)
            assert json.loads(filtered.readline())["WindowUrgencyChanged"]["urgent"] is False
            assert not req({'version': 1, 'command': 'focused_window'})["FocusedWindow"]["is_urgent"]
            first.command("activate " + first.token())  # already focused: ignored
            focus(second.wid)
            assert border_pixels() == idle_pixels, "taskbar border did not clear"
            first.command("activate unknown-token")
            assert not win(first.wid)["is_urgent"]
            act("minimize_window", id=first.wid)
            first.command("activate " + first.token())
            urgency(first.wid, True)
            assert win(first.wid)["is_minimized"] and win(second.wid)["is_focused"]
            act("restore_window", id=first.wid)
            urgency(first.wid, False)
            print("PASS: Wayland attention without focus theft, focused/invalid-token rejection, minimize/restore, snapshot/filter state and taskbar pixels")

            display = req({'version': 1, 'command': 'get_runtime_info'})["RuntimeInfo"]["xwayland_display"]
            xenv = dict(os.environ, DISPLAY=display, XDG_RUNTIME_DIR=str(tmp))
            xenv.pop("WAYLAND_DISPLAY", None)
            xenv.pop("XAUTHORITY", None)
            xpeer = Peer([str(tmp / "x11-client")], xenv)
            peers.append(xpeer)
            xid = event("WindowOpened", lambda e: e["window"]["backend"] == "xwayland")["window"]["id"]
            focus(second.wid)
            serial = 0
            def xcommand(command, expected=None):
                nonlocal serial
                serial += 1
                title = f"Urgency barrier {serial}"
                xpeer.send(command + "\ntitle " + title)
                event("WindowChanged", lambda e: e["window"]["id"] == xid and e["window"]["title"] == title)
                changes = pending[:]
                pending.clear()
                if expected is None: assert changes == [], changes
                else: assert len(changes) == 1 and changes[0]["id"] == xid and changes[0]["urgent"] is expected, changes
                return changes
            def demands_state():
                xpeer.send("demands-state")
                while True:
                    line = xpeer.messages.get(timeout=10)
                    if line.startswith("demands-state "): return line.endswith("1")
            xcommand("urgent 1", True)
            assert demands_state(), "X11 urgency was not published in _NET_WM_STATE"
            assert win(xid)["is_urgent"] and win(second.wid)["is_focused"]
            xcommand("urgent 1")
            xcommand("urgent 0", False)
            xcommand("demands 1", True)
            assert demands_state()
            xcommand("demands 0", False)
            assert not demands_state()
            xcommand("activate", True)
            assert win(second.wid)["is_focused"]
            focus(xid)
            urgency(xid, False)
            assert not demands_state(), "focus did not clear the X11 attention property"
            xcommand("urgent 1")  # focused requests cannot re-light the chip
            focus(second.wid)
            xcommand("urgent-input")  # unrelated hint change cannot reassert consumed urgency
            assert not win(xid)["is_urgent"]
            xcommand("urgent 0")
            xcommand("urgent 1", True)
            # Filtered stream must not receive any of the X11 window's events.
            # The two earlier first-window transitions must be next in order.
            for value in (True, False):
                change = json.loads(filtered.readline())["WindowUrgencyChanged"]
                assert change["id"] == first.wid and change["urgent"] is value
            first.command("activate " + first.token())
            urgency(first.wid, True)
            change = json.loads(filtered.readline())["WindowUrgencyChanged"]
            assert change["id"] == first.wid and change["urgent"] is True, change
            first.command("unmap")
            event("WindowClosed", lambda e: e["id"] == first.wid)
            first.command("activate " + first.token())
            xpeer.send("unmap")
            event("WindowClosed", lambda e: e["id"] == xid)
            xpeer.send("map")
            remapped = event("WindowOpened", lambda e: e["window"]["id"] == xid)["window"]
            assert not remapped["is_urgent"]
            print("PASS: X11 WM_HINTS, EWMH demands-attention, activation requests, focus acknowledgment, stale hints and remap")
        except Exception:
            print((tmp / "compositor.log").read_text()[-5000:])
            raise
        finally:
            for peer in peers: peer.close()
            for connection in connections: connection.close()
            compositor.terminate()
            compositor.wait(timeout=10)
            log.close()


if __name__ == "__main__":
    main()

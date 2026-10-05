#!/usr/bin/env python3
"""Cursor-shape protocol and policy tests on an isolated headless compositor."""
import os
from pathlib import Path
import re
import struct
import subprocess
import tempfile

from desktop_zoom import ROOT, wait_for
from ipc_client import IPCClient, spawn_compositor, stop_process

SHAPES = """default context-menu help pointer progress wait cell crosshair text
vertical-text alias copy move no-drop not-allowed grab grabbing e-resize n-resize
ne-resize nw-resize s-resize se-resize sw-resize w-resize ew-resize ns-resize
nesw-resize nwse-resize col-resize row-resize all-scroll zoom-in zoom-out dnd-ask
all-resize""".split()


def build_theme(tmp):
    # A minimal Xcursor theme makes name resolution independent of host themes.
    # Deliberately omit help to exercise the missing-shape fallback.
    cursors = tmp / "icons/default/cursors"
    cursors.mkdir(parents=True)
    image_type = 0xfffd0002
    header = struct.pack("<7I", 0x72756358, 16, 0x10000, 1, image_type, 32, 28)
    image = struct.pack("<9I", 36, image_type, 32, 1, 32, 32, 0, 0, 0)
    for name in SHAPES:
        if name != "help":
            (cursors / name).write_bytes(header + image + struct.pack("<I", 0xffffffff) * 1024)


def build_client(tmp):
    protocol_dir = Path(subprocess.check_output(
        ["pkg-config", "--variable=pkgdatadir", "wayland-protocols"], text=True).strip())
    sources = []
    for name, path in (
        ("xdg-shell", "stable/xdg-shell/xdg-shell.xml"),
        ("xdg-decoration", "unstable/xdg-decoration/xdg-decoration-unstable-v1.xml"),
        ("cursor-shape", "staging/cursor-shape/cursor-shape-v1.xml"),
        ("tablet", "stable/tablet/tablet-v2.xml"),
    ):
        for mode, suffix in (("client-header", "client-protocol.h"), ("private-code", "protocol.c")):
            subprocess.run(["wayland-scanner", mode, str(protocol_dir / path),
                            str(tmp / f"{name}-{suffix}")], check=True)
        sources.append(str(tmp / f"{name}-protocol.c"))
    subprocess.run(["cc", "-Wall", "-Wextra", "-Werror", f"-I{tmp}",
                    str(ROOT / "tests/cursor_shape_client.c"), *sources,
                    "-lwayland-client", "-o", str(tmp / "client")], check=True)


class Client:
    def __init__(self, tmp, display, name, version=2):
        self.path = tmp / f"{name}.log"
        self.commands = 0
        with self.path.open("w") as log:
            self.process = subprocess.Popen(
                [str(tmp / "client"), name, str(version)],
                env=dict(os.environ, XDG_RUNTIME_DIR=str(tmp), WAYLAND_DISPLAY=display),
                stdin=subprocess.PIPE, stdout=log, stderr=log, text=True)

    def serials(self, event="enter"):
        return [int(s) for s in re.findall(rf"^{event} (\d+)$", self.path.read_text(), re.M)]

    def send(self, command, error=False):
        self.process.stdin.write(command + "\n")
        self.process.stdin.flush()
        self.commands += 1
        if error:
            self.process.wait(timeout=10)
            assert "Invalid shape" in self.path.read_text(), self.path.read_text()
        else:
            wait_for(lambda: f"done {self.commands}\n" in self.path.read_text(),
                     f"command {command!r} did not finish: {self.path}")


def run():
    with tempfile.TemporaryDirectory(prefix="rediwm-cursor-shape-") as directory:
        tmp = Path(directory)
        build_client(tmp)
        build_theme(tmp)
        compositor, log = spawn_compositor(
            tmp, scale=os.environ.get("REDIWM_TEST_SCALE", "1"),
            config_content="[compositor]\nxwayland = false\n",
            env_extra={"XDG_CACHE_HOME": str(tmp / "cache"),
                       "XCURSOR_PATH": str(tmp / "icons"), "XCURSOR_THEME": "default"})
        clients = []
        try:
            socket_path = wait_for(lambda: next(tmp.glob("rediwm-*.sock"), None), "IPC unavailable")
            display = next(p.name for p in tmp.glob("wayland-*") if not p.name.endswith(".lock"))
            with IPCClient(str(socket_path)) as ipc:
                def spawn(name, version=2):
                    client = Client(tmp, display, name, version)
                    clients.append(client)
                    win = wait_for(lambda: next((w for w in ipc.get_windows() if w["app_id"] == name), None),
                                   "fixture did not map")
                    return client, win

                def state():
                    s = ipc.get_input_state()
                    return s["cursor_source"], s["cursor_name"]

                def expect(source, name):
                    assert state() == (source, name), ipc.get_input_state()

                def enter(client, win, x=180, y=180):
                    before = len(client.serials())
                    ipc.move_cursor(win["x"] + x, win["y"] + y)
                    wait_for(lambda: len(client.serials()) > before, "pointer enter missing")
                    return client.serials()[-1]

                first, win = spawn("cursor-first")
                ipc.action("move_window_to", {"id": win["id"], "x": 100, "y": 100})
                win = next(w for w in ipc.get_windows() if w["id"] == win["id"])
                ipc.move_cursor(0, 0)
                first_serial = enter(first, win)
                expect("default", "default")
                for shape, name in enumerate(SHAPES, 1):
                    first.send(f"shape {shape}")
                    if name in ("default", "help"):
                        expect("default", "default")
                    else:
                        expect("theme", name)
                first.send("shape 1")
                expect("default", "default")

                # Surface cursors, hidden cursors and shapes replace each other.
                first.send("surface")
                expect("surface", None)
                first.send("shape 9")
                expect("theme", "text")
                first.send("hide")
                expect("hidden", None)
                first.send("shape 1")
                expect("default", "default")
                first.send("shape 4")
                first.send("surface")
                expect("surface", None)

                # Only an exact latest enter serial is accepted, including after
                # another valid seat event (button) or re-entry to the same surface.
                first.send("shape 9")
                first.send("serial 4294967295 4")
                expect("theme", "text")
                before = len(first.serials("button"))
                ipc.action("pointer_button", {"button": 272, "pressed": True})
                ipc.action("pointer_button", {"button": 272, "pressed": False})
                wait_for(lambda: len(first.serials("button")) > before, "button missing")
                first.send(f"serial {first.serials('button')[-1]} 4")
                expect("theme", "text")
                first.send("shape 4")
                expect("theme", "pointer")
                ipc.move_cursor(0, 0)
                expect("default", "default")
                enter(first, win)
                first.send("shape 9")
                first.send(f"serial {first_serial} 4")
                expect("theme", "text")

                # A new wl_pointer while focused receives a fresh serial without
                # a seat focus-change event. Recreating just the shape device does not.
                old_serial = first.serials()[-1]
                first.send("pointer")
                assert first.serials()[-1] != old_serial
                first.send("shape 4")
                expect("theme", "pointer")
                first.send(f"serial {old_serial} 9")
                expect("theme", "pointer")
                first.send("destroy")
                expect("theme", "pointer")
                first.send("device")
                first.send("shape 9")
                expect("theme", "text")

                # Keyboard focus alone grants no cursor authority.
                second, other = spawn("cursor-second", 1)
                ipc.action("move_window_to", {"id": other["id"], "x": 650, "y": 100})
                other = next(w for w in ipc.get_windows() if w["id"] == other["id"])
                enter(second, other)
                second.send("shape 4")
                ipc.focus_window(win["id"])
                first.send("shape 9")
                expect("theme", "pointer")

                # Shell and interactive resize/pan cursors retain ownership.
                ipc.move_cursor(win["x"] + 100, win["y"] + 30)
                first.send("shape 9")
                expect("default", "default")
                ipc.move_cursor(win["x"] - 2, win["y"] + 150)
                edge_cursor = state()
                assert edge_cursor[0] == "theme", edge_cursor
                first.send("shape 9")
                assert state() == edge_cursor
                ipc.action("pointer_button", {"button": 272, "pressed": True})
                assert ipc.get_input_state()["cursor_mode"] == "resize"
                first.send("shape 4")
                assert state() == edge_cursor
                ipc.action("pointer_button", {"button": 272, "pressed": False})
                enter(first, win)
                expect("default", "default")
                first.send("shape 9")
                ipc.action("key", {"keycode": 125, "pressed": True})
                ipc.action("key", {"keycode": 56, "pressed": True})
                ipc.move_cursor(win["x"] + 180, win["y"] + 180)
                assert ipc.get_input_state()["cursor_mode"] == "pan"
                pan_cursor = state()
                first.send("shape 4")
                assert state() == pan_cursor
                ipc.action("key", {"keycode": 56, "pressed": False})
                ipc.action("key", {"keycode": 125, "pressed": False})
                ipc.move_cursor(0, 0)
                enter(first, win)

                # Manager destruction leaves existing devices usable.
                first.send("manager")
                first.send("shape 9")
                expect("theme", "text")
                # v2 additions are legal (a theme missing them falls back to default).
                for shape, name in ((35, "dnd-ask"), (36, "all-resize")):
                    first.send(f"shape {shape}")
                    assert state() in (("theme", name), ("default", "default")), state()
                # Invalid enums and using a v2 enum on a v1 device disconnect
                # the offending client; the compositor and other clients survive.
                second.send("shape 35", error=True)
                first.send("shape 0", error=True)
                assert compositor.poll() is None
                third, third_win = spawn("cursor-after-errors")
                ipc.move_cursor(0, 0)
                enter(third, third_win)
                third.send("shape 9")
                expect("theme", "text")
                # Destroying a window during resize cancels the grab and cursor override.
                ipc.move_cursor(third_win["x"] - 2, third_win["y"] + 150)
                ipc.action("pointer_button", {"button": 272, "pressed": True})
                assert ipc.get_input_state()["cursor_mode"] == "resize"
                third.process.terminate()
                third.process.wait(timeout=5)
                wait_for(lambda: ipc.get_input_state()["cursor_mode"] == "passthrough", "destroy did not cancel resize")
                ipc.action("pointer_button", {"button": 272, "pressed": False})
                ipc.move_cursor(0, 0)
                expect("default", "default")
                # Quit through the normal compositor keybinding so deinit runs;
                # SIGTERM would bypass cleanup and only test process termination.
                for keycode in (125, 42):  # Super+Shift
                    ipc.action("key", {"keycode": keycode, "pressed": True})
                try:
                    ipc.action("key", {"keycode": 18, "pressed": True})  # E
                except EOFError:
                    pass  # Normal shutdown can close IPC before replying.
            # Exercise display teardown with a live shape device still bound.
            compositor.wait(timeout=10)
            assert compositor.returncode == 0, (tmp / "compositor.log").read_text()
            print("cursor-shape: protocol, serials, cursor policy and lifecycle passed")
        except Exception:
            print((tmp / "compositor.log").read_text()[-6000:])
            for client in clients:
                print(client.path.name, client.path.read_text())
            raise
        finally:
            for client in clients:
                if client.process.poll() is None:
                    stop_process(client.process)
                client.process.stdin.close()
            if compositor.poll() is None:
                stop_process(compositor)
            log.close()


if __name__ == "__main__":
    run()

#!/usr/bin/env python3
"""Relative pointer motion and pointer lock/confinement with real Wayland peers."""
import os
from pathlib import Path
import subprocess
import tempfile
import time

from desktop_zoom import ROOT, build_client
from xwayland import start_compositor, ipc_connect, request, wait_for, wayland_display_name


def compile_client(tmp):
    build_client(tmp)
    system = Path(subprocess.check_output(
        ["pkg-config", "--variable=pkgdatadir", "wayland-protocols"], text=True).strip())
    protocols = {
        "pointer-constraints-unstable-v1": system / "unstable/pointer-constraints/pointer-constraints-unstable-v1.xml",
        "relative-pointer-unstable-v1": system / "unstable/relative-pointer/relative-pointer-unstable-v1.xml",
    }
    sources = [tmp / "xdg-shell-protocol.c", tmp / "xdg-decoration-protocol.c"]
    for name, path in protocols.items():
        for mode, suffix in (("client-header", "client-protocol.h"), ("private-code", "protocol.c")):
            subprocess.run(["wayland-scanner", mode, str(path), str(tmp / f"{name}-{suffix}")], check=True)
        sources.append(tmp / f"{name}-protocol.c")
    subprocess.run(["cc", "-Wall", "-Wextra", f"-I{tmp}",
                    str(ROOT / "tests/pointer_constraints_client.c"), *map(str, sources),
                    "-lwayland-client", "-lm", "-o", str(tmp / "constraints-client")], check=True)


def run():
    with tempfile.TemporaryDirectory(prefix="rediwm-pointer-constraints-") as directory:
        tmp = Path(directory)
        compile_client(tmp)
        compositor, log = start_compositor(tmp, '[compositor]\nxwayland = false\n[keybinds]\n"F9" = "set_depth 2"\n"F8" = "set_depth 0"\n')
        clients = []
        sock = reader = None
        try:
            sock, reader = ipc_connect(tmp)
            env = dict(os.environ, XDG_RUNTIME_DIR=str(tmp), WAYLAND_DISPLAY=wayland_display_name(tmp))
            env.pop("DISPLAY", None)
            env.pop("WAYLAND_DEBUG", None)

            def req(value): return request(sock, reader, value)
            def action(name, params=None): return req({"version": 1, "command": name, "params": params or {}})
            def windows(): return req({'version': 1, 'command': 'windows'})["Windows"]
            def window(name): return next((w for w in windows() if w["app_id"] == name), None)
            def focus(name): action('focus_window', {"id": window(name)["id"]})
            def cursor():
                state = req({'version': 1, 'command': 'get_input_state'})["InputState"]
                return state["pointer_x"], state["pointer_y"]
            def move(x, y): action('move_cursor', {"x": round(x), "y": round(y)})
            def nudge(dx, dy): action('move_cursor_relative', {"dx": dx, "dy": dy})

            class Peer:
                def __init__(self, name):
                    self.name = name
                    self.path = tmp / f"{name}.log"
                    with self.path.open("w") as out:
                        self.process = subprocess.Popen([str(tmp / "constraints-client"), name], env=env,
                                                        stdin=subprocess.PIPE, stdout=out, stderr=out, text=True)
                    clients.append(self.process)
                    wait_for(lambda: "ready\n" in self.text(), f"{name} failed to start")
                    wait_for(lambda: window(name), f"{name} did not map")

                def text(self): return self.path.read_text()
                def count(self, text):
                    # Whole lines: "unlocked" must not count as "locked".
                    if text.endswith("\n"): return self.text().splitlines().count(text[:-1])
                    return self.text().count(text)
                def send(self, command):
                    old = self.count(f"ack {command}\n")
                    self.process.stdin.write(command + "\n")
                    self.process.stdin.flush()
                    wait_for(lambda: self.count(f"ack {command}\n") > old,
                             lambda: f"no ack for {command}: {self.text()[-1500:]}")

                def expect_count(self, text, count):
                    wait_for(lambda: self.count(text) >= count,
                             lambda: f"expected {count}x {text!r}: {self.text()[-1500:]}")
                    self.send("sync")
                    assert self.count(text) == count, f"expected exactly {count}x {text!r}: {self.text()[-1500:]}"

                def last_motion(self):
                    self.send("sync")
                    line = [l for l in self.text().splitlines() if l.startswith("motion ")][-1]
                    return tuple(float(v) for v in line.split()[1:])

            game = Peer("rediwm.game")
            for interface in ("zwp_pointer_constraints_v1", "zwp_relative_pointer_manager_v1"):
                assert f"global {interface} 1\n" in game.text(), game.text()
            other = Peer("rediwm.other")
            focus("rediwm.game")

            def origin():
                # The fixture has a child subsurface at (100,80)-(160,120);
                # every probe below stays clear of it.
                w = window("rediwm.game")
                x, y = w["x"] + 20, w["y"] + 20
                hit = req({"version": 1, "command": 'hit_test', "params": {"x": x, "y": y}})["HitTest"]
                assert hit["window_id"] == w["id"], hit
                return x - hit["local_x"], y - hit["local_y"]

            ox, oy = origin()
            move(ox + 20, oy + 20)
            game.send("relative")
            nudge(7, -3)
            game.expect_count("relative 7.000 -3.000 7.000 -3.000\n", 1)
            print("PASS: globals and relative motion")

            # A lock freezes the cursor and wl_pointer motion but keeps
            # relative deltas flowing: this is mouse-look.
            game.send("lock persistent")
            game.expect_count("locked\n", 1)
            held = cursor()
            motions = game.count("motion ")
            nudge(40, 25)
            game.expect_count("relative 40.000 25.000 40.000 25.000\n", 1)
            assert cursor() == held, (cursor(), held)
            assert game.count("motion ") == motions, "locked pointer still sent wl_pointer.motion"

            # Losing keyboard focus releases it; a persistent lock returns
            # with focus while the pointer is still over the surface.
            focus("rediwm.other")
            game.expect_count("unlocked\n", 1)
            focus("rediwm.game")
            game.expect_count("locked\n", 2)
            # Shell panels keep seat focus but must free the cursor to be
            # usable: the first motion after the start menu opens escapes.
            action('open_start_menu')
            held = cursor()
            nudge(3, 3)
            game.expect_count("unlocked\n", 2)
            assert cursor() == (held[0] + 3, held[1] + 3), "start menu left the cursor locked"
            action('close_panel', {"panel": "start_menu"})
            time.sleep(.6)  # a closing menu still takes hits
            action('wait_for_frame', {})
            focus("rediwm.game")
            nudge(0, 0)
            game.expect_count("locked\n", 3)

            # Releasing a hinted lock puts the cursor where the client drew it.
            game.send("hint 30.5 40.25")
            game.send("unlock")
            x, y = cursor()
            assert abs(x - (ox + 30.5)) < 0.01 and abs(y - (oy + 40.25)) < 0.01, ((x, y), (ox, oy))
            nudge(5, 5)
            assert cursor() == (x + 5, y + 5), "cursor stayed locked after the lock was destroyed"
            print("PASS: lock freezes the cursor, focus/shell escapes, re-activation and cursor hint")

            # Oneshot constraints die on deactivation and never come back.
            game.send("lock oneshot")
            game.expect_count("locked\n", 4)
            focus("rediwm.other")
            game.expect_count("unlocked\n", 3)
            focus("rediwm.game")
            nudge(1, 1)
            game.expect_count("locked\n", 4)
            game.send("unlock")
            print("PASS: oneshot lock is not re-activated")

            def check_confinement(depth):
                ox, oy = origin()
                move(ox + 20, oy + 20)
                confined = game.count("confined\n")
                game.send("confine persistent 50 50 200 100")
                game.send("sync")
                assert game.count("confined\n") == confined, "confinement activated with the pointer outside its region"
                move(ox + 60, oy + 60)
                game.expect_count("confined\n", confined + 1)
                nudge(400, 400)
                mx, my = game.last_motion()
                assert 249 <= mx < 250 and 149 <= my < 150, (depth, mx, my)
                nudge(-400, -400)
                mx, my = game.last_motion()
                assert mx == 50 and my == 50, (depth, mx, my)
                game.send("unconfine")
                move(ox + 20, oy + 20)
                mx, my = game.last_motion()
                assert mx < 50 and my < 50, (depth, mx, my)

            check_confinement(0)
            # Window zoom changes surface units per layout pixel.
            action('key_press', {"key": "F9"})
            wait_for(lambda: window("rediwm.game")["zoom_percent"] == 70, "window did not zoom")
            time.sleep(.6)
            action('wait_for_frame', {})
            check_confinement(2)
            action('key_press', {"key": "F8"})
            time.sleep(.6)
            action('wait_for_frame', {})
            print("PASS: confinement clamps motion to its region at 100% and 70% window zoom")

            # A client dying while locked must release the cursor.
            ox, oy = origin()
            move(ox + 20, oy + 20)
            game.send("lock persistent")
            game.expect_count("locked\n", 5)
            game.process.kill(); game.process.wait(timeout=5)
            wait_for(lambda: window("rediwm.game") is None, "game window did not go away")
            before = cursor()
            nudge(10, 10)
            assert cursor() == (before[0] + 10, before[1] + 10), "cursor stayed locked after the client died"
            assert compositor.poll() is None
            print("PASS: client exit while locked")
        except BaseException:
            for path in tmp.glob("*.log"):
                print(f"{path.name}:\n{path.read_text(errors='replace')[-6000:]}")
            raise
        finally:
            for process in reversed(clients):
                if process.poll() is None:
                    process.terminate()
                    try: process.wait(timeout=5)
                    except subprocess.TimeoutExpired: process.kill(); process.wait(timeout=5)
            if reader: reader.close()
            if sock: sock.close()
            compositor.terminate(); compositor.wait(timeout=5); log.close()


if __name__ == "__main__":
    run()

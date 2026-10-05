#!/usr/bin/env python3
"""keyboard-shortcuts-inhibit: a VM or remote desktop takes over compositor bindings."""
import os
from pathlib import Path
import subprocess
import tempfile

from desktop_zoom import ROOT, build_client
from xwayland import start_compositor, ipc_connect, request, wait_for, wayland_display_name

KEY_ESC, KEY_TAB, KEY_Z, KEY_X, KEY_LEFTALT, KEY_LEFTMETA = 1, 15, 44, 45, 56, 125


def compile_client(tmp):
    build_client(tmp)
    system = Path(subprocess.check_output(
        ["pkg-config", "--variable=pkgdatadir", "wayland-protocols"], text=True).strip())
    name = "keyboard-shortcuts-inhibit-unstable-v1"
    path = system / f"unstable/keyboard-shortcuts-inhibit/{name}.xml"
    for mode, suffix in (("client-header", "client-protocol.h"), ("private-code", "protocol.c")):
        subprocess.run(["wayland-scanner", mode, str(path), str(tmp / f"{name}-{suffix}")], check=True)
    sources = [tmp / "xdg-shell-protocol.c", tmp / "xdg-decoration-protocol.c", tmp / f"{name}-protocol.c"]
    subprocess.run(["cc", "-Wall", "-Wextra", f"-I{tmp}",
                    str(ROOT / "tests/shortcuts_inhibit_client.c"), *map(str, sources),
                    "-lwayland-client", "-lm", "-o", str(tmp / "inhibit-client")], check=True)


def run():
    with tempfile.TemporaryDirectory(prefix="rediwm-shortcuts-inhibit-") as directory:
        tmp = Path(directory)
        compile_client(tmp)
        # restore_shortcuts (Super+Escape) is inherited even by configs with
        # their own [keybinds], like hardware keys.
        compositor, log = start_compositor(tmp, '[compositor]\nxwayland = false\n[keybinds]\n'
                                                '"super+z" = "set_depth 2"\n"super+x" = "set_depth 0"\n'
                                                '"alt+tab" = "focus_next"\n')
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
            def input_state(): return req({'version': 1, 'command': 'get_input_state'})["InputState"]
            def key(code, pressed): action('key', {"keycode": code, "pressed": pressed})
            def chord(*codes):
                for code in codes: key(code, True)
                for code in reversed(codes): key(code, False)

            class Peer:
                def __init__(self, name):
                    self.name = name
                    self.path = tmp / f"{name}.log"
                    with self.path.open("w") as out:
                        self.process = subprocess.Popen([str(tmp / "inhibit-client"), name], env=env,
                                                        stdin=subprocess.PIPE, stdout=out, stderr=out, text=True)
                    clients.append(self.process)
                    wait_for(lambda: "ready\n" in self.text(), f"{name} failed to start")
                    wait_for(lambda: window(name), f"{name} did not map")

                def text(self): return self.path.read_text()
                # Whole lines: "inactive" must not count as "active".
                def count(self, line): return self.text().splitlines().count(line)
                def send(self, command):
                    old = self.count(f"ack {command}")
                    self.process.stdin.write(command + "\n")
                    self.process.stdin.flush()
                    wait_for(lambda: self.count(f"ack {command}") > old,
                             lambda: f"no ack for {command}: {self.text()[-1500:]}")

                def expect_count(self, line, count):
                    wait_for(lambda: self.count(line) >= count,
                             lambda: f"expected {count}x {line!r}: {self.text()[-1500:]}")
                    self.send("sync")
                    assert self.count(line) == count, f"expected exactly {count}x {line!r}: {self.text()[-1500:]}"

            def zoom(name, percent):
                wait_for(lambda: window(name)["zoom_percent"] == percent,
                         lambda: f"{name} zoom {window(name)['zoom_percent']} != {percent}")

            def binding_fires(peer):
                """Super+Z zooms the focused window without reaching it."""
                presses = peer.count(f"key {KEY_Z} 1")
                chord(KEY_LEFTMETA, KEY_Z)
                zoom(peer.name, 70)
                peer.expect_count(f"key {KEY_Z} 1", presses)
                chord(KEY_LEFTMETA, KEY_X)
                zoom(peer.name, 100)

            def binding_inhibited(peer):
                presses = peer.count(f"key {KEY_Z} 1")
                chord(KEY_LEFTMETA, KEY_Z)
                peer.expect_count(f"key {KEY_Z} 1", presses + 1)
                assert window(peer.name)["zoom_percent"] == 100, "inhibited binding still ran"

            vm = Peer("rediwm.vm")
            assert "global zwp_keyboard_shortcuts_inhibit_manager_v1 1" in vm.text().splitlines(), vm.text()
            other = Peer("rediwm.other")
            focus("rediwm.vm")
            binding_fires(vm)
            print("PASS: global advertised; bindings run without an inhibitor")

            vm.send("inhibit")
            vm.expect_count("active", 1)
            binding_inhibited(vm)
            vm_id = window("rediwm.vm")["id"]
            tabs = vm.count(f"key {KEY_TAB} 1")
            chord(KEY_LEFTALT, KEY_TAB)
            vm.expect_count(f"key {KEY_TAB} 1", tabs + 1)
            assert input_state()["keyboard_focused_window_id"] == vm_id, "Alt+Tab switched away from the VM"
            # Super-drag pan belongs to the client's Super too.
            def super_drag():
                w = window("rediwm.vm")
                action('move_cursor', {"x": w["x"] + 40, "y": w["y"] + 40})
                key(KEY_LEFTMETA, True)
                key(KEY_LEFTALT, True)
                action('move_cursor_relative', {"dx": 30, "dy": 10})
                mode = input_state()["cursor_mode"]
                key(KEY_LEFTALT, False)
                key(KEY_LEFTMETA, False)
                return mode
            assert super_drag() == "passthrough", "Super-drag panned under an inhibitor"
            print("PASS: active inhibitor gets bindings, Alt+Tab and Super-drag")

            # Super+Escape takes the bindings back; Escape itself is consumed.
            escapes = vm.count(f"key {KEY_ESC} 1")
            chord(KEY_LEFTMETA, KEY_ESC)
            vm.expect_count("inactive", 1)
            vm.expect_count(f"key {KEY_ESC} 1", escapes)
            vm.expect_count(f"key {KEY_ESC} 0", 0)
            binding_fires(vm)
            assert super_drag() == "pan", "Super-drag did not pan once shortcuts were restored"
            # The revocation lasts until focus leaves the surface.
            focus("rediwm.other")
            focus("rediwm.vm")
            vm.expect_count("active", 2)
            binding_inhibited(vm)
            focus("rediwm.other")
            vm.expect_count("inactive", 2)
            binding_fires(other)
            focus("rediwm.vm")
            vm.expect_count("active", 3)
            print("PASS: Super+Escape revokes until refocus; focus changes (de)activate")

            # Without an inhibitor Super+Escape is an ordinary key.
            vm.send("uninhibit")
            binding_fires(vm)
            chord(KEY_LEFTMETA, KEY_ESC)
            vm.expect_count(f"key {KEY_ESC} 1", escapes + 1)
            # A fresh request after a revocation is granted.
            vm.send("inhibit")
            vm.expect_count("active", 4)
            chord(KEY_LEFTMETA, KEY_ESC)
            vm.expect_count("inactive", 3)
            vm.send("uninhibit")
            vm.send("inhibit")
            vm.expect_count("active", 5)
            print("PASS: destroyed inhibitor restores bindings; a new request is granted")

            # A client dying while inhibiting must hand the bindings back.
            vm.process.kill(); vm.process.wait(timeout=5)
            wait_for(lambda: window("rediwm.vm") is None, "vm window did not go away")
            focus("rediwm.other")
            binding_fires(other)
            assert compositor.poll() is None
            print("PASS: client exit while inhibiting")
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

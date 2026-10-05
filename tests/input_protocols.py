#!/usr/bin/env python3
"""Real clipboard, activation and IME peers in an isolated headless session."""
import os
import json
from pathlib import Path
import subprocess
import tempfile
import time

from PIL import Image
from desktop_zoom import ROOT, build_client
from xwayland import start_compositor, ipc_connect, request, wait_for, wayland_display_name


def compile_client(tmp):
    build_client(tmp)
    system = Path(subprocess.check_output(
        ["pkg-config", "--variable=pkgdatadir", "wayland-protocols"], text=True).strip())
    protocols = {
        "xdg-activation-v1": system / "staging/xdg-activation/xdg-activation-v1.xml",
        "text-input-unstable-v3": system / "unstable/text-input/text-input-unstable-v3.xml",
        "input-method-unstable-v2": ROOT / "protocol/input-method-unstable-v2.xml",
        "virtual-keyboard-unstable-v1": ROOT / "protocol/virtual-keyboard-unstable-v1.xml",
    }
    sources = [tmp / "xdg-shell-protocol.c", tmp / "xdg-decoration-protocol.c"]
    for name, path in protocols.items():
        for mode, suffix in (("client-header", "client-protocol.h"), ("private-code", "protocol.c")):
            subprocess.run(["wayland-scanner", mode, str(path), str(tmp / f"{name}-{suffix}")], check=True)
        sources.append(tmp / f"{name}-protocol.c")
    subprocess.run(["cc", "-Wall", "-Wextra", f"-I{tmp}",
                    str(ROOT / "tests/input_protocol_client.c"), *map(str, sources),
                    "-lwayland-client", "-lxkbcommon", "-o", str(tmp / "protocol-client")], check=True)
    name = "wlr-data-control-unstable-v1"
    for mode, suffix in (("client-header", "client-protocol.h"), ("private-code", "protocol.c")):
        subprocess.run(["wayland-scanner", mode, str(ROOT / f"protocol/{name}.xml"),
                        str(tmp / f"{name}-{suffix}")], check=True)
    subprocess.run(["cc", "-Wall", "-Wextra", "-Werror", f"-I{tmp}",
                    str(ROOT / "tests/data_control_client.c"), str(tmp / f"{name}-protocol.c"),
                    "-lwayland-client", "-o", str(tmp / "data-control-client")], check=True)


def run():
    with tempfile.TemporaryDirectory(prefix="rediwm-input-protocols-") as directory:
        tmp = Path(directory)
        compile_client(tmp)
        compositor, log = start_compositor(tmp, '[compositor]\nxwayland = false\n[keybinds]\n"F12" = "lock_screen"\n"F10" = "set_depth 0"\n"F9" = "set_depth 2"\n"F8" = "set_depth 0"\n"super+t" = "set_depth 0"\n')
        clients = []
        sock = reader = None
        try:
            sock, reader = ipc_connect(tmp)
            env = dict(os.environ, XDG_RUNTIME_DIR=str(tmp), WAYLAND_DISPLAY=wayland_display_name(tmp))
            env.pop("DISPLAY", None)
            env.pop("WAYLAND_DEBUG", None)

            def req(value): return request(sock, reader, value)
            def action(name, params=None): return req({"version": 1, "command": name, "params": params or {}})
            def ime_state(): return req({'version': 1, 'command': 'get_text_input'})["TextInput"]
            def windows(): return req({'version': 1, 'command': 'windows'})["Windows"]
            def window(name): return next((w for w in windows() if w["app_id"] == name), None)
            def focus(name): action('focus_window', {"id": window(name)["id"]})

            class Peer:
                def __init__(self, name, mode):
                    self.path = tmp / f"{name}.log"
                    with self.path.open("w") as out:
                        self.process = subprocess.Popen([str(tmp / "protocol-client"), mode], env=env,
                                                        stdin=subprocess.PIPE, stdout=out, stderr=out, text=True)
                    clients.append(self.process)
                    wait_for(lambda: "ready\n" in self.text(), f"{name} failed to start")

                def text(self): return self.path.read_text()
                def send(self, command):
                    old = self.text().count(f"ack {command}\n")
                    self.process.stdin.write(command + "\n")
                    self.process.stdin.flush()
                    wait_for(lambda: self.text().count(f"ack {command}\n") > old,
                             lambda: f"no ack for {command}: {self.text()[-1500:]}")

                def expect(self, text):
                    wait_for(lambda: text in self.text(), lambda: f"missing {text!r}: {self.text()[-1500:]}")

                def token(self, command="token"):
                    self.send(command)
                    return [line.split()[1] for line in self.text().splitlines() if line.startswith("token ")][-1]

            app = Peer("app", "rediwm.protocol-app")
            wait_for(lambda: window("rediwm.protocol-app"), "app did not map")
            for interface in ("zwlr_data_control_manager_v1", "ext_data_control_manager_v1",
                              "xdg_activation_v1", "zwp_text_input_manager_v3",
                              "zwp_input_method_manager_v2", "zwp_virtual_keyboard_manager_v1"):
                app.expect(f"global {interface} ")
            assert "text-enter\n" not in app.text(), "text input enabled without an input method"

            cli = subprocess.check_output([str(ROOT / "zig-out/bin/rediwm-msg"),
                                           "--socket", str(next(tmp.glob("rediwm-*.sock"))),
                                           "--json", "text-input"], env=env, text=True)
            assert "input_method" in json.loads(cli), cli
            cli_text = subprocess.check_output([str(ROOT / "zig-out/bin/rediwm-msg"),
                                                "--socket", str(next(tmp.glob("rediwm-*.sock"))),
                                                "text-input"], env=env, text=True)
            assert "Text input:" in cli_text and "input_method" in cli_text, cli_text
            initial = ime_state()
            assert not initial["input_method"]["connected"] and initial["focused"]["pending"], initial

            # wl-copy/paste must work in the background, without a helper window
            # or keyboard focus. A manager is the owner, not a persistence store.
            for primary in (False, True):
                flags = ["--primary"] if primary else []
                owner = subprocess.Popen(["wl-copy", "--foreground", *flags], env=env,
                                         stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
                clients.append(owner)
                owner.stdin.write(b"clipboard without focus")
                owner.stdin.close()
                def pasted():
                    result = subprocess.run(["wl-paste", "--no-newline", *flags], env=env,
                                            capture_output=True, timeout=3)
                    return result.stdout == b"clipboard without focus"
                wait_for(pasted, "data-control clipboard transfer failed")
                legacy_log = tmp / f"legacy-{primary}.log"
                with legacy_log.open("w") as output:
                    legacy = subprocess.Popen([str(tmp / "data-control-client"), "get",
                                               "primary" if primary else "clipboard"],
                                              env=env, stdout=output, stderr=output)
                clients.append(legacy)
                wait_for(lambda: "received clipboard without focus\n" in legacy_log.read_text(),
                         "legacy data-control did not receive the clipboard")
                legacy.terminate(); legacy.wait(timeout=5)
                assert window("rediwm.protocol-app")["is_focused"]
                owner.terminate(); owner.wait(timeout=5)
                legacy = subprocess.Popen([str(tmp / "data-control-client"), "set",
                                           "primary" if primary else "clipboard"],
                                          env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
                clients.append(legacy)
                def legacy_pasted():
                    return subprocess.run(["wl-paste", "--no-newline", *flags], env=env,
                                          capture_output=True, timeout=3).stdout == b"legacy clipboard"
                wait_for(legacy_pasted, "legacy data-control could not set clipboard")
                legacy.terminate(); legacy.wait(timeout=5)
            print("PASS: globals, background clipboard and primary-selection transfers")

            other = Peer("other", "rediwm.protocol-other")
            wait_for(lambda: window("rediwm.protocol-other"), "second app did not map")
            # Source gets a real seat serial, then passes the opaque token to a
            # different process. Activation restores a minimized target.
            valid = other.token()
            action('minimize_window', {"id": window("rediwm.protocol-app")["id"]})
            app.send("activate " + valid)
            wait_for(lambda: window("rediwm.protocol-app")["is_focused"] and
                     not window("rediwm.protocol-app")["is_minimized"], "valid activation failed")
            focus("rediwm.protocol-other")
            app.send("activate " + valid)
            assert window("rediwm.protocol-other")["is_focused"], "token was reusable"
            for invalid in (other.token("token-bad"), other.token("token-empty"), app.token(), "unknown-token"):
                app.send("activate " + invalid)
                assert window("rediwm.protocol-other")["is_focused"], "invalid token stole focus"
            print("PASS: cross-client activation, restore, single-use and invalid-token rejection")

            focus("rediwm.protocol-app")
            ime = Peer("ime", "ime")
            ime.send("method")
            app.expect("text-enter\n")
            ime.expect("surround hello 3 1\n")
            ime.expect("content 1 0\n")
            state = ime_state()
            assert state["input_method"]["active"] and not state["focused"]["pending"], state
            assert state["focused"]["surrounding_bytes"] == 5, state
            assert "hello" not in str(state) and "surrounding_text" not in str(state), state
            ime.send("compose")
            app.expect("preedit pré 0 4\n")
            app.expect("commit composed\n")
            app.expect("delete 2 1\n")
            before = app.text().count("commit composed\n")
            ime.send("stale"); app.send("sync")
            assert app.text().count("commit composed\n") == before, "stale IME commit applied"
            ime.send("commit-only")
            app.expect("preedit  0 0\n")
            app.expect("commit final\n")
            app.send("update")
            ime.expect("surround updated 7 7\n")
            ime.expect("cause 1\n")
            print("PASS: IME activation, state, UTF-8 preedit, commit/delete and stale serial rejection")

            # Popups are clickable without moving keyboard focus into the IME.
            ime.send("popup")
            ime.expect("rectangle ")
            def popup_pixel():
                path = tmp / "popup.png"
                path.unlink(missing_ok=True)
                action('screenshot', {"path": str(path)})
                with Image.open(path) as shot:
                    shot = shot.convert("RGB")
                    for y in range(shot.height):
                        for x in range(shot.width):
                            if shot.getpixel((x, y)) == (0, 255, 255): return x + 5, y + 5
                return None
            point = wait_for(popup_pixel, "IME popup did not render")
            hit = req({"version": 1, "command": 'hit_test', "params": {"x": point[0], "y": point[1]}})
            assert hit["HitTest"]["target_type"] == "input_popup", hit
            action('move_cursor', {"x": point[0], "y": point[1]})
            action('pointer_button', {"button": 272, "pressed": True})
            action('pointer_button', {"button": 272, "pressed": False})
            assert window("rediwm.protocol-app")["is_focused"]
            w = window("rediwm.protocol-app")
            action('move_window_to', {"id": w["id"], "x": w["x"] + 40, "y": w["y"] + 30})
            wait_for(lambda: popup_pixel() == (point[0] + 40, point[1] + 30),
                     "IME popup did not follow its window")
            placed = ime_state()["popups"][0]
            before_zoom = window("rediwm.protocol-app")
            action('key_press', {"key": "F9"})
            wait_for(lambda: window("rediwm.protocol-app")["zoom_percent"] == 70, "window did not zoom")
            time.sleep(.6)
            action('wait_for_frame', {})
            zoomed = ime_state()["popups"][0]
            assert (placed["width"], placed["height"]) == (zoomed["width"], zoomed["height"]), zoomed
            zoom_window = window("rediwm.protocol-app")
            for axis in ("x", "y"):
                expected = zoom_window[axis] + (placed[axis] - before_zoom[axis]) * .7
                assert abs(zoomed[axis] - expected) <= 1, (axis, zoomed, expected)
            action('key_press', {"key": "F8"})
            time.sleep(.6)
            action('wait_for_frame', {})
            before_pan = ime_state()["popups"][0]
            action('set_camera', {"x": 60, "y": 40})
            time.sleep(.6)
            action('wait_for_frame', {})
            panned = ime_state()["popups"][0]
            assert abs(panned["x"] - (before_pan["x"] - 60)) <= 1, (before_pan, panned)
            assert abs(panned["y"] - (before_pan["y"] - 40)) <= 1, (before_pan, panned)
            action('set_camera', {"x": 0, "y": 0})
            time.sleep(.6)
            action('wait_for_frame', {})
            action('open_start_menu')
            action('wait_for_frame', {})
            assert not ime_state()["popups"][0]["visible"]
            action('close_panel', {"panel": "start_menu"})
            action('wait_for_frame', {})
            assert ime_state()["popups"][0]["visible"]
            app.send("extreme-rectangle")
            assert popup_pixel() is not None, "large client coordinates broke popup placement"
            app.send("update")
            app.send("disable")
            assert popup_pixel() is None, "disabled IME popup remained visible"
            app.send("enable")
            wait_for(popup_pixel, "reenabled popup did not return")
            focus("rediwm.protocol-other")
            other.expect("text-enter\n")
            app.expect("text-leave\n")
            ime.expect("deactivate\n")
            focus("rediwm.protocol-app")
            app.send("sync"); ime.send("sync")
            action('key', {"keycode": 45, "pressed": True}) # x before grab
            app.expect("app-key 45 1\n")
            ime.send("grab")
            ime.expect("grab-keymap\n")
            action('key', {"keycode": 45, "pressed": False})
            app.expect("app-key 45 0\n")
            ime.send("sync")
            assert "grab-key 45 0\n" not in ime.text(), "release crossed into new grab"
            for code in (68, 66): # overlapping F10/F8 shortcut presses
                action('key', {"keycode": code, "pressed": True})
            for code in (68, 66):
                action('key', {"keycode": code, "pressed": False})
            app.send("sync"); ime.send("sync")
            assert "grab-key 68 " not in ime.text() and "app-key 68 " not in app.text()
            action('key', {"keycode": 46, "pressed": True})
            ime.expect("grab-key 46 1\n")
            ime.send("ungrab")
            ime.send("grab")
            action('key', {"keycode": 46, "pressed": False})
            app.send("sync"); ime.send("sync")
            assert "app-key 46 0\n" not in app.text() and "grab-key 46 0\n" not in ime.text()
            assert ime_state()["input_method"]["keyboard_grab"]
            before = app.text().count("app-key 30 1\n")
            action('key_press', {"key": "a"})
            ime.expect("grab-key 30 1\n")
            app.send("sync")
            assert app.text().count("app-key 30 1\n") == before, "grabbed key leaked to client"
            ime.send("forward")
            action('key_press', {"key": "a"})
            wait_for(lambda: app.text().count("app-key 30 1\n") == before + 1,
                     "IME virtual keyboard did not forward exactly once")
            ime.send("ungrab")
            action('key_press', {"key": "b"})
            app.expect("app-key 48 1\n")
            print("PASS: candidate popup, focus routing, keyboard grab and virtual-keyboard loop prevention")

            # A protocol keyboard exercises real layout state and hot reload;
            # the IPC keyboard must keep its independent US map.
            map_count = app.text().count("app-layouts ")
            ime.send("layout-keyboard"); app.send("sync")
            assert app.text().count("app-layouts ") == map_count, "new virtual keyboard stole the seat"
            before = app.text().count("app-key 20 1\n")
            ime.send("layout-shortcut"); app.send("sync")
            assert app.text().count("app-key 20 1\n") == before, "Russian layout lost Super+t"
            ime.send("layout-text"); app.expect("app-sym Cyrillic_ie\n")
            original_config = (tmp / "config.toml").read_text()
            (tmp / "config.toml").write_text(original_config + '[input]\nxkb_layout = "us"\n')
            action('reload_config')
            ime.send("layout-us"); app.send("sync")
            after_reload = app.text().count("app-sym t\n")
            ime.send("layout-text")
            wait_for(lambda: app.text().count("app-sym t\n") > after_reload, "layout reload did not reach virtual keyboard")
            (tmp / "config.toml").write_text(original_config + '[input]\nxkb_layout = "rediwm_nonexistent_layout"\n')
            action('reload_config')
            after_invalid = app.text().count("app-sym t\n")
            ime.send("layout-text")
            wait_for(lambda: app.text().count("app-sym t\n") > after_invalid, "invalid reload replaced the working keymap")
            (tmp / "config.toml").write_text(original_config)
            action('reload_config')
            action('type_text', {"text": "t"})
            app.send("sync")
            print("PASS: Russian shortcut fallback, text input, keymap reload and invalid-map preservation")

            duplicate = Peer("duplicate", "ime")
            duplicate.send("method"); duplicate.expect("unavailable\n")
            ime.process.terminate(); ime.process.wait(timeout=5)
            app.send("sync")
            replacement = Peer("replacement", "ime")
            replacement.send("method")
            replacement.expect("activate\n")
            app.send("destroy-input")
            replacement.expect("deactivate\n")
            app.send("create-input")
            app.send("sync"); replacement.send("sync")
            composed_before = app.text().count("commit composed\n")
            replacement.send("compose")
            app.send("sync")
            assert app.text().count("commit composed\n") == composed_before + 1
            print("PASS: duplicate IME rejection, disconnect/reconnect and text-input destruction")

            # Disconnect/unmap clears focus and cannot leave a live IME pointing
            # into freed text-input state. Recreate the client before lock tests.
            app.send("unmap")
            replacement.send("sync")
            count = replacement.text().count("activate\n")
            app.send("enable")
            replacement.send("sync")
            assert replacement.text().count("activate\n") == count
            focus("rediwm.protocol-other")
            other.send("sync"); replacement.send("sync")
            token = other.token()
            replacement.send("grab")
            replacement.expect("grab-keymap\n")
            other_before = other.text().count("keyboard-enter\n")
            action('key', {"keycode": 88, "pressed": True})  # F12 locks; no password input.
            other.send("sync"); replacement.send("sync")
            activations = replacement.text().count("activate\n")
            commits = other.text().count("commit composed\n")
            other.send("enable")
            other.send("activate " + token)
            replacement.send("virtual-key")
            replacement.send("compose")
            other.send("sync"); replacement.send("sync")
            assert replacement.text().count("activate\n") == activations
            assert other.text().count("commit composed\n") == commits
            assert other.text().count("keyboard-enter\n") == other_before
            assert compositor.poll() is None
            print("PASS: unmapped input and locked-session activation/IME isolation")
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

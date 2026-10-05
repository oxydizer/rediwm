#!/usr/bin/env python3
"""Layout and config events with a real Wayland keyboard in an isolated session."""
import json
import os
from pathlib import Path
import queue
import subprocess
import tempfile
import threading

from input_protocols import compile_client
from xwayland import ROOT, start_compositor, ipc_connect, request, wayland_display_name


def main():
    with tempfile.TemporaryDirectory(prefix="rediwm-layout-ipc-") as directory:
        tmp = Path(directory)
        compile_client(tmp)
        config = '[compositor]\nxwayland = false\n'
        compositor, log = start_compositor(tmp, config)
        peer = None
        connections = []
        try:
            sock, reader = ipc_connect(tmp)
            connections += [reader, sock]

            def req(value): return request(sock, reader, value)
            def act(name, **params): return req({"version": 1, "command": name, "params": params})
            def layouts(): return req({'version': 1, 'command': 'get_keyboard_layouts'})["KeyboardLayouts"]
            def status(): return req({'version': 1, 'command': 'get_config_status'})["ConfigStatus"]

            def subscribe(filters):
                stream, lines = ipc_connect(tmp)
                connections.extend([lines, stream])
                request(stream, lines, {"version": 1, "command": 'event_stream', "params": {"events": filters}})
                assert "StateSnapshot" in json.loads(lines.readline())
                return lines

            events = subscribe(["keyboard_layouts_changed", "keyboard_layout_switched", "config_loaded"])

            def event(name, predicate=lambda _: True):
                # Blocking socket reads have a timeout; no polling the compositor.
                while True:
                    value = json.loads(events.readline())
                    if name in value and predicate(value[name]): return value[name]

            assert layouts() == {"names": [], "current_idx": None}
            assert event("KeyboardLayoutsChanged")["keyboard_layouts"] == layouts()
            initial = event("ConfigLoaded")
            assert not initial["failed"] and initial["generation"] == status()["generation"]
            sock.sendall(b'{"version":1,"command":"switch_layout","params":{"layout":"next"}}\n')
            assert json.loads(reader.readline()) == {"Err": "NoKeyboard"}

            env = dict(os.environ, XDG_RUNTIME_DIR=str(tmp), WAYLAND_DISPLAY=wayland_display_name(tmp))
            peer = subprocess.Popen([str(tmp / "protocol-client"), "rediwm.layout-test"], env=env,
                                    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            messages = queue.Queue()
            def collect():
                for line in peer.stdout: messages.put(line.rstrip())
            thread = threading.Thread(target=collect, daemon=True)
            thread.start()

            def expect(text):
                while True:
                    line = messages.get(timeout=10)
                    if line == text: return

            def send(command):
                peer.stdin.write(command + "\n")
                peer.stdin.flush()
                expect("ack " + command)

            expect("ready")
            send("layout-keyboard")
            assert layouts()["names"] == [], "unused virtual keyboard stole active layout"
            send("layout-text")
            changed = event("KeyboardLayoutsChanged")["keyboard_layouts"]
            assert len(changed["names"]) == 2 and changed["current_idx"] == 1, changed
            assert layouts() == changed
            # IPC synthetic input must not replace the remembered real keyboard.
            act("key_press", key="a")
            assert layouts() == changed
            for target, expected in (("next", 0), ("prev", 1), (0, 0), (1, 1)):
                act("switch_layout", layout=target)
                assert event("KeyboardLayoutSwitched")["idx"] == expected
                assert layouts()["current_idx"] == expected
                peer.stdin.write("layout-key\n"); peer.stdin.flush()
                expect("app-sym " + ("t" if expected == 0 else "Cyrillic_ie"))
                expect("ack layout-key")
            sock.sendall(b'{"version":1,"command":"switch_layout","params":{"layout":2}}\n')
            assert json.loads(reader.readline()) == {"Err": "InvalidLayoutIndex"}
            assert layouts()["current_idx"] == 1
            # Same-index requests are silent. The next real change must be first.
            act("switch_layout", layout=1)
            send("layout-us")
            assert event("KeyboardLayoutSwitched")["idx"] == 0

            cli = [str(ROOT / "zig-out/bin/rediwm-msg"), "--socket", str(next(tmp.glob("rediwm-*.sock")))]
            result = subprocess.check_output(cli + ["--json", "keyboard-layouts"], text=True)
            assert json.loads(result) == layouts()
            subprocess.run(cli + ["switch-layout", "next"], check=True, capture_output=True)
            assert event("KeyboardLayoutSwitched")["idx"] == 1

            generation = status()["generation"]
            (tmp / "config.toml").write_text(config + '[input]\nxkb_layout = "us"\n')
            loaded = event("ConfigLoaded", lambda e: e["generation"] > generation)
            assert not loaded["failed"] and status()["generation"] == loaded["generation"]
            assert len(layouts()["names"]) == 1 and layouts()["current_idx"] == 0
            generation = loaded["generation"]
            (tmp / "config.toml").write_text(config + '[input]\nxkb_layout = "rediwm_nonexistent_layout"\n')
            failed = event("ConfigLoaded", lambda e: e["failed"])
            assert failed["generation"] == generation and failed["error_name"] == "InvalidConfig"
            assert status()["last_reload_result"] == "failed"
            assert status()["last_reload_error"] == failed["error_name"]
            assert len(layouts()["names"]) == 1
            filtered = subscribe(["config_loaded"])
            assert json.loads(filtered.readline())["ConfigLoaded"] == failed
            # Manual reload reports failures too, without advancing generation.
            act("reload_config")
            again = event("ConfigLoaded")
            assert again["failed"] and again["generation"] == generation
            (tmp / "config.toml").write_text(config)
            recovered = event("ConfigLoaded", lambda e: not e["failed"])
            assert recovered["generation"] > generation and status()["last_reload_error"] is None
            act("reload_config")
            manual = event("ConfigLoaded")
            assert not manual["failed"] and manual["generation"] > recovered["generation"]
            send("layout-destroy")
            assert event("KeyboardLayoutsChanged", lambda e: not e["keyboard_layouts"]["names"])["keyboard_layouts"]["current_idx"] is None
            assert layouts()["names"] == []
            print("PASS: layout query/switch/CLI/events, synthetic isolation, keyboard removal, reload success/failure/recovery and filtered initial state")
        except Exception:
            print((tmp / "compositor.log").read_text()[-5000:])
            raise
        finally:
            if peer is not None:
                peer.terminate()
                peer.wait(timeout=5)
            for connection in connections: connection.close()
            compositor.terminate()
            compositor.wait(timeout=10)
            log.close()


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Headless decoration negotiation and client-control regression tests."""
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile

from desktop_zoom import ROOT, build_client, wait_for


def run():
    with tempfile.TemporaryDirectory(prefix="rediwm-decorations-") as directory:
        tmp = Path(directory)
        build_client(tmp)
        (tmp / "config.toml").write_text("")
        env = dict(os.environ, XDG_RUNTIME_DIR=str(tmp), WLR_BACKENDS="headless",
                   WLR_HEADLESS_OUTPUTS="1", WLR_RENDERER="pixman", REDIWM_SCALE="1",
                   REDIWM_CONFIG=str(tmp / "config.toml"), REDIWM_IPC_AUTOMATION="1")
        env.pop("WAYLAND_DISPLAY", None)
        env.pop("REDIWM_SOCKET", None)
        clients = []
        with (tmp / "compositor.log").open("w") as log:
            compositor = subprocess.Popen([str(ROOT / "zig-out/bin/rediwm")], env=env, stdout=log, stderr=log)
        try:
            ipc = wait_for(lambda: next(tmp.glob("rediwm-*.sock"), None), "IPC unavailable")
            display = next(p.name for p in tmp.glob("wayland-*") if not p.name.endswith(".lock"))
            with socket.socket(socket.AF_UNIX) as sock:
                sock.settimeout(10)
                sock.connect(str(ipc))
                reader = sock.makefile("r")

                def request(value):
                    sock.sendall((json.dumps(value) + "\n").encode())
                    result = json.loads(reader.readline())
                    assert "Ok" in result, result
                    return result["Ok"]

                def action(name, params):
                    return request({"version": 1, "command": name, "params": params})

                def windows():
                    return request({'version': 1, 'command': 'windows'})["Windows"]

                def key(code):
                    action('key', {"keycode": code, "pressed": True})
                    action('key', {"keycode": code, "pressed": False})

                for mode in ("absent", "client", "server", "default"):
                    path = tmp / (mode + ".log")
                    with path.open("w") as log:
                        client = subprocess.Popen([str(tmp / "client")], env=dict(env, WAYLAND_DISPLAY=display, REDIWM_TEST_DECORATION=mode, REDIWM_TEST_RESIZE="1"), stdout=log, stderr=log)
                    clients.append(client)
                    win = wait_for(lambda: next(iter(windows()), None), "client did not map")
                    decorated = mode in ("server", "default")
                    if decorated:
                        assert win["width"] > 400 and win["height"] > 260, win
                    else:
                        assert (win["width"], win["height"]) == (400, 260), win
                    if mode != "absent":
                        assert f"decoration {2 if decorated else 1}" in path.read_text(), path.read_text()
                    action('focus_window', {"id": win["id"]})
                    if mode == "client":
                        # F6 switches to SSD, F5 back to CSD, F7 unsets preference.
                        key(64)
                        ssd = wait_for(lambda: next((w for w in windows() if w["width"] > 400), None), "SSD switch failed")
                        key(63)
                        wait_for(lambda: next((w for w in windows() if (w["width"], w["height"]) == (400, 260)), None), "CSD switch left frame extents")
                        key(65)
                        wait_for(lambda: next((w for w in windows() if (w["width"], w["height"]) == (ssd["width"], ssd["height"])), None), "unset preference failed")
                        key(63)
                        win = wait_for(lambda: next((w for w in windows() if w["width"] == 400), None), "CSD switch failed")
                    if mode in ("absent", "client"):
                        # The former titlebar is client input, without any offset.
                        start = len(path.read_text())
                        action('move_cursor', {"x": win["x"] + 200, "y": win["y"] + 10})
                        wait_for(lambda: "enter main 200.000 10.000" in path.read_text()[start:], "client input offset or hidden titlebar")
                        action('drag', {"from_x": win["x"] + 5, "from_y": win["y"] + 5,
                                        "to_x": win["x"] + 35, "to_y": win["y"] + 25})
                        resized = wait_for(lambda: next((w for w in windows() if w["width"] == 370 and w["height"] == 240), None), "CSD resize failed")
                        assert (resized["x"], resized["y"]) == (win["x"] + 30, win["y"] + 20), resized
                        key(66)
                        maximized = wait_for(lambda: next((w for w in windows() if w["width"] > 400), None), "client maximize ignored")
                        assert maximized["width"] == 1280, maximized
                        key(68)
                        wait_for(lambda: next((w for w in windows() if w["is_minimized"]), None), "client minimize ignored")
                    action('close_window', {"id": win["id"]})
                    wait_for(lambda: not windows(), "client did not close")
                    client.wait(timeout=3)
                    print(f"PASS: {mode} decoration mode")
        except Exception:
            for path in tmp.glob("*.log"):
                print(path.name, path.read_text())
            raise
        finally:
            for process in clients + [compositor]:
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=3)


if __name__ == "__main__":
    run()

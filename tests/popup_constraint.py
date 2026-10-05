#!/usr/bin/env python3
"""Run after zig build. Requires cc, wayland-scanner and a headless renderer.
Popups are constrained to the visible screen, not to the world's origin screen.

Windows live in camera "world" space; the output's usable box is in layout
space. A window panned or zoomed into view far from the world origin used to
have its context menu slid to the world's left edge. Uses the zoom_client.c
fixture (a right-click opens an xdg_popup that asks to slide). Creates its own
Wayland runtime and clients; never connects to the host desktop.
"""
import json
import os
from pathlib import Path
import re
import shlex
import socket
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
POPUP_W = 100
CONTENT_X, CONTENT_Y = 1, 55  # border and title band of the fixture window
OUTPUT_W = 1280


def wait_for(check, message, timeout=15):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = check()
        if result:
            return result
        time.sleep(.03)
    raise AssertionError(message)


def build_client(tmp):
    protocol_dir = subprocess.check_output(["pkg-config", "--variable=pkgdatadir", "wayland-protocols"], text=True).strip()
    for mode, suffix in [("client-header", "client-protocol.h"), ("private-code", "protocol.c")]:
        for xml, name in [("stable/xdg-shell/xdg-shell.xml", "xdg-shell"), ("unstable/xdg-decoration/xdg-decoration-unstable-v1.xml", "xdg-decoration")]:
            subprocess.run(["wayland-scanner", mode, str(Path(protocol_dir) / xml), str(tmp / f"{name}-{suffix}")], check=True)
    subprocess.run(["cc", "-Wall", "-Wextra", f"-I{tmp}", str(ROOT / "tests/zoom_client.c"), str(tmp / "xdg-shell-protocol.c"), str(tmp / "xdg-decoration-protocol.c"), "-lwayland-client", "-o", str(tmp / "client")], check=True)


def run_case(name, *, zoom, window_x, pan_dx, popup_at):
    """Open the fixture's popup and return its configured (x, y) plus the
    layout x of its right edge."""
    with tempfile.TemporaryDirectory(prefix="rediwm-popup-test-") as tmp:
        tmp = Path(tmp)
        build_client(tmp)
        (tmp / "state").mkdir()
        config_path = tmp / "rediwm-config.toml"
        config_path.write_text("[input]\ninvert_scroll = false\npan_speed = 1.0\n")
        env = dict(
            os.environ, XDG_RUNTIME_DIR=str(tmp), XDG_STATE_HOME=str(tmp / "state"), WLR_BACKENDS="headless", WLR_HEADLESS_OUTPUTS="1",
            WLR_RENDERER=os.environ.get("REDIWM_TEST_RENDERER", "pixman"), WLR_RENDERER_ALLOW_SOFTWARE="1", REDIWM_SCALE="1",
            REDIWM_IPC_AUTOMATION="1", REDIWM_CONFIG=str(config_path), REDIWM_TEST_POPUP_SLIDE="1",
        )
        if popup_at:
            env["REDIWM_TEST_POPUP_AT"] = popup_at
        env.pop("WAYLAND_DISPLAY", None)
        env.pop("REDIWM_SOCKET", None)
        client_log = tmp / "client.log"
        command = f"exec {shlex.quote(str(tmp / 'client'))} > {shlex.quote(str(client_log))} 2>&1"
        with (tmp / "compositor.log").open("w") as log:
            compositor = subprocess.Popen([str(ROOT / "zig-out/bin/rediwm"), command], env=env, stdout=log, stderr=log, start_new_session=True)
        try:
            socket_path = wait_for(lambda: next(tmp.glob("rediwm-*.sock"), None), "IPC socket did not appear")
            with socket.socket(socket.AF_UNIX) as sock:
                sock.settimeout(15)
                sock.connect(str(socket_path))
                reader = sock.makefile("r")

                def request(value):
                    sock.sendall((json.dumps(value) + "\n").encode())
                    response = json.loads(reader.readline())
                    assert "Ok" in response, response
                    return response["Ok"]

                def action(name, params=None):
                    return request({"version": 1, "command": name, "params": params or {}})

                def pointer(x, y):
                    action('move_cursor', {"x": round(x), "y": round(y)})

                def camera():
                    return request({'version': 1, 'command': 'get_camera'})["Camera"]

                def wait_camera():
                    def settled():
                        payload = request({'version': 1, 'command': 'get_animations'})
                        items = payload.get("Animations", []) if isinstance(payload, dict) else payload
                        return not any(str(i.get("site", "")).startswith("camera.") and not i.get("settled") for i in items)
                    wait_for(settled, "camera animation did not settle")

                win = wait_for(lambda: next((w for w in request({'version': 1, 'command': 'windows'})["Windows"] if w["app_id"] == "rediwm.zoom-fixture"), None), "fixture did not map")
                wait_for(lambda: "frame 3" in client_log.read_text(), "frame callbacks not delivered")
                if zoom != 100:
                    pointer(0, 0)
                    action('set_zoom', {"percent": zoom})
                    wait_camera()
                action('move_window_to', {"id": win["id"], "x": window_x, "y": 100})
                if pan_dx:
                    # Super+Alt drag: the same pan a user does to reach a window
                    # on another screen of the canvas.
                    pointer(1200, 400)
                    action('key', {"keycode": 125, "pressed": True})
                    action('key', {"keycode": 56, "pressed": True})
                    pointer(1200 - pan_dx, 400)
                    action('key', {"keycode": 56, "pressed": False})
                    action('key', {"keycode": 125, "pressed": False})
                    wait_camera()
                cam = camera()
                z = cam["zoom_percent"] / 100
                w = next(w for w in request({'version': 1, 'command': 'windows'})["Windows"] if w["id"] == win["id"])
                left = (w["x"] - cam["x"]) * z
                top = (w["y"] - cam["y"]) * z
                assert 0 <= left < OUTPUT_W - 50 * z and 0 <= top < 400, f"{name}: window is not on screen ({left}, {top}) camera {cam}"
                pointer(left + z * (CONTENT_X + 200), top + z * (CONTENT_Y + 180))
                wait_for(lambda: "enter main" in client_log.read_text(), f"{name}: pointer never entered the window")
                action('pointer_button', {"button": 273, "pressed": True})
                action('pointer_button', {"button": 273, "pressed": False})
                wait_for(lambda: "popup " in client_log.read_text(), f"{name}: popup did not configure")
                match = re.search(r"popup (-?\d+) (-?\d+) (\d+) (\d+)", client_log.read_text())
                x, y = int(match[1]), int(match[2])
                right = left + z * (CONTENT_X + x + POPUP_W)
                return x, y, right
        finally:
            compositor.terminate()
            try:
                compositor.wait(10)
            except subprocess.TimeoutExpired:
                compositor.kill()


def run():
    # Zoomed out, the window sits well past the first screen's width in world
    # units even though it is on screen: the old box was [0, output width].
    x, y, _ = run_case("zoomed", zoom=55, window_x=1900, pan_dx=0, popup_at=None)
    assert (x, y) == (50, 40), f"popup on a zoomed-out far window was moved to {(x, y)}"
    x, y, right = run_case("zoomed edge", zoom=55, window_x=1900, pan_dx=0, popup_at="390,40")
    assert x < 390 and abs(right - OUTPUT_W) <= 2, f"popup past the visible edge should slide to it: x={x} right={right}"
    # Panned at 100%: the window is on the first-screen-relative screen but
    # far from the world origin.
    x, y, _ = run_case("panned", zoom=100, window_x=1500, pan_dx=1100, popup_at=None)
    assert (x, y) == (50, 40), f"popup on a panned window was moved to {(x, y)}"
    x, y, right = run_case("panned edge", zoom=100, window_x=1500, pan_dx=500, popup_at="390,40")
    assert x < 390 and abs(right - OUTPUT_W) <= 2, f"popup past the visible edge should slide to it: x={x} right={right}"
    print("popup constraint: zoomed and panned windows keep popups on the visible screen")


if __name__ == "__main__":
    run()

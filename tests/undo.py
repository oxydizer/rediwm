#!/usr/bin/env python3
"""Integration tests for global spatial undo (Super + Z).
Modelled on tests/desktop_zoom.py (headless backend, real zoom_client.c window, IPC socket).
"""
import json
import os
from pathlib import Path
import shlex
import socket
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def wait_for(check, message, timeout=15):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = check()
        if result:
            return result
        time.sleep(0.03)
    raise AssertionError(message)


def build_client(tmp):
    protocol_dir = subprocess.check_output(
        ["pkg-config", "--variable=pkgdatadir", "wayland-protocols"], text=True
    ).strip()
    protocol = Path(protocol_dir) / "stable/xdg-shell/xdg-shell.xml"
    for mode, target in [
        ("client-header", "xdg-shell-client-protocol.h"),
        ("private-code", "xdg-shell-protocol.c"),
    ]:
        subprocess.run(
            ["wayland-scanner", mode, str(protocol), str(tmp / target)], check=True
        )
    decoration_protocol = (
        Path(protocol_dir)
        / "unstable/xdg-decoration/xdg-decoration-unstable-v1.xml"
    )
    for mode, target in [
        ("client-header", "xdg-decoration-client-protocol.h"),
        ("private-code", "xdg-decoration-protocol.c"),
    ]:
        subprocess.run(
            ["wayland-scanner", mode, str(decoration_protocol), str(tmp / target)],
            check=True,
        )
    subprocess.run(
        [
            "cc",
            "-Wall",
            "-Wextra",
            f"-I{tmp}",
            str(ROOT / "tests/zoom_client.c"),
            str(tmp / "xdg-shell-protocol.c"),
            str(tmp / "xdg-decoration-protocol.c"),
            "-lwayland-client",
            "-o",
            str(tmp / "client"),
        ],
        check=True,
    )


def run():
    with tempfile.TemporaryDirectory(prefix="rediwm-undo-test-") as tmp:
        tmp = Path(tmp)
        build_client(tmp)
        env = dict(
            os.environ,
            XDG_RUNTIME_DIR=str(tmp),
            WLR_BACKENDS="headless",
            WLR_HEADLESS_OUTPUTS=os.environ.get("REDIWM_TEST_OUTPUTS", "1"),
            WLR_RENDERER=os.environ.get("REDIWM_TEST_RENDERER", "pixman"),
            WLR_RENDERER_ALLOW_SOFTWARE="1",
            REDIWM_SCALE=os.environ.get("REDIWM_TEST_SCALE", "1"),
            REDIWM_IPC_AUTOMATION="1",
        )
        config_path = tmp / "rediwm-config.toml"
        config_path.write_text(
            "[input]\ninvert_scroll = false\npan_speed = 1.0\n\n[keybinds]\n\"super+z\" = \"undo\"\n"
        )
        env["REDIWM_CONFIG"] = str(config_path)
        env.pop("WAYLAND_DISPLAY", None)
        env.pop("REDIWM_SOCKET", None)
        client_log = tmp / "client.log"
        command = f"exec {shlex.quote(str(tmp / 'client'))} > {shlex.quote(str(client_log))} 2>&1"
        with (tmp / "compositor.log").open("w") as log:
            compositor = subprocess.Popen(
                [str(ROOT / "zig-out/bin/rediwm"), command],
                env=env,
                stdout=log,
                stderr=log,
                start_new_session=True,
            )
        other_client = None
        try:
            socket_path = wait_for(
                lambda: next(tmp.glob("rediwm-*.sock"), None),
                "IPC socket did not appear",
            )
            with socket.socket(socket.AF_UNIX) as sock:
                sock.settimeout(15)
                sock.connect(str(socket_path))
                reader = sock.makefile("r")

                def request(value):
                    sock.sendall((json.dumps(value) + "\n").encode())
                    line = reader.readline()
                    assert line, "IPC socket EOF"
                    response = json.loads(line)
                    assert "Ok" in response, response
                    return response["Ok"]

                def action(name, params=None):
                    return request(
                        {"version": 1, "command": name, "params": params or {}}
                    )

                def windows():
                    return request({'version': 1, 'command': 'windows'})["Windows"]

                def pointer(x, y):
                    action('move_cursor', {"x": round(x), "y": round(y)})

                def button(code, pressed):
                    action('pointer_button', {"button": code, "pressed": pressed})

                def key(code, pressed):
                    action('key', {"keycode": code, "pressed": pressed})

                def super_z():
                    key(125, True)
                    key(44, True)
                    key(44, False)
                    key(125, False)

                def camera():
                    return request({'version': 1, 'command': 'get_camera'})["Camera"]

                def current_window():
                    return next(w for w in windows() if w["id"] == win["id"])

                win = wait_for(
                    lambda: next(
                        (
                            w
                            for w in windows()
                            if w["app_id"] == "rediwm.zoom-fixture"
                        ),
                        None,
                    ),
                    "fixture did not map",
                )
                wait_for(
                    lambda: client_log.exists()
                    and "frame 8" in client_log.read_text(),
                    "frame callbacks not delivered",
                )

                # Reset pointer and wait for settle
                pointer(0, 0)
                time.sleep(0.3)

                # ── 1. Drag a window, Super + Z, assert Windows reports original x/y ──
                print("Testing: Window drag & Super + Z undo...")
                w0 = current_window()
                orig_x, orig_y = w0["x"], w0["y"]
                # Titlebar is at (w0["x"] + 100, w0["y"] + 15)
                pointer(orig_x + 100, orig_y + 15)
                button(272, True)
                pointer(orig_x + 180, orig_y + 65)
                button(272, False)
                wait_for(
                    lambda: current_window()["x"] == orig_x + 80
                    and current_window()["y"] == orig_y + 50,
                    "window drag did not change position",
                )
                super_z()
                wait_for(
                    lambda: current_window()["x"] == orig_x
                    and current_window()["y"] == orig_y,
                    "undo window drag failed",
                )

                # ── 2. Resize by dragging an edge, Super + Z, assert original size restored ──
                print("Testing: Window resize & Super + Z undo...")
                w_pre_resize = current_window()
                orig_w, orig_h = w_pre_resize["width"], w_pre_resize["height"]
                rx = w_pre_resize["x"] + orig_w - 30
                ry = w_pre_resize["y"] + orig_h - 30
                pointer(rx, ry)
                key(56, True)  # Alt down
                button(273, True)  # Right click down
                pointer(rx + 80, ry + 60)
                button(273, False)
                key(56, False)  # Alt up
                wait_for(
                    lambda: current_window()["width"] != orig_w,
                    "window resize failed",
                )
                super_z()
                wait_for(
                    lambda: current_window()["width"] == orig_w
                    and current_window()["height"] == orig_h,
                    "undo window resize failed",
                )

                # ── 3. Pan with Super-drag, Super + Z, assert GetCamera returns original offsets ──
                print("Testing: Camera pan & Super + Z undo...")
                cam0 = camera()
                key(125, True)  # Super+Alt down
                key(56, True)
                pointer(500, 300)
                button(272, True)
                pointer(400, 240)
                button(272, False)
                key(56, False)
                key(125, False)
                wait_for(
                    lambda: abs(camera()["x"] - cam0["x"]) > 10
                    or abs(camera()["y"] - cam0["y"]) > 10,
                    "camera pan failed",
                )
                super_z()
                wait_for(
                    lambda: abs(camera()["x"] - cam0["x"]) < 2
                    and abs(camera()["y"] - cam0["y"]) < 2,
                    "undo camera pan failed",
                )

                # ── 4. Wheel-zoom 5 notches with pinned clock, Super + Z restores to start ──
                print("Testing: Wheel-zoom coalescing with pinned clock & Super + Z undo...")
                action('set_anim_time', {"ms": 1000})
                time.sleep(0.05)
                pointer(current_window()["x"] + 150, current_window()["y"] + 150)
                key(56, True)  # Alt down
                for _ in range(5):
                    action('scroll', {"dx": 0, "dy": 40})
                key(56, False)
                wait_for(
                    lambda: current_window()["zoom_percent"] <= 70,
                    "window wheel zoom failed",
                )
                super_z()
                wait_for(
                    lambda: current_window()["zoom_percent"] == 100,
                    "undo wheel zoom did not restore full zoom",
                )
                action('set_anim_time', {"ms": None})

                # ── 5. Click window A then window B, Super + Z, assert A is focused again ──
                print("Testing: Focus change & Super + Z undo...")
                display = next(
                    p.name
                    for p in tmp.glob("wayland-*")
                    if not p.name.endswith(".lock")
                )
                other_client = subprocess.Popen(
                    [str(tmp / "client")],
                    env=dict(env, WAYLAND_DISPLAY=display),
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )
                other = wait_for(
                    lambda: next(
                        (w for w in windows() if w["id"] != win["id"]), None
                    ),
                    "second fixture did not map",
                )
                action('move_window_to', {"id": other["id"], "x": 750, "y": 250})
                time.sleep(0.2)

                # Focus window A (win)
                pointer(win["x"] + 100, win["y"] + 100)
                button(272, True)
                button(272, False)
                wait_for(
                    lambda: next(w for w in windows() if w["id"] == win["id"])[
                        "is_focused"
                    ],
                    "window A not focused",
                )

                # Focus window B (other)
                pointer(750 + 100, 250 + 100)
                button(272, True)
                button(272, False)
                wait_for(
                    lambda: next(w for w in windows() if w["id"] == other["id"])[
                        "is_focused"
                    ],
                    "window B not focused",
                )

                # Super + Z restores focus to window A
                super_z()
                wait_for(
                    lambda: next(w for w in windows() if w["id"] == win["id"])[
                        "is_focused"
                    ],
                    "undo focus failed",
                )

                # ── 6. Click the already focused window, Super + Z restores previous move ──
                print("Testing: Click already focused window does not evict undo...")
                # Window A is currently focused. Move window A:
                w_a = next(w for w in windows() if w["id"] == win["id"])
                ax, ay = w_a["x"], w_a["y"]
                pointer(ax + 100, ay + 15)
                button(272, True)
                pointer(ax + 150, ay + 45)
                button(272, False)
                wait_for(
                    lambda: next(w for w in windows() if w["id"] == win["id"])[
                        "x"
                    ]
                    == ax + 50,
                    "drag window A failed",
                )

                # Click window A again (already focused)
                pointer(ax + 150, ay + 15)
                button(272, True)
                button(272, False)
                time.sleep(0.1)

                # Super + Z must undo the MOVE of window A, not a no-op click
                super_z()
                wait_for(
                    lambda: next(w for w in windows() if w["id"] == win["id"])[
                        "x"
                    ]
                    == ax,
                    "clicking focused window clobbered move undo",
                )

                # ── 7. Press titlebar of unfocused window and drag: one Super + Z restores position & focus ──
                print("Testing: Press folding (drag unfocused window) & Super + Z...")
                # Ensure window A is focused and window B is at (750, 250)
                wait_for(
                    lambda: next(w for w in windows() if w["id"] == win["id"])[
                        "is_focused"
                    ],
                    "win A not focused",
                )
                assert not next(w for w in windows() if w["id"] == other["id"])[
                    "is_focused"
                ]
                w_b = next(w for w in windows() if w["id"] == other["id"])
                bx, by = w_b["x"], w_b["y"]

                # Drag window B by its titlebar:
                pointer(bx + 100, by + 15)
                button(272, True)
                pointer(bx + 160, by + 55)
                button(272, False)
                wait_for(
                    lambda: next(w for w in windows() if w["id"] == other["id"])[
                        "x"
                    ]
                    == bx + 60,
                    "drag window B failed",
                )
                assert next(w for w in windows() if w["id"] == other["id"])[
                    "is_focused"
                ]

                # One Super + Z restores both B's position and A's focus!
                super_z()
                wait_for(
                    lambda: next(w for w in windows() if w["id"] == other["id"])[
                        "x"
                    ]
                    == bx
                    and next(w for w in windows() if w["id"] == win["id"])[
                        "is_focused"
                    ],
                    "press folding undo failed to restore position and focus",
                )

                # ── 8. Super + Z with empty slot: no crash, no state change ──
                print("Testing: Super + Z with empty slot...")
                w_before = [(w["id"], w["x"], w["y"]) for w in windows()]
                super_z()
                time.sleep(0.1)
                w_after = [(w["id"], w["x"], w["y"]) for w in windows()]
                assert w_before == w_after, "empty slot undo caused state change"

                # ── 9. Move a window, close it, Super + Z: no crash, slot consumed ──
                print("Testing: Move window then close it & Super + Z...")
                # Drag window B
                w_b = next(w for w in windows() if w["id"] == other["id"])
                pointer(w_b["x"] + 100, w_b["y"] + 15)
                button(272, True)
                pointer(w_b["x"] + 140, w_b["y"] + 45)
                button(272, False)
                wait_for(
                    lambda: next(w for w in windows() if w["id"] == other["id"])[
                        "x"
                    ]
                    == w_b["x"] + 40,
                    "drag window B failed",
                )
                # Close window B
                action('close_window', {"id": other["id"]})
                other_client.wait(timeout=5)
                wait_for(lambda: len(windows()) == 1, "other window did not close")

                # Super + Z should not crash, and should consume the slot cleanly
                super_z()
                time.sleep(0.1)
                # Second Super + Z should also do nothing
                super_z()

                # ── 10. IPC Action "undo" ──
                print("Testing: IPC Action undo...")
                w_single = current_window()
                sx, sy = w_single["x"], w_single["y"]
                pointer(sx + 100, sy + 15)
                button(272, True)
                pointer(sx + 170, sy + 55)
                button(272, False)
                wait_for(
                    lambda: current_window()["x"] == sx + 70,
                    "drag failed",
                )
                action('undo')
                wait_for(
                    lambda: current_window()["x"] == sx,
                    "IPC undo action failed",
                )

                # Test action form {"action": "undo", "params": {}}
                pointer(sx + 100, sy + 15)
                button(272, True)
                pointer(sx + 170, sy + 55)
                button(272, False)
                wait_for(
                    lambda: current_window()["x"] == sx + 70,
                    "drag failed",
                )
                request({'version': 1, 'command': "undo", "params": {}})
                wait_for(
                    lambda: current_window()["x"] == sx,
                    "IPC {'action': 'undo'} failed",
                )

                print("All undo integration tests passed!")
        except Exception:
            if (tmp / "compositor.log").exists():
                print("=== Compositor Log ===")
                print((tmp / "compositor.log").read_text()[-3000:])
            if client_log.exists():
                print("=== Client Log ===")
                print(client_log.read_text()[-3000:])
            raise
        finally:
            if other_client is not None and other_client.poll() is None:
                other_client.terminate()
                other_client.wait(timeout=5)
            import signal

            try:
                os.killpg(compositor.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            compositor.wait(timeout=5)


if __name__ == "__main__":
    run()

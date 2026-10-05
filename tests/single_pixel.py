#!/usr/bin/env python3
"""Render real single-pixel buffers in an isolated headless compositor."""
import os
from pathlib import Path
import subprocess
import tempfile

from PIL import Image

from desktop_zoom import ROOT, wait_for
from ipc_client import IPCClient, spawn_compositor, stop_process


def build_client(tmp):
    protocols = Path(subprocess.check_output(
        ["pkg-config", "--variable=pkgdatadir", "wayland-protocols"], text=True).strip())
    sources = []
    for name, path in (
        ("xdg-shell", "stable/xdg-shell/xdg-shell.xml"),
        ("viewporter", "stable/viewporter/viewporter.xml"),
        ("single-pixel-buffer", "staging/single-pixel-buffer/single-pixel-buffer-v1.xml"),
    ):
        for mode, suffix in (("client-header", "client-protocol.h"), ("private-code", "protocol.c")):
            subprocess.run(["wayland-scanner", mode, str(protocols / path),
                            str(tmp / f"{name}-{suffix}")], check=True)
        sources.append(str(tmp / f"{name}-protocol.c"))
    subprocess.run(["cc", "-Wall", "-Wextra", "-Werror", f"-I{tmp}",
                    str(ROOT / "tests/single_pixel_client.c"), *sources,
                    "-lwayland-client", "-o", str(tmp / "client")], check=True)


def run():
    scale = float(os.environ.get("REDIWM_TEST_SCALE", "1"))
    renderer = os.environ.get("REDIWM_TEST_RENDERER", "pixman")
    with tempfile.TemporaryDirectory(prefix="rediwm-single-pixel-") as directory:
        tmp = Path(directory)
        build_client(tmp)
        compositor, log = spawn_compositor(
            tmp, scale=str(scale), renderer=renderer,
            config_content="[compositor]\nxwayland = false\n",
            env_extra={"XDG_CACHE_HOME": str(tmp / "cache"), "WLR_RENDERER_ALLOW_SOFTWARE": "1"})
        client = None
        client_log = tmp / "client.log"
        try:
            socket_path = wait_for(lambda: next(tmp.glob("rediwm-*.sock"), None), "IPC unavailable")
            display = next(p.name for p in tmp.glob("wayland-*") if not p.name.endswith(".lock"))
            with client_log.open("w") as output:
                client = subprocess.Popen([str(tmp / "client")], stdin=subprocess.PIPE,
                                          stdout=output, stderr=output, text=True,
                                          env=dict(os.environ, XDG_RUNTIME_DIR=str(tmp), WAYLAND_DISPLAY=display))
            with IPCClient(socket_path) as ipc:
                win = wait_for(lambda: next((w for w in ipc.get_windows()
                                             if w["app_id"] == "rediwm.single-pixel-fixture"), None),
                               "single-pixel toplevel did not map")
                assert (win["width"], win["height"]) == (320, 240), win
                wait_for(lambda: "frame 1\n" in client_log.read_text(), "frame callback missing")
                ipc.action("move_window_to", {"id": win["id"], "x": 100, "y": 100})
                ipc.move_cursor(0, 0)
                commands = 0
                captures = 0

                def send(command):
                    nonlocal commands
                    client.stdin.write(command + "\n")
                    client.stdin.flush()
                    commands += 1
                    wait_for(lambda: f"done {commands}\n" in client_log.read_text(),
                             f"client did not finish {command!r}")

                def color(r, g, b, a=255):
                    # Express 8-bit test values over the protocol's full u32 range.
                    send("color " + " ".join(str(v * 0x01010101) for v in (r, g, b, a)))

                def capture():
                    nonlocal captures
                    captures += 1
                    path = tmp / f"capture-{captures}.png"
                    ipc.screenshot(path=str(path))
                    with Image.open(path) as image:
                        return image.convert("RGB")

                def expect(image, x, y, rgb):
                    window = next(w for w in ipc.get_windows() if w["id"] == win["id"])
                    camera = ipc.action("get_camera")
                    zoom = window["zoom_percent"] / 100
                    px = ((window["x"] - camera["x"]) * camera["zoom_percent"] / 100 + x * zoom) * scale
                    py = ((window["y"] - camera["y"]) * camera["zoom_percent"] / 100 + y * zoom) * scale
                    actual = image.getpixel((round(px), round(py)))
                    assert all(abs(a - b) <= 1 for a, b in zip(actual, rgb)), (x, y, actual, rgb)

                image = capture()
                expect(image, 20, 20, (0, 0, 255))
                for x, y in ((45, 55), (100, 100), (195, 145)):
                    expect(image, x, y, (255, 0, 0))

                # Replacement damage, channel order, premultiplied alpha and zero alpha.
                for rgba, expected in (
                    ((0, 255, 0, 255), (0, 255, 0)),
                    ((32, 128, 192, 255), (32, 128, 192)),
                    ((128, 0, 0, 128), (128, 0, 127)),
                    ((64, 32, 16, 128), (64, 32, 143)),
                    ((0, 0, 0, 0), (0, 0, 255)),
                ):
                    color(*rgba)
                    expect(capture(), 100, 100, expected)
                wait_for(lambda: "release 2\n" in client_log.read_text(), "replaced buffer was not released")

                color(0, 255, 0)
                send("resize 80 60")  # No new buffer or damage; viewport state alone changes bounds.
                image = capture()
                expect(image, 115, 105, (0, 255, 0))
                expect(image, 125, 105, (0, 0, 255))
                expect(image, 115, 115, (0, 0, 255))
                send("resize 160 100")
                expect(capture(), 195, 145, (0, 255, 0))

                send("shm")
                expect(capture(), 100, 100, (255, 0, 255))
                send("single")
                expect(capture(), 100, 100, (0, 255, 0))
                send("hide")
                expect(capture(), 100, 100, (0, 0, 255))
                send("single")
                expect(capture(), 100, 100, (0, 255, 0))

                # Projection must preserve cached colors and viewport geometry.
                ipc.set_zoom(win["id"], 70)
                image = capture()
                expect(image, 20, 20, (0, 0, 255))
                expect(image, 195, 145, (0, 255, 0))
                ipc.action("set_zoom", {"percent": 70})
                image = capture()
                expect(image, 20, 20, (0, 0, 255))
                expect(image, 195, 145, (0, 255, 0))
                color(128, 0, 0, 128)
                expect(capture(), 100, 100, (128, 0, 127))
                ipc.action("set_zoom", {"percent": 100})
                ipc.set_zoom(win["id"], 100)

                # Destroying the factory leaves its buffers usable. Destroying
                # an attached wl_buffer leaves the current surface content intact.
                send("manager")
                send("hide")
                expect(capture(), 100, 100, (0, 0, 255))
                send("single")
                expect(capture(), 100, 100, (128, 0, 127))
                send("destroy_buffer")
                send("resize 100 80")
                image = capture()
                expect(image, 100, 100, (128, 0, 127))
                expect(image, 150, 100, (0, 0, 255))

                # A live surface during orderly shutdown exercises buffer/global cleanup.
                for keycode in (125, 42):
                    ipc.action("key", {"keycode": keycode, "pressed": True})
                try:
                    ipc.action("key", {"keycode": 18, "pressed": True})
                except EOFError:
                    pass
            compositor.wait(timeout=10)
            assert compositor.returncode == 0, (tmp / "compositor.log").read_text()
            print(f"single-pixel: rendered colors, alpha, viewports, zoom and lifecycle passed ({renderer}, {scale:g}x)")
        except Exception:
            print((tmp / "compositor.log").read_text()[-6000:])
            if client_log.exists():
                print(client_log.read_text())
            raise
        finally:
            if client:
                if client.poll() is None:
                    stop_process(client)
                client.stdin.close()
            if compositor.poll() is None:
                stop_process(compositor)
            log.close()


if __name__ == "__main__":
    run()

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
        ("alpha-modifier", "staging/alpha-modifier/alpha-modifier-v1.xml"),
        ("ext-background-effect", "staging/ext-background-effect/ext-background-effect-v1.xml"),
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


def check_surface_effects(ipc, tmp, client_log, send, color, capture, pixel, expect):
    # Surface-only commits multiply premultiplied colour and alpha.
    send("alpha 2147483648")
    expect(capture(), 100, 100, (0, 255, 0))
    send("commit-child")
    expect(capture(), 100, 100, (0, 128, 127))
    send("shm")
    expect(capture(), 100, 100, (128, 0, 255))

    # Reload window opacity while the client multiplier is live, and
    # commit again. The magenta subsurface now covers 1/4 of the base.
    config_path = tmp / "rediwm-config.toml"
    original = config_path.read_text()
    config_path.write_text(original + '\n[[window_rules]]\napp_id = "rediwm.single-pixel-fixture"\nopacity = 0.5\n')
    ipc.reload_config()
    send("alpha 0")
    send("commit-child")
    base = pixel(capture(), 100, 100)
    send("alpha 2147483648")
    send("commit-child")
    expected = tuple(round(bg * .75 + fg * .25) for bg, fg in zip(base, (255, 0, 255)))
    expect(capture(), 100, 100, expected)
    config_path.write_text(original)
    ipc.reload_config()
    expect(capture(), 100, 100, (128, 0, 255))
    send("alpha-release")
    expect(capture(), 100, 100, (128, 0, 255))
    send("commit-child")
    expect(capture(), 100, 100, (255, 0, 255))

    # A transparent synchronized child blurs two bands over the
    # parent's blue/white edge. The hole retains the exact base pixels.
    color(0, 0, 0, 0)
    send("pattern")
    blur = "REDIWM_NO_GLASS" not in os.environ
    assert f"blur-capability {int(blur)}" in client_log.read_text()
    baseline = capture()
    send("blur-bands")
    expect(capture(), 152, 68, pixel(baseline, 152, 68))
    send("commit-parent")
    blurred = capture()
    for y in (68, 132):
        if blur:
            assert pixel(blurred, 152, y)[0] > pixel(baseline, 152, y)[0] + 12
        else:
            expect(blurred, 152, y, pixel(baseline, 152, y))
    for y in (45, 100, 155):
        expect(blurred, 152, y, pixel(baseline, 152, y))
    send("blur-release")
    expect(capture(), 152, 68, pixel(blurred, 152, 68))
    send("commit-child")
    expect(capture(), 152, 68, pixel(blurred, 152, 68))
    send("commit-parent")
    expect(capture(), 152, 68, pixel(baseline, 152, 68))
    # Rebind and change only the hole, keeping the same extents. Zooming
    # moves every mask edge with the window.
    window_id = next(w["id"] for w in ipc.get_windows() if w["app_id"] == "rediwm.single-pixel-fixture")
    ipc.set_zoom(window_id, 70)
    send("blur-bands")
    send("commit-parent")
    with_hole = capture()
    send("blur-full")
    send("commit-parent")
    full = capture()
    send("blur-null")
    send("commit-parent")
    clear = capture()
    expect(with_hole, 152, 100, pixel(clear, 152, 100))
    for image, y in ((with_hole, 68), (full, 100)):
        if blur:
            assert pixel(image, 152, y)[0] > pixel(clear, 152, y)[0] + 12
        else:
            expect(image, 152, y, pixel(clear, 152, y))
    ipc.set_zoom(window_id, 100)
    color(0, 255, 0)
    send("background")


def run():
    scale = float(os.environ.get("REDIWM_TEST_SCALE", "1"))
    renderer = os.environ.get("REDIWM_TEST_RENDERER", "gles2")
    with tempfile.TemporaryDirectory(prefix="rediwm-single-pixel-") as directory:
        tmp = Path(directory)
        build_client(tmp)
        compositor, log = spawn_compositor(
            tmp, scale=str(scale), renderer=renderer,
            config_content="[compositor]\nxwayland = false\n[animations]\nenabled = false\n",
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

                def pixel(image, x, y):
                    window = next(w for w in ipc.get_windows() if w["id"] == win["id"])
                    camera = ipc.action("get_camera")
                    debug = ipc.get_window_debug(win["id"])
                    zoom = debug["effective_zoom"]
                    camera_zoom = camera["zoom_percent"] / 100
                    client = debug["client_box"]
                    px = ((window["x"] - camera["x"]) * camera_zoom + (client["x"] - window["x"] + x) * zoom) * scale
                    py = ((window["y"] - camera["y"]) * camera_zoom + (client["y"] - window["y"] + y) * zoom) * scale
                    return image.getpixel((round(px), round(py)))

                def expect(image, x, y, rgb):
                    actual = pixel(image, x, y)
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

                check_surface_effects(ipc, tmp, client_log, send, color, capture, pixel, expect)

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

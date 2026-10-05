#!/usr/bin/env python3
"""Titlebar blur hold during interactive moves, checked by pixels.

A nearly opaque titlebar keeps its last blur while dragged and refreshes it on
release; a translucent one follows the backdrop every frame. Requires GLES2
(glass is disabled on pixman), so this defaults REDIWM_TEST_RENDERER to gles2.
Creates its own Wayland runtime and clients; never connects to the host desktop.
"""
import os
from pathlib import Path
import subprocess
import tempfile
import time

from PIL import Image, ImageChops

from desktop_zoom import ROOT, build_client, wait_for
from ipc_client import IPCClient

SCALE = 1.5
TITLEBAR_HEIGHT = 55  # chrome.titlebar_height
START, GRAB, DROP = (100, 60), (300, 80), (700, 330)


def session(tmp, window_bg, drag, holds=False):
    """Drag from START to DROP, or place the window where a drag ended."""
    config = tmp / "config.toml"
    config.write_text(f'[theme]\nwindow_bg = "{window_bg}"\n' if window_bg else "")
    runtime = Path(tempfile.mkdtemp(prefix="runtime-", dir=tmp))
    env = dict(os.environ, XDG_RUNTIME_DIR=str(runtime), XDG_CONFIG_HOME=str(runtime / "config"),
               XDG_CACHE_HOME=str(runtime / "cache"), XDG_DATA_HOME=str(runtime / "data"),
               REDIWM_CONFIG=str(config), WLR_BACKENDS="headless", WLR_HEADLESS_OUTPUTS="1",
               WLR_RENDERER=os.environ.get("REDIWM_TEST_RENDERER", "gles2"),
               WLR_RENDERER_ALLOW_SOFTWARE="1", REDIWM_SCALE=str(SCALE),
               REDIWM_TEST_DECORATION="server", DBUS_SESSION_BUS_ADDRESS="")
    env.pop("WAYLAND_DISPLAY", None)
    env.pop("REDIWM_SOCKET", None)
    processes = []
    log_path = runtime / "compositor.log"
    try:
        with log_path.open("w") as log:
            processes.append(subprocess.Popen([str(ROOT / "zig-out/bin/rediwm")], env=env, stdout=log, stderr=log))
        socket = wait_for(lambda: next(runtime.glob("rediwm-*.sock"), None), "IPC unavailable")
        display = wait_for(lambda: next((p.name for p in runtime.glob("wayland-*") if not p.name.endswith(".lock")), None), "display unavailable")
        with IPCClient(socket) as ipc:
            ipc.action('wait_for', {"condition": "wallpaper_presented", "timeout_ms": 10000})
            processes.append(subprocess.Popen([str(tmp / "client")], env=dict(env, WAYLAND_DISPLAY=display),
                                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
            win = wait_for(lambda: next(iter(ipc.get_windows()), None), "window unavailable")
            time.sleep(.5)
            shots = {}
            if drag is None:
                ipc.action('move_window_to', {"id": win["id"], "x": START[0], "y": START[1]})
                ipc.move_cursor(*GRAB)
                time.sleep(.4)
                ipc.action('pointer_button', {"button": 272, "pressed": True})
                for step in range(1, 61):
                    ipc.move_cursor(GRAB[0] + (DROP[0] - GRAB[0]) * step // 60,
                                    GRAB[1] + (DROP[1] - GRAB[1]) * step // 60)
                    time.sleep(1 / 120)
                time.sleep(.4)
                shots["held"] = runtime / "held.png"
                ipc.action('screenshot', {"path": str(shots["held"])})
                ipc.action("reset_performance_stats")
                ipc.action('pointer_button', {"button": 272, "pressed": False})
                time.sleep(.4)
                # Nothing else damages the output: only the release frame can
                # refresh the blur, before the screenshot forces one of its own.
                # A blur that followed the drag has nothing left to present, so
                # that frame's commit is skipped as redundant.
                perf = ipc.get_perf()
                assert perf["output_commits"] + perf["output_skipped_commits"] > 0, "release scheduled no frame"
                if holds:
                    assert perf["output_commits"] > 0, "release frame did not present the refreshed blur"
                shots["released"] = runtime / "released.png"
                ipc.action('screenshot', {"path": str(shots["released"])})
            else:
                ipc.action('move_window_to', {"id": win["id"], "x": drag["x"], "y": drag["y"]})
                ipc.move_cursor(*DROP)
                time.sleep(.6)
                shots["reference"] = runtime / "reference.png"
                ipc.action('screenshot', {"path": str(shots["reference"])})
            window = ipc.get_windows()[0]
            assert processes[1].poll() is None
            return window, {name: crop_titlebar(path, window) for name, path in shots.items()}
    except Exception:
        print(log_path.read_text()[-3000:])
        raise
    finally:
        for process in reversed(processes):
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=3)


def crop_titlebar(path, window):
    box = [round(v * SCALE) for v in (window["x"], window["y"],
                                      window["x"] + window["width"], window["y"] + TITLEBAR_HEIGHT)]
    return Image.open(path).convert("RGB").crop(box)


def differs(a, b):
    return ImageChops.difference(a, b).getbbox() is not None


def run():
    with tempfile.TemporaryDirectory(prefix="rediwm-glass-hold-") as directory:
        tmp = Path(directory)
        build_client(tmp)
        # 250/255 is the nearest hex alpha at or above the 98% threshold.
        for window_bg, holds in ((None, True), ("#101215fa", True), ("rgba(16,18,21,0.90)", False)):
            moved, drag = session(tmp, window_bg, None, holds)
            placed, reference = session(tmp, window_bg, moved)
            assert (placed["x"], placed["y"]) == (moved["x"], moved["y"]), (placed, moved)
            name = window_bg or "default"
            assert differs(drag["held"], reference["reference"]) == holds, (name, "held drag frame")
            assert not differs(drag["released"], reference["reference"]), (name, "release did not refresh the blur")
            print(f"PASS: {name} window_bg {'holds' if holds else 'follows'} the titlebar blur during a move")


if __name__ == "__main__":
    run()

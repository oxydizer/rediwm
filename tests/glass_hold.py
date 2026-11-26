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

from PIL import Image, ImageChops, ImageStat

from desktop_zoom import ROOT, build_client, wait_for
from ipc_client import IPCClient, spawn_compositor, stop_process
from scrolling import Session

SCALE = 1.5
START, GRAB, DROP = (100, 60), (300, 80), (700, 330)


def session(tmp, window_bg, drag, holds=False):
    """Drag from START to DROP, or place the window where a drag ended."""
    config = tmp / "config.toml"
    # Compare the same frame geometry during and after the grab.
    config.write_text('[compositor]\ndrag_feedback = false\n' +
                      (f'[theme]\nwindow_bg = "{window_bg}"\n' if window_bg else ""))
    runtime = Path(tempfile.mkdtemp(prefix="runtime-", dir=tmp))
    env = dict(os.environ, XDG_RUNTIME_DIR=str(runtime), XDG_CONFIG_HOME=str(runtime / "config"),
               XDG_CACHE_HOME=str(runtime / "cache"), XDG_DATA_HOME=str(runtime / "data"),
               XDG_STATE_HOME=str(runtime / "state"), REDIWM_CONFIG=str(config), REDIWM_THEME=str(config),
               REDIWM_IPC_AUTOMATION="1", WLR_BACKENDS="headless", WLR_HEADLESS_OUTPUTS="1",
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
    # Hover changes the window's outer ring during a grab. Sample glass
    # inside the titlebar, clear of that ring and its rounded corners.
    box = [round(v * SCALE) for v in (window["x"] + 16, window["y"] + 8,
                                      window["x"] + window["width"] - 16, window["y"] + 32)]
    return Image.open(path).convert("RGB").crop(box)


def differs(a, b):
    return ImageChops.difference(a, b).getbbox() is not None


def mixed_scale_idle():
    """Outputs of different scales share glass effects; a static desktop must stay idle.

    The effect's scale is part of its hash, so rendering it for whichever output
    was updating made each output re-blur it and damage the other, forever.
    """
    with tempfile.TemporaryDirectory(prefix="rediwm-glass-mixed-") as directory:
        tmp = Path(directory)
        build_client(tmp)
        # Mixer reconnects and clock ticks can repaint an otherwise idle bar.
        config = ('[compositor]\nxwayland = false\ntaskbar_items = ["-volume", "-clock", "-network", "-battery"]\n'
                  '[[outputs]]\nname = "HEADLESS-1"\nscale = 1\n'
                  '[[outputs]]\nname = "HEADLESS-2"\nscale = 1.5\n')
        process, log = spawn_compositor(
            tmp, scale="auto", outputs="2", config_content=config,
            renderer=os.environ.get("REDIWM_TEST_RENDERER", "gles2"),
            env_extra={"DBUS_SESSION_BUS_ADDRESS": "", "REDIWM_THEME": str(tmp / "rediwm-config.toml")})
        client = None
        try:
            with IPCClient(tmp) as ipc:
                ipc.wait_for("wallpaper_presented", timeout_ms=10000)
                outputs = sorted(ipc.get_outputs(), key=lambda out: out["x"])
                assert sorted(out["scale"] for out in outputs) == [1, 1.5], outputs
                display = wait_for(lambda: next((p.name for p in tmp.glob("wayland-*")
                                                 if not p.name.endswith(".lock")), None), "display unavailable")
                client = subprocess.Popen([str(tmp / "client")], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                          env=dict(os.environ, XDG_RUNTIME_DIR=str(tmp), WAYLAND_DISPLAY=display,
                                                   REDIWM_TEST_DECORATION="server"))
                win = wait_for(lambda: next(iter(ipc.get_windows()), None), "window unavailable")
                # Straddle the boundary so its titlebar glass is seen by both outputs.
                ipc.action("move_window_to", {"id": win["id"], "x": outputs[1]["x"] - 200, "y": 120})
                time.sleep(1.0)
                ipc.wait_for_frame()
                ipc.reset_perf()
                time.sleep(1.5)
                perf = ipc.get_perf()
                assert perf["output_commits"] == 0, ("mixed-scale desktop keeps repainting", perf["output_commits"])
                print("PASS: outputs of different scales settle with a glass window across both")
        except Exception:
            print(log_text(tmp))
            raise
        finally:
            if client is not None and client.poll() is None:
                client.terminate()
                client.wait(timeout=3)
            stop_process(process)
            log.close()


def log_text(tmp):
    path = tmp / "compositor.log"
    return path.read_text()[-3000:] if path.exists() else ""


def stationary_strip_backdrop():
    """A stationary floating titlebar refreshes after a strip reveal."""
    with tempfile.TemporaryDirectory(prefix="rediwm-scroll-glass-") as directory:
        tmp = Path(directory)
        build_client(tmp)
        s = Session(tmp, '[compositor]\nxwayland = false\ndesktop_mode = "scrolling"\n'
                         'scroll_column_width = 1.0\n[theme]\nwindow_bg = "#10121580"\n'
                         '[animations]\nreduced_motion = "off"\n')
        try:
            red = s.launch("red", REDIWM_TEST_EDGE="1")
            blue = s.launch("blue")
            panel = s.launch("floating")
            s.ipc.action("tiling_action", {"action": "toggle_floating", "id": panel})
            out = s.ipc.get_outputs()[0]
            x, y = out["logical_width"] // 4, 2 * out["logical_height"] // 3
            s.ipc.action("move_window_to", {"id": panel, "x": x, "y": y})
            s.settled(panel)

            def titlebar_sample(window):
                path = tmp / f"panel-{window}.png"
                s.ipc.focus_window(window)
                # An overlapping window is safe to sample once its strip settles.
                s.settled(panel)
                s.ipc.screenshot(path=str(path))
                scale = out["scale"]
                with Image.open(path) as image:
                    patch = image.crop(tuple(round(v * scale) for v in (x + 30, y + 8, x + 60, y + 18)))
                    return ImageStat.Stat(patch).mean[:3]

            r, _, b = titlebar_sample(red)
            assert r > b + 10, ("initial red backdrop", r, b)
            r, _, b = titlebar_sample(blue)
            assert b > r + 10, ("settled blue backdrop", r, b)
        finally:
            s.stop()
    print("PASS: stationary glass refreshes when the strip settles")


def run():
    mixed_scale_idle()
    stationary_strip_backdrop()
    with tempfile.TemporaryDirectory(prefix="rediwm-glass-hold-") as directory:
        tmp = Path(directory)
        build_client(tmp)
        # 250/255 is the nearest hex alpha at or above the 98% threshold. The default
        # theme is 80% opaque, so it follows the backdrop like the 90% case.
        for window_bg, holds in ((None, False), ("#101215fa", True), ("rgba(16,18,21,0.90)", False)):
            moved, drag = session(tmp, window_bg, None, holds)
            placed, reference = session(tmp, window_bg, moved)
            assert (placed["x"], placed["y"]) == (moved["x"], moved["y"]), (placed, moved)
            name = window_bg or "default"
            assert differs(drag["held"], reference["reference"]) == holds, (name, "held drag frame")
            assert not differs(drag["released"], reference["reference"]), (name, "release did not refresh the blur")
            print(f"PASS: {name} window_bg {'holds' if holds else 'follows'} the titlebar blur during a move")


if __name__ == "__main__":
    run()

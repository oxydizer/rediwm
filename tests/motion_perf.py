#!/usr/bin/env python3
"""Isolated pointer/drag measurements; no input reaches the host session.

Run optimized builds with the same REDIWM_TEST_RENDERER and REDIWM_TEST_SCALE.
CPU percentages use /proc process ticks (100% = one core); frame timers are
wall time. Headless pacing and software rendering differ from a real desktop.
"""
import argparse
import json
import math
import os
from pathlib import Path
import subprocess
import tempfile
import time

from desktop_zoom import ROOT, build_client, wait_for
from ipc_client import IPCClient


def cpu_seconds(process):
    fields = Path(f"/proc/{process.pid}/stat").read_text().rsplit(")", 1)[1].split()
    return (int(fields[11]) + int(fields[12])) / os.sysconf("SC_CLK_TCK")


def run(args):
    with tempfile.TemporaryDirectory(prefix="rediwm-motion-") as directory:
        tmp = Path(directory)
        if not args.selection_only:
            build_client(tmp)
        (tmp / "config.toml").write_text("[desktop]\nenabled = true\n")
        desktop_dir = tmp / "Desktop"
        desktop_dir.mkdir()
        for index in range(args.icons):
            (desktop_dir / f"Motion {index:02d}.txt").write_text("motion fixture")
        env = dict(os.environ, XDG_RUNTIME_DIR=directory,
                   XDG_CONFIG_HOME=str(tmp / "config"), XDG_CACHE_HOME=str(tmp / "cache"),
                   XDG_DATA_HOME=str(tmp / "data"), REDIWM_DESKTOP_DIR=str(desktop_dir),
                   REDIWM_CONFIG=str(tmp / "config.toml"), WLR_BACKENDS="headless",
                   WLR_HEADLESS_OUTPUTS="1", WLR_RENDERER_ALLOW_SOFTWARE="1",
                   WLR_RENDERER=os.environ.get("REDIWM_TEST_RENDERER", "pixman"),
                   REDIWM_SCALE=os.environ.get("REDIWM_TEST_SCALE", "1"),
                   REDIWM_TEST_DECORATION="server", DBUS_SESSION_BUS_ADDRESS="")
        env.pop("WAYLAND_DISPLAY", None)
        env.pop("REDIWM_SOCKET", None)
        processes = []

        def start(binary, name, **extra):
            with (tmp / f"{name}.log").open("w") as log:
                process = subprocess.Popen([str(binary)], env=dict(env, **extra), stdout=log, stderr=log)
            processes.append(process)
            return process

        try:
            compositor = start(args.bin_dir / "rediwm", "compositor")
            socket = wait_for(lambda: next(tmp.glob("rediwm-*.sock"), None), "IPC unavailable")
            display = wait_for(lambda: next((p.name for p in tmp.glob("wayland-*") if not p.name.endswith(".lock")), None), "display unavailable")
            with IPCClient(socket) as ipc:
                ipc.action('wait_for', {"condition": "wallpaper_presented", "timeout_ms": 10000})
                wait_for(lambda: (tmp / "config/rediwm-desktop/layout.toml").exists(), "desktop never saved its layout")
                time.sleep(1)
                output = ipc.get_outputs()[0]
                width = output["logical_width"]
                height = output["logical_height"]

                def measure(name, motion, stable=False):
                    # The desktop's own counters: canvas repaints, tiles handed
                    # to the scene, and textures created instead of updated.
                    ipc.action("reset_performance_stats")
                    before = cpu_seconds(compositor)
                    started = time.monotonic()
                    count = 0
                    while time.monotonic() - started < args.seconds:
                        motion(count)
                        count += 1
                        time.sleep(max(0, started + count / args.rate - time.monotonic()))
                    time.sleep(.05)  # Drain the final input and its frame.
                    elapsed = time.monotonic() - started
                    cpu = (cpu_seconds(compositor) - before) * 100 / elapsed
                    stats = ipc.get_perf()
                    desktop = stats["desktop"]
                    paints = desktop["paints"]
                    print(json.dumps({"workload": name, "renderer": env["WLR_RENDERER"],
                                      "scale": env["REDIWM_SCALE"], "motions": count,
                                      "icons": args.icons, "elapsed_seconds": elapsed,
                                      "cpu_percent": {"compositor": cpu},
                                      "desktop_paints": paints,
                                      "desktop_tile_presents": desktop["tile_presents"],
                                      "desktop_texture_uploads": desktop["texture_uploads"],
                                      "desktop_damage_pixels": desktop["damage_pixels"],
                                      "desktop_damage_fraction": desktop["damage_pixels"] / (width * height * paints) if paints else 0,
                                      "output_commits": stats["output_commits"],
                                      "titlebar_paints": stats["titlebar_paints"],
                                      "frame_work": stats["frame_work"]}), flush=True)
                    assert stats["output_failed_commits"] == 0, stats
                    if stable and not args.allow_repaints:
                        assert paints == 0, (name, "unchanged desktop repainted", paints)

                ipc.move_cursor(200, 200)
                time.sleep(.4)
                measure("idle", lambda n: None, stable=True)
                if not args.selection_only:
                    measure("empty desktop motion", lambda n: ipc.move_cursor(200 + n % 100, 200), stable=True)
                ipc.move_cursor(width - 70, 60)
                time.sleep(.4)
                if not args.selection_only:
                    measure("settled icon hover", lambda n: ipc.move_cursor(width - 70 + n % 10, 60), stable=True)

                # Start outside the grid and repeatedly grow/shrink through
                # several rows and columns. Keep the output and input rate
                # identical when comparing builds.
                ipc.move_cursor(width - 500, 10)
                ipc.action('pointer_button', {"button": 272, "pressed": True})
                measure("desktop selection", lambda n: ipc.move_cursor(
                    round(width - 300 + 250 * math.sin(n / args.rate * 2 * math.pi)),
                    round(280 + 220 * math.cos(n / args.rate * 2 * math.pi))))
                ipc.action('pointer_button', {"button": 272, "pressed": False})
                ipc.move_cursor(200, 200)
                time.sleep(.4)
                measure("idle after selection", lambda n: None, stable=True)
                if args.selection_only:
                    return

                client = start(tmp / "client", "client", WAYLAND_DISPLAY=display)
                win = wait_for(lambda: next(iter(ipc.get_windows()), None), "window unavailable")
                ipc.action('move_window_to', {"id": win["id"], "x": 100, "y": 100})
                time.sleep(.4)
                # Cross the window boundary repeatedly to animate its border.
                measure("window hover", lambda n: ipc.move_cursor(200, 120 if n % 60 < 30 else 80))
                ipc.move_cursor(200, 120)
                time.sleep(.4)
                ipc.action('pointer_button', {"button": 272, "pressed": True})
                measure("window drag", lambda n: ipc.move_cursor(201 + n % 100, 121 + n % 40))
                ipc.action('pointer_button', {"button": 272, "pressed": False})
                moved = ipc.get_windows()[0]
                assert (moved["x"], moved["y"]) != (100, 100), moved
                # Pan input updates camera state immediately, but scene
                # projection should run at presentation rate, not mouse rate.
                ipc.move_cursor(500, 350)
                ipc.key(125, True)  # KEY_LEFTMETA + KEY_LEFTALT: the pan trigger
                ipc.key(56, True)
                measure("desktop pan", lambda n: ipc.move_cursor(
                    500 + round(100 * math.sin(n / args.rate * 2 * math.pi)),
                    350 + round(60 * math.cos(n / args.rate * 2 * math.pi))))
                ipc.key(56, False)
                ipc.key(125, False)
                ipc.action("reset_camera")
                time.sleep(.4)
                if args.capture_dir:
                    args.capture_dir.mkdir(parents=True, exist_ok=True)
                    ipc.action('move_window_to', {"id": win["id"], "x": 100, "y": 100})
                    right = 100 + moved["width"]
                    for name, point in (("idle", (200, 80)), ("hover", (200, 120)),
                                        ("minimize", (right - 106, 125)),
                                        ("maximize", (right - 68, 125)),
                                        ("close", (right - 30, 125))):
                        ipc.move_cursor(*point)
                        time.sleep(.4)
                        ipc.action('screenshot', {"path": str(args.capture_dir.resolve() / f"{name}.png")})
                    ipc.maximize(win["id"])
                    ipc.move_cursor(200, 300)
                    time.sleep(.4)
                    ipc.action('screenshot', {"path": str(args.capture_dir.resolve() / "maximized.png")})
                assert client.poll() is None
        except Exception:
            for path in tmp.glob("*.log"):
                print(path.name, path.read_text()[-3000:])
            raise
        finally:
            for process in reversed(processes):
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=3)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bin-dir", type=Path, default=ROOT / "zig-out/bin")
    parser.add_argument("--seconds", type=float, default=3)
    parser.add_argument("--rate", type=float, default=120)
    parser.add_argument("--icons", type=int, default=24, help="Desktop icon count (default 24)")
    parser.add_argument("--selection-only", action="store_true", help="Measure selection and idle without window workloads")
    parser.add_argument("--allow-repaints", action="store_true", help="Measure builds that repaint an unchanged desktop")
    parser.add_argument("--capture-dir", type=Path, help="Save settled window screenshots for before/after pixel comparison")
    args = parser.parse_args()
    if not all(math.isfinite(n) and n > 0 for n in (args.seconds, args.rate)):
        parser.error("seconds and rate must be finite and positive")
    if args.icons < 1:
        parser.error("icons must be positive")
    run(args)

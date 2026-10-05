#!/usr/bin/env python3
"""Frame-work and present-loop measurement via GetPerformanceStats. Run after zig build.

REDIWM_TEST_RENDERER=pixman|gles2 selects the headless renderer.
REDIWM_TEST_BACKEND=wayland uses the host session (vsync); default is headless.
"""
import argparse
import math
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

from desktop_zoom import ROOT, build_client, wait_for
from ipc_client import IPCClient


def validate(stats, require_frames=True):
    """Check measurements, never enforce machine-dependent speed thresholds."""
    if "frame_work" not in stats:
        raise SystemExit("Frame-work counters are missing; rebuild and restart the compositor first.")
    work = stats["frame_work"]
    stages = ["cpu_frame", "taskbar_cpu", "chrome_cpu", "panels_cpu", "glass_cpu", "scene_commit_cpu", "gpu_elapsed"]
    if "projection_cpu" in work:  # Older binaries predate this stage timer.
        stages.append("projection_cpu")
    if "anim_cpu" in work:
        stages.append("anim_cpu")
    for name in stages:
        summary = work[name]
        assert 0 <= summary["samples"] <= 512, summary
        assert summary["total_samples"] >= summary["samples"], summary
        for field in ("avg_ms", "p50_ms", "p95_ms", "p99_ms", "max_ms"):
            assert math.isfinite(summary[field]) and summary[field] >= 0, summary
        assert summary["p50_ms"] <= summary["p95_ms"] <= summary["p99_ms"] <= summary["max_ms"], summary
        assert summary["avg_ms"] <= summary["max_ms"] + 1e-9, summary
        if summary["samples"] == 0:
            assert summary["max_ms"] == summary["avg_ms"] == 0, summary
    if require_frames:
        assert work["cpu_frame"]["total_samples"] > 0, work
        assert work["cpu_frame"]["max_ms"] > 0, work
        assert work["scene_commit_cpu"]["total_samples"] > 0, work
    if "projection_cpu" in work:
        assert work["cpu_frame"]["total_samples"] >= work["projection_cpu"]["total_samples"], work
    assert work["cpu_frame"]["total_samples"] >= work["glass_cpu"]["total_samples"], work
    assert work["cpu_frame"]["total_samples"] >= work["scene_commit_cpu"]["total_samples"], work
    if not work["gpu_timing_available"]:
        assert work["gpu_elapsed"]["total_samples"] == 0, work
    assert stats["output_failed_commits"] == 0, stats


def measure(ipc, seconds=2.0):
    ipc.action("reset_performance_stats")
    time.sleep(seconds)
    return ipc.get_perf()


def summarize(label, stats):
    paints = stats.get("taskbar_paints") or 0
    paint_ns = stats.get("taskbar_paint_ns") or 0
    decode_count = stats.get("icon_decode_count") or 0
    decode_ns = stats.get("icon_decode_ns") or 0
    print(f"{label}:")
    print(json.dumps({
        "fps": stats.get("fps"),
        "commit_interval_ms": stats.get("frame_time_ms"),
        "frame_work": stats["frame_work"],
        "missed_frames": stats.get("missed_frames"),
        "refresh_hz": stats.get("refresh_hz"),
        "output_commits": stats.get("output_commits"),
        "output_failed_commits": stats.get("output_failed_commits"),
        "titlebar_paints": stats.get("titlebar_paints"),
        "footer_paints": stats.get("footer_paints"),
        "edge_samples_attempted": stats.get("edge_samples_attempted"),
        "edge_samples_succeeded": stats.get("edge_samples_succeeded"),
        "edge_samples_skipped": stats.get("edge_samples_skipped"),
        "taskbar_paints": paints,
        "taskbar_paint_ms_avg": round(paint_ns / paints / 1e6, 3) if paints else 0,
        "taskbar_raster_pixels": stats.get("taskbar_raster_pixels"),
        "panel_paints": stats.get("panel_paints"),
        "anim_frames_scheduled": stats.get("anim_frames_scheduled"),
        "anim_wasted_wakeups": stats.get("anim_wasted_wakeups"),
        "anim_longest_ms": stats.get("anim_longest_ms"),
        "anim_sampling_budget_ms": 0.2,
        "taskbar_clock_frame_requests": stats.get("taskbar_clock_frame_requests"),
        "taskbar_clock_paints": stats.get("taskbar_clock_paints"),
        "taskbar_start_paints": stats.get("taskbar_start_paints"),
        "taskbar_chip_paints": stats.get("taskbar_chip_paints"),
        "taskbar_tray_paints": stats.get("taskbar_tray_paints"),
        "taskbar_hover_paints": stats.get("taskbar_hover_paints"),
        "taskbar_press_paints": stats.get("taskbar_press_paints"),
        "taskbar_audio_paints": stats.get("taskbar_audio_paints"),
        "icon_cache_hits": stats.get("icon_cache_hits"),
        "icon_cache_misses": stats.get("icon_cache_misses"),
        "icon_decode_count": stats.get("icon_decode_count"),
        "icon_decode_ms_avg": round(decode_ns / decode_count / 1e6, 3) if decode_count else 0,
        "icon_decoded_bytes": stats.get("icon_decoded_bytes"),
        "icon_queue_depth_max": stats.get("icon_queue_depth_max"),
    }, indent=2))


def run(binary=None):
    renderer = os.environ.get("REDIWM_TEST_RENDERER", "pixman")
    backend = os.environ.get("REDIWM_TEST_BACKEND", "headless")
    seconds = float(os.environ.get("REDIWM_TEST_PERF_SECONDS", "2"))
    if not math.isfinite(seconds) or seconds <= 0:
        raise SystemExit("REDIWM_TEST_PERF_SECONDS must be finite and positive")
    host_display = os.environ.get("WAYLAND_DISPLAY")
    host_runtime = os.environ.get("XDG_RUNTIME_DIR")
    if backend == "wayland" and not host_display:
        raise SystemExit("REDIWM_TEST_BACKEND=wayland needs WAYLAND_DISPLAY")

    with tempfile.TemporaryDirectory(prefix="rediwm-perf-") as directory:
        tmp = Path(directory)
        build_client(tmp)
        (tmp / "config.toml").write_text("")
        env = dict(
            os.environ,
            XDG_RUNTIME_DIR=str(tmp),
            WLR_BACKENDS=backend,
            WLR_HEADLESS_OUTPUTS="1",
            WLR_WL_OUTPUTS="1",
            WLR_RENDERER=renderer,
            WLR_RENDERER_ALLOW_SOFTWARE="1",
            REDIWM_SCALE="1",
            REDIWM_CONFIG=str(tmp / "config.toml"),
            REDIWM_TEST_PERF="1",
            REDIWM_TEST_DECORATION="server",
        )
        if backend == "headless":
            env.pop("WAYLAND_DISPLAY", None)
        elif host_display:
            # Keep the compositor attached to the host display while its own
            # sockets live in tmp. An absolute path survives the runtime-dir swap.
            if host_display.startswith("/"):
                env["WAYLAND_DISPLAY"] = host_display
            elif host_runtime:
                env["WAYLAND_DISPLAY"] = str(Path(host_runtime) / host_display)
        env.pop("REDIWM_SOCKET", None)

        client_log = tmp / "client.log"
        with (tmp / "compositor.log").open("w") as log:
            compositor = subprocess.Popen([str(binary or ROOT / "zig-out/bin/rediwm")], env=env, stdout=log, stderr=log)
        client = None
        try:
            ipc_path = wait_for(lambda: next(tmp.glob("rediwm-*.sock"), None), "IPC unavailable")
            display = wait_for(
                lambda: next((p.name for p in tmp.glob("wayland-*") if not p.name.endswith(".lock")), None),
                "nested/headless display missing",
            )
            with client_log.open("w") as clog:
                client = subprocess.Popen(
                    [str(tmp / "client")],
                    env=dict(env, WAYLAND_DISPLAY=display),
                    stdout=clog,
                    stderr=clog,
                )
            with IPCClient(ipc_path, timeout=15) as ipc:
                wait_for(lambda: ipc.get_windows(), "fixture did not map")
                wait_for(lambda: client_log.exists() and "frame 8" in client_log.read_text(), "present loop did not start")
                ipc.wait_for_frame()

                empty = measure(ipc, seconds)
                validate(empty)
                summarize(f"{backend}/{renderer} empty commits ({seconds:.0f}s)", empty)

                client.terminate()
                client.wait(timeout=3)
                client = None

            env["REDIWM_TEST_PERF_DAMAGE"] = "1"
            with client_log.open("a") as clog:
                client = subprocess.Popen(
                    [str(tmp / "client")],
                    env=dict(env, WAYLAND_DISPLAY=display),
                    stdout=clog,
                    stderr=clog,
                )
            with IPCClient(ipc_path, timeout=15) as ipc:
                wait_for(lambda: ipc.get_windows(), "damage fixture did not map")
                time.sleep(0.3)
                ipc.wait_for_frame()
                damaged = measure(ipc, seconds)
                validate(damaged)
                summarize(f"{backend}/{renderer} full damage ({seconds:.0f}s)", damaged)
                if renderer == "pixman":
                    assert not damaged["frame_work"]["gpu_timing_available"], damaged
                elif damaged["frame_work"]["gpu_timing_available"]:
                    assert damaged["frame_work"]["gpu_elapsed"]["total_samples"] > 0, damaged

                # Repeated retargets exercise the start-button raster's spring
                # sampling as well as the steady client underneath it.
                bar = ipc.get_shell_state()["taskbars"][0]
                box = bar["start_button_box"]
                ipc.reset_perf()
                deadline = time.monotonic() + seconds
                hovering = False
                while time.monotonic() < deadline:
                    hovering = not hovering
                    ipc.move_cursor(box["x"] + box["width"] // 2, box["y"] + (box["height"] // 2 if hovering else -20))
                    time.sleep(.12)
                hover = ipc.get_perf()
                validate(hover)
                assert hover["taskbar_hover_paints"] > 0, hover
                summarize(f"{backend}/{renderer} start-button hover ({seconds:.0f}s)", hover)
                ipc.move_cursor(box["x"] + box["width"] // 2, box["y"] - 20)

                # Exercise menu painting and asynchronous icon arrivals, not just
                # a steady client. This is a warm process/filesystem scenario.
                ipc.action("reset_performance_stats")
                ipc.action('open_start_menu')
                ipc.move_cursor(250, 300)
                deadline = time.monotonic() + seconds
                direction = 1
                while time.monotonic() < deadline:
                    ipc.scroll(0, direction * 180)
                    direction *= -1
                    time.sleep(.05)
                menu = ipc.get_perf()
                validate(menu)
                summarize(f"{backend}/{renderer} menu open/scroll ({seconds:.0f}s)", menu)
        except Exception:
            for path in tmp.glob("*.log"):
                print(path.name, path.read_text()[-3000:])
            raise
        finally:
            for process in (client, compositor):
                if process is not None and process.poll() is None:
                    process.terminate()
                    process.wait(timeout=3)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, help="Compositor binary for the isolated fixture")
    parser.add_argument("--socket", type=Path, help="Observe an existing compositor; resets stats but injects no input")
    parser.add_argument("--seconds", type=float, default=5, help="Live observation duration (default: 5)")
    args = parser.parse_args()
    if not math.isfinite(args.seconds) or args.seconds <= 0:
        parser.error("--seconds must be finite and positive")
    print("Frame work is separate from commit pacing; these results are not uncapped FPS.")
    print("Durations summarize the most recent 512 samples; GPU elapsed can overlap CPU work.")
    if args.socket:
        ipc = IPCClient(args.socket, timeout=max(15, args.seconds + 5))
        try:
            ipc.connect()
        except (ConnectionRefusedError, FileNotFoundError) as error:
            ipc.close()
            reason = "no compositor is listening (the socket may be stale)" if isinstance(error, ConnectionRefusedError) else "the socket was not found"
            parser.exit(1, f"Cannot connect to {ipc.socket_path or args.socket}: {reason}.\n"
                        "Start the compositor and use its current IPC socket with --socket.\n"
                        "To run the isolated headless benchmark instead, omit --socket.\n")
        with ipc:
            print(f"Observing for {args.seconds:g}s; interact with the desktop normally.", flush=True)
            result = measure(ipc, args.seconds)
            validate(result, require_frames=False)
            summarize("Live desktop", result)
    else:
        run(args.binary)

#!/usr/bin/env python3
"""Measure spawn → first composited frame for a real client via REDIWM_SOCKET.

Launches the client with the compositor's IPC `spawn` action (so it inherits
the nested WAYLAND_DISPLAY / REDIWM_SOCKET) and waits on compositor barriers:

  spawn  →  window_mapped  →  wait_for_frame

`window_mapped` is xdg map (the client has committed a buffer and the
toplevel is in the scene). `wait_for_frame` is the next output presentation
after that, which is an upper bound on the first frame that includes the
window. Headless pacing is not vsync; set REDIWM_TEST_BACKEND=wayland for a
nested session that waits on the host's refresh.

REDIWM_TEST_RENDERER=pixman|gles2 selects the renderer (default pixman).
REDIWM_TEST_FOOT overrides the foot binary. Requires foot on PATH.

Run after zig build:

    python tests/spawn_latency.py
    python tests/spawn_latency.py --runs 5
    REDIWM_TEST_BACKEND=wayland python tests/spawn_latency.py
    python tests/spawn_latency.py --socket $REDIWM_SOCKET
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shutil
import statistics
import subprocess
import sys
import tempfile
import time
from typing import Any, Dict, List, Optional

from ipc_client import IPCClient, IPCError, ROOT, stop_process


def median(values: List[float]) -> float:
    if not values:
        return 0.0
    return float(statistics.median(values))


def summarize_ms(values: List[float]) -> Dict[str, float]:
    if not values:
        return {"min": 0.0, "median": 0.0, "mean": 0.0, "max": 0.0}
    return {
        "min": round(min(values), 3),
        "median": round(median(values), 3),
        "mean": round(sum(values) / len(values), 3),
        "max": round(max(values), 3),
    }


def find_new_window(ipc: IPCClient, before_ids: set, app_id: Optional[str]):
    for window in ipc.get_windows():
        if window["id"] in before_ids:
            continue
        if window.get("placeholder"):
            continue
        if app_id and window.get("app_id") != app_id:
            continue
        return window
    return None


def wait_new_window(
    ipc: IPCClient,
    before_ids: set,
    app_id: Optional[str],
    timeout_ms: int,
):
    found = find_new_window(ipc, before_ids, app_id)
    if found:
        return found, True

    stale = any(
        (app_id is None or window.get("app_id") == app_id) and window["id"] in before_ids
        for window in ipc.get_windows()
    )
    if stale:
        deadline = time.perf_counter() + timeout_ms / 1000.0
        while time.perf_counter() < deadline:
            found = find_new_window(ipc, before_ids, app_id)
            if found:
                return found, False
            time.sleep(0.002)
        raise TimeoutError(
            f"no new window with app_id={app_id!r} after {timeout_ms}ms "
            f"(an older matching window is still mapped)"
        )

    ipc.wait_for("window_mapped", app_id=app_id, timeout_ms=timeout_ms)
    found = find_new_window(ipc, before_ids, app_id)
    if not found:
        raise TimeoutError(
            f"window_mapped returned but no new window with app_id={app_id!r} is listed"
        )
    return found, False


def close_window(ipc: IPCClient, window_id: int, timeout_ms: int = 5000) -> None:
    try:
        ipc.close_window(window_id)
        ipc.wait_for("window_closed", window_id=window_id, timeout_ms=timeout_ms)
    except (IPCError, TimeoutError):
        # A leftover window is tolerated: the next run keys off new ids.
        pass


def measure_once(
    ipc: IPCClient,
    argv: List[str],
    desktop_id: Optional[str],
    app_id: Optional[str],
    timeout_ms: int,
) -> Dict[str, Any]:
    before_ids = {window["id"] for window in ipc.get_windows()}
    ipc.reset_perf()
    commits_before = ipc.get_perf().get("output_commits") or 0

    started = time.perf_counter()
    if desktop_id:
        ipc.action('launch_app', {"desktop_id": desktop_id})
    else:
        ipc.action("spawn", {"argv": argv})
    spawned = time.perf_counter()

    window, already_mapped = wait_new_window(ipc, before_ids, app_id, timeout_ms)
    mapped = time.perf_counter()

    frame = ipc.wait_for_frame(timeout_ms=timeout_ms)
    presented = time.perf_counter()

    debug: Dict[str, Any] = {}
    try:
        debug = ipc.get_window_debug(window["id"]) or {}
    except IPCError as error:
        debug = {"error": str(error)}

    stats = ipc.get_perf()
    result = {
        "window_id": window["id"],
        "app_id": window.get("app_id"),
        "title": window.get("title"),
        "pid": window.get("pid"),
        "width": window.get("width"),
        "height": window.get("height"),
        "spawn_ms": round((spawned - started) * 1000, 3),
        "spawn_to_mapped_ms": round((mapped - started) * 1000, 3),
        "spawn_to_first_frame_ms": round((presented - started) * 1000, 3),
        "mapped_to_first_frame_ms": round((presented - mapped) * 1000, 3),
        "mapped_already": already_mapped,
        "frame_wait_elapsed_ms": frame.get("elapsed_ms") if isinstance(frame, dict) else None,
        "frame_seq": frame.get("frame_seq") if isinstance(frame, dict) else None,
        "output": frame.get("output") if isinstance(frame, dict) else None,
        "output_commits": (stats.get("output_commits") or 0) - commits_before,
        "buffer_width": debug.get("buffer_width"),
        "buffer_height": debug.get("buffer_height"),
        "decoration_mode": debug.get("decoration_mode"),
    }
    if debug.get("error"):
        result["window_debug_error"] = debug["error"]
    return result


def validate_run(run: Dict[str, Any]) -> None:
    assert run["spawn_to_mapped_ms"] >= 0, run
    assert run["spawn_to_first_frame_ms"] >= run["spawn_to_mapped_ms"], run
    buf_w = run.get("buffer_width") or 0
    buf_h = run.get("buffer_height") or 0
    if run.get("window_debug_error"):
        raise AssertionError(f"window_debug failed after map: {run['window_debug_error']}")
    assert buf_w > 0 and buf_h > 0, run
    assert (run.get("output_commits") or 0) >= 1, run


def compositor_env(tmp: Path, backend: str, renderer: str, scale: str, config: str) -> dict:
    (tmp / "home").mkdir()
    (tmp / "cache").mkdir()
    (tmp / "config").mkdir()
    (tmp / "data").mkdir()
    config_path = tmp / "rediwm-config.toml"
    config_path.write_text(config)
    env = dict(
        os.environ,
        XDG_RUNTIME_DIR=str(tmp),
        HOME=str(tmp / "home"),
        XDG_CACHE_HOME=str(tmp / "cache"),
        XDG_CONFIG_HOME=str(tmp / "config"),
        XDG_DATA_HOME=str(tmp / "data"),
        WLR_BACKENDS=backend,
        WLR_HEADLESS_OUTPUTS="1",
        WLR_WL_OUTPUTS="1",
        WLR_RENDERER=renderer,
        WLR_RENDERER_ALLOW_SOFTWARE="1",
        REDIWM_SCALE=str(scale),
        REDIWM_CONFIG=str(config_path),
        DBUS_SESSION_BUS_ADDRESS="",
    )
    host_display = os.environ.get("WAYLAND_DISPLAY")
    host_runtime = os.environ.get("XDG_RUNTIME_DIR")
    env.pop("REDIWM_SOCKET", None)
    if backend == "headless":
        env.pop("WAYLAND_DISPLAY", None)
    elif host_display:
        if host_display.startswith("/"):
            env["WAYLAND_DISPLAY"] = host_display
        elif host_runtime:
            env["WAYLAND_DISPLAY"] = str(Path(host_runtime) / host_display)
    return env


def run_isolated(args) -> None:
    backend = os.environ.get("REDIWM_TEST_BACKEND", "headless")
    renderer = os.environ.get("REDIWM_TEST_RENDERER", "pixman")
    scale = os.environ.get("REDIWM_TEST_SCALE", "1")
    host_display = os.environ.get("WAYLAND_DISPLAY")
    if backend == "wayland" and not host_display:
        raise SystemExit("REDIWM_TEST_BACKEND=wayland needs WAYLAND_DISPLAY")

    config = "[compositor]\nxwayland = false\n"
    if args.no_anim:
        config += "[animations]\nenabled = false\n"

    with tempfile.TemporaryDirectory(prefix="rediwm-spawn-latency-") as directory:
        tmp = Path(directory)
        env = compositor_env(tmp, backend, renderer, scale, config)
        with (tmp / "compositor.log").open("w") as log:
            compositor = subprocess.Popen([str(args.binary)], env=env, stdout=log, stderr=log)
        try:
            with IPCClient(tmp, timeout=max(15, args.timeout_ms / 1000 + 5)) as ipc:
                ipc.wait_for("wallpaper_presented", timeout_ms=10000)
                ipc.wait_for_frame(timeout_ms=5000)
                measure_session(ipc, args, backend=backend, renderer=renderer, scale=scale)
        except Exception:
            log_path = tmp / "compositor.log"
            if log_path.exists():
                print(log_path.read_text()[-4000:], file=sys.stderr)
            raise
        finally:
            stop_process(compositor)


def run_attached(args) -> None:
    socket_path = args.socket
    with IPCClient(socket_path, timeout=max(15, args.timeout_ms / 1000 + 5)) as ipc:
        measure_session(ipc, args, backend="attached", renderer=None, scale=None)


def measure_session(
    ipc: IPCClient,
    args,
    backend: str,
    renderer: Optional[str],
    scale: Optional[str],
) -> None:
    argv = list(args.command)
    app_id = args.app_id
    runs: List[Dict[str, Any]] = []
    closed: List[int] = []

    total = args.warmup + args.runs
    try:
        for index in range(total):
            sample = measure_once(ipc, argv, args.desktop_id, app_id, args.timeout_ms)
            validate_run(sample)
            if index >= args.warmup:
                runs.append(sample)
            if not args.keep:
                close_window(ipc, sample["window_id"])
                closed.append(sample["window_id"])
    finally:
        if not args.keep:
            for window_id in {sample["window_id"] for sample in runs} - set(closed):
                close_window(ipc, window_id)

    mapped = [sample["spawn_to_mapped_ms"] for sample in runs]
    visible = [sample["spawn_to_first_frame_ms"] for sample in runs]
    payload = {
        "command": argv if not args.desktop_id else None,
        "desktop_id": args.desktop_id,
        "app_id": app_id,
        "backend": backend,
        "renderer": renderer,
        "scale": scale,
        "warmup": args.warmup,
        "runs": runs,
        "spawn_to_mapped_ms": summarize_ms(mapped),
        "spawn_to_first_frame_ms": summarize_ms(visible),
    }
    print(json.dumps(payload, indent=2))
    if visible:
        stats = payload["spawn_to_first_frame_ms"]
        print(
            f"spawn → first frame: min {stats['min']:.1f}  "
            f"median {stats['median']:.1f}  mean {stats['mean']:.1f}  "
            f"max {stats['max']:.1f} ms  ({len(visible)} runs, {backend}"
            f"{'/' + renderer if renderer else ''})",
            flush=True,
        )


def resolve_command(args) -> None:
    if args.desktop_id:
        return
    if not args.command:
        foot = os.environ.get("REDIWM_TEST_FOOT") or shutil.which("foot")
        if not foot:
            raise SystemExit(
                "foot not found on PATH; install it or pass --command /path/to/client"
            )
        args.command = [foot]
        if args.app_id is None:
            args.app_id = "foot"
        return
    if args.app_id is None and Path(args.command[0]).name == "foot":
        args.app_id = "foot"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--binary",
        type=Path,
        default=ROOT / "zig-out/bin/rediwm",
        help="Compositor binary for the isolated fixture",
    )
    parser.add_argument(
        "--socket",
        nargs="?",
        const=True,
        help="Attach to a running compositor. Pass a path, or omit the path to use REDIWM_SOCKET",
    )
    parser.add_argument(
        "--command",
        nargs="+",
        help="Argv to IPC spawn (default: foot). Ignored when --desktop-id is set",
    )
    parser.add_argument("--desktop-id", help="Launch via IPC launch instead of spawn")
    parser.add_argument("--app-id", help="xdg app_id to wait for (default: foot)")
    parser.add_argument("--runs", type=int, default=3, help="Timed runs after warmup (default: 3)")
    parser.add_argument("--warmup", type=int, default=1, help="Discarded launches before timing (default: 1)")
    parser.add_argument("--timeout-ms", type=int, default=15000, help="Per-wait timeout")
    parser.add_argument("--no-anim", action="store_true", help="Disable compositor animations in the isolated fixture")
    parser.add_argument("--keep", action="store_true", help="Leave launched windows open")
    args = parser.parse_args()
    if args.runs < 1:
        parser.error("--runs must be at least 1")
    if args.warmup < 0:
        parser.error("--warmup must be >= 0")
    if args.timeout_ms < 1:
        parser.error("--timeout-ms must be positive")

    if args.socket is True:
        env_socket = os.environ.get("REDIWM_SOCKET")
        if not env_socket:
            parser.error("--socket without a path requires REDIWM_SOCKET")
        args.socket = env_socket

    resolve_command(args)
    if args.socket:
        run_attached(args)
    else:
        if not args.binary.exists():
            parser.error(f"compositor binary not found: {args.binary} (run zig build first)")
        run_isolated(args)


if __name__ == "__main__":
    main()

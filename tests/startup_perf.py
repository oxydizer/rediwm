#!/usr/bin/env python3
"""Measure process entry to first frame, responsive IPC and wallpaper.

Uses isolated headless sessions, no host buses or audio. Cache files persist
between runs unless --cold-cache is set; OS page caches are never flushed.
--publication-delay-ms models a slow login supervisor on a private socket.
"""
import argparse
import json
import os
from pathlib import Path
import socket
import statistics
import subprocess
import tempfile
import threading
import time

from ipc_client import IPCClient, ROOT, stop_process


def measure(args, base, iteration):
    tmp = base / str(iteration)
    tmp.mkdir(mode=0o700)
    config = tmp / "config.toml"
    config.write_text('[compositor]\nxwayland = true\nxwayland_native_scaling = ' +
                      str(args.native_scaling).lower() + '\n')
    env = dict(os.environ,
               XDG_RUNTIME_DIR=str(tmp), XDG_CONFIG_HOME=str(tmp / "config"),
               XDG_STATE_HOME=str(tmp / "state"), XDG_DATA_HOME=str(base / "data"),
               XDG_CACHE_HOME=str((tmp if args.cold_cache else base) / "cache"),
               DBUS_SESSION_BUS_ADDRESS="unix:path=" + str(tmp / "missing-session"),
               DBUS_SYSTEM_BUS_ADDRESS="unix:path=" + str(tmp / "missing-system"),
               PULSE_SERVER="unix:" + str(tmp / "missing-pulse"), PIPEWIRE_RUNTIME_DIR=str(tmp),
               REDIWM_DESKTOP_DIR=str(base / "desktop"),
               WLR_BACKENDS="headless", WLR_HEADLESS_OUTPUTS="1", WLR_RENDERER=args.renderer,
               REDIWM_CONFIG=str(config), REDIWM_SCALE=args.scale, REDIWM_STARTUP_TIMING="1")
    for key in ("WAYLAND_DISPLAY", "DISPLAY", "XAUTHORITY", "REDIWM_SOCKET", "REDIWM_SESSION_FD"):
        env.pop(key, None)
    for key in ("REDIWM_CATALOG_CACHE_PATH", "REDIWM_DISABLE_CATALOG_CACHE",
                "REDIWM_CATALOG_SCAN_DELAY_MS", "REDIWM_WALLPAPER_DECODE_DELAY_MS"):
        env.pop(key, None)

    parent = child = supervisor = None
    stopped = threading.Event()
    failures = []
    if args.publication_delay_ms:
        parent, child = socket.socketpair(socket.AF_UNIX, socket.SOCK_SEQPACKET)
        env["REDIWM_SESSION_FD"] = str(child.fileno())

        def acknowledge():
            try:
                parent.settimeout(15)
                assert parent.recv(16384), "missing readiness message"
                if not stopped.wait(args.publication_delay_ms / 1000):
                    parent.send(b"ready")
            except Exception as error:
                if not stopped.is_set():
                    failures.append(error)

        supervisor = threading.Thread(target=acknowledge)
        supervisor.start()

    try:
        with (tmp / "compositor.log").open("w") as log:
            started = time.monotonic_ns()
            process = subprocess.Popen([str(args.binary)], cwd=ROOT, env=env,
                                       pass_fds=(child.fileno(),) if child else (),
                                       stdout=log, stderr=log)
            if child:
                child.close()
            try:
                with IPCClient(tmp, timeout=15 + args.publication_delay_ms / 1000) as ipc:
                    first = ipc.get_perf()["startup"]
                    first_reply_ms = (time.monotonic_ns() - started) / 1e6
                    ipc.wait_for("wallpaper_presented", timeout_ms=10000)
                    ipc.wait_for("catalog_published", timeout_ms=10000)
                    if supervisor:
                        supervisor.join(timeout=15 + args.publication_delay_ms / 1000)
                        assert not supervisor.is_alive(), "readiness supervisor timed out"
                        if failures:
                            raise failures[0]
                    final = ipc.get_perf()["startup"]
                    # Newer binaries expose client launch timing. Wait for its
                    # one-shot callback, using frame barriers between checks.
                    deadline = time.monotonic() + 5
                    while "session_clients_started_ns" in final and not final["session_clients_started_ns"]:
                        assert time.monotonic() < deadline, "session clients never started"
                        ipc.wait_for_frame(timeout_ms=2000)
                        final = ipc.get_perf()["startup"]
                    assert final["first_presented_ns"] > 0, final
                    return {"startup": final, "first_reply_ms": first_reply_ms,
                            "cache_used": bool(first["catalog_cache_read_ns"])}
            except BaseException:
                log.flush()
                print((tmp / "compositor.log").read_text())
                raise
            finally:
                stop_process(process)
    finally:
        stopped.set()
        if parent:
            try:
                parent.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
        if supervisor:
            supervisor.join(timeout=2)
        if parent:
            parent.close()
        if child:
            child.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=ROOT / "zig-out/bin/rediwm")
    parser.add_argument("--runs", type=int, default=7)
    parser.add_argument("--renderer", choices=("pixman", "gles2"), default="pixman")
    parser.add_argument("--scale", default="1")
    parser.add_argument("--native-scaling", action="store_true")
    parser.add_argument("--cold-cache", action="store_true")
    parser.add_argument("--publication-delay-ms", type=int, default=0)
    args = parser.parse_args()
    if args.runs < 1 or args.publication_delay_ms < 0:
        parser.error("runs must be positive and publication delay must be nonnegative")
    args.binary = args.binary.resolve()
    os.umask(0o077)
    with tempfile.TemporaryDirectory(prefix="rediwm-startup-perf-") as directory:
        runs = [measure(args, Path(directory), i) for i in range(args.runs)]
    marks = runs[0]["startup"]
    print(json.dumps({
        "binary": str(args.binary), "build_mode": marks["build_mode"],
        "renderer": marks["renderer"], "runs": args.runs,
        "native_scaling": args.native_scaling, "cold_cache": args.cold_cache,
        "publication_delay_ms": args.publication_delay_ms,
        "median_first_reply_ms": round(statistics.median(r["first_reply_ms"] for r in runs), 3),
        "median_ms": {k: round(statistics.median(r["startup"][k] for r in runs) / 1e6, 3)
                      for k in marks if k.endswith("_ns")},
        "samples": [{"first_frame_ms": round(r["startup"]["first_presented_ns"] / 1e6, 3),
                     "first_reply_ms": round(r["first_reply_ms"], 3), "cache_used": r["cache_used"]}
                    for r in runs],
    }, indent=2))


if __name__ == "__main__":
    main()

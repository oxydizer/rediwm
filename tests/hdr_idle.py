#!/usr/bin/env python3
"""Measure idle compositor CPU, context switches and memory in fresh headless sessions."""
import argparse
import json
import tempfile
import time
from pathlib import Path

from ipc_client import IPCClient, ROOT, spawn_compositor, stop_process
from memory_retention import memory
from scene_baseline import thread_snapshot


def measure(binary, hdr, seconds):
    with tempfile.TemporaryDirectory(prefix="rediwm-hdr-idle-") as directory:
        tmp = Path(directory)
        config = f'[compositor]\nxwayland = false\n[[outputs]]\nname = "HEADLESS-1"\nhdr = "{hdr}"\n'
        private = {key: str(tmp / key) for key in ("HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME")}
        private["DBUS_SESSION_BUS_ADDRESS"] = "unix:path=/nonexistent-hdr-idle-bus"
        process, log = spawn_compositor(tmp, binary=binary, config_content=config, env_extra=private)
        try:
            with IPCClient(tmp) as ipc:
                ipc.wait_for("wallpaper_presented")
                ipc.wait_for_frame(output="HEADLESS-1")
                assert ipc.get_outputs()[0]["hdr_linear"] == (hdr == "on")
            time.sleep(2)
            before = thread_snapshot(process.pid)
            start = time.monotonic()
            time.sleep(seconds)
            after = thread_snapshot(process.pid)
            elapsed = time.monotonic() - start
            assert before and after and process.poll() is None
            cpu, switches = 0, 0
            for tid, (_, ns, voluntary, forced) in after.items():
                _, old_ns, old_voluntary, old_forced = before.get(tid, ("", 0, 0, 0))
                cpu += ns - old_ns
                switches += voluntary + forced - old_voluntary - old_forced
            sizes = memory(process.pid)
            return dict(binary=str(binary), hdr=hdr, seconds=round(elapsed, 2),
                        cpu_percent=round(cpu / 1e7 / elapsed, 3),
                        switches_per_second=round(switches / elapsed, 2),
                        **{k: sizes[k] for k in ("pss_kib", "private_kib", "drm_clients_kib")})
        finally:
            stop_process(process)
            log.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=ROOT / "zig-out/release-safe/bin/rediwm")
    parser.add_argument("--baseline", type=Path)
    parser.add_argument("--seconds", type=float, default=15)
    parser.add_argument("--repeat", type=int, default=3)
    args = parser.parse_args()
    if args.seconds <= 0 or args.repeat < 1:
        parser.error("seconds and repeat must be positive")
    binaries = ([args.baseline] if args.baseline else []) + [args.binary]
    for repetition in range(args.repeat):
        for binary in binaries[::1 if repetition % 2 == 0 else -1]:
            for hdr in (("off", "on") if repetition % 2 == 0 else ("on", "off")):
                print(json.dumps(measure(binary.resolve(), hdr, args.seconds)), flush=True)

#!/usr/bin/env python3
"""Isolated idle and tray hover regression measurement; no host input."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile
import time

from PIL import Image, ImageChops

from desktop_zoom import build_client
from ipc_client import IPCClient, spawn_compositor, stop_process
from motion_perf import cpu_seconds


def run(binary, scale, outputs):
    with tempfile.TemporaryDirectory(prefix="rediwm-tray-perf-") as directory:
        tmp = Path(directory)
        build_client(tmp)
        original = subprocess.Popen
        def launch(argv, *args, **kwargs):
            if binary and str(argv[0]).endswith("/zig-out/bin/rediwm"):
                argv = [str(binary), *argv[1:]]
            return original(argv, *args, **kwargs)
        subprocess.Popen = launch
        try:
            process, log = spawn_compositor(tmp, scale=scale, outputs=outputs, env_extra={"DBUS_SESSION_BUS_ADDRESS": ""})
        finally:
            subprocess.Popen = original
        try:
            with IPCClient(tmp) as ipc:
                ipc.wait_for("wallpaper_presented", timeout_ms=10000)
                ipc.action("spawn", {"argv": [str(tmp / "client")]})
                ipc.wait_for("window_mapped", app_id="rediwm.zoom-fixture", timeout_ms=10000)
                time.sleep(2)
                taskbar = ipc.get_shell_state()["taskbars"][0]
                bar = taskbar["box"]
                # Tray positions are measured from the clock's reserved width.
                x = bar["x"] + bar["width"] - 160
                y = bar["y"] + bar["height"] // 2
                def capture(name):
                    path = tmp / f"{name}.png"
                    ipc.screenshot(str(path), output=taskbar["output"])
                    with Image.open(path) as image:
                        factor = float(scale)
                        return image.convert("RGB").crop((round((x - bar["x"] - 110) * factor),
                            image.height - round(bar["height"] * factor),
                            round((x - bar["x"] + 25) * factor), image.height))
                baseline = capture("before")
                for label in ("idle", "tray", "tail", "settled"):
                    ipc.reset_perf()
                    before = cpu_seconds(process)
                    start = time.monotonic()
                    if label == "tray":
                        for i in range(20):
                            ipc.move_cursor(x, y if i % 2 else bar["y"] - 20)
                            time.sleep(.1)
                    else:
                        time.sleep(2)
                    elapsed = time.monotonic() - start
                    stats = ipc.get_perf()
                    if label in ("idle", "settled"):
                        assert stats["anim_frames_scheduled"] == 0, stats
                        assert stats["taskbar_hover_paints"] == 0, stats
                    if label == "tray":
                        assert stats["taskbar_hover_paints"] > 0, stats
                    print(json.dumps({"workload": label, "cpu_percent": (cpu_seconds(process)-before)*100/elapsed,
                        "frames": stats["frame_work"]["cpu_frame"]["total_samples"],
                        "taskbar_cpu": stats["frame_work"]["taskbar_cpu"],
                        "paints": stats["taskbar_paints"], "scheduled": stats["anim_frames_scheduled"]}), flush=True)
                ipc.move_cursor(x, bar["y"] - 20)
                time.sleep(1)
                assert ImageChops.difference(baseline, capture("restored")).getbbox() is None, "tray hover left stale pixels"
        finally:
            stop_process(process)
            log.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path)
    parser.add_argument("--scale", default="1.5")
    parser.add_argument("--outputs", default="1")
    args = parser.parse_args()
    run(args.binary, args.scale, args.outputs)

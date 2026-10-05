#!/usr/bin/env python3
"""Retained picker work and atomic PNG publication, in private headless sessions."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
from PIL import Image
from ipc_client import IPCClient, ROOT, spawn_compositor, stop_process
from screenshot_tool import wait_for


def cpu_seconds(process):
    fields = Path(f"/proc/{process.pid}/stat").read_text().split(")")[1].split()
    return (int(fields[11]) + int(fields[12])) / os.sysconf("SC_CLK_TCK")


def selection_work(tmp):
    renderer = os.environ.get("REDIWM_TEST_RENDERER", "pixman")
    process, log = spawn_compositor(tmp, scale="1.5", renderer=renderer, config_content="[compositor]\nxwayland = false\n", env_extra={"HOME": str(tmp), "WLR_RENDERER_ALLOW_SOFTWARE": "1"})
    try:
        with IPCClient(tmp, timeout=15) as ipc:
            ipc.wait_for("wallpaper_presented", timeout_ms=10000)
            ipc.key(29, True)
            ipc.key(42, True)
            ipc.key_down_up(31)
            ipc.key(42, False)
            ipc.key(29, False)
            ipc.move_cursor(100, 180)
            ipc.pointer_button(272, True)
            ipc.wait_for_frame()
            # Retained CPU buffers can be released after GLES texture upload.
            # Each changed endpoint must survive a previous rendered frame;
            # a burst coalesced to one update does not exercise this lifecycle.
            for x, y in ((420, 330), (540, 390), (100, 390), (540, 180),
                         (60, 120), (100, 180), (480, 310)):
                ipc.move_cursor(x, y)
                ipc.wait_for_frame()
                assert process.poll() is None, "drag crashed after texture upload"
            ipc.action('reset_performance_stats')
            start_cpu = cpu_seconds(process)
            start = time.perf_counter()
            for i in range(240):
                ipc.move_cursor(300 + (i * 7) % 500, 250 + (i * 3) % 200)
            ipc.wait_for_frame()
            elapsed = time.perf_counter() - start
            used_cpu = cpu_seconds(process) - start_cpu
            stats = ipc.get_perf()
            picker = stats["screenshot_selection"]
            assert picker["motion_events"] == 240, picker
            assert picker["toolbar_paints"] == picker["scene_nodes_created"] == 0, picker
            assert 0 < picker["updates"] < picker["motion_events"], picker
            assert picker["updates"] <= stats["frame_work"]["cpu_frame"]["total_samples"], picker
            assert picker["label_paints"] <= picker["updates"], picker
            # Only the 116×30 dimension label needs pixels after opening.
            label_bytes = 174 * 45 * 4
            assert stats["panel_allocated_bytes"] + stats["panel_reused_bytes"] <= label_bytes * picker["label_paints"], stats
            before = dict(picker)
            for _ in range(100):
                ipc.move_cursor(300 + (239 * 7) % 500, 250 + (239 * 3) % 200)
            ipc.wait_for_frame()
            after = ipc.get_perf()["screenshot_selection"]
            assert after["updates"] == before["updates"], (before, after)
            print(f"{renderer}: 240 drag motions: {elapsed:.3f}s elapsed, {used_cpu:.3f}s CPU, {picker['updates']} presented updates, no new scene nodes or toolbar paint")
            ipc.key_press("Escape")
    except Exception:
        log.flush()
        print((tmp / "compositor.log").read_text()[-6000:])
        raise
    finally:
        stop_process(process)
        log.close()


def saving(tmp, hook, mode):
    marker = tmp / "writing"
    process, log = spawn_compositor(tmp, config_content="[compositor]\nxwayland = false\n", env_extra={
        "HOME": str(tmp), "LD_PRELOAD": str(hook),
        "REDIWM_SCREENSHOT_SAVE_FAULT": mode,
        "REDIWM_SCREENSHOT_WRITE_MARKER": str(marker),
    })
    try:
        with IPCClient(tmp, timeout=15) as ipc:
            ipc.wait_for("wallpaper_presented", timeout_ms=10000)
            ipc.key_press("Print")
            wait_for(marker.exists, "save hook did not see a staging file")
            folder = tmp / "Screenshots"
            assert not list(folder.glob("*.png")), "final PNG name exposed before write completed"
            expected = "Screenshot saved and copied" if mode == "interrupt" else "Screenshot failed"
            wait_for(lambda: expected in json.dumps(ipc.get_notifications()), "save did not report its actual outcome")
            assert not list(folder.glob(".rediwm-screenshot-*")), "staging file leaked"
            files = list(folder.glob("*.png"))
            if mode == "interrupt":
                assert len(files) == 1 and files[0].stat().st_size > 0
                with Image.open(files[0]) as image:
                    image.verify()
                display = next(p.name for p in tmp.glob("wayland-*") if not p.name.endswith(".lock"))
                result = subprocess.run(["wl-paste", "--no-newline", "--type", "image/png"], env=dict(os.environ, XDG_RUNTIME_DIR=str(tmp), WAYLAND_DISPLAY=display), capture_output=True, timeout=5, check=True)
                assert result.stdout == files[0].read_bytes()
            elif mode == "publish_race":
                assert len(files) == 1 and files[0].read_bytes() == b"existing destination"
            else:
                assert files == [], files
            assert process.poll() is None
            print(f"atomic PNG publication ({mode}): passed")
    finally:
        stop_process(process)
        log.close()


if __name__ == "__main__":
    with tempfile.TemporaryDirectory(prefix="screenshot-regressions-") as directory:
        tmp = Path(directory)
        hook = tmp / "save_hook.so"
        subprocess.run(["cc", "-shared", "-fPIC", "-Wall", "-Wextra", "-Werror", str(ROOT / "tests/screenshot_save_hook.c"), "-o", str(hook), "-ldl"], check=True)
        perf = tmp / "perf"
        # Private like the runtime dir: the IPC socket refuses group/other access.
        perf.mkdir(mode=0o700)
        selection_work(perf)
        for mode in ("interrupt", "write_fail", "sync_fail", "publish_race"):
            case = tmp / mode
            case.mkdir(mode=0o700)
            saving(case, hook, mode)

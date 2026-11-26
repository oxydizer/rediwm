#!/usr/bin/env python3
"""Compare a keyboard strip reveal and a three-finger strip swipe with a canvas
pan of the same windows and distance.

Use a ReleaseSafe binary for timing. Also check that a callback-driven client
goes idle both off-strip and on a hidden workspace, then resumes on reveal.
"""
import argparse
import json
from pathlib import Path
import tempfile
import time

from desktop_zoom import ROOT, build_client, wait_for
from scene_baseline import thread_snapshot
from scrolling import Session


def idle(session, seconds, frames):
    # Allow the glide, workspace switch and the last pending callback to finish.
    time.sleep(1)
    session.ipc.reset_perf()
    count = frames()
    before = thread_snapshot(session.process.pid)
    start = time.monotonic()
    time.sleep(seconds)
    after = thread_snapshot(session.process.pid)
    elapsed = time.monotonic() - start
    callbacks = frames() - count
    assert not callbacks, f"hidden client received {callbacks} callbacks"
    common = before.keys() & after.keys()
    assert common
    switches = sum(sum(after[tid][2:]) - sum(before[tid][2:]) for tid in common)
    return dict(switches_per_second=round(switches / elapsed, 2),
                output_commits=session.ipc.get_perf()["output_commits"], callbacks=callbacks)


def cost(ipc, cycles, move):
    ipc.reset_perf()
    for _ in range(cycles):
        for end in (True, False):
            move(end)
    perf = ipc.get_perf()
    count = cycles * 2
    assert perf["output_commits"] > count, "workload did not animate"
    return dict(commits_per_move=perf["output_commits"] / count, reblurs_per_move=perf["glass_reblurs"] / count,
                **{key + "_ms": round(perf["frame_work"][key]["avg_ms"], 3)
                   for key in ("cpu_frame", "projection_cpu", "gpu_elapsed")})


def run(args):
    with tempfile.TemporaryDirectory(prefix="rediwm-scroll-perf-") as directory:
        tmp = Path(directory)
        build_client(tmp)
        s = Session(tmp, '''[compositor]
desktop_mode = "scrolling"
xwayland = false
window_gap = 8
mini_map_enabled = false
taskbar_items = ["-volume", "-clock", "-network", "-battery"]
[animations]
enabled = true
reduced_motion = "off"
''', binary=args.binary)
        try:
            ipc = s.ipc
            log = tmp / "frames.log"
            with log.open("w") as output:
                a = s.launch("callback", stdout=output, REDIWM_TEST_PERF="1")

            def frames():
                return log.read_text().count("frame ")

            wait_for(lambda: frames() > 8, "visible callback-driven client")
            b = s.launch("middle")
            c = s.launch("end")
            s.settled(c)
            assert not ipc.get_window_debug(a)["outputs"]
            result = {"culled": idle(s, args.idle_seconds, frames)}
            ipc.action("switch_workspace", {"workspace": 2})
            result["hidden_workspace"] = idle(s, args.idle_seconds, frames)
            ipc.action("switch_workspace", {"workspace": 1})
            s.settled(c)
            distance = s.workspace(1)["view"]
            assert distance > 0

            def strip(end):
                window = c if end else a
                ipc.focus_window(window)
                s.settled(window)
                assert s.workspace(1)["view"] == (distance if end else 0)

            before = frames()
            strip(False)
            wait_for(lambda: frames() > before + 1, "callbacks resume on reveal")
            geometries = {win: ipc.get_window_debug(win) for win in (a, b, c)}
            result["strip"] = cost(ipc, args.cycles, strip)

            def swipe(end):
                # 1:1 with pan_speed 2, at about the touchpad's event rate,
                # held still before lifting so the snap has no fling.
                steps = 24
                dx = (-1 if end else 1) * distance / 2 / steps
                ipc.action("swipe", {"phase": "begin", "fingers": 3})
                for _ in range(steps):
                    ipc.action("swipe", {"phase": "update", "dx": dx, "dy": 0})
                    time.sleep(0.008)
                time.sleep(0.15)
                ipc.action("swipe", {"phase": "end"})
                for window in (a, b, c):
                    s.settled(window)
                assert abs(s.workspace(1)["view"] - (distance if end else 0)) < 0.5, s.workspace(1)["view"]

            result["swipe"] = cost(ipc, args.cycles, swipe)

            s.set_mode("canvas")
            for win, geometry in geometries.items():
                client, frame = geometry["client_box"], geometry["chrome_box"]
                ipc.action("set_window_size", {"id": win, "width": client["width"], "height": client["height"]})
                ipc.action("move_window_to", {"id": win, "x": frame["x"], "y": frame["y"]})
                s.settled(win)

            def canvas(end):
                target = distance if end else 0
                ipc.action("set_camera", {"x": target, "y": 0})
                wait_for(lambda: ipc.query("get_camera")["x"] == target and
                         all(e["settled"] for e in ipc.query("get_animations") if e["site"].startswith("camera.")),
                         "canvas pan settles")

            canvas(False)
            result["canvas"] = cost(ipc, args.cycles, canvas)
            result["distance_px"] = distance
            print(json.dumps(result, indent=2))
        finally:
            s.stop()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=ROOT / "zig-out/release-safe/bin/rediwm")
    parser.add_argument("--idle-seconds", type=float, default=5)
    parser.add_argument("--cycles", type=int, default=4)
    args = parser.parse_args()
    if args.cycles < 1 or args.idle_seconds <= 0:
        parser.error("cycles and idle seconds must be positive")
    run(args)

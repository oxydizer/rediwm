#!/usr/bin/env python3
"""Isolated switcher CPU/frame-cost and retention audit; compare ReleaseSafe builds.

Run comparable binaries serially, preferably in alternating order. Clean mode
never requests compositor performance counters (those enable extra GPU timers).
Stats mode uses a separate session. CPU100% means one core; frame_time_ms is
commit cadence, not rendering cost. Headless results do not prove DRM latency.

    python3 tests/switcher_perf.py --binary zig-out/release-safe/bin/rediwm \
        --style circular --mode clean --out /tmp/circular-clean.json
    python3 tests/switcher_perf.py --style linear --mode stats --out /tmp/linear-stats.json
    python3 tests/switcher_perf.py --style circular --mode retention --cycles 50 \
        --out /tmp/circular-retention.json
"""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import statistics
import subprocess
import tempfile
import time

from PIL import Image

from desktop_zoom import ROOT, build_client, wait_for
from i18n import isolated_environment
from ipc_client import IPCClient, spawn_compositor, stop_process
from memory_retention import memory, scene_counts, summarize
from scene_baseline import condense, power_state, thread_snapshot


FIXTURE_VARS = ("REDIWM_TEST_PERF", "REDIWM_TEST_PERF_DAMAGE", "REDIWM_TEST_PERF_HZ",
                "REDIWM_TEST_PERF_DAMAGE_RECT", "REDIWM_TEST_LIVE_FILE",
                "REDIWM_TEST_EDGE", "REDIWM_TEST_COMMANDS", "REDIWM_TEST_INITIAL_STATE")


def cpu_seconds(pid):
    fields = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()
    return (int(fields[11]) + int(fields[12])) / os.sysconf("SC_CLK_TCK")


def thread_delta(before, after, elapsed):
    rows = []
    for tid, (name, ns, voluntary, involuntary) in after.items():
        old = before.get(tid, (name, 0, 0, 0))
        rows.append({"tid": tid, "name": name, "cpu_ns": ns - old[1],
                     "voluntary": voluntary - old[2], "involuntary": involuntary - old[3]})
    return {"cpu_percent": sum(r["cpu_ns"] for r in rows) / 1e9 / elapsed * 100,
            "voluntary_switches_per_second": sum(r["voluntary"] for r in rows) / elapsed,
            "involuntary_switches_per_second": sum(r["involuntary"] for r in rows) / elapsed,
            "threads": sorted(rows, key=lambda r: -r["cpu_ns"]),
            "exited_threads": sorted(set(before) - set(after))}


class Session:
    def __init__(self, args, tmp):
        self.args, self.tmp = args, tmp
        self.clients, self.client_logs, self.ids = [], [], []
        self.held = False
        self.phase_rows = {}
        build_client(tmp)
        env = isolated_environment(tmp)
        # Prevent delayed autosave restore from moving fixtures during a sample.
        no_state = tmp / "state-disabled"
        no_state.write_text("isolated performance fixture")
        env.update(XDG_STATE_HOME=str(no_state), PULSE_SERVER=f"unix:{tmp}/missing-pulse",
                   PIPEWIRE_RUNTIME_DIR=str(tmp), REDIWM_DESKTOP_DIR=str(tmp / "desktop"),
                   REDIWM_APP_SCOPES="0", REDIWM_SESSION_FD="", REDIWM_LOGIN_SESSION="",
                   DISPLAY="", XAUTHORITY="", WLR_RENDERER_ALLOW_SOFTWARE="1",
                   REDIWM_THEME=str(tmp / "rediwm-config.toml"))
        if args.drm_device:
            env["WLR_RENDER_DRM_DEVICE"] = args.drm_device
        self.env = env
        wallpaper = tmp / "wallpaper.png"
        Image.new("RGB", (32, 32), (20, 24, 30)).save(wallpaper)
        config = (f'[compositor]\nxwayland = false\nfocus_zoom = "keep"\n'
                  f'wallpaper = "{wallpaper}"\nswitcher_style = "{args.style}"\n'
                  '[desktop]\nenabled = false\n[polkit]\nenable = false\n'
                  '[keybinds]\n"ctrl+tab" = "focus_next"\n"ctrl+shift+tab" = "focus_prev"\n')
        self.process, self.log = spawn_compositor(tmp, binary=args.binary, renderer=args.renderer,
            scale=str(args.scale), config_content=config, env_extra=env)
        self.ipc = None
        try:
            self.ipc = IPCClient(tmp, timeout=20).connect()
            self.ipc.wait_for("wallpaper_presented", timeout_ms=15000)
            self.display = next(p.name for p in tmp.glob("wayland-*") if not p.name.endswith(".lock"))
            self.outputs = self.ipc.get_outputs()
            self.ipc.move_cursor(0, 0)
            if args.mode == "stats":
                self.ipc.get_perf()  # Instrumentation belongs to this session only.
        except Exception:
            self.close()
            raise

    def close(self):
        for client in self.clients:
            if client.poll() is None:
                stop_process(client)
        if self.ipc:
            self.ipc.close()
        if self.process.poll() is None:
            stop_process(self.process)
        self.log.close()

    def callbacks(self):
        return [path.read_text().count("frame ") for path in self.client_logs]

    def settle(self, seconds=0.7):
        self.ipc.wait_for_frame()
        time.sleep(seconds)

    def open_switcher(self, timed=False):
        self.ipc.key(29, True)
        self.held = True
        started = time.monotonic()
        self.ipc.key_down_up(15)
        dispatched = time.monotonic()
        if timed:
            self.ipc.wait_for_frame()
            return {"dispatch_ms": (dispatched - started) * 1000,
                    "dispatch_to_frame_ms": (time.monotonic() - dispatched) * 1000,
                    "total_to_frame_ms": (time.monotonic() - started) * 1000}

    def cancel_switcher(self):
        self.ipc.key_down_up(1)
        self.ipc.key(29, False)
        self.held = False

    def fixtures(self, live=False):
        if self.held:
            self.cancel_switcher()
        for client in self.clients:
            if client.poll() is None:
                stop_process(client)
        self.clients, self.client_logs, self.ids = [], [], []
        wait_for(lambda: not self.ipc.get_windows(), "old fixtures did not close")
        self.settle()
        for i in range(self.args.windows):
            env = dict(os.environ, **self.env, XDG_RUNTIME_DIR=str(self.tmp),
                       WAYLAND_DISPLAY=self.display, REDIWM_TEST_NO_CHILD="1",
                       REDIWM_TEST_DECORATION="server", REDIWM_TEST_HIDE_CURSOR="1")
            for name in FIXTURE_VARS:
                env.pop(name, None)
            if live:
                env["REDIWM_TEST_PERF"] = "1"
                env["REDIWM_TEST_PERF_HZ"] = str(self.args.fps)
                if self.args.live_kind == "damage":
                    env["REDIWM_TEST_PERF_DAMAGE"] = "1"
                if self.args.damage_rect and self.args.live_kind == "damage":
                    env["REDIWM_TEST_PERF_DAMAGE_RECT"] = self.args.damage_rect
            title = f"Switcher performance {i}"
            path = self.tmp / f"{'live' if live else 'static'}-{i}.log"
            with path.open("w") as log:
                client = subprocess.Popen([str(self.tmp / "client"), "--title", title,
                    "--app-id", f"rediwm.switcher-perf.{i % self.args.apps}"],
                    env=env, stdout=log, stderr=log)
            self.clients.append(client)
            self.client_logs.append(path)
            window = wait_for(lambda: next((w for w in self.ipc.get_windows() if w["title"] == title), None),
                              "fixture did not map")
            wid = window["id"]
            self.ids.append(wid)
            self.ipc.action("set_window_size", {"id": wid, "width": 640, "height": 420})
            self.ipc.action("move_window_to", {"id": wid, "x": 120, "y": 80})
            self.ipc.wait_for("window_geometry_settled", window_id=wid)
            wait_for(lambda: path.read_text().count("frame ") >= 8, "fixture initial callbacks did not settle")
            self.ipc.action("minimize_window", {"id": wid})
        self.settle(1)
        assert all(w["is_minimized"] for w in self.ipc.get_windows())

    def warmup(self):
        for _ in range(self.args.warmup):
            self.open_switcher()
            for _ in range(min(3, self.args.windows) - 1):
                self.ipc.key_down_up(15)
            self.ipc.wait_for_frame()
            time.sleep(self.args.dwell)
            self.cancel_switcher()
            self.ipc.wait_for_frame()
        self.settle(1)

    def measure(self, name, cycling=False, expect_static=False, expect_live=False):
        if self.args.mode == "stats":
            self.ipc.reset_perf()
        callbacks_before = self.callbacks()
        mem_before = memory(self.process.pid)
        threads_before = thread_snapshot(self.process.pid)
        ticks_before = cpu_seconds(self.process.pid)
        started = time.monotonic()
        inputs = 0
        if cycling:
            while time.monotonic() - started < self.args.seconds:
                self.ipc.key_down_up(15)
                inputs += 1
                time.sleep(max(0, started + inputs / self.args.rate - time.monotonic()))
        else:
            time.sleep(self.args.seconds)
        elapsed = time.monotonic() - started
        ticks_after = cpu_seconds(self.process.pid)
        threads_after = thread_snapshot(self.process.pid)
        callbacks = [a - b for a, b in zip(self.callbacks(), callbacks_before)]
        row = {"seconds": elapsed, "input_steps": inputs, **thread_delta(threads_before, threads_after, elapsed),
               "cpu_ticks_percent": (ticks_after - ticks_before) / elapsed * 100,
               "client_callbacks": callbacks, "client_callbacks_per_second": sum(callbacks) / elapsed,
               "memory_before": mem_before, "memory_after": memory(self.process.pid)}
        if self.args.mode == "stats":
            row["stats"] = condense(self.ipc.get_perf())
        if expect_static:
            assert sum(callbacks) == 0, (name, "supposedly static clients kept requesting callbacks", callbacks)
        if expect_live:
            assert sum(callbacks) > 0, (name, "live workload did not draw", callbacks)
        self.phase_rows[name] = row
        print(f"{name}: CPU {row['cpu_percent']:.3f}%, switches "
              f"{row['voluntary_switches_per_second']:.1f}/s, callbacks "
              f"{row['client_callbacks_per_second']:.1f}/s", flush=True)
        assert self.process.poll() is None
        return row

    def performance(self):
        self.fixtures()
        cold_open = self.open_switcher(timed=True)
        self.cancel_switcher()
        self.warmup()
        self.measure("closed_idle", expect_static=True)
        self.open_switcher()
        self.settle(1)
        self.measure("held_static", expect_static=True)
        self.measure("cycling_static", cycling=True, expect_static=True)
        self.cancel_switcher()
        self.settle(1)
        self.measure("post_close_static_idle", expect_static=True)
        self.fixtures(live=True)
        self.ipc.restore(self.ids[-1])
        self.ipc.wait_for("window_geometry_settled", window_id=self.ids[-1])
        self.settle(1)
        self.measure("ordinary_live_window", expect_live=True)
        self.ipc.action("minimize_window", {"id": self.ids[-1]})
        self.settle(1)
        self.open_switcher()
        self.settle(1)
        self.measure("held_live_minimized", expect_live=True)
        self.cancel_switcher()
        self.settle(1)
        self.measure("post_close_live_idle", expect_static=True)
        return {"cold_open": cold_open, "phases": self.phase_rows}

    def retention_snapshot(self):
        counts = scene_counts(self.ipc)
        return {**memory(self.process.pid), "scene_counts": counts, "scene_nodes": sum(counts.values())}

    def retention(self):
        self.fixtures()
        cold = self.retention_snapshot()
        cold_open = self.open_switcher(timed=True)
        self.cancel_switcher()
        self.warmup()
        baseline = self.retention_snapshot()
        rows = []
        for cycle in range(self.args.cycles):
            opened = self.open_switcher(timed=True)
            for _ in range(min(3, self.args.windows) - 1):
                self.ipc.key_down_up(15)
            self.ipc.wait_for_frame()
            time.sleep(self.args.dwell)
            self.cancel_switcher()
            self.settle(self.args.settle)
            sample = self.retention_snapshot()
            sample["cycle"] = cycle + 1
            sample["open_timing"] = opened
            assert sample["scene_counts"] == baseline["scene_counts"], ("scene nodes retained", cycle, sample, baseline)
            assert sample["fds"] == baseline["fds"], ("file descriptors retained", cycle, sample, baseline)
            rows.append(sample)
            if (cycle + 1) % 10 == 0:
                print(f"retention {cycle + 1}/{self.args.cycles}: private {sample['private_kib']} KiB, "
                      f"nodes {sample['scene_nodes']}, FDs {sample['fds']}", flush=True)
        timing = {}
        for key in ("dispatch_ms", "dispatch_to_frame_ms", "total_to_frame_ms"):
            values = sorted(row["open_timing"][key] for row in rows)
            timing[key] = {"p50": statistics.median(values),
                           "p95": values[math.ceil(len(values) * .95) - 1], "max": max(values)}
        return {"cold": cold, "cold_open": cold_open, "warmed_baseline": baseline,
                "cycles": rows, "open_timings_ms": timing, "summary": summarize(baseline, rows)}


def run(args):
    power = power_state()
    if power["ac_online"] is False and not args.allow_battery:
        raise SystemExit("Performance comparisons on battery are unreliable; use AC or --allow-battery.")
    report = {"binary": str(args.binary), "sha256": hashlib.sha256(args.binary.read_bytes()).hexdigest(),
              "mode": args.mode, "style": args.style, "scale": args.scale, "windows": args.windows,
              "apps": args.apps, "fixture_size": [640, 420], "live_damage_rect": args.damage_rect,
              "live_kind": args.live_kind,
              "live_fps_limit": args.fps,
              "seconds_per_phase": args.seconds, "cycling_rate": args.rate,
              "warmup_cycles": args.warmup, "power_before": power,
              "renderer": args.renderer, "drm_device": args.drm_device,
              "renderer_environment": {name: os.environ.get(name) for name in
                  ("LIBGL_ALWAYS_SOFTWARE", "MESA_LOADER_DRIVER_OVERRIDE", "REDIWM_NO_GLASS")},
              "cpu_affinity": sorted(os.sched_getaffinity(0)),
              "notes": ["100% CPU is one core; clean mode never enables performance IPC.",
                        "Frame CPU/GPU costs overlap and must not be added.",
                        "Open timings measure IPC dispatch and a subsequent frame barrier, not scanout latency.",
                        "Headless results do not establish physical-display latency."]}
    with tempfile.TemporaryDirectory(prefix="rediwm-switcher-perf-") as directory:
        tmp = Path(directory)
        tmp.chmod(0o700)
        session = None
        try:
            session = Session(args, tmp)
            report["outputs"] = session.outputs
            report.update(session.retention() if args.mode == "retention" else session.performance())
            report["power_after"] = power_state()
        finally:
            if session:
                session.close()
            log = tmp / "compositor.log"
            if log.exists():
                contents = log.read_text()
                report["compositor_log_tail"] = contents[-12000:]
                report["renderer_log"] = [line for line in contents.splitlines()
                    if any(word in line.lower() for word in ("egl", "opengl", "renderer", "drm"))][:40]
            args.out.parent.mkdir(parents=True, exist_ok=True)
            args.out.write_text(json.dumps(report, indent=2) + "\n")
    print(f"Saved {args.out}", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=ROOT / "zig-out/release-safe/bin/rediwm")
    parser.add_argument("--style", choices=("linear", "circular"), default="circular")
    parser.add_argument("--mode", choices=("clean", "stats", "retention"), default="clean")
    parser.add_argument("--scale", type=float, default=1)
    parser.add_argument("--windows", type=int, default=8)
    parser.add_argument("--apps", type=int, default=4)
    parser.add_argument("--seconds", type=float, default=5)
    parser.add_argument("--rate", type=float, default=6)
    parser.add_argument("--fps", type=int, default=60, help="Live fixture cadence; 0 means unpaced")
    parser.add_argument("--warmup", type=int, default=5)
    parser.add_argument("--cycles", type=int, default=50)
    parser.add_argument("--dwell", type=float, default=.15)
    parser.add_argument("--settle", type=float, default=.25)
    parser.add_argument("--renderer", default=os.environ.get("REDIWM_TEST_RENDERER", "gles2"))
    parser.add_argument("--drm-device", default=os.environ.get("WLR_RENDER_DRM_DEVICE"))
    parser.add_argument("--damage-rect", help="Live fixture surface-local x,y,w,h; absent means full damage")
    parser.add_argument("--live-kind", choices=("empty", "damage"), default="damage",
                        help="Callback-only commits or buffer repaint commits in live phases")
    parser.add_argument("--allow-battery", action="store_true")
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    args.binary = args.binary.resolve()
    if not args.binary.is_file():
        parser.error("--binary must exist")
    if not all(math.isfinite(v) and v > 0 for v in (args.scale, args.seconds, args.rate, args.dwell, args.settle)):
        parser.error("scale, seconds, rate, dwell and settle must be positive and finite")
    if args.windows < 1 or not 1 <= args.apps <= args.windows or args.cycles < 1 or args.warmup < 1:
        parser.error("require windows >= apps >=1, cycles >=1 and warmup >=1")
    if not 0 <= args.fps <= 1000:
        parser.error("fps must be between 0 and 1000")
    run(args)

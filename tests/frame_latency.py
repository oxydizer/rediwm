#!/usr/bin/env python3
"""Frame scheduling and latency measurements, with and without late rendering.

Needs a compositor built with `-Dframe-trace=true`:

    zig build install -Dframe-trace=true -Doptimize=ReleaseSafe --prefix zig-out/frame-trace-late

Each scenario runs in its own isolated compositor (private runtime dir and
config, no D-Bus; the host session is never touched) with `late_render` off
and/or on:

  idle     nothing happens: CPU and wakeups must not change
  pointer  synthetic pointer motion over the desktop (IPC automation)
  event    a probe client commits on every pointer motion over its window
  paced    a probe client animates, one commit per frame callback

The probe client (frame_probe_client.c) records, per commit, when it was made
and when wp_presentation says the display showed it: the end-to-end latency,
and the number to judge by. The compositor trace (see output/frame_trace.zig)
adds the stages inside the compositor.

    python3 tests/frame_latency.py --late both                    # headless: cost only
    python3 tests/frame_latency.py --backend drm --late both      # on a spare text VT

The headless backend presents synchronously, so its latencies mean nothing and
late rendering never engages there. Only `--backend drm` (a text VT; it takes
the display) and `--backend wayland` (nested, opens a window on the host)
report real presentation times. `--bin-dir` selects the binary, so a build from
before late rendering can supply the baseline (`--late off`). To analyse a log
from any traced compositor: `--analyze LOG [--probe FILE]`.
"""
import argparse
import os
from pathlib import Path
import random
import re
import statistics
import subprocess
import tempfile
import time

from desktop_zoom import ROOT, wait_for
from ipc_client import IPCClient

TRACE_LINE = re.compile(r"frame_trace\): ([FP]) (.*)$")
# Presentation gaps longer than this many periods are idle, not missed frames.
BURST_PERIODS = 8
SCENARIOS = ("idle", "pointer", "event", "paced")


def parse(text):
    frames, presents = [], {}
    for raw in text.splitlines():
        match = TRACE_LINE.search(raw)
        if not match:
            continue
        kind, rest = match.groups()
        record = {k: (v if k == "out" else int(v)) for k, v in (kv.split("=", 1) for kv in rest.split())}
        if kind == "F":
            frames.append(record)
        else:
            presents[(record["out"], record["cseq"])] = record
    return frames, presents


def percentile(values, p):
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, max(0, -(-len(ordered) * p // 100) - 1))]


def stats_line(name, values):
    if not values:
        return f"{name:26s} (no samples)"
    return (f"{name:26s} n={len(values):6d} p50={percentile(values, 50):8.3f} p95={percentile(values, 95):8.3f} "
            f"p99={percentile(values, 99):8.3f} max={max(values):8.3f} avg={statistics.fmean(values):8.3f}")


def trace_rows(text, skip):
    frames, presents = parse(text)
    committed = [f for f in frames if f["commit"]]
    rows = []
    for f in committed:
        p = presents.get((f["out"], f["cseq"]))
        if p and p["presented"]:
            rows.append(dict(f, when=p["when"], now=p["now"], flags=p["flags"], refresh=p["refresh"]))
    return frames, rows[skip:]


def analyze_trace(text, skip=30):
    """Pair each committed frame with its presentation; all values in ms."""
    frames, rows = trace_rows(text, skip)
    ms = 1e6
    out = [f"{len(frames)} frames ({sum(1 for f in frames if not f['commit'])} without a commit), {len(rows)} presented and analysed"]
    out.append(stats_line("frame event -> start", [(r["start"] - r["ev"]) / ms for r in rows if r["ev"]]))
    out.append(stats_line("render (start->built)", [(r["built"] - r["start"]) / ms for r in rows]))
    out.append(stats_line("commit (built->done)", [(r["done"] - r["built"]) / ms for r in rows]))
    out.append(stats_line("cpu (start->done)", [(r["done"] - r["start"]) / ms for r in rows]))
    out.append(stats_line("slack (done->light)", [(r["when"] - r["done"]) / ms for r in rows]))
    out.append(stats_line("age of render start", [(r["when"] - r["start"]) / ms for r in rows]))
    out.append(stats_line("age of oldest damage", [(r["when"] - r["d1"]) / ms for r in rows if r["d1"]]))
    out.append(stats_line("age of newest damage", [(r["when"] - r["d2"]) / ms for r in rows if r["d2"]]))
    phase, gaps, missed, last = [], [], 0, None
    for r in rows:
        if last is not None and last["out"] == r["out"]:
            gap = (r["when"] - last["when"]) / ms
            period = (r["refresh"] or last["refresh"]) / ms or 16.667
            if gap < period * BURST_PERIODS:
                gaps.append(gap)
                missed += max(0, round(gap / period) - 1)
            phase.append((r["start"] - last["when"]) / ms)
        last = r
    out.append(stats_line("start after last light", phase))
    out.append(stats_line("present interval", gaps))
    flags = {}
    for r in rows:
        flags[r["flags"]] = flags.get(r["flags"], 0) + 1
    refresh = statistics.median([r["refresh"] for r in rows]) if rows else 0
    out.append(f"missed refreshes in bursts: {missed}; present flags: {flags}; predicted refresh: {refresh / ms:.3f} ms")
    late = [r for r in rows if r.get("late")]
    if late:
        hits = sum(1 for r in late if r["when"] - r["vexp"] <= (r["refresh"] or 16_666_667) / 2)
        out.append(f"late-rendered frames: {len(late)} ({len(late) * 100 // max(len(rows), 1)}% of presented), "
                   f"deadline hits {hits}, misses {len(late) - hits}")
        out.append(stats_line("late: estimate", [r["est"] / ms for r in late]))
        out.append(stats_line("late: margin", [r["mrg"] / ms for r in late]))
        out.append(stats_line("late: slack (done->vexp)", [(r["vexp"] - r["done"]) / ms for r in late]))
    return "\n".join(out)


def probe_latencies(path):
    """Commit-to-photon per commit: a replaced frame is shown with the next presented one."""
    records = []
    for line in Path(path).read_text().splitlines():
        commit, presented, _flags = (int(x) for x in line.split())
        records.append((commit, presented))
    shown, latencies = None, []
    for commit, presented in reversed(records):
        if presented:
            shown = presented
        if shown:
            latencies.append((shown - commit) / 1e6)
    return latencies[::-1]


def process_load(pid):
    """CPU seconds and context switches of the whole process so far."""
    fields = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()
    cpu = (int(fields[11]) + int(fields[12])) / os.sysconf("SC_CLK_TCK")
    switches = 0
    for task in Path(f"/proc/{pid}/task").iterdir():
        try:
            for line in (task / "status").read_text().splitlines():
                if "ctxt_switches" in line:
                    switches += int(line.split()[1])
        except OSError:
            pass
    return cpu, switches


def build_probe(tmp):
    protocols = subprocess.check_output(["pkg-config", "--variable=pkgdatadir", "wayland-protocols"], text=True).strip()
    for xml, name in (("stable/xdg-shell/xdg-shell.xml", "xdg-shell"),
                      ("stable/presentation-time/presentation-time.xml", "presentation-time")):
        for mode, target in (("client-header", f"{name}-client-protocol.h"), ("private-code", f"{name}-protocol.c")):
            subprocess.run(["wayland-scanner", mode, str(Path(protocols) / xml), str(tmp / target)], check=True)
    subprocess.run(["cc", "-Wall", "-Wextra", f"-I{tmp}", str(ROOT / "tests/frame_probe_client.c"),
                    str(tmp / "xdg-shell-protocol.c"), str(tmp / "presentation-time-protocol.c"),
                    "-lwayland-client", "-o", str(tmp / "frame_probe_client")], check=True)
    return tmp / "frame_probe_client"


def session_env(args, tmp):
    env = dict(os.environ, XDG_RUNTIME_DIR=str(tmp), XDG_CONFIG_HOME=str(tmp / "config"),
               XDG_CACHE_HOME=str(tmp / "cache"), XDG_DATA_HOME=str(tmp / "data"), XDG_STATE_HOME=str(tmp / "state"),
               REDIWM_CONFIG=str(tmp / "config.toml"), WLR_RENDERER_ALLOW_SOFTWARE="1",
               WLR_RENDERER=os.environ.get("REDIWM_TEST_RENDERER", "gles2"),
               REDIWM_SCALE=os.environ.get("REDIWM_TEST_SCALE", "1"), REDIWM_IPC_AUTOMATION="1", DBUS_SESSION_BUS_ADDRESS="")
    for name in ("REDIWM_SOCKET", "DISPLAY", "WLR_BACKENDS", "WLR_HEADLESS_OUTPUTS"):
        env.pop(name, None)
    if args.backend == "wayland":
        # The private runtime dir hides the host's socket: name it in full.
        host = Path(os.environ.get("XDG_RUNTIME_DIR", "")) / os.environ.get("WAYLAND_DISPLAY", "")
        if not host.is_socket():
            raise SystemExit("--backend wayland needs a host Wayland session")
        env["WAYLAND_DISPLAY"] = str(host)
    else:
        env.pop("WAYLAND_DISPLAY", None)
    if args.backend == "headless":
        env.update(WLR_BACKENDS="headless", WLR_HEADLESS_OUTPUTS="1")
    return env


def jitter_pointer(ipc, area, seconds, rng):
    """Pointer motion at about 125 Hz with jitter, back and forth across `area` (x, y, w, h)."""
    x0, y0, w, h = area
    started, count = time.monotonic(), 0
    while time.monotonic() - started < seconds:
        count += 1
        ipc.move_cursor(int(x0 + w * (0.1 + 0.8 * abs((count % 200) / 100 - 1))), int(y0 + h * (0.3 + 0.4 * abs((count % 50) / 25 - 1))))
        time.sleep(rng.uniform(.005, .011))


def run_scenario(args, scenario, late, probe_bin):
    with tempfile.TemporaryDirectory(prefix="rediwm-frame-latency-") as directory:
        tmp = Path(directory)
        # Off writes no key at all, so a build from before late rendering takes the same config.
        (tmp / "config.toml").write_text(("[compositor]\nlate_render = true\n" if late else "") + args.config)
        env = session_env(args, tmp)
        log_path = tmp / "compositor.log"
        with log_path.open("w") as log:
            compositor = subprocess.Popen([str(args.bin_dir / "rediwm")], env=env, stdout=log, stderr=log)
        client = None
        result = {"scenario": scenario, "late": late}
        try:
            socket = wait_for(lambda: next(tmp.glob("rediwm-*.sock"), None), "IPC unavailable", 30)
            display = wait_for(lambda: next((p.name for p in tmp.glob("wayland-*") if not p.name.endswith(".lock")), None), "display unavailable")
            with IPCClient(socket) as ipc:
                ipc.action("wait_for", {"condition": "wallpaper_presented", "timeout_ms": 15000})
                time.sleep(1)
                output = ipc.get_outputs()[0]
                width, height = output["logical_width"], output["logical_height"]
                area = (0, 0, width, height)
                probe_file = tmp / "probe.txt"
                if scenario in ("event", "paced"):
                    mode = "event" if scenario == "event" else "paced"
                    client = subprocess.Popen([str(probe_bin), mode, str(args.seconds + 1), str(probe_file)],
                                              env=dict(env, WAYLAND_DISPLAY=display))
                    window = wait_for(lambda: next((w for w in ipc.get_windows() if w.get("app_id") == "frame-probe"), None), "probe window never mapped")
                    ipc.wait_for("window_geometry_settled", window_id=window["id"])
                    window = next(w for w in ipc.get_windows() if w.get("app_id") == "frame-probe")
                    area = (window["x"], window["y"], window["width"], window["height"])
                    time.sleep(.5)
                cpu0, switches0 = process_load(compositor.pid)
                started = time.monotonic()
                rng = random.Random(1)
                if scenario in ("pointer", "event"):
                    jitter_pointer(ipc, area, args.seconds, rng)
                else:
                    time.sleep(args.seconds)
                elapsed = time.monotonic() - started
                cpu1, switches1 = process_load(compositor.pid)
                result["cpu_percent"] = (cpu1 - cpu0) * 100 / elapsed
                result["switches_per_s"] = (switches1 - switches0) / elapsed
            if client:
                client.wait(timeout=30)
                result["probe"] = probe_latencies(probe_file) if probe_file.exists() else []
        finally:
            for process in (client, compositor):
                if process and process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(5)
                    except subprocess.TimeoutExpired:
                        process.kill()
        result["log"] = log_path.read_text(errors="replace")
    return result


def summary_row(result, skip):
    probe = result.get("probe", [])[skip:]
    _, rows = trace_rows(result["log"], skip)
    late = sum(1 for r in rows if r.get("late"))
    row = f"{result['scenario']:8s} late={'on ' if result['late'] else 'off'} cpu={result['cpu_percent']:5.2f}% wakeups={result['switches_per_s']:7.1f}/s frames={len(rows):5d} late_frames={late:5d}"
    if probe:
        row += (f"\n{'':9s}commit->photon ms: p50={percentile(probe, 50):6.2f} p95={percentile(probe, 95):6.2f} "
                f"p99={percentile(probe, 99):6.2f} max={max(probe):6.2f} spread(p99-p50)={percentile(probe, 99) - percentile(probe, 50):5.2f} n={len(probe)}")
    return row


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--bin-dir", type=Path, default=ROOT / "zig-out/frame-trace-late/bin")
    parser.add_argument("--analyze", type=Path, help="analyse this compositor log instead of running sessions")
    parser.add_argument("--probe", type=Path, help="with --analyze: a probe client's output file")
    parser.add_argument("--backend", choices=("headless", "wayland", "drm"), default="headless")
    parser.add_argument("--late", choices=("off", "on", "both"), default="both")
    parser.add_argument("--scenario", default="all", help="comma separated: " + ", ".join(SCENARIOS) + ", or all")
    parser.add_argument("--seconds", type=float, default=12)
    parser.add_argument("--config", default="", help="more config.toml text, e.g. '[compositor]' keys after late_render")
    parser.add_argument("--keep", type=Path, help="save each run's compositor log in this directory")
    parser.add_argument("--skip", type=int, default=30, help="warm-up frames to drop")
    args = parser.parse_args()

    if args.analyze:
        print(analyze_trace(args.analyze.read_text(errors="replace"), args.skip))
        if args.probe:
            print(stats_line("commit->photon (probe)", probe_latencies(args.probe)[args.skip:]))
        return
    if args.backend == "drm" and os.environ.get("XDG_SESSION_TYPE") != "tty":
        raise SystemExit("--backend drm takes the display: run it from a text VT (XDG_SESSION_TYPE=tty), not inside a desktop session")
    scenarios = SCENARIOS if args.scenario == "all" else tuple(s for s in args.scenario.split(",") if s in SCENARIOS)
    modes = {"off": (False,), "on": (True,), "both": (False, True)}[args.late]
    with tempfile.TemporaryDirectory(prefix="rediwm-probe-build-") as build_dir:
        probe_bin = build_probe(Path(build_dir)) if any(s in ("event", "paced") for s in scenarios) else None
        results = []
        for scenario in scenarios:
            for late in modes:
                print(f"running {scenario}, late_render {'on' if late else 'off'} ...", flush=True)
                result = run_scenario(args, scenario, late, probe_bin)
                results.append(result)
                if args.keep:
                    args.keep.mkdir(parents=True, exist_ok=True)
                    (args.keep / f"{scenario}-{'late' if late else 'normal'}.log").write_text(result["log"])
    print()
    for result in results:
        print(summary_row(result, args.skip))
    for result in results:
        if result["scenario"] != "idle":
            print(f"\n== {result['scenario']}, late_render {'on' if result['late'] else 'off'}")
            print(analyze_trace(result["log"], args.skip))


if __name__ == "__main__":
    main()

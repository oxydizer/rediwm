#!/usr/bin/env python3
"""Repeated open/close retention audit in a private headless GLES2 compositor.

Records compositor PSS, private clean + dirty memory, swap, scene nodes, FDs,
and driver-reported DRM memory after every cycle. Warm-up cycles are recorded
but excluded from growth/slope calculations. PSS does not include all GPU memory;
missing DRM accounting is reported as null, never zero. No allocator trimming.

    python3 tests/memory_retention.py --cycles 50 --out /tmp/retention.json
    python3 tests/memory_retention.py --app files --scale 1.5 --out /tmp/files.json
    python3 tests/memory_retention.py --app control-center --out /tmp/settings.json
    python3 tests/memory_retention.py --app brave --dwell 2 --out /tmp/brave.json

Use ReleaseSafe for memory comparisons; Debug's allocator has different retention.
Memory thresholds are opt-in and machine-specific. Scene counts must return to
the warmed baseline. Applications must exit on close (no background daemon).
"""

import argparse
from collections import Counter
import hashlib
import json
import math
import os
from pathlib import Path
import shutil
import signal
import statistics
import subprocess
import tempfile
import time

from PIL import Image

from ipc_client import IPCClient, ROOT, spawn_compositor, stop_process


# Animated canvas: keeps Brave committing new dmabuf frames while the window is open.
PAGE = """<!doctype html><title>retention</title><body style="margin:0"><canvas id=c></canvas><script>
const c = document.getElementById("c"), g = c.getContext("2d");
c.width = innerWidth; c.height = innerHeight;
(function f(t) { const x = (t / 8) % c.width, gr = g.createLinearGradient(x, 0, x + 400, c.height);
  gr.addColorStop(0, "#c33"); gr.addColorStop(1, "#38c"); g.fillStyle = gr;
  g.fillRect(0, 0, c.width, c.height); requestAnimationFrame(f); })(0);
</script>"""


def drm_memory(proc):
    """Keep counters per DRM client; duplicated FDs must not double-count them."""
    clients = {}
    for path in (proc / "fdinfo").iterdir():
        try:
            fields = dict(line.split(":", 1) for line in path.read_text().splitlines() if ":" in line)
        except FileNotFoundError:  # A short-lived FD can disappear during enumeration.
            continue
        fields = {key: value.strip() for key, value in fields.items()}
        if "drm-client-id" not in fields:
            continue
        identity = ":".join(fields.get(key, "") for key in ("drm-driver", "drm-pdev", "drm-client-id"))
        counters = {}
        for key, value in fields.items():
            if key.startswith(("drm-memory-", "drm-total-", "drm-shared-", "drm-resident-",
                               "drm-active-", "drm-purgeable-")):
                parts = value.split()
                if len(parts) == 2 and parts[1] in ("KiB", "kB"):
                    counters[key] = int(parts[0])
        clients[identity] = counters
    return clients or None


def memory(pid):
    proc = Path(f"/proc/{pid}")
    fields = {}
    for line in (proc / "smaps_rollup").read_text().splitlines():
        parts = line.split()
        if len(parts) == 3 and parts[2] == "kB":
            fields[parts[0].removesuffix(":")] = int(parts[1])
    return {
        "pss_kib": fields["Pss"], "rss_kib": fields["Rss"],
        "private_kib": fields["Private_Clean"] + fields["Private_Dirty"],
        "private_clean_kib": fields["Private_Clean"], "private_dirty_kib": fields["Private_Dirty"],
        "pss_anon_kib": fields.get("Pss_Anon"), "pss_file_kib": fields.get("Pss_File"),
        "pss_shmem_kib": fields.get("Pss_Shmem"), "swap_kib": fields["Swap"],
        "swap_pss_kib": fields.get("SwapPss"),
        "fds": len(list((proc / "fd").iterdir())),
        "mappings": len((proc / "maps").read_text().splitlines()),
        "threads": len(list((proc / "task").iterdir())),
        "drm_clients_kib": drm_memory(proc),
    }


def scene_counts(ipc):
    scene = ipc.get_scene_tree(max_depth=256)
    nodes = scene["nodes"]
    assert len(nodes) == scene["total_nodes"], "scene query truncated"
    return dict(sorted(Counter(f"{n['node_type']}:{n['role']}" for n in nodes).items()))


def settle(ipc, seconds):
    # window_closed means unmapped, not destroyed: allow the close animation,
    # deferred teardown and renderer releases to finish before sampling.
    time.sleep(seconds)
    ipc.wait_for_frame()
    ipc.wait_for_frame()


def sample(ipc, pid):
    assert not ipc.get_windows(), "a window survived closure"
    counts = scene_counts(ipc)
    return {**memory(pid), "scene_counts": counts, "scene_nodes": sum(counts.values())}


def brave_command(env):
    """Isolated Brave: private profile, no network (a dead-end proxy), animated page."""
    browser = os.environ.get("REDIWM_TEST_BRAVE") or shutil.which("brave")
    if not browser:
        raise SystemExit("Brave not found; set REDIWM_TEST_BRAVE to its executable")
    home = Path(env["HOME"])
    return [browser, "--ozone-platform=wayland", f"--user-data-dir={home / 'brave-profile'}",
            "--no-first-run", "--no-default-browser-check", "--disable-background-networking",
            "--proxy-server=http://127.0.0.1:9", "--password-store=basic",
            "--hide-crash-restore-bubble", (home / "page.html").as_uri()]


def kill_group(pid):
    """Brave is a process tree started in its own session; never leave children behind."""
    try:
        os.killpg(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass


def cycle(args, ipc, env, app_log):
    app = None
    try:
        if args.app == "control-center":
            ipc.open_control_center()
            ipc.wait_for("window_mapped", app_id="rediwm-settings")
        else:
            if args.app == "brave":
                # A reused profile restores last cycle's tab and Brave then asks "Close all tabs?".
                shutil.rmtree(Path(env["HOME"]) / "brave-profile", ignore_errors=True)
                command, app_id = brave_command(env), "brave-browser"
            else:
                command, app_id = [str(args.binary.parent / f"rediwm-{args.app}")], f"rediwm-{args.app}"
            if args.app == "files":
                command.append(env["HOME"])
            app = subprocess.Popen(command, env=env, stdout=app_log, stderr=app_log,
                                   start_new_session=args.app == "brave")
            ipc.wait_for("window_mapped", app_id=app_id, timeout_ms=30000)
        windows = ipc.get_windows()
        assert len(windows) == 1, f"expected one window, got {windows}"
        window_id = windows[0]["id"]
        ipc.wait_for("window_geometry_settled", window_id=window_id)
        ipc.wait_for_frame()
        opened = memory(app.pid) if app else None
        time.sleep(args.dwell)
        if args.close_mode == "kill":
            kill_group(app.pid) if args.app == "brave" else app.kill()
        else:
            ipc.close_window(window_id)
        if app:
            try:
                code = app.wait(timeout=30 if args.app == "brave" else 10)
            except subprocess.TimeoutExpired:
                tree = subprocess.run(["ps", "-o", "pid,stat,wchan:22,etime,args", "--sid", str(app.pid)],
                                      capture_output=True, text=True).stdout
                shot = args.out.with_name(args.out.stem + "-hang.png")
                ipc.screenshot(path=str(shot))
                raise AssertionError(f"{args.app} did not exit after close (screenshot: {shot}); windows={ipc.get_windows()}\n"
                                     + "\n".join(line[:160] for line in tree.splitlines()[:12])) from None
            if args.app == "brave":
                kill_group(app.pid)
            expected = -9 if args.close_mode == "kill" else 0
            assert code == expected, f"application exited {code}, expected {expected}"
        ipc.wait_for("window_closed", window_id=window_id)
        settle(ipc, args.settle)
        return opened
    finally:
        if app and app.poll() is None:
            stop_process(app)
        if app and args.app == "brave":
            kill_group(app.pid)


def summarize(baseline, rows):
    result = {}
    for key in ("pss_kib", "private_kib", "rss_kib", "swap_kib", "fds", "mappings", "scene_nodes"):
        values = [row[key] for row in rows]
        n = len(values)
        mean_x = (n - 1) / 2
        denominator = sum((i - mean_x) ** 2 for i in range(n))
        slope = sum((i - mean_x) * value for i, value in enumerate(values)) / denominator if denominator else 0
        tail = values[-min(5, n):]
        result[key] = {"baseline": baseline[key], "final": values[-1],
                       "growth": values[-1] - baseline[key], "peak": max(values),
                       "tail_median_growth": statistics.median(tail) - baseline[key],
                       "slope_per_cycle": round(slope, 3)}
    return result


def run(args, tmp, report):
    wallpaper = tmp / "wallpaper.png"
    Image.new("RGB", (64, 64), (32, 48, 64)).save(wallpaper)
    (tmp / "page.html").write_text(PAGE)
    env = dict(HOME=str(tmp), XDG_CONFIG_HOME=str(tmp / "config"), XDG_DATA_HOME=str(tmp / "data"),
               XDG_CACHE_HOME=str(tmp / "cache"), XDG_STATE_HOME=str(tmp / "state"),
               XDG_RUNTIME_DIR=str(tmp), XDG_DATA_DIRS=str(tmp / "data"),
               DBUS_SESSION_BUS_ADDRESS=f"unix:path={tmp}/missing-session",
               DBUS_SYSTEM_BUS_ADDRESS=f"unix:path={tmp}/missing-system",
               PULSE_SERVER=f"unix:{tmp}/missing-pulse", PIPEWIRE_RUNTIME_DIR=str(tmp),
               REDIWM_DESKTOP_DIR=str(tmp / "desktop"), REDIWM_FILES_DEVICES="0",
               REDIWM_APP_SCOPES="0", REDIWM_SESSION_FD="", REDIWM_LOGIN_SESSION="",
               DISPLAY="", XAUTHORITY="", WLR_RENDERER_ALLOW_SOFTWARE="1",
               REDIWM_THEME=str(tmp / "rediwm-config.toml"))
    if args.no_glass:
        env["REDIWM_NO_GLASS"] = "1"
    config = (f'[compositor]\nxwayland = false\nfocus_zoom = "keep"\nwallpaper = "{wallpaper}"\n'
              '[desktop]\nenabled = false\n'
              f'[animations]\nenabled = {str(not args.no_animations).lower()}\n')
    compositor, log = spawn_compositor(tmp, binary=args.binary, renderer="gles2", scale=str(args.scale),
                                       config_content=config, env_extra=env)
    try:
        with IPCClient(tmp, timeout=20) as ipc, (tmp / "app.log").open("w") as app_log:
            ipc.wait_for("wallpaper_presented", timeout_ms=15000)
            ipc.wait_for("catalog_published", timeout_ms=15000)
            display = next(p.name for p in tmp.glob("wayland-*") if not p.name.endswith(".lock"))
            app_env = dict(os.environ, **env, WAYLAND_DISPLAY=display,
                           REDIWM_CONFIG=str(tmp / "rediwm-config.toml"))
            app_env.pop("REDIWM_SOCKET", None)
            ipc.move_cursor(0, 0)
            report["runtime"] = ipc.get_runtime()
            report["outputs"] = ipc.get_outputs()
            settle(ipc, args.settle)
            report["cold"] = sample(ipc, compositor.pid)
            for i in range(args.warmup + args.cycles):
                opened = cycle(args, ipc, app_env, app_log)
                row = {"cycle": i + 1, "warmup": i < args.warmup,
                       "app_open": opened, **sample(ipc, compositor.pid)}
                report["samples"].append(row)
                print(f"{i + 1:3d} {'warm' if row['warmup'] else 'test'} "
                      f"PSS={row['pss_kib']:8d} KiB private={row['private_kib']:8d} KiB "
                      f"nodes={row['scene_nodes']} fds={row['fds']}", flush=True)
                if i == args.warmup - 1:
                    report["baseline"] = row
                    report["baseline_smaps"] = Path(f"/proc/{compositor.pid}/smaps").read_text()
            report["final_smaps"] = Path(f"/proc/{compositor.pid}/smaps").read_text()
            measured = report["samples"][args.warmup:]
            report["summary"] = summarize(report["baseline"], measured)
            failures = report["failures"]
            for row in measured:
                if row["scene_counts"] != report["baseline"]["scene_counts"]:
                    failures.append(f"scene counts differ at cycle {row['cycle']}")
            if args.max_private_growth_kib is not None:
                if report["summary"]["private_kib"]["tail_median_growth"] > args.max_private_growth_kib:
                    failures.append("private memory growth exceeded threshold")
            if args.max_pss_slope_kib is not None:
                if report["summary"]["pss_kib"]["slope_per_cycle"] > args.max_pss_slope_kib:
                    failures.append("PSS slope exceeded threshold")
    finally:
        stop_process(compositor)
        log.close()
        report["compositor_exit"] = compositor.returncode
        report["compositor_log"] = Path(log.name).read_text(errors="replace")
        report["app_log"] = (tmp / "app.log").read_text(errors="replace") if (tmp / "app.log").exists() else ""
        if compositor.returncode != 0:
            report["failures"].append(f"compositor exited {compositor.returncode}")
        if "memory leaks reported" in report["compositor_log"]:
            report["failures"].append("Debug allocator reported leaks on shutdown")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=ROOT / "zig-out/release-safe/bin/rediwm")
    parser.add_argument("--app", choices=("calculator", "editor", "files", "control-center", "brave"), default="calculator")
    parser.add_argument("--cycles", type=int, default=30)
    parser.add_argument("--warmup", type=int, default=5)
    parser.add_argument("--settle", type=float, default=1.0, help="seconds after each close before frame barriers")
    parser.add_argument("--dwell", type=float, default=0.0, help="seconds to keep the window open before closing")
    parser.add_argument("--scale", type=float, default=1.0)
    parser.add_argument("--close-mode", choices=("graceful", "kill"), default="graceful")
    parser.add_argument("--no-animations", action="store_true")
    parser.add_argument("--no-glass", action="store_true")
    parser.add_argument("--max-private-growth-kib", type=float)
    parser.add_argument("--max-pss-slope-kib", type=float)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    if args.cycles < 2 or args.warmup < 1 or not math.isfinite(args.settle) or args.settle < 0 or not math.isfinite(args.dwell) or args.dwell < 0:
        parser.error("need at least two measured cycles, one warm-up cycle and a nonnegative finite settle time")
    if not math.isfinite(args.scale) or args.scale <= 0:
        parser.error("scale must be positive and finite")
    for threshold in (args.max_private_growth_kib, args.max_pss_slope_kib):
        if threshold is not None and (not math.isfinite(threshold) or threshold < 0):
            parser.error("memory thresholds must be nonnegative and finite")
    if args.app == "control-center" and args.close_mode == "kill":
        parser.error("control-center is compositor-owned; use graceful closure")
    args.binary = args.binary.resolve()
    os.umask(0o077)
    os.environ.pop("REDIWM_NO_GLASS", None)
    report = {"schema": 1, "options": {k: str(v) if isinstance(v, Path) else v for k, v in vars(args).items()},
              "revision": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
              "dirty": bool(subprocess.check_output(["git", "status", "--porcelain"], cwd=ROOT)),
              "render_device": os.environ.get("WLR_RENDER_DRM_DEVICE"), "samples": [], "failures": []}
    with args.binary.open("rb") as binary:
        report["binary_sha256"] = hashlib.file_digest(binary, "sha256").hexdigest()
    try:
        with tempfile.TemporaryDirectory(prefix="rediwm-retention-") as directory:
            run(args, Path(directory), report)
    except Exception as error:
        report["failures"].append(f"{type(error).__name__}: {error}")
    finally:
        args.out.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report.get("summary", {}), indent=2))
    print(f"Report: {args.out}")
    if report["failures"]:
        raise SystemExit("FAIL: " + "; ".join(report["failures"]))


if __name__ == "__main__":
    main()

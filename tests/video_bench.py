#!/usr/bin/env python3
"""Compare the two VAAPI players on one RediWM output (video-player.md, phase 2).

--live-output shows temporary fullscreen windows on the named DRM connector.
--headless is a smoke test. Each interval sleeps between counter snapshots.
"""
import argparse
from bisect import bisect_left
from contextlib import contextmanager
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import re
import shutil
import signal
import socket
import statistics
import struct
import subprocess
import tempfile
import time

from ipc_client import IPCClient, ROOT, spawn_compositor, stop_process
from scene_baseline import thread_snapshot

TICKS = os.sysconf("SC_CLK_TCK")
BIN = ROOT / "zig-out/release-safe/bin"


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def digest(path):
    with path.open("rb") as f:
        return hashlib.file_digest(f, "sha256").hexdigest()


def output_info(ipc, name):
    return next(o for o in ipc.get_outputs() if o["name"] == name and o["enabled"])


def display_mode(output):
    return tuple(output.get(k) for k in ("name", "enabled", "buffer_width", "buffer_height",
                                         "refresh_hz", "scale", "transform", "hdr_active"))


def connector_for(name, *, lit=True):
    matches = [p for p in Path("/sys/class/drm").glob("card*-*")
               if p.name.split("-", 1)[1] == name
               and (p / "status").read_text().strip() == "connected"
               and (not lit or (p / "enabled").read_text().strip() == "enabled")]
    require(len(matches) == 1, f"Expected one connected DRM connector named {name} (lit required: {lit})")
    return matches[0]


def package_meter():
    # Use just the package domain. The MMIO copy and the core/uncore
    # subdomains overlap with it. psys has platform-specific coverage.
    for p in sorted(Path("/sys/class/powercap").glob("intel-rapl:*")):
        if (p / "name").read_text().strip() == "package-0":
            return p
    raise RuntimeError("Intel package-0 RAPL energy counter unavailable")


def cpu_ticks(pid):
    stat = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()
    return int(stat[11]) + int(stat[12])  # utime and stime across all threads


def video_engine(pid, pci):
    # A VA device may have duplicate fds for the same DRM client.
    clients = {}
    for p in Path(f"/proc/{pid}/fdinfo").iterdir():
        try:
            fields = dict(line.split(":\t", 1) for line in p.read_text().splitlines() if ":\t" in line)
        except FileNotFoundError:
            continue
        if fields.get("drm-pdev") != pci or "drm-client-id" not in fields:
            continue
        engines = [int(value.split()[0]) for key, value in fields.items()
                   if re.fullmatch(r"drm-engine-(video|vcs)[0-9]*", key) and value.endswith(" ns")]
        if engines:
            clients[fields["drm-client-id"]] = sum(engines)
    return clients


def demux_clock(clip, seconds):
    """Map the native reader's file offset to DTS. Its packet and frame
    queues are bounded, so sustained demux progress verifies the workload
    without polling the player or tracing Wayland during a sample."""
    packets = json.loads(subprocess.check_output([
        "ffprobe", "-v", "error", "-select_streams", "v:0", "-read_intervals", f"%+{seconds}",
        "-show_packets", "-show_entries", "packet=pos,dts_time", "-of", "json", clip]))["packets"]
    indexed = sorted((int(p["pos"]), float(p["dts_time"])) for p in packets if "pos" in p and "dts_time" in p)
    require(indexed, "Clip has no indexed packet positions")
    offsets, times = zip(*indexed)
    identity = clip.stat()

    def position(pid):
        for fd in Path(f"/proc/{pid}/fd").iterdir():
            try:
                st = fd.stat()
            except FileNotFoundError:
                continue
            if (st.st_dev, st.st_ino) == (identity.st_dev, identity.st_ino):
                data = Path(f"/proc/{pid}/fdinfo/{fd.name}").read_text()
                offset = int(re.search(r"^pos:\s*(\d+)", data, re.M)[1])
                return times[max(0, bisect_left(offsets, offset) - 1)]
        raise RuntimeError("Could not find native demuxer clip fd")
    return position


def snapshot(pid, compositor, meter, pci):
    ticks = list(map(int, Path("/proc/stat").read_text().splitlines()[0].split()[1:9]))
    return {
        "threads": thread_snapshot(pid),
        "engine": video_engine(pid, pci),
        "player": cpu_ticks(pid),
        "compositor": cpu_ticks(compositor),
        "host_busy": sum(ticks) - ticks[3] - ticks[4],
        "energy": int((meter / "energy_uj").read_text()) if meter else None,
        "time": time.monotonic(),
    }


def interval(before, after, energy_range, paused):
    elapsed = after["time"] - before["time"]
    def percent(field):
        return round(100 * (after[field] - before[field]) / (TICKS * elapsed), 3)
    row = {"seconds": round(elapsed, 4), "player_cpu_pct": percent("player"),
           "compositor_cpu_pct": percent("compositor"), "host_busy_cpu_pct": percent("host_busy")}
    if energy_range:
        delta = (after["energy"] - before["energy"]) % energy_range
        require(delta > 0, "Package energy counter did not advance")
        row["package_w"] = round(delta / 1e6 / elapsed, 4)
    if before["engine"]:
        require(before["engine"].keys() == after["engine"].keys(), "DRM decode client changed")
        busy = sum(after["engine"].values()) - sum(before["engine"].values())
        require(busy >= 0 and (paused or busy > 0), "Video engine did not advance during playback")
        row["decode_engine_ms"] = round(busy / 1e6, 3)
    if paused:
        old, new = before["threads"], after["threads"]
        require(old and old.keys() == new.keys(), "Paused player thread set changed during sample")
        row["threads"] = [{"tid": tid, "name": name, "cpu_ns": ns - old[tid][1],
                           "voluntary": vol - old[tid][2], "involuntary": inv - old[tid][3]}
                          for tid, (name, ns, vol, inv) in sorted(new.items())]
        row["context_switches"] = sum(t["voluntary"] + t["involuntary"] for t in row["threads"])
    return row


def peer_pid(sock):
    return struct.unpack("3i", sock.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))[0]


def mpv_state(path):
    with socket.socket(socket.AF_UNIX) as sock:
        sock.settimeout(3)
        sock.connect(str(path))
        result = {}
        with sock.makefile("rb") as reader:
            for name in ("current-vo", "hwdec-current", "pause", "eof-reached", "time-pos",
                         "frame-drop-count", "decoder-frame-drop-count"):
                sock.sendall(json.dumps({"command": ["get_property", name], "request_id": 1}).encode() + b"\n")
                while True:
                    reply = json.loads(reader.readline())
                    if reply.get("request_id") == 1:
                        require(reply.get("error") == "success", f"mpv {name}: {reply}")
                        result[name] = reply["data"]
                        break
        return result


def sleep_alive(proc, seconds):
    time.sleep(seconds)
    require(proc.poll() is None, f"{proc.args[0]} exited during sample ({proc.returncode})")


def wait_window(ipc, proc, app, name):
    until = time.monotonic() + 12
    while time.monotonic() < until:
        require(proc.poll() is None, f"{app} exited at startup ({proc.returncode})")
        owned = next((w for w in ipc.get_windows() if w["pid"] == proc.pid and w["app_id"] == app), None)
        if owned:
            wid = owned["id"]
            state = ipc.get_window_debug(wid)
            if state["outputs"] != [name]:
                if state["fullscreen"]:
                    ipc.fullscreen(wid)
                    ipc.wait_for("window_geometry_settled", window_id=wid)
                ipc.action("move_window_to", {"id": wid, "output": name})
                ipc.wait_for("window_geometry_settled", window_id=wid)
                state = ipc.get_window_debug(wid)
            if not state["fullscreen"]:
                ipc.fullscreen(wid, output=name)
                ipc.wait_for("window_geometry_settled", window_id=wid)
            return wid
        time.sleep(.1)
    raise RuntimeError(f"{app} did not map")


def check_window(ipc, proc, wid, name):
    state = ipc.get_window_debug(wid)
    require(state["pid"] == proc.pid and state["fullscreen"] and not state["minimized"]
            and state["outputs"] == [name], "Benchmark window left the selected fullscreen output")
    require(any(w["id"] == wid and w["is_focused"] for w in ipc.get_windows()),
            "Benchmark window lost focus")
    return output_info(ipc, name)


def measure(args, ipc, name, env, directory, tool, paused, meter, energy_range, pci, compositor):
    addr = directory / "mpv.sock"
    # mpv removes its socket on exit; each sample gets a fresh child.
    if tool == "mpv":
        cmd = [str(args.mpv), "--no-config", "--no-audio", "--hwdec=vaapi", "--vo=dmabuf-wayland",
               f"--vaapi-device={args.render_node}", "--wayland-app-id=rediwm-phase2-mpv",
               "--no-osc", "--osd-level=0", "--no-input-terminal", "--no-terminal",
               f"--input-ipc-server={addr}"]
        app = "rediwm-phase2-mpv"
        if paused:
            cmd.append("--pause")
    else:
        cmd = [str(args.player)]
        app = "rediwm-video"
        if paused:
            cmd.append("--paused")
    cmd.append(str(args.clip))
    log = directory / "player.log"
    with log.open("w") as out:
        proc = subprocess.Popen(cmd, env=env, stdin=subprocess.DEVNULL, stdout=out, stderr=out)
    try:
        wid = wait_window(ipc, proc, app, name)
        sleep_alive(proc, args.warmup)
        start_output = check_window(ipc, proc, wid, name)
        require(display_mode(start_output) == args.expected_mode, "Display mode changed between samples")
        if tool == "mpv" and not paused:
            state = mpv_state(addr)
            require(state["hwdec-current"] == "vaapi" and state["current-vo"] == "dmabuf-wayland"
                    and state["pause"] == paused and not state["eof-reached"], f"Wrong mpv path: {state}")
        if tool == "rediwm-video":
            first_dts = args.read_position(proc.pid)
        before = snapshot(proc.pid, compositor, meter, pci)
        if not args.headless:
            require(before["engine"], f"No video-engine counter on the requested GPU {pci}")
        sleep_alive(proc, args.paused_seconds if paused else args.seconds)
        after = snapshot(proc.pid, compositor, meter, pci)
        end_output = check_window(ipc, proc, wid, name)
        require(start_output == end_output, "Output state changed during sample")
        row = interval(before, after, energy_range, paused)
        row["direct_scanout"] = end_output["direct_scanout"]
        if tool == "rediwm-video":
            advance = args.read_position(proc.pid) - first_dts
            require(abs(advance - (0 if paused else row["seconds"])) < .5, f"Native demux clock drifted: {advance}")
            row["demux_seconds"] = round(advance, 3)
        if tool == "mpv":
            end = mpv_state(addr)
            require(end["hwdec-current"] == "vaapi" and end["current-vo"] == "dmabuf-wayland"
                    and end["pause"] == paused and not end["eof-reached"], f"mpv playback state changed: {end}")
            if paused:
                # Even closing a read-only IPC connection can wake the core
                # and VO. The first contact with a paused child is after the
                # final thread/energy snapshot.
                require(abs(end["time-pos"]) < .1, "mpv did not hold the first picture")
                row["media_position_s"] = end["time-pos"]
            else:
                advance = end["time-pos"] - state["time-pos"]
                require(abs(advance - row["seconds"]) < .35, "mpv media time drifted")
                row["media_seconds"] = round(advance, 3)
                row["vo_drops"] = end["frame-drop-count"] - state["frame-drop-count"]
                row["decoder_drops"] = end["decoder-frame-drop-count"] - state["decoder-frame-drop-count"]
        ipc.close_window(wid)
        require(proc.wait(timeout=5) == 0, f"{app} did not exit cleanly")
        if tool == "rediwm-video":
            messages = log.read_text()
            require("(VAAPI)" in messages and "switching to software" not in messages
                    and "using shm" not in messages, f"Native zero-copy path unavailable: {messages}")
            dropped = re.search(r"dropped (\d+) late video frames", messages)
            require(dropped, "Native player did not report its final frame count")
            row["late_drops_including_warmup"] = int(dropped[1])
        return row
    except Exception:
        print(log.read_text()[-2000:], flush=True)
        raise
    finally:
        if proc.poll() is None:
            stop_process(proc)


@contextmanager
def display_inhibitor(ipc, name):
    """Hold the physical display at its normal brightness for both states.
    Closing the private bus connection releases this handle even on failure."""
    from gi.repository import Gio, GLib

    connector = connector_for(name, lit=False)
    state = next(o for o in ipc.get_outputs() if o["name"] == name)
    if not state["enabled"]:
        require(ipc.query("get_idle_state")["state"] == "blanked", "Selected output was manually disabled")
    address = Gio.dbus_address_get_for_bus_sync(Gio.BusType.SESSION, None)
    flags = Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION
    conn = Gio.DBusConnection.new_for_address_sync(address, flags, None, None)
    try:
        bus = "org.freedesktop.DBus"
        saver = "org.freedesktop.ScreenSaver"
        def call(dest, path, interface, method, params):
            return conn.call_sync(dest, path, interface, method, params, None,
                                  Gio.DBusCallFlags.NO_AUTO_START, 3000, None).unpack()
        owner, = call(bus, "/org/freedesktop/DBus", bus, "GetConnectionUnixProcessID", GLib.Variant("(s)", (saver,)))
        require(owner == peer_pid(ipc.sock), "Screensaver and display have different owners")
        cookie, = call(saver, "/org/freedesktop/ScreenSaver", saver, "Inhibit",
                       GLib.Variant("(ss)", ("Video benchmark", "Measure playing and paused at equal brightness")))
        try:
            until = time.monotonic() + 5
            while (connector / "enabled").read_text().strip() != "enabled" and time.monotonic() < until:
                time.sleep(.2)
            connector_for(name)
            yield
        finally:
            call(saver, "/org/freedesktop/ScreenSaver", saver, "UnInhibit", GLib.Variant("(u)", (cookie,)))
    finally:
        conn.close_sync(None)


@contextmanager
def session(args, directory):
    # Give both clients the same private config/cache and no host audio/bus.
    env = dict(os.environ)
    for key in ("HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME", "XDG_STATE_HOME"):
        env[key] = str(directory / key)
        Path(env[key]).mkdir(mode=0o700)
    env.update(DBUS_SESSION_BUS_ADDRESS="unix:path=/nonexistent-video-bench-bus",
               DBUS_SYSTEM_BUS_ADDRESS="unix:path=/nonexistent-video-bench-bus")
    for key in ("DISPLAY", "WAYLAND_DEBUG", "REDIWM_CONFIG", "REDIWM_THEME", "REDIWM_SOCKET"):
        env.pop(key, None)
    env["WLR_RENDER_DRM_DEVICE"] = str(args.render_node)
    if args.headless:
        env["XDG_RUNTIME_DIR"] = str(directory)
        private = {k: v for k, v in env.items() if k.startswith(("XDG_", "DBUS_")) or k == "HOME"}
        proc, log = spawn_compositor(directory, binary=args.player.with_name("rediwm"),
                                     config_content='[compositor]\nxwayland = false\n[animations]\nenabled = false\n',
                                     env_extra={**private, "WLR_RENDER_DRM_DEVICE": str(args.render_node)})
        try:
            with IPCClient(directory) as ipc:
                env["WAYLAND_DISPLAY"] = next(p.name for p in directory.glob("wayland-*") if p.is_socket())
                yield ipc, "HEADLESS-1", env
        finally:
            stop_process(proc)
            log.close()
    else:
        display = Path(env["XDG_RUNTIME_DIR"]) / env["WAYLAND_DISPLAY"]
        with IPCClient(os.environ["REDIWM_SOCKET"]) as ipc, socket.socket(socket.AF_UNIX) as check:
            check.connect(str(display))
            require(peer_pid(check) == peer_pid(ipc.sock), "IPC and Wayland belong to different compositors")
            with display_inhibitor(ipc, args.live_output):
                output_info(ipc, args.live_output)
                yield ipc, args.live_output, env


def run(args):
    meta = json.loads(subprocess.check_output(["ffprobe", "-v", "error", "-show_streams", "-show_format",
                                              "-of", "json", args.clip]))
    streams = meta["streams"]
    require(len(streams) == 1 and streams[0]["codec_type"] == "video", "Use a video-only clip")
    if args.state != "paused":
        require(float(meta["format"]["duration"]) > args.seconds + args.warmup + 3, "Clip too short")
    node = Path("/sys/class/drm") / args.render_node.name / "device"
    pci = node.resolve(strict=True).name
    meter = None if args.headless else package_meter()
    energy_range = int((meter / "max_energy_range_uj").read_text()) if meter else None
    if meter:
        require(energy_range > 0, "Package energy counter has no usable range")
        int((meter / "energy_uj").read_text())  # fail before mapping a player
    args.read_position = demux_clock(args.clip, args.seconds + args.warmup + 15)
    report = {"backend": "headless" if args.headless else "drm", "utc": datetime.now(timezone.utc).isoformat(),
              "kernel": platform.release(), "render_node": str(args.render_node), "pci": pci,
              "driver": (node / "driver").resolve().name, "player_sha256": digest(args.player),
              "mpv_version": subprocess.check_output([args.mpv, "--version"], text=True).splitlines()[0],
              "clip": {"sha256": digest(args.clip), **{k: streams[0][k] for k in
                       ("codec_name", "profile", "width", "height", "pix_fmt", "avg_frame_rate")}},
              "rounds": args.rounds, "states": args.state, "warmup_seconds": args.warmup, "package_meter": str(meter) if meter else None, "samples": []}
    report["cpu"] = re.search(r"^model name\s*:\s*(.+)", Path("/proc/cpuinfo").read_text(), re.M)[1]
    for key, path in (("ac_online", "/sys/class/power_supply/AC0/online"),
                      ("platform_profile", "/sys/firmware/acpi/platform_profile"),
                      ("governor", "/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor")):
        if Path(path).exists():
            report[key] = Path(path).read_text().strip()
    with tempfile.TemporaryDirectory(prefix="rediwm-video-bench-") as tmp:
        directory = Path(tmp)
        with session(args, directory) as (ipc, name, env):
            compositor = peer_pid(ipc.sock)
            if not args.headless:
                report["backlights"] = {p.name: int((p / "actual_brightness").read_text())
                                        for p in Path("/sys/class/backlight").iterdir()}
            report["compositor_version"] = ipc.query("version")
            report["output"] = output_info(ipc, name)
            args.expected_mode = display_mode(report["output"])
            for rnd in range(args.rounds):
                players = ["rediwm-video", "mpv"] if rnd % 2 == 0 else ["mpv", "rediwm-video"]
                for paused in ([False, True] if rnd % 2 == 0 else [True, False]):
                    if args.state != "both" and args.state != ("paused" if paused else "playing"):
                        continue
                    for tool in players:
                        row = measure(args, ipc, name, env, directory, tool, paused, meter, energy_range, pci, compositor)
                        row.update(round=rnd + 1, player=tool, state="paused" if paused else "playing")
                        report["samples"].append(row)
                        temporary = args.json.with_suffix(args.json.suffix + ".tmp")
                        temporary.write_text(json.dumps(report, indent=2) + "\n")
                        temporary.replace(args.json)
                        print(f"{rnd+1} {tool} {row['state']}: {row['player_cpu_pct']}% player, "
                              f"{row['compositor_cpu_pct']}% compositor, {row.get('package_w', 'n/a')} W, "
                              f"{row.get('context_switches', '-')} paused switches", flush=True)
    for state in ("playing", "paused"):
        for tool in ("rediwm-video", "mpv"):
            rows = [r for r in report["samples"] if r["player"] == tool and r["state"] == state]
            if not rows:
                continue
            fields = ("player_cpu_pct", "compositor_cpu_pct", "package_w", "context_switches")
            print(state, tool, {f: statistics.median(r[f] for r in rows) for f in fields if f in rows[0]})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    backend = parser.add_mutually_exclusive_group(required=True)
    backend.add_argument("--live-output", metavar="DRM_CONNECTOR")
    backend.add_argument("--headless", action="store_true")
    parser.add_argument("--clip", type=Path, required=True)
    parser.add_argument("--json", type=Path, required=True)
    parser.add_argument("--player", type=Path, default=BIN / "rediwm-video")
    parser.add_argument("--render-node", type=Path, default=Path("/dev/dri/renderD128"))
    parser.add_argument("--state", choices=("both", "playing", "paused"), default="both")
    parser.add_argument("--rounds", type=int, default=4)
    parser.add_argument("--seconds", type=float, default=15)
    parser.add_argument("--paused-seconds", type=float, default=8)
    parser.add_argument("--warmup", type=float, default=5)
    args = parser.parse_args()
    args.mpv = shutil.which("mpv")
    if not args.mpv or args.rounds < 1 or not all(math.isfinite(n) and n > 0 for n in
                                                   (args.seconds, args.paused_seconds, args.warmup)):
        parser.error("mpv, a positive round count and positive finite intervals are required")
    args.player = args.player.resolve(strict=True)
    args.clip = args.clip.resolve(strict=True)

    def terminate(_sig, _frame):
        raise SystemExit("Benchmark interrupted")
    signal.signal(signal.SIGTERM, terminate)
    run(args)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""wp_fifo_v1 on a headless GLES2 output (docs/plans/fifo.md).

The fixture (tests/fifo_client.c) sends commits back to back, so only the
compositor's barrier can spread them over refreshes; presentation feedback
shows the outcome. Cases: barriers across two and more commits (with a
no-fifo control that must collapse), an update that only sets a barrier,
synchronized and desynchronized subsurfaces, hidden surfaces (minimized and
covered) released at the 20 Hz fallback, a barrier queued behind an explicit
sync acquire point, destroying the fifo or the surface with commits held,
and both protocol errors; then vkcube (Mesa's Vulkan WSI) shown and
minimized. Explicit sync skips without a render node, GBM or a
timeline-capable renderer; the vkcube case without vkcube or a driver that
uses fifo-v1.
"""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

from desktop_zoom import ROOT, wait_for
from ipc_client import IPCClient, spawn_compositor, stop_process

PROTOCOLS = (
    ("xdg-shell", "stable/xdg-shell/xdg-shell.xml"),
    ("presentation-time", "stable/presentation-time/presentation-time.xml"),
    ("fifo-v1", "staging/fifo/fifo-v1.xml"),
    ("commit-timing-v1", "staging/commit-timing/commit-timing-v1.xml"),
    ("linux-dmabuf-v1", "stable/linux-dmabuf/linux-dmabuf-v1.xml"),
    ("linux-drm-syncobj-v1", "staging/linux-drm-syncobj/linux-drm-syncobj-v1.xml"),
)
HIDDEN_PERIOD = 0.050


def render_node():
    return next((str(p) for p in sorted(Path("/dev/dri").glob("renderD*"))), None)


def build_client(tmp):
    protocols = Path(subprocess.check_output(
        ["pkg-config", "--variable=pkgdatadir", "wayland-protocols"], text=True).strip())
    sources = []
    for name, path in PROTOCOLS:
        for mode, suffix in (("client-header", "client-protocol.h"), ("private-code", "protocol.c")):
            subprocess.run(["wayland-scanner", mode, str(protocols / path),
                            str(tmp / f"{name}-{suffix}")], check=True)
        sources.append(str(tmp / f"{name}-protocol.c"))
    flags = subprocess.check_output(["pkg-config", "--cflags", "--libs", "libdrm", "gbm"], text=True).split()
    subprocess.run(["cc", "-Wall", "-Wextra", "-Werror", f"-I{tmp}", str(ROOT / "tests/fifo_client.c"),
                    *sources, *flags, "-lwayland-client", "-o", str(tmp / "client")], check=True)


def parse(lines):
    presented, discarded, other = {}, [], []
    for line in lines:
        fields = line.split()
        if fields[0] == "presented":
            presented[fields[1]] = (int(fields[2]), int(fields[3]))
        elif fields[0] == "discarded":
            discarded.append(fields[1])
        else:
            other.append(line)
    return presented, discarded, other


def assert_paced(presented, labels, period_ns):
    """Every update reached its own refresh, in order."""
    missing = [label for label in labels if label not in presented]
    assert not missing, f"not presented: {missing} ({presented})"
    # Headless reports no refresh counter (seq 0): judge by presentation time.
    times = [presented[label][1] for label in labels]
    gaps = [b - a for a, b in zip(times, times[1:])]
    assert all(gap >= period_ns // 2 for gap in gaps), f"two updates shared a refresh: gaps {gaps} ns"


def vkcube_case(tmp, env, ipc, refresh_hz):
    """Mesa's Vulkan WSI in FIFO mode: paced by barriers alone (it asks for
    no frame callbacks once fifo-v1 is offered), 20 Hz while minimized."""
    if not shutil.which("vkcube"):
        print("SKIP: vkcube (not installed)")
        return
    log_path = tmp / "vkcube.log"
    with log_path.open("w") as output:
        vk = subprocess.Popen(["vkcube", "--wsi", "wayland"], env=dict(env, WAYLAND_DEBUG="1"),
                              stdout=subprocess.DEVNULL, stderr=output)
    try:
        def submissions():
            # Mesa can send a second barrier-only commit for the same image
            # when commit timing is advertised.
            return log_path.read_text(errors="replace").count(".attach(wl_buffer")

        def rate(seconds):
            start, began = submissions(), time.monotonic()
            time.sleep(seconds)
            return (submissions() - start) / (time.monotonic() - began)

        win = wait_for(lambda: next((w for w in ipc.get_windows() if w["app_id"] != "rediwm.fifo-fixture"), None),
                       "vkcube did not map", timeout=30)
        time.sleep(0.5)
        if ".wait_barrier(" not in log_path.read_text(errors="replace"):
            print("SKIP: vkcube's Vulkan driver does not use wp_fifo_v1")
            return
        ipc.reset_perf()
        shown = rate(2.0)
        stats = dict(ipc.get_perf().get("fifo") or {})
        assert 0.8 * refresh_hz <= shown <= 1.1 * refresh_hz, (shown, refresh_hz)
        assert stats["late"] == 0 and stats["latched"] > 0, stats
        ipc.minimize(win["id"])
        wait_for(lambda: ipc.get_window_debug(win["id"])["minimized"], "vkcube did not minimize")
        time.sleep(0.5)
        hidden = rate(2.0)
        assert 0.6 / HIDDEN_PERIOD <= hidden <= 1.2 / HIDDEN_PERIOD, hidden
        ipc.restore(win["id"])
        time.sleep(1.0)
        restored = rate(1.0)
        assert restored >= 0.8 * refresh_hz, restored
        text = log_path.read_text(errors="replace")
        frames = text.count(".frame(new id")
        print(f"fifo: vkcube {shown:.0f}/s shown, {hidden:.1f}/s minimized, {restored:.0f}/s restored "
              f"({frames} frame callbacks requested)")
    finally:
        vk.terminate()
        vk.wait(timeout=10)


def run():
    node = render_node()
    with tempfile.TemporaryDirectory(prefix="rediwm-fifo-") as directory:
        tmp = Path(directory)
        build_client(tmp)
        extra = {"XDG_CACHE_HOME": str(tmp / "cache")}
        if node:
            extra["WLR_RENDER_DRM_DEVICE"] = node
        compositor, log = spawn_compositor(
            tmp, renderer=os.environ.get("REDIWM_TEST_RENDERER", "gles2"),
            config_content="[compositor]\nxwayland = false\nscroll_column_width = 1.0\n", env_extra=extra)
        client = None
        client_log = tmp / "client.log"
        try:
            socket_path = wait_for(lambda: next(tmp.glob("rediwm-*.sock"), None), "IPC unavailable")
            display = next(p.name for p in tmp.glob("wayland-*") if not p.name.endswith(".lock"))
            env = dict(os.environ, XDG_RUNTIME_DIR=str(tmp), WAYLAND_DISPLAY=display)
            if node:
                env["FIFO_RENDER_NODE"] = node
            with client_log.open("w") as output:
                client = subprocess.Popen([str(tmp / "client")], stdin=subprocess.PIPE, stdout=output,
                                          stderr=output, text=True, env=env)
            done_count = 1
            wait_for(lambda: client_log.read_text().splitlines().count("done") >= 1, "fixture did not start")
            ready = next(l for l in client_log.read_text().splitlines() if l.startswith("ready")).split()
            has_dmabuf, has_syncobj = ready[1] == "1", ready[2] == "1"

            def command(value, timeout=20):
                nonlocal done_count
                start = len(client_log.read_text().splitlines())
                client.stdin.write(value + "\n")
                client.stdin.flush()
                done_count += 1
                wait_for(lambda: client_log.read_text().splitlines().count("done") >= done_count,
                         f"fixture did not finish {value!r}", timeout=timeout)
                lines = [l for l in client_log.read_text().splitlines()[start:] if l != "done"]
                assert not any(l.startswith(("pending", "timeout", "unknown", "display error"))
                               for l in lines), (value, lines)
                return lines

            with IPCClient(socket_path) as ipc:
                win = wait_for(lambda: next((w for w in ipc.get_windows()
                                             if w["app_id"] == "rediwm.fifo-fixture"), None), "fixture did not map")
                output = ipc.get_outputs()[0]
                refresh_hz = output.get("refresh") or 60
                if refresh_hz > 1000:
                    refresh_hz /= 1000
                period_ns = int(1e9 / refresh_hz)
                ipc.action("move_window_to", {"id": win["id"], "x": 200, "y": 200})
                ipc.wait_for("window_geometry_settled", window_id=win["id"])

                def fifo_stats():
                    return dict(ipc.get_perf().get("fifo") or {})

                presented, discarded, other = parse(command("timing"))
                first, second = map(int, next(line for line in other if line.startswith("targets ")).split()[1:])
                assert not discarded and first <= presented["first"][1] < second, (presented, discarded)
                assert second <= presented["second"][1] < presented["untimed"][1], presented
                presented, discarded, other = parse(command("timing-sub"))
                target = int(next(line for line in other if line.startswith("target ")).split()[1])
                assert not discarded and presented["parent"][1] == presented["child"][1] >= target, presented
                assert "survivor" in presented, presented
                print("commit timing: ordered timestamps, timer lifetime, FIFO and atomic subsurface presentation")

                # Control: without barriers a burst collapses into one refresh.
                presented, discarded, _ = parse(command("plain 6"))
                assert discarded, f"control burst was not collapsed: {presented}"

                # Barriers across commits: each update gets its own refresh.
                before = fifo_stats()
                presented, discarded, _ = parse(command("burst 8"))
                assert not discarded, discarded
                assert_paced(presented, [f"b{i}" for i in range(8)], period_ns)
                after = fifo_stats()
                assert after["held"] - before["held"] >= 7, (before, after)
                assert after["late"] == before["late"], f"latches missed: {before} -> {after}"
                assert after["hidden"] == before["hidden"], (before, after)
                print(f"fifo: 8 back-to-back commits on 8 refreshes ({refresh_hz:g} Hz)")

                # An update that changes nothing still gets a latch (vblank).
                before = fifo_stats()
                lines = command("empty")
                presented, _, other = parse(lines)
                assert "e" in presented, lines
                latency = float(next(l for l in other if l.startswith("latency_ms")).split()[1])
                after = fifo_stats()
                assert after["late"] == before["late"], f"empty barrier fell back: {before} -> {after}"
                assert after["latched"] > before["latched"], (before, after)
                assert latency < 4 * period_ns / 1e6, latency
                print(f"fifo: barrier-only update latched by the vblank ({latency:.1f} ms)")

                # Synchronized subsurfaces ignore wait_barrier; desynchronized do not.
                presented, discarded, _ = parse(command("sub 6 sync"))
                assert discarded, f"a synchronized subsurface was held: {presented}"
                presented, discarded, _ = parse(command("sub 6 desync"))
                assert not discarded, discarded
                assert_paced(presented, [f"s{i}" for i in range(6)], period_ns)
                print("fifo: synchronized subsurface exempt, desynchronized paced")

                # Hidden surfaces: released at the 20 Hz fallback, never stuck.
                def hidden_case(label, updates=10):
                    ipc.reset_perf()
                    started = time.monotonic()
                    command(f"send {updates + 1}")
                    wait_for(lambda: fifo_stats().get("hidden", 0) >= updates,
                             f"{label}: hidden updates were not released", timeout=10)
                    elapsed = time.monotonic() - started
                    stats = fifo_stats()
                    assert updates * HIDDEN_PERIOD * 0.8 <= elapsed <= updates * HIDDEN_PERIOD * 4, (label, elapsed, stats)
                    assert stats["late"] == 0, (label, stats)
                    print(f"fifo: {label} surface released {updates} updates in {elapsed:.2f} s")

                ipc.minimize(win["id"])
                wait_for(lambda: ipc.get_window_debug(win["id"])["minimized"], "fixture did not minimize")
                time.sleep(0.2)
                hidden_case("minimized")
                ipc.restore(win["id"])
                ipc.wait_for("window_geometry_settled", window_id=win["id"])
                presented, discarded, _ = parse(command("burst 3"))
                assert_paced(presented, ["b0", "b1", "b2"], period_ns)

                command("cover")
                cover = wait_for(lambda: next((w for w in ipc.get_windows()
                                               if w["app_id"] == "rediwm.fifo-cover"), None), "cover did not map")
                ipc.action("move_window_to", {"id": cover["id"], "x": 60, "y": 60})
                ipc.focus_window(cover["id"])
                ipc.wait_for("window_geometry_settled", window_id=cover["id"])
                time.sleep(0.2)
                hidden_case("covered")
                # A window on the active strip leaves its frame-pacing output
                # when scrolled away, then resumes at refresh rate on reveal.
                ipc.action("set_desktop_mode", {"mode": "scrolling", "persist": False})
                ipc.focus_window(cover["id"])
                wait_for(lambda: ipc.get_workspaces()[0]["view"] > 0, "focus scrolls to the cover")
                ipc.wait_for("window_geometry_settled", window_id=cover["id"])
                assert not ipc.get_window_debug(win["id"])["outputs"]
                hidden_case("scrolled off-screen", updates=40)
                ipc.focus_window(win["id"])
                ipc.wait_for("window_geometry_settled", window_id=win["id"])
                presented, discarded, _ = parse(command("burst 3"))
                assert_paced(presented, ["b0", "b1", "b2"], period_ns)
                ipc.action("set_desktop_mode", {"mode": "canvas", "persist": False})
                command("uncover")
                presented, discarded, _ = parse(command("burst 3"))
                assert_paced(presented, ["b0", "b1", "b2"], period_ns)

                # Explicit sync: a barrier still waiting on its acquire point.
                if has_dmabuf and has_syncobj and node:
                    lines = command("explicit-sync")
                    presented, discarded, other = parse(lines)
                    assert "unresolved-before-signal 1" in other, lines
                    assert not discarded, lines
                    gap = presented["es2"][1] - presented["es1"][1]
                    assert gap >= period_ns // 2, f"es1 and es2 shared a refresh ({gap} ns): {lines}"
                    print("fifo: barrier queued behind an acquire point was waited for")
                else:
                    print("SKIP: explicit sync (no dmabuf/syncobj or render node)")

                # Destroying the fifo releases held updates; the last one shows.
                presented, discarded, _ = parse(command("destroy-fifo 6"))
                assert "d5" in presented, (presented, discarded)
                # Destroying the surface with updates held drops them safely.
                before = fifo_stats()
                assert "survived" in command("destroy-surface 6")
                after = fifo_stats()
                assert after["held"] - before["held"] >= 4, f"nothing was held at destroy: {before} -> {after}"
                presented, _, _ = parse(command("burst 3"))
                assert_paced(presented, ["b0", "b1", "b2"], period_ns)
                assert ipc.get_windows() is not None
                print("fifo: destroying the fifo or its surface with updates held")

                vkcube_case(tmp, env, ipc, refresh_hz)

            for mode, expected in (("already-exists", "error wp_fifo_manager_v1 0"),
                                   ("surface-destroyed", "error wp_fifo_v1 0"),
                                   ("recreate", "error none 0"),
                                   ("timing-duplicate", "error wp_commit_timing_manager_v1 0"),
                                   ("timing-nsec", "error wp_commit_timer_v1 0"),
                                   ("timing-pending", "error wp_commit_timer_v1 1"),
                                   ("timing-orphan", "error wp_commit_timer_v1 2")):
                result = subprocess.run([str(tmp / "client"), mode], env=env, capture_output=True,
                                        text=True, timeout=10)
                assert result.returncode == 0 and expected in result.stdout, (mode, result.stdout, result.stderr)
            print("fifo: protocol errors")

            client.stdin.close()
            client.wait(timeout=5)
            assert client.returncode == 0, client_log.read_text()
            assert compositor.poll() is None, "compositor exited"
        except Exception:
            print((tmp / "compositor.log").read_text()[-6000:])
            if client_log.exists():
                print(client_log.read_text()[-4000:])
            raise
        finally:
            if client and client.poll() is None:
                stop_process(client)
            if compositor.poll() is None:
                stop_process(compositor)
            log.close()
    print("fifo checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(run())

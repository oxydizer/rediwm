"""Check the first GTK/X11 click across a scrolling workspace's output edge."""
from contextlib import contextmanager
import os
from pathlib import Path
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time

from desktop_zoom import build_client, wait_for
from scrolling import Session, MOTION_OFF


@contextmanager
def pause_xserver(s, display):
    """Delay both X transports. The wrapper recorded the PID before exec."""
    # RediWM's geometry can settle before GTK handles its X ConfigureNotify.
    # Stopping X in the middle of that exchange can strand wlroots' regular
    # synchronous PropertyNotify reader before the pointer test even starts.
    for name, child in s.clients.items():
        path = s.tmp / (name + ".log")
        window = next((w for w in s.ipc.get_windows()
                       if w["pid"] == child.pid and w["backend"] == "xwayland"), None)
        if not window or window["is_minimized"]:
            continue
        wid = window["id"]
        box = s.ipc.get_window_debug(wid)["client_box"]
        configure = "configure " + " ".join(str(box[k]) for k in ("x", "y", "width", "height"))
        def latest_configure():
            return next((line for line in reversed(path.read_text().splitlines())
                         if line.startswith("configure ")), None)
        wait_for(lambda: latest_configure() == configure, name + " accepted its X11 geometry")
        title = f"{name} {time.monotonic_ns()}"
        child.stdin.write(f"xwm-barrier {title}\n")
        child.stdin.flush()
        wait_for(lambda: s.window(wid)["title"] == title, name + " XWM property barrier")
    pid_text, name = (s.tmp / "xserver.pid").read_text().split()
    assert name == display and s.process.poll() is None
    pid = int(pid_text)
    timeout = s.ipc.sock.gettimeout()
    try:
        os.kill(pid, signal.SIGSTOP)
        # A compositor blocked waiting on X would freeze even a local IPC request.
        s.ipc.sock.settimeout(2)
        yield
    finally:
        os.kill(pid, signal.SIGCONT)
        s.ipc.sock.settimeout(timeout)


def check_delayed_crossings(s, display, strip, resident, crossing, witness, crossing_log, witness_log):
    ipc = s.ipc
    seam = max(strip["x"], resident["x"])
    direction = 1 if strip["x"] == seam else -1
    # A float overlapping the shared edge keeps its geometry on focus.
    ipc.action("move_window_to", {"id": crossing, "x": seam - 150, "y": 220})
    s.settle_all()
    paths = {crossing: crossing_log, witness: witness_log}

    def buttons(wid):
        return [line for line in paths[wid].read_text().splitlines() if line.startswith(("button ", "release "))]

    wait_for(lambda: buttons(witness)[-1].startswith("release "), "previous click released")
    expected = {wid: buttons(wid) for wid in paths}

    def tap(wid, offset, y):
        out = strip if wid == crossing else resident
        x = seam + (direction if wid == crossing else -direction) * offset
        box = ipc.get_window_debug(wid)["client_box"]
        assert ipc.hit_test(x - out["x"], y, output=out["name"])["window_id"] == wid
        ipc.move_cursor(x - out["x"], y, output=out["name"])
        ipc.pointer_button(272, True)
        ipc.pointer_button(272, False)
        local = f'1 {x - box["x"]} {y - box["y"]}'
        return ["button " + local, "release " + local]

    with pause_xserver(s, display):
        for index, wid in enumerate((crossing, witness, crossing, witness)):
            expected[wid].extend(tap(wid, 28 + index, 410 + index))
        assert ipc.get_input_state()["held_buttons"] == []
    for wid in paths:
        try:
            wait_for(lambda: buttons(wid) == expected[wid], "queued GTK clicks")
        except AssertionError:
            actual = {id: buttons(id) for id in paths}
            raise AssertionError(("queued GTK clicks", expected, actual, ipc.get_input_state())) from None

    # Move on to a native surface before the queued X tap can be sent.
    # Both its first tap and a subsequent click with no motion belong here.
    ipc.move_cursor(600, 400, output=strip["name"])
    native_log = s.tmp / "native.log"
    with native_log.open("w") as log:
        native = s.launch("native-after-X", stdout=log)
    ipc.action("move_window_to", {"id": native, "x": strip["x"] + 520, "y": 200})
    s.settle_all()
    native_box = ipc.get_window_debug(native)["client_box"]
    nx, ny = native_box["x"] + 65 - strip["x"], native_box["y"] + 65
    ipc.move_cursor(seam - direction * 32 - resident["x"], 417, output=resident["name"])
    wait_for(lambda: ipc.get_input_state()["pointer_focused_window_id"] == witness, "resident hover")
    with pause_xserver(s, display):
        expected[crossing].extend(tap(crossing, 36, 419))
        ipc.move_cursor(nx, ny, output=strip["name"])
        ipc.pointer_button(272, True)
        ipc.pointer_button(272, False)
    wait_for(lambda: buttons(crossing) == expected[crossing], "X tap before native enter")
    wait_for(lambda: native_log.read_text().splitlines().count("button 272 0") == 1, "first native tap")
    assert ipc.get_input_state()["pointer_focused_window_id"] == native
    ipc.click()
    wait_for(lambda: native_log.read_text().splitlines().count("button 272 0") == 2, "stationary native click")
    ipc.move_cursor(seam - direction * 32 - resident["x"], 417, output=resident["name"])
    wait_for(lambda: ipc.get_input_state()["pointer_focused_window_id"] == witness, "resident hover restored")

    # Before X can process the next handoff, its target disappears. The
    # cancelled click must never land on the client uncovered by minimizing.
    with pause_xserver(s, display):
        tap(crossing, 37, 421)
        ipc.minimize(crossing)
        assert s.window(crossing)["is_minimized"]
    expected[witness].extend(tap(witness, 42, 423))
    wait_for(lambda: buttons(witness) == expected[witness], "click after pending X target disappeared")
    assert buttons(crossing) == expected[crossing], (buttons(crossing), expected[crossing])
    assert ipc.get_input_state()["held_buttons"] == []

    # The native press and release must finish even if X never acknowledges
    # the preceding tap. Only read the client's log after sending the release.
    ipc.restore(crossing)
    s.settle_all()
    ipc.move_cursor(seam - direction * 32 - resident["x"], 417, output=resident["name"])
    wait_for(lambda: ipc.get_input_state()["pointer_focused_window_id"] == witness, "resident hover before stall")
    with pause_xserver(s, display):
        tap(crossing, 39, 420)
        ipc.move_cursor(nx, ny, output=strip["name"])
        ipc.pointer_button(272, True)
        ipc.pointer_button(272, False)
        wait_for(lambda: native_log.read_text().splitlines().count("button 272 0") == 3,
                 "native tap waited for stalled Xwayland", timeout=2)


def check_edge(strip_left):
    with tempfile.TemporaryDirectory(prefix="rediwm-strip-x11-") as directory:
        tmp = Path(directory)
        build_client(tmp)
        strip_name = "HEADLESS-1" if strip_left else "HEADLESS-2"
        cfg = f"""[compositor]
desktop_mode = "scrolling"
xwayland = true
scroll_column_width = 0.8
window_gap = 8
[[outputs]]
name = "HEADLESS-1"
x = 0
y = 0
[[outputs]]
name = "HEADLESS-2"
x = 1280
y = 0
[[window_rules]]
title = "Background map"
output = "{strip_name}"
focus = false
""" + MOTION_OFF
        runner = tmp / "run-xwayland"
        binary = shutil.which("Xwayland")
        assert binary, "Xwayland is required"
        runner.write_text('#!/bin/sh\nprintf "%s %s\\n" "$$" "$1" > "$XDG_RUNTIME_DIR/xserver.pid"\n'
                          f'exec {shlex.quote(binary)} "$@"\n')
        runner.chmod(0o700)
        s = Session(tmp, cfg, outputs=2, scale="1", env_extra={"WLR_XWAYLAND": str(runner)})
        try:
            ipc = s.ipc
            strip, resident = sorted(ipc.get_outputs(), key=lambda out: out["name"] != strip_name)
            env = {**s.env, "DISPLAY": ipc.query("get_runtime_info")["xwayland_display"],
                   "GDK_BACKEND": "x11", "GDK_SCALE": "1", "HOME": str(tmp),
                   "XDG_CONFIG_HOME": str(tmp / "config"), "XDG_CACHE_HOME": str(tmp / "cache"),
                   "XDG_DATA_HOME": str(tmp / "data"), "DBUS_SESSION_BUS_ADDRESS": "unix:path=/nonexistent",
                   "REDIWM_TEST_POINTER_LOG": "1"}
            env.pop("WAYLAND_DISPLAY", None)

            def launch_gtk(title):
                path = tmp / (title + ".log")
                with path.open("w") as log:
                    proc = subprocess.Popen([sys.executable, str(Path(__file__).with_name("xwayland_gtk_client.py"))],
                        env={**env, "REDIWM_TEST_TITLE": title}, stdin=subprocess.PIPE, stdout=log, stderr=log, text=True)
                s.clients[title] = proc
                wid = wait_for(lambda: next((w["id"] for w in ipc.get_windows() if w["pid"] == proc.pid), None), title)
                assert s.window(wid)["backend"] == "xwayland"
                return wid, path

            ipc.move_cursor(180, 180, output=resident["name"])
            witness, witness_log = launch_gtk("Seam resident")
            s.chord("w")
            wait_for(lambda: s.frame(witness)[2] > resident["logical_width"] * .9, "full-width X11 client")
            ipc.move_cursor(180, 180, output=strip_name)
            # On the left strip show the first column; its next column hangs
            # to the right. On the right strip show the last column instead.
            if strip_left:
                anchor = s.launch("anchor")
            crossing, crossing_log = launch_gtk("Overhanging tile")
            wait_for(lambda: s.frame(crossing)[2] > strip["logical_width"] * .7, "X11 tile configure")
            if strip_left:
                ipc.focus_window(anchor)
            else:
                s.launch("anchor")
            s.settle_all()
            seam = max(strip["x"], resident["x"])
            dx = 48 if strip_left else -48
            x, y = seam + dx, 500
            def client_box(wid):
                return ipc.get_window_debug(wid)["client_box"]
            for wid in (witness, crossing):
                b = client_box(wid)
                assert b["x"] <= x < b["x"] + b["width"] and b["y"] <= y < b["y"] + b["height"], (wid, b)
            # Approach from the crossing tile on its own monitor. The very
            # first click after the warp must arrive with the correct local
            # coordinates, even when the previous X window covered this point.
            ipc.move_cursor(seam - dx - strip["x"], y, output=strip_name)
            ipc.click_at(x - resident["x"], y, output=resident["name"])
            box = client_box(witness)
            local = f'{x - box["x"]} {y - box["y"]}'
            pressed = "button 1 " + local
            wait_for(lambda: pressed in witness_log.read_text().splitlines(), "first click on resident at " + local)
            assert "enter " + local in witness_log.read_text().splitlines()
            assert not any(line.startswith("button ") for line in crossing_log.read_text().splitlines())

            # A background X11 window mapping on the other monitor cannot
            # steal hover/click from the stationary pointer.
            before = ipc.get_input_state()
            background, _ = launch_gtk("Background map")
            s.settle_all()
            assert s.window(background)["workspace_id"] == s.window(crossing)["workspace_id"]
            after = ipc.get_input_state()
            assert (before["pointer_x"], before["pointer_y"]) == (after["pointer_x"], after["pointer_y"])
            ipc.click()
            wait_for(lambda: witness_log.read_text().splitlines().count(pressed) == 2, "stationary X11 click")
            if not strip_left:
                check_delayed_crossings(s, env["DISPLAY"], strip, resident, crossing, witness,
                                        crossing_log, witness_log)
        finally:
            s.stop()


def x11_strip_clicks():
    check_edge(False)
    check_edge(True)
    print("PASS: GTK/X11 first clicks, queued crossings and disappearing targets at scrolling output edges")

#!/usr/bin/env python3
"""session/layout_autosave.zig: periodic autosave and startup restore.

Isolated XDG_STATE_HOME per run; never touches the host's real
~/.local/state/rediwm/autosave-layout.toml. Uses the existing zoom_client.c
fixture (desktop_zoom.py's build_client) as a real toplevel with a stable
app_id to move and match against.
"""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
from ipc_client import IPCClient, spawn_compositor, stop_process
from desktop_zoom import build_client
from xwayland import wayland_display_name

APP_ID = "rediwm.zoom-fixture"
SAVED_X = 321
SAVED_Y = 87
MOVED_X = 500
MOVED_Y = 260
# One step below 100%: restoring the index must not re-anchor the frame at
# the startup cursor (setZoom would, setZoomOrigin does not).
SAVED_ZOOM_PERCENT = 85


def wait_for(check, message, timeout=15):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = check()
        if result:
            return result
        time.sleep(0.05)
    raise AssertionError(message)


def launch_client(tmp, client_bin):
    display = wayland_display_name(tmp)
    log = (tmp / f"client-{time.monotonic_ns()}.log").open("w")
    proc = subprocess.Popen(
        [str(client_bin)],
        env={**os.environ, "XDG_RUNTIME_DIR": str(tmp), "WAYLAND_DISPLAY": display},
        stdout=log, stderr=log,
    )
    return proc, log


def stop_client(client, log):
    if client is not None:
        client.terminate()
        client.wait(timeout=5)
    log.close()


def fixture_window(ipc):
    return next((w for w in ipc.get_windows() if w["app_id"] == APP_ID), None)


def run():
    with tempfile.TemporaryDirectory(prefix="rediwm-autosave-test-") as directory:
        tmp = Path(directory)
        client_bin = tmp / "client"
        build_client(tmp)
        state_dir = tmp / "state"
        autosave_path = state_dir / "rediwm" / "autosave-layout.toml"
        # Two separate runtime dirs (each its own Wayland/IPC socket
        # namespace) sharing one XDG_STATE_HOME, standing in for two
        # consecutive logins/restarts on the same real machine.
        run1 = tmp / "run1"
        run2 = tmp / "run2"
        run1.mkdir()
        run2.mkdir()

        # Phase 1: move the fixture, wait for the periodic autosave to record it.
        process, log = spawn_compositor(run1, env_extra={"XDG_STATE_HOME": str(state_dir)})
        client = client_log = None
        try:
            with IPCClient(run1, timeout=15) as ipc:
                ipc.wait_for("wallpaper_presented", timeout_ms=10000)
                client, client_log = launch_client(run1, client_bin)
                win = wait_for(lambda: fixture_window(ipc), "fixture did not map")
                assert (win["x"], win["y"]) != (SAVED_X, SAVED_Y), "fixture spawned at the position under test"
                ipc.action('set_window_zoom', {"id": win["id"], "percent": SAVED_ZOOM_PERCENT})
                ipc.action('move_window_to', {"id": win["id"], "x": SAVED_X, "y": SAVED_Y})
                wait_for(lambda: autosave_path.exists(), "periodic autosave did not run", timeout=15)
                content = autosave_path.read_text()
                assert f'x = {SAVED_X}' in content and f'y = {SAVED_Y}' in content and APP_ID in content, content
                assert 'zoom_index = 1' in content, content
        finally:
            stop_client(client, client_log)
            stop_process(process)
            log.close()
        print("layout autosave: periodic save records the moved window's position")

        # Phase 2: fresh compositor and fixture, same state dir: restore on startup.
        started = time.monotonic()
        process, log = spawn_compositor(run2, env_extra={"XDG_STATE_HOME": str(state_dir)})
        client = client_log = None
        try:
            with IPCClient(run2, timeout=15) as ipc:
                ipc.wait_for("wallpaper_presented", timeout_ms=10000)
                client, client_log = launch_client(run2, client_bin)
                win = wait_for(lambda: fixture_window(ipc), "fixture did not map (phase 2)")
                # A matching window is placed on its first commit, not by a
                # timed attempt: if that path regresses nothing restores it.
                wait_for(
                    lambda: (lambda w: w is not None and (w["x"], w["y"]) == (SAVED_X, SAVED_Y) and
                             w["zoom_percent"] == SAVED_ZOOM_PERCENT)(fixture_window(ipc)),
                    "startup restore did not place the fixture at its saved position and zoom",
                    timeout=15,
                )
                print("layout autosave: startup restore places a matching window at its saved position and zoom")
                # A window moved after the restore has to stay where the user
                # put it. The periodic save rewrites the file every 10 s and
                # the timed attempts run at about 2, 7, 17 and 37 s; moving it
                # between them used to let a retry put it back.
                time.sleep(max(0.0, started + 13.5 - time.monotonic()))
                ipc.action('move_window_to', {"id": win["id"], "x": MOVED_X, "y": MOVED_Y})
                time.sleep(max(0.0, started + 23.0 - time.monotonic()))
                win = fixture_window(ipc)
                assert (win["x"], win["y"]) == (MOVED_X, MOVED_Y), ("a later restore attempt moved the window back", win["x"], win["y"])
                assert win["zoom_percent"] == SAVED_ZOOM_PERCENT, win
        finally:
            stop_client(client, client_log)
            stop_process(process)
            log.close()
        print("layout autosave: a window moved after the restore is not put back by later attempts")


if __name__ == "__main__":
    run()

#!/usr/bin/env python3
"""Integration tests for ext-idle-notify-v1, idle-inhibit-v1, and display blanking/wake."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

from desktop_zoom import ROOT, wait_for
from ipc_client import IPCClient, spawn_compositor, stop_process


def build_client(tmp):
    protocol_dir = Path(subprocess.check_output(
        ["pkg-config", "--variable=pkgdatadir", "wayland-protocols"], text=True).strip())
    sources = []
    for name, path in (
        ("xdg-shell", "stable/xdg-shell/xdg-shell.xml"),
        ("ext-idle-notify-v1", "staging/ext-idle-notify/ext-idle-notify-v1.xml"),
        ("idle-inhibit-unstable-v1", "unstable/idle-inhibit/idle-inhibit-unstable-v1.xml"),
    ):
        for mode, suffix in (("client-header", "client-protocol.h"), ("private-code", "protocol.c")):
            subprocess.run(["wayland-scanner", mode, str(protocol_dir / path),
                            str(tmp / f"{name}-{suffix}")], check=True)
        sources.append(str(tmp / f"{name}-protocol.c"))
    subprocess.run(["cc", "-Wall", "-Wextra", "-Werror", f"-I{tmp}",
                    str(ROOT / "tests/idle_client.c"), *sources,
                    "-lwayland-client", "-o", str(tmp / "client")], check=True)


def get_idle_state(ipc):
    return ipc.request(query="get_idle_state")


def set_idle_config(ipc, enabled=None, blank_after_seconds=None, suspend_after_seconds=None):
    params = {}
    if enabled is not None:
        params["enabled"] = enabled
    if blank_after_seconds is not None:
        params["blank_after_seconds"] = blank_after_seconds
    if suspend_after_seconds is not None:
        params["suspend_after_seconds"] = suspend_after_seconds
    return ipc.action("set_idle_config", params)


def advance_idle_time(ipc, seconds):
    return ipc.action("advance_idle_time", {"seconds": seconds})


def run():
    scale = float(os.environ.get("REDIWM_TEST_SCALE", "1"))
    renderer = os.environ.get("REDIWM_TEST_RENDERER", "pixman")
    with tempfile.TemporaryDirectory(prefix="rediwm-idle-") as directory:
        tmp = Path(directory)
        build_client(tmp)
        compositor, log = spawn_compositor(
            tmp, scale=str(scale), renderer=renderer,
            config_content="[compositor]\nxwayland = false\n\n[idle]\nenabled = true\nblank_after_seconds = 600\nsuspend_after_seconds = 0\n",
            env_extra={"XDG_CACHE_HOME": str(tmp / "cache"), "WLR_RENDERER_ALLOW_SOFTWARE": "1"})
        client = None
        client_log = tmp / "client.log"
        try:
            socket_path = wait_for(lambda: next(tmp.glob("rediwm-*.sock"), None), "IPC unavailable")
            display = next(p.name for p in tmp.glob("wayland-*") if not p.name.endswith(".lock"))
            with client_log.open("w") as output:
                client = subprocess.Popen([str(tmp / "client")], stdin=subprocess.PIPE,
                                          stdout=output, stderr=output, text=True,
                                          env=dict(os.environ, XDG_RUNTIME_DIR=str(tmp), WAYLAND_DISPLAY=display))
            with IPCClient(socket_path) as ipc:
                win = wait_for(lambda: next((w for w in ipc.get_windows()
                                             if w["app_id"] == "rediwm.idle-fixture"), None),
                               "idle fixture toplevel did not map")
                wait_for(lambda: "ready\n" in client_log.read_text(), "client not ready")

                def send(cmd):
                    client.stdin.write(cmd + "\n")
                    client.stdin.flush()

                # 1. Inspect initial idle state
                state = get_idle_state(ipc)
                assert state["enabled"] is True, state
                assert state["state"] == "active", state
                assert state["blank_after_seconds"] == 600, state
                assert state["is_inhibited"] is False, state
                assert state["inhibitor_count"] == 0, state

                # 2. Test Wayland idle inhibitor lifecycle
                send("inhibit")
                wait_for(lambda: "inhibited\n" in client_log.read_text(), "inhibit confirmation missing")

                state = wait_for(lambda: get_idle_state(ipc) if get_idle_state(ipc)["is_inhibited"] else None,
                                 "inhibitor not active in IPC")
                assert state["inhibitor_count"] == 1, state
                assert len(state["inhibitors"]) == 1, state
                inh = state["inhibitors"][0]
                assert inh["app_id"] == "rediwm.idle-fixture", inh
                assert inh["is_active"] is True, inh

                # Move window off-canvas: inhibitor should become inactive
                ipc.action("move_window_to", {"id": win["id"], "x": 10000, "y": 10000})
                state = wait_for(lambda: get_idle_state(ipc) if not get_idle_state(ipc)["is_inhibited"] else None,
                                 "inhibitor did not deactivate off-canvas")
                assert state["inhibitor_count"] == 1, state
                inh = state["inhibitors"][0]
                assert inh["is_active"] is False, inh
                assert inh["reason"] == "off-canvas", inh

                # Move window back onscreen: inhibitor reactivates
                ipc.action("move_window_to", {"id": win["id"], "x": 100, "y": 100})
                state = wait_for(lambda: get_idle_state(ipc) if get_idle_state(ipc)["is_inhibited"] else None,
                                 "inhibitor did not reactivate onscreen")
                assert state["is_inhibited"] is True, state
                assert state["inhibitors"][0]["is_active"] is True, state

                # Minimize window: inhibitor deactivates
                ipc.action("minimize_window", {"id": win["id"]})
                state = wait_for(lambda: get_idle_state(ipc) if not get_idle_state(ipc)["is_inhibited"] else None,
                                 "inhibitor did not deactivate on minimize")
                assert state["inhibitors"][0]["is_active"] is False, state
                assert state["inhibitors"][0]["reason"] == "minimized", state

                # Restore window: inhibitor reactivates
                ipc.action("restore_window", {"id": win["id"]})
                state = wait_for(lambda: get_idle_state(ipc) if get_idle_state(ipc)["is_inhibited"] else None,
                                 "inhibitor did not reactivate on restore")
                assert state["is_inhibited"] is True, state

                # Uninhibit from client
                send("uninhibit")
                wait_for(lambda: "uninhibited\n" in client_log.read_text(), "uninhibit confirmation missing")
                state = wait_for(lambda: get_idle_state(ipc) if not get_idle_state(ipc)["is_inhibited"] else None,
                                 "inhibition not cleared")
                assert state["inhibitor_count"] == 0, state

                # 3. Test display blanking and wake input absorption
                set_idle_config(ipc, blank_after_seconds=10)
                state = get_idle_state(ipc)
                assert state["blank_after_seconds"] == 10, state

                # Advance idle time past blank deadline
                advance_idle_time(ipc, 15)
                state = wait_for(lambda: get_idle_state(ipc) if get_idle_state(ipc)["state"] == "blanked" else None,
                                 "state did not transition to blanked")
                assert state["state"] == "blanked", state

                # Verify camera bounds did not collapse to zero
                cam = ipc.action("get_camera")
                assert cam["max_x"] > 0 and cam["max_y"] > 0, cam

                # Test wake key absorption: first key press wakes displays and is absorbed
                ipc.action("key", {"keycode": 30, "pressed": True})
                state = wait_for(lambda: get_idle_state(ipc) if get_idle_state(ipc)["state"] == "active" else None,
                                 "key press did not wake displays")
                assert state["state"] == "active", state

                # Matching release event is also absorbed without leaving stuck key
                ipc.action("key", {"keycode": 30, "pressed": False})
                input_state = ipc.get_input_state()
                assert len(input_state["held_keys"]) == 0, input_state

                # Blank again
                advance_idle_time(ipc, 15)
                state = wait_for(lambda: get_idle_state(ipc) if get_idle_state(ipc)["state"] == "blanked" else None,
                                 "state did not transition to blanked")

                # Test wake mouse button absorption
                ipc.action("pointer_button", {"button": 0x110, "pressed": True})
                state = wait_for(lambda: get_idle_state(ipc) if get_idle_state(ipc)["state"] == "active" else None,
                                 "pointer button did not wake displays")
                assert state["state"] == "active", state

                ipc.action("pointer_button", {"button": 0x110, "pressed": False})
                input_state = ipc.get_input_state()
                assert len(input_state["held_buttons"]) == 0, input_state

                # 4. Test ext-idle-notify protocol notifications
                send("watch 100")
                wait_for(lambda: "watching\n" in client_log.read_text(), "ext-idle-notify watch missing")

                # Wait for idle event on client (100ms timeout)
                wait_for(lambda: "idled\n" in client_log.read_text(), "idled event not received by client")

                # Move cursor via IPC: user activity should trigger resumed event
                ipc.move_cursor(50, 50)
                wait_for(lambda: "resumed\n" in client_log.read_text(), "resumed event not received by client")

                send("unwatch")
                send("quit")
                print("Idle integration tests passed successfully!")
        finally:
            if client:
                stop_process(client)
            stop_process(compositor)
            if log:
                log.close()


if __name__ == "__main__":
    run()

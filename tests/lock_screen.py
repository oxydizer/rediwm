#!/usr/bin/env python3
"""Headless lock isolation; never submits passwords or host power requests."""
import json
from pathlib import Path
import tempfile
import time
from ipc_client import IPCClient, IPCError, spawn_compositor, stop_process


def denied(call):
    try:
        call()
    except IPCError as exc:
        assert "SessionLocked" in str(exc), str(exc)
    else:
        raise AssertionError("locked compositor accepted an IPC request")


def run(scale, outputs, sequence=False):
    with tempfile.TemporaryDirectory(prefix="rediwm-lock-test-") as directory:
        tmp = Path(directory)
        # A single-key fixture also tests cancellation halfway through TypeText.
        config = "[compositor]\nxwayland = false\n"
        if sequence:
            config += '[keybinds]\n"l" = "lock_screen"\n'
        process, log = spawn_compositor(tmp, scale=scale, outputs=outputs, config_content=config)
        try:
            with IPCClient(tmp, timeout=15) as client:
                client.wait_for("wallpaper_presented", timeout_ms=10000)
                client.get_shell_state()
                # A wait pending when the lock engages must end rather than
                # keep reporting state changes from behind the lock.
                waiter = IPCClient(tmp, timeout=15).connect()
                waiter.sock.sendall((json.dumps({"version": 1, "id": 1, "command": "wait_for", "params": {
                    "condition": {"window_mapped": {"app_id": "never.appears"}}, "timeout_ms": 60000}}) + "\n").encode())
                if sequence:
                    denied(lambda: client.type_text("locked-input-must-not-reach-password"))
                else:
                    client.key(29, True)  # Ctrl
                    client.key(56, True)  # Alt
                    client.key(38, True)  # L
                for call in (
                    client.get_shell_state,
                    lambda: client.key(1, True),  # Escape is no bypass
                    lambda: client.key_press("XF86AudioRaiseVolume"),
                    lambda: client.key_press("XF86AudioMicMute"),
                    lambda: client.key_press("Caps_Lock"),
                    lambda: client.type_text("must-not-be-submitted"),
                    lambda: client.click_at(640, 540),
                    lambda: client.screenshot(path=str(tmp / "forbidden.png")),
                    lambda: client.action("sample_pixels", {"x": 0, "y": 0}),
                    lambda: client.action("close_window", {}),
                ):
                    denied(call)
                ended = json.loads(waiter.reader.readline())
                assert ended.get("id") == 1 and ended.get("Err") == "SessionLocked", ended
                waiter.close()
                # New connections are subject to the same gate, including
                # event subscriptions, which begin with a state snapshot.
                with IPCClient(tmp, timeout=10) as second:
                    denied(second.get_shell_state)
                    denied(lambda: second.query("event_stream"))
                    denied(lambda: second.query("windows"))
                time.sleep(.3)
                assert process.poll() is None, (tmp / "compositor.log").read_text()
                assert not (tmp / "forbidden.png").exists()
        except Exception:
            print((tmp / "compositor.log").read_text())
            raise
        finally:
            stop_process(process)
            log.close()
        output = (tmp / "compositor.log").read_text()
        assert "panic:" not in output, output
    print(f"PASS: lock IPC/input/capture isolation ({outputs} outputs, scale {scale}, sequence={sequence})")


if __name__ == "__main__":
    run("1", "1")
    run("1.5", "2")
    run("1", "1", sequence=True)

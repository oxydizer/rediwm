#!/usr/bin/env python3
"""IPC socket permissions and the [ipc] automation tier."""
import os
import json
from pathlib import Path
import stat
import tempfile
import time
from ipc_client import IPCClient, IPCError, spawn_compositor, stop_process


def disabled(call):
    try:
        call()
    except IPCError as exc:
        assert "AutomationDisabled" in str(exc), str(exc)
    else:
        raise AssertionError("automation command accepted without [ipc] automation")


def session(config, env, check):
    with tempfile.TemporaryDirectory(prefix="rediwm-ipc-automation-") as directory:
        tmp = Path(directory)
        process, log = spawn_compositor(tmp, config_content="[compositor]\nxwayland = false\n" + config, env_extra=env)
        try:
            check(tmp, process)
        except Exception:
            print((tmp / "compositor.log").read_text())
            raise
        finally:
            stop_process(process)
            log.close()
        assert "panic:" not in (tmp / "compositor.log").read_text()


def default_off(tmp, _process):
    with IPCClient(tmp, timeout=15) as client:
        client.wait_for("wallpaper_presented", timeout_ms=10000)
        sock = Path(client.sock.getpeername())
        assert sock.parent == tmp, sock
        assert stat.S_IMODE(sock.stat().st_mode) == 0o600, oct(sock.stat().st_mode)
        # Only canonical v1 requests reach dispatch; malformed lines don't poison
        # the connection, and integer/string correlation IDs survive round trips.
        for old in ('"Windows"', '{"Windows":{}}', '{"Action":"Click"}',
                    '{"query":"windows"}', '{"request":"Windows"}',
                    '{"version":0,"command":"windows"}',
                    '{"version":1,"command":"Windows"}',
                    '{"version":1,"command":"state"}'):
            assert "Err" in client.send_raw(old), old
        for request_id in (0, "v1-check"):
            reply = client.send_raw(json.dumps({"version": 1, "id": request_id,
                                                "command": "windows"}))
            assert reply == {"id": request_id, "Ok": {"Windows": []}}, reply
        assert client.describe()["protocol_version"] == "1"
        # Queries and window management stay available.
        client.get_windows()
        client.get_state()
        client.open_start_menu()
        client.close_panel("start_menu")
        for call in (
            lambda: client.move_cursor(10, 10),
            lambda: client.move_cursor_relative(1, 1),
            lambda: client.pointer_button(0x110, True),
            lambda: client.click(),
            lambda: client.scroll(0, 1),
            lambda: client.key(30, True),
            lambda: client.key_press("a"),
            lambda: client.type_text("x"),
            lambda: client.drag(0, 0, 10, 10),
            lambda: client.screenshot(path=str(tmp / "forbidden.png")),
            lambda: client.sample_pixels(0, 0),
            lambda: client.dump_buffer("taskbar"),
            lambda: client.action("pinch", {"phase": "begin"}),
            lambda: client.action("swipe", {"phase": "begin"}),
        ):
            disabled(call)
        # Nothing was injected: no key or button is held.
        state = client.get_input_state()
        assert not state["held_keys"] and not state["held_buttons"], state
        reasons = client.describe()["unavailable_reasons"]
        assert any("automation disabled" in r for r in reasons), reasons
    assert not (tmp / "forbidden.png").exists()


def config_on(tmp, _process):
    with IPCClient(tmp, timeout=15) as client:
        client.wait_for("wallpaper_presented", timeout_ms=10000)
        assert len(client.sample_pixels(0, 0)["pixels"]) == 1
        client.move_cursor(10, 10)
        reasons = client.describe()["unavailable_reasons"]
        assert not any("automation" in r for r in reasons), reasons


def run():
    # "0" overrides the switch the ipc_client import sets for every test.
    session("", {"REDIWM_IPC_AUTOMATION": "0"}, default_off)
    session("[ipc]\nautomation = true\n", {"REDIWM_IPC_AUTOMATION": "0"}, config_on)
    with tempfile.TemporaryDirectory(prefix="rediwm-ipc-shared-") as shared_root:
        shared = Path(shared_root) / "shared"
        shared.mkdir()
        os.chmod(shared, 0o777)
        session("", {"REDIWM_SOCKET": str(shared / "rediwm.sock")},
                lambda tmp, process: shared_dir_refused_at(shared, tmp, process))
    print("PASS: IPC socket is private; automation commands need [ipc] automation")


def shared_dir_refused_at(shared, tmp, process):
    deadline = time.monotonic() + 10
    log = tmp / "compositor.log"
    while "not private to this uid" not in log.read_text():
        assert process.poll() is None and time.monotonic() < deadline, log.read_text()
        time.sleep(0.1)
    assert not (shared / "rediwm.sock").exists()


if __name__ == "__main__":
    run()

#!/usr/bin/env python3
"""Headless `rediwm --greeter` smoke test against a fake login manager socket.

Checks what the greeter must not do: open the IPC control socket, start
Xwayland, write a config, or contact the daemon before anyone submits. The
rediwm-dm conversation itself is covered by `zig build test-lock`.
"""
import os
from pathlib import Path
import signal
import socket
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
AUTOSTART_CONFIG = """[compositor]
xwayland = true

[[autostart]]
cmd = "touch {marker}"
"""


def wait_for(path, text, timeout=15):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if text in path.read_text(errors="replace"):
            return
        time.sleep(0.2)
    raise AssertionError(f"timed out waiting for {text!r}\n{path.read_text(errors='replace')}")


def run(with_dm):
    with tempfile.TemporaryDirectory(prefix="rediwm-greeter-test-") as directory:
        tmp = Path(directory)
        home = tmp / "home"
        home.mkdir()
        # Configs that enable X11 and autostart must not make the greeter
        # start either: an explicit REDIWM_CONFIG, or one in the greeter's home.
        config = home / ".config/rediwm/config.toml" if not with_dm else tmp / "greeter.toml"
        config.parent.mkdir(parents=True, exist_ok=True)
        config.write_text(AUTOSTART_CONFIG.format(marker=tmp / "autostarted"))
        env = dict(
            os.environ,
            HOME=str(home),
            XDG_RUNTIME_DIR=str(tmp),
            WLR_BACKENDS="headless",
            WLR_HEADLESS_OUTPUTS="2",
            WLR_RENDERER="pixman",
            REDIWM_SCALE="1",
            DBUS_SYSTEM_BUS_ADDRESS="unix:path=/nonexistent-rediwm-test-system-bus",
            DBUS_SESSION_BUS_ADDRESS="unix:path=/nonexistent-rediwm-test-session-bus",
        )
        for key in ("WAYLAND_DISPLAY", "REDIWM_SOCKET", "XDG_STATE_HOME", "XDG_CONFIG_HOME", "REDIWM_CONFIG", "REDIWM_GREETER_FD", "GREETD_SOCK", "DISPLAY"):
            env.pop(key, None)
        if with_dm:
            env["REDIWM_CONFIG"] = str(config)
        daemon_sock = None
        pass_fds = ()
        if with_dm:
            daemon_sock, greeter_sock = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
            os.set_inheritable(greeter_sock.fileno(), True)
            env["REDIWM_GREETER_FD"] = str(greeter_sock.fileno())
            pass_fds = (greeter_sock.fileno(),)
        log_path = tmp / "compositor.log"
        with log_path.open("w") as log:
            process = subprocess.Popen([str(ROOT / "zig-out/bin/rediwm"), "--greeter"], env=env, stdout=log, stderr=log, pass_fds=pass_fds)
        if with_dm:
            greeter_sock.close()
        try:
            wait_for(log_path, "Running compositor on WAYLAND_DISPLAY")
            wait_for(log_path, "greeter: ")
            time.sleep(1)
            assert process.poll() is None, log_path.read_text()
            output = log_path.read_text(errors="replace")
            names = sorted(p.name for p in tmp.iterdir())
            assert not any(n.startswith("rediwm-") and n.endswith(".sock") for n in names), names
            assert "Xwayland disabled in config" in output and "Xwayland display" not in output, output
            # Nothing written into the greeter's home, not even a default config.
            assert sorted(str(p.relative_to(home)) for p in home.rglob("*") if p.is_file()) == (
                [] if with_dm else [".config/rediwm/config.toml"]), list(home.rglob("*"))
            assert not (tmp / "autostarted").exists()
            if with_dm:
                daemon_sock.setblocking(False)
                try:
                    data = daemon_sock.recv(1024)
                except BlockingIOError:
                    data = b""
                assert not data, "greeter contacted daemon before a submit"
                from wlr_protocols import compile_fixture
                compile_fixture(tmp)
                wayland_socket = next(p for p in tmp.iterdir() if p.name.startswith("wayland-") and not p.name.endswith(".lock"))
                dump_env = dict(env, WAYLAND_DISPLAY=wayland_socket.name)
                registry_res = subprocess.run([str(tmp / "fixture"), "dump-registry"], env=dump_env, capture_output=True, text=True, check=True)
                for interface in ("wp_security_context_manager_v1", "ext_workspace_manager_v1",
                                  "wp_drm_lease_device_v1", "xdg_toplevel_tag_manager_v1",
                                  "wp_content_type_manager_v1", "wp_tearing_control_manager_v1",
                                  "wp_color_manager_v1", "wp_color_representation_manager_v1"):
                    assert interface not in registry_res.stdout, registry_res.stdout
            else:
                assert "REDIWM_GREETER_FD unset" in output, output
        finally:
            process.send_signal(signal.SIGTERM)
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                raise
            if daemon_sock:
                daemon_sock.close()
        output = log_path.read_text(errors="replace")
        assert "panic:" not in output, output
    print(f"PASS: greeter isolation (daemon={'fake' if with_dm else 'absent'})")


if __name__ == "__main__":
    run(True)
    run(False)

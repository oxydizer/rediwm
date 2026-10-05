#!/usr/bin/env python3
"""Integration tests for wp_security_context_manager_v1 and sandbox isolation.

Tests:
1. Privileged globals hidden on sandboxed connections.
2. Guess-bind hidden globals raises protocol error.
3. Nested create_listener forbidden.
4. IPC get_windows reports trusted sandbox metadata for sandboxed clients, null for unsandboxed.
5. [[sandbox_allow]] grants per-app access to specified global groups.
6. Sandboxed IPC callers via Flatpak (.flatpak-info) blocked unless allowed, checked per-request.
7. Clean teardown with live sandboxed client.
"""
import os
from pathlib import Path
import select
import shutil
import subprocess
import tempfile
import time

from desktop_zoom import ROOT, build_client, wait_for
from ipc_client import IPCClient, IPCError, spawn_compositor, stop_process
from wlr_protocols import compile_fixture, expect_line
from xwayland import wayland_display_name

PRIVILEGED_GLOBALS = {
    "ext_workspace_manager_v1",
    "wp_drm_lease_device_v1",
    "zwlr_screencopy_manager_v1",
    "ext_image_copy_capture_manager_v1",
    "ext_output_image_capture_source_manager_v1",
    "ext_foreign_toplevel_image_capture_source_manager_v1",
    "ext_foreign_toplevel_list_v1",
    "zwlr_foreign_toplevel_manager_v1",
    "zwlr_data_control_manager_v1",
    "ext_data_control_manager_v1",
    "zwp_virtual_keyboard_manager_v1",
    "zwlr_virtual_pointer_manager_v1",
    "zwp_input_method_manager_v2",
    "zwlr_output_manager_v1",
    "zwlr_output_power_manager_v1",
    "ext_session_lock_manager_v1",
    "zwlr_layer_shell_v1",
    "ext_idle_notifier_v1",
    "wp_security_context_manager_v1",
    "xwayland_shell_v1",
}

CORE_GLOBALS = {
    "wl_compositor",
    "wl_shm",
    "xdg_wm_base",
    "wl_seat",
    "wl_output",
    "wl_subcompositor",
}


class ContextSession:
    def __init__(self, tmp, config="[compositor]\nxwayland = false\n", automation=False):
        self.tmp = tmp
        env_extra = {"REDIWM_IPC_AUTOMATION": "1" if automation else "0"}
        self.process, self.log = spawn_compositor(tmp, config_content=config, env_extra=env_extra)
        self.ipc = IPCClient(tmp, timeout=15).connect()
        self.ipc.wait_for("wallpaper_presented", timeout_ms=10000)
        self.env = dict(os.environ, XDG_RUNTIME_DIR=str(tmp), WAYLAND_DISPLAY=wayland_display_name(tmp))
        self.env.pop("DISPLAY", None)
        self.children = []

    def close(self):
        for child in self.children:
            if child.poll() is None:
                child.kill()
            child.wait()
        self.ipc.close()
        stop_process(self.process)
        self.log.close()
        text = (self.tmp / "compositor.log").read_text()
        assert "panic:" not in text and "reached unreachable" not in text, text[-4000:]


def dump_registry(fixture_bin, env):
    res = subprocess.run([str(fixture_bin), "dump-registry"], env=env, capture_output=True, text=True, check=True)
    lines = [line.strip() for line in res.stdout.splitlines() if line.strip() and line.strip() != "done"]
    return set(lines)


def test_registry_and_guess_bind():
    with tempfile.TemporaryDirectory(prefix="rediwm-sc-test-") as directory:
        tmp = Path(directory)
        compile_fixture(tmp)
        build_client(tmp)

        session = ContextSession(tmp)
        try:
            # 1. Normal connection sees privileged globals
            normal_globals = dump_registry(tmp / "fixture", session.env)
            assert "wp_security_context_manager_v1" in normal_globals, "security context manager missing on normal socket"
            assert "zwlr_screencopy_manager_v1" in normal_globals, "screencopy missing on normal socket"
            assert "ext_session_lock_manager_v1" in normal_globals, "session lock missing on normal socket"

            # 2. Create security context listener
            sandboxed_sock = tmp / "sandboxed.sock"
            sc_proc = subprocess.Popen(
                [str(tmp / "fixture"), "security-context", str(sandboxed_sock), "org.rediwm.test", "org.example.Sandboxed"],
                env=session.env,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                text=True,
            )
            session.children.append(sc_proc)
            expect_line(sc_proc, "listening")

            # 3. Dump registry through sandboxed connection
            sandboxed_env = dict(session.env, WAYLAND_DISPLAY=str(sandboxed_sock))
            sandboxed_globals = dump_registry(tmp / "fixture", sandboxed_env)

            # Core globals present
            for cg in CORE_GLOBALS:
                assert cg in sandboxed_globals, f"core global {cg} missing on sandboxed socket"

            # All privileged globals absent
            for pg in PRIVILEGED_GLOBALS:
                assert pg not in sandboxed_globals, f"privileged global {pg} leaked to sandboxed client"

            # 4. Guess-bind hidden global raises protocol error
            guess_res = subprocess.run(
                [str(tmp / "fixture"), "guess-bind", "1", "zwlr_screencopy_manager_v1", "3"],
                env=sandboxed_env,
                capture_output=True,
                text=True,
            )
            assert "error:" in guess_res.stdout, f"guess-bind should fail with error, got: {guess_res.stdout}"

            # 5. Nested create_listener forbidden
            nested_res = subprocess.run(
                [str(tmp / "fixture"), "try-nested"],
                env=sandboxed_env,
                capture_output=True,
                text=True,
            )
            assert "not_advertised" in nested_res.stdout or "nested_error:" in nested_res.stdout, nested_res.stdout

            # Sc proc closes cleanly
            sc_proc.stdin.write("exit\n")
            sc_proc.stdin.flush()
            sc_proc.wait(timeout=5)
        finally:
            session.close()
    print("PASS: privileged globals hidden and nested context forbidden")


def test_window_attribution():
    with tempfile.TemporaryDirectory(prefix="rediwm-sc-test-") as directory:
        tmp = Path(directory)
        compile_fixture(tmp)
        build_client(tmp)

        session = ContextSession(tmp)
        try:
            # Normal client window -> sandbox: null
            normal_client = subprocess.Popen([str(tmp / "client")], env=session.env)
            session.children.append(normal_client)

            def find_normal():
                for w in session.ipc.get_windows():
                    if w["app_id"] == "rediwm.zoom-fixture":
                        return w
                return None

            w_normal = wait_for(find_normal, "timed out waiting for normal client window")
            assert w_normal.get("sandbox") is None, f"expected sandbox null for normal client, got: {w_normal.get('sandbox')}"

            # Start sandboxed listener
            sandboxed_sock = tmp / "sandboxed.sock"
            sc_proc = subprocess.Popen(
                [str(tmp / "fixture"), "security-context", str(sandboxed_sock), "org.rediwm.test", "org.example.App"],
                env=session.env,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                text=True,
            )
            session.children.append(sc_proc)
            expect_line(sc_proc, "listening")

            # Map window over sandboxed connection
            sandboxed_env = dict(session.env, WAYLAND_DISPLAY=str(sandboxed_sock))
            sandboxed_client = subprocess.Popen([str(tmp / "client")], env=sandboxed_env)
            session.children.append(sandboxed_client)

            def find_sandboxed():
                for w in session.ipc.get_windows():
                    sb = w.get("sandbox")
                    if sb and sb.get("app_id") == "org.example.App":
                        return w
                return None

            w_sandboxed = wait_for(find_sandboxed, "timed out waiting for sandboxed client window")
            sb = w_sandboxed["sandbox"]
            assert sb["engine"] == "org.rediwm.test", sb
            assert sb["app_id"] == "org.example.App", sb
            assert sb["instance_id"] is None, sb

            # Terminate clients
            normal_client.terminate()
            sandboxed_client.terminate()
            sc_proc.stdin.write("exit\n")
            sc_proc.stdin.flush()
        finally:
            session.close()
    print("PASS: window sandbox attribution over IPC")


def test_sandbox_allowances():
    config = """[compositor]
xwayland = false

[[sandbox_allow]]
app_id = "org.example.AllowedApp"
allow = ["clipboard"]
"""
    with tempfile.TemporaryDirectory(prefix="rediwm-sc-test-") as directory:
        tmp = Path(directory)
        compile_fixture(tmp)
        session = ContextSession(tmp, config=config)
        try:
            sandboxed_sock = tmp / "sandboxed.sock"
            sc_proc = subprocess.Popen(
                [str(tmp / "fixture"), "security-context", str(sandboxed_sock), "org.rediwm.test", "org.example.AllowedApp"],
                env=session.env,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                text=True,
            )
            session.children.append(sc_proc)
            expect_line(sc_proc, "listening")

            sandboxed_env = dict(session.env, WAYLAND_DISPLAY=str(sandboxed_sock))
            globals_seen = dump_registry(tmp / "fixture", sandboxed_env)

            # Clipboard group allowed
            assert "zwlr_data_control_manager_v1" in globals_seen, "data-control should be granted by clipboard group"
            assert "ext_data_control_manager_v1" in globals_seen, "ext-data-control should be granted by clipboard group"

            # Capture group still forbidden
            assert "zwlr_screencopy_manager_v1" not in globals_seen
            assert "ext_session_lock_manager_v1" not in globals_seen
            assert "wp_security_context_manager_v1" not in globals_seen

            sc_proc.stdin.write("exit\n")
            sc_proc.stdin.flush()
        finally:
            session.close()
    print("PASS: sandbox allowances grant specified groups")


def test_sandboxed_ipc_caller():
    if not shutil.which("bwrap"):
        print("SKIP: bwrap not available")
        return

    config = """[compositor]
xwayland = false

[ipc]
automation = true

[[sandbox_allow]]
app_id = "org.example.IpcApp"
allow = ["ipc"]

[[sandbox_allow]]
app_id = "org.example.AutoApp"
allow = ["ipc", "automation"]
"""
    with tempfile.TemporaryDirectory(prefix="rediwm-sc-test-") as directory:
        tmp = Path(directory)
        session = ContextSession(tmp, config=config, automation=True)
        try:
            # Create fake .flatpak-info files
            unallowed_info = tmp / "unallowed.info"
            unallowed_info.write_text("[Application]\nname=org.example.UnallowedApp\n")

            allowed_info = tmp / "allowed.info"
            allowed_info.write_text("[Application]\nname=org.example.IpcApp\n")

            auto_info = tmp / "auto.info"
            auto_info.write_text("[Application]\nname=org.example.AutoApp\n")

            malformed_info = tmp / "malformed.info"
            malformed_info.write_text("[Context]\nfoo=bar\n")

            bwrap_base = [
                "bwrap",
                "--tmpfs", "/",
                "--ro-bind", "/usr", "/usr",
                "--symlink", "usr/lib", "/lib",
                "--symlink", "usr/lib64", "/lib64",
                "--symlink", "usr/bin", "/bin",
                "--symlink", "usr/sbin", "/sbin",
                "--dev", "/dev",
                "--proc", "/proc",
                "--ro-bind", "/etc", "/etc",
                "--bind", "/home", "/home",
                "--bind", "/run", "/run",
                "--bind", "/tmp", "/tmp",
            ]

            script = """
import sys, pathlib
sys.path.insert(0, sys.argv[1])
from ipc_client import IPCClient
try:
    c = IPCClient(pathlib.Path(sys.argv[2]), timeout=5).connect()
    res = c.get_version()
    print("SUCCESS", res)
except Exception as exc:
    print("REJECTED", exc)
"""

            # 1. Unallowed app -> rejected at accept
            cmd_unallowed = [*bwrap_base, "--ro-bind", str(unallowed_info), "/.flatpak-info", "python3", "-c", script, str(ROOT / "tests"), str(tmp)]
            r1 = subprocess.run(cmd_unallowed, env=session.env, capture_output=True, text=True)
            assert "REJECTED" in r1.stdout or r1.returncode != 0, f"unallowed client should be rejected, got: {r1.stdout}"

            # 2. Allowed app -> connects and succeeds for regular queries
            cmd_allowed = [*bwrap_base, "--ro-bind", str(allowed_info), "/.flatpak-info", "python3", "-c", script, str(ROOT / "tests"), str(tmp)]
            r2 = subprocess.run(cmd_allowed, env=session.env, capture_output=True, text=True)
            assert "SUCCESS" in r2.stdout, f"allowed client failed: {r2.stdout} {r2.stderr}"

            # 3. Allowed app without automation allowance -> fails on automation commands
            auto_script = """
import sys, pathlib
sys.path.insert(0, sys.argv[1])
from ipc_client import IPCClient
try:
    c = IPCClient(pathlib.Path(sys.argv[2]), timeout=5).connect()
    # Try automation command (move cursor)
    res = c.move_cursor(100, 100)
    print("AUTO_RESULT", res)
except Exception as exc:
    print("AUTO_FAILED", type(exc).__name__, exc)
"""
            cmd_auto_denied = [*bwrap_base, "--ro-bind", str(allowed_info), "/.flatpak-info", "python3", "-c", auto_script, str(ROOT / "tests"), str(tmp)]
            r3 = subprocess.run(cmd_auto_denied, env=session.env, capture_output=True, text=True)
            assert "PermissionDenied" in r3.stdout or "AUTO_FAILED" in r3.stdout, f"automation command should be denied: {r3.stdout}"

            # 4. App with both ipc and automation allowances -> automation succeeds
            cmd_auto_allowed = [*bwrap_base, "--ro-bind", str(auto_info), "/.flatpak-info", "python3", "-c", auto_script, str(ROOT / "tests"), str(tmp)]
            r4 = subprocess.run(cmd_auto_allowed, env=session.env, capture_output=True, text=True)
            assert "AUTO_RESULT" in r4.stdout, f"automation command should succeed for auto app: {r4.stdout} {r4.stderr}"

            # 5. Malformed .flatpak-info -> fails closed
            cmd_malformed = [*bwrap_base, "--ro-bind", str(malformed_info), "/.flatpak-info", "python3", "-c", script, str(ROOT / "tests"), str(tmp)]
            r5 = subprocess.run(cmd_malformed, env=session.env, capture_output=True, text=True)
            assert "REJECTED" in r5.stdout or r5.returncode != 0, f"malformed flatpak-info should fail closed: {r5.stdout}"
        finally:
            session.close()
    print("PASS: sandboxed IPC caller detection via Flatpak info and bubblewrap")


if __name__ == "__main__":
    test_registry_and_guess_bind()
    test_window_attribution()
    test_sandbox_allowances()
    test_sandboxed_ipc_caller()

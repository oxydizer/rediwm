#!/usr/bin/env python3
"""Exercise real greeter input through a private parent Wayland compositor.

Parent IPC injects keyboard/pointer events into the child's wl_seat. The
greeter itself has no IPC or test hook; a socketpair stands in for the DM and
checks the selected session and typed dummy secret. No PAM or host bus is used.
"""
import json
import os
from pathlib import Path
import pwd
import select
import socket
import struct
import subprocess
import tempfile
import time

from ipc_client import IPCClient, spawn_compositor, stop_process


ROOT = Path(__file__).resolve().parents[1]
BINARY = Path(os.environ.get("REDIWM_READINESS_BINARY", ROOT / "zig-out/bin/rediwm"))
PARENT_BINARY = Path(os.environ.get("REDIWM_PARENT_BINARY", BINARY))
PASSWORD = "readiness-only-42"


def wait_for(predicate, description, timeout=20):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.05)
    raise AssertionError(f"timed out waiting for {description}")


class Peer:
    def __init__(self, sock):
        self.sock = sock

    def read(self, size):
        data = b""
        while len(data) < size:
            chunk = self.sock.recv(size - len(data))
            assert chunk, "greeter disconnected"
            data += chunk
        return data

    def recv(self, timeout=20):
        self.sock.settimeout(timeout)
        size = struct.unpack("=I", self.read(4))[0]
        assert size <= 8192, size
        return json.loads(self.read(size))

    def send(self, message):
        payload = json.dumps(message).encode()
        self.sock.sendall(struct.pack("=I", len(payload)) + payload)

    def quiet(self, timeout=0.4):
        assert not select.select([self.sock], [], [], timeout)[0], "unsolicited greeter request"


def environment(directory, share):
    env = dict(os.environ)
    for key in list(env):
        if key.startswith("REDIWM_") or key in ("WAYLAND_DISPLAY", "DISPLAY", "GREETD_SOCK", "NOTIFY_SOCKET"):
            env.pop(key, None)
    for name in ("home", "state", "cache", "config", "data", "runtime"):
        (directory / name).mkdir(mode=0o700, parents=True, exist_ok=True)
    env.update(
        HOME=str(directory / "home"),
        XDG_RUNTIME_DIR=str(directory / "runtime"),
        XDG_STATE_HOME=str(directory / "state"),
        XDG_CACHE_HOME=str(directory / "cache"),
        XDG_CONFIG_HOME=str(directory / "config"),
        XDG_DATA_HOME=str(directory / "data"),
        XDG_DATA_DIRS=str(share),
        DBUS_SYSTEM_BUS_ADDRESS="unix:path=/nonexistent-rediwm-readiness-system-bus",
        DBUS_SESSION_BUS_ADDRESS="unix:path=/nonexistent-rediwm-readiness-session-bus",
        PULSE_SERVER="unix:/nonexistent-rediwm-readiness-audio",
        WLR_RENDERER="gles2", WLR_RENDERER_ALLOW_SOFTWARE="1",
        REDIWM_SCALE="1", REDIWM_STARTUP_TIMING="1",
        REDIWM_GREETER_READY_INPUT="keyboard-pointer",
    )
    # Fix selection without depending on another login's saved state.
    user = pwd.getpwuid(os.getuid()).pw_name
    state = directory / "state/rediwm"
    state.mkdir()
    (state / "greeter.state").write_text(f"user={user}\nsession.{user}=alpha\n")
    return env, user


def launch(directory, env):
    daemon, child = socket.socketpair()
    env = dict(env, REDIWM_GREETER_FD=str(child.fileno()))
    log_path = directory / "greeter.log"
    with log_path.open("w") as log:
        process = subprocess.Popen([str(BINARY), "--greeter"], env=env,
                                   stdout=log, stderr=log, pass_fds=(child.fileno(),))
    child.close()
    return process, Peer(daemon), log_path


def assert_no_greeter_ipc(directory):
    assert not list((directory / "runtime").glob("rediwm-*.sock")), "greeter exposed IPC"


def no_input_case(root, share):
    directory = root / "no-input"
    env, _ = environment(directory, share)
    env.update(WLR_BACKENDS="headless", WLR_HEADLESS_OUTPUTS="1")
    process, peer, log = launch(directory, env)
    try:
        wait_for(lambda: "first_presented" in log.read_text(errors="replace"), "headless presentation")
        assert process.poll() is None, log.read_text()
        # Presentation alone cannot satisfy readiness, even after event-loop
        # turns. This is a negative invariant, not a boot-latency measurement.
        peer.quiet(1)
        assert_no_greeter_ipc(directory)
        print("PASS: presented greeter without input devices does not report ready")
    finally:
        stop_process(process)
        peer.sock.close()


def nested_case(root, share):
    parent_dir = root / "parent"
    parent_dir.mkdir()
    parent_env, _ = environment(parent_dir, share)
    parent_env.update(REDIWM_IPC_AUTOMATION="1", REDIWM_DESKTOP_BUILTINS="0")
    parent, parent_log = spawn_compositor(
        parent_dir, binary=PARENT_BINARY,
        config_content='[compositor]\nxwayland = false\n',
        env_extra=parent_env,
    )
    child = peer = None
    try:
        with IPCClient(parent_dir / "runtime") as ipc:
            display = wait_for(lambda: next((p for p in (parent_dir / "runtime").glob("wayland-*")
                                            if not p.name.endswith(".lock")), None), "parent Wayland socket")
            directory = root / "nested"
            env, user = environment(directory, share)
            env.update(WLR_BACKENDS="wayland", WAYLAND_DISPLAY=str(display), WAYLAND_DEBUG="client")
            env.pop("WLR_HEADLESS_OUTPUTS", None)
            child, peer, log = launch(directory, env)
            window = wait_for(lambda: next(iter(ipc.get_windows()), None), "nested greeter window")
            ipc.fullscreen(window["id"])
            ipc.focus_window(window["id"])
            ipc.wait_for("window_geometry_settled", window_id=window["id"])
            ipc.wait_for_frame()
            message = peer.recv()
            assert message == {"type": "ready"}, message
            output = log.read_text(errors="replace")
            assert "first_presented" in output, "ready preceded presentation"
            assert "reveal_done" in output, "ready preceded the visible greeter (black/fading veil)"
            assert "wl_keyboard" in output and "wl_pointer" in output, "nested seat missing input"
            peer.send({"type": "ready"})
            peer.quiet()
            assert_no_greeter_ipc(directory)

            # Coordinates are inside the visible session selector, measured
            # in the nested output's logical pixels. The resulting 'start'
            # request must name beta, proving the pointer changed selection.
            box = ipc.get_window_debug(window["id"])["client_box"]
            width, height = box["width"], box["height"]
            scale = min(1, width / 600, height / 900) * 0.85
            # Enter the nested surface, then move within it so the child
            # receives wl_pointer.motion in addition to wl_pointer.enter.
            ipc.move_cursor(box["x"] + width // 2, box["y"] + height // 2)
            ipc.wait_for_frame()
            ipc.click_at(round(box["x"] + 120 * scale), round(box["y"] + height - 60 * scale))
            ipc.wait_for_frame()
            # Typing returns focus to the password field. Events traverse the
            # parent's virtual device, Wayland wl_keyboard, and greeter field.
            ipc.type_text(PASSWORD)
            ipc.key_down_up(28)  # evdev KEY_ENTER
            message = peer.recv()
            assert message == {"type": "login", "user": user}, message
            peer.send({"type": "question", "kind": "secret", "text": "Fixture password:"})
            message = peer.recv()
            assert message == {"type": "answer", "response": PASSWORD}, message
            peer.send({"type": "ok"})
            message = peer.recv()
            assert message == {"type": "start", "session": "beta"}, message
            output = log.read_text(errors="replace")
            assert ".key(" in output and ".button(" in output, "input did not traverse Wayland"
            assert "panic:" not in output, output
            peer.quiet()
            print("PASS: ready greeter consumes pointer selection and keyboard secret through Wayland")
            # Do not acknowledge start: no real session or PAM is involved.
    finally:
        if child is not None:
            stop_process(child)
        if peer is not None:
            peer.sock.close()
        stop_process(parent)
        parent_log.close()


def main():
    if os.getuid() == 0:
        raise SystemExit("Run as an ordinary user; this test never needs root.")
    if not BINARY.is_file() or not PARENT_BINARY.is_file():
        raise SystemExit("Build rediwm first, or set REDIWM_READINESS_BINARY/REDIWM_PARENT_BINARY.")
    os.umask(0o077)
    with tempfile.TemporaryDirectory(prefix="rediwm-readiness-input-") as temporary:
        root = Path(temporary)
        share = root / "share"
        sessions = share / "wayland-sessions"
        sessions.mkdir(parents=True)
        for name in ("alpha", "beta"):
            (sessions / (name + ".desktop")).write_text(
                f"[Desktop Entry]\nName={name.title()}\nExec=/usr/bin/true\nType=Application\n")
        try:
            no_input_case(root, share)
            nested_case(root, share)
        except BaseException:
            for path in root.rglob("*.log"):
                print(f"--- {path.relative_to(root)} ---\n{path.read_text(errors='replace')[-16000:]}")
            raise


if __name__ == "__main__":
    main()

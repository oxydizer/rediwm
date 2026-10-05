#!/usr/bin/env python3
"""Integration tests for rediwm-dm in unprivileged `--test` mode.

The daemon runs its real workers and PAM through `pam_start_confdir` with test
stacks: `pam_exec expose_authtok` asks a real secret question and checks the
answer, `pam_succeed_if` picks who may log in and whose session may open.
Fake greeters speak the protocol exactly like `greeter.zig` and fail on any
reply they did not ask for; one test runs the real `rediwm --greeter`.
The daemon starts with SIGPIPE ignored, as systemd does.
"""

import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
DM_BIN = ROOT / "zig-out/bin/rediwm-dm"
PASSWORD = 'p"w\\é\x08'

# Shared by every fake greeter. `recv` returns None at EOF and "TIMEOUT" when
# nothing arrived; `expect` fails the greeter on anything unexpected.
HARNESS = r'''#!/usr/bin/env python3
import json, os, signal, socket, struct, sys
TMP = {tmp!r}
PASSWORD = {password!r}
with open(TMP + "/greeter-pids.txt", "a") as f:
    f.write(str(os.getpid()) + "\n")
if os.path.exists(TMP + "/greeter-done"):
    while True:
        signal.pause()
sock = socket.socket(fileno=int(os.environ["REDIWM_GREETER_FD"]))
log = []

def send(obj):
    data = json.dumps(obj).encode()
    sock.sendall(struct.pack("=I", len(data)) + data)

def read_exact(n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            return None
        buf += chunk
    return buf

def recv(timeout=10):
    sock.settimeout(timeout)
    try:
        head = read_exact(4)
    except socket.timeout:
        return "TIMEOUT"
    if head is None:
        return None
    sock.settimeout(None)
    return json.loads(read_exact(struct.unpack("=I", head)[0]))

def expect(want, timeout=10, **fields):
    got = recv(timeout)
    log.append(got)
    ok = isinstance(got, dict) and got.get("type") == want and all(got.get(k) == v for k, v in fields.items())
    if not ok:
        finish("expected " + want + " " + repr(fields) + ", got " + repr(got))
    return got

def quiet(timeout=1.5):
    got = recv(timeout)
    if got != "TIMEOUT":
        finish("unsolicited reply " + repr(got))

def finish(error=None):
    with open(TMP + "/greeter-result.json.tmp", "w") as f:
        json.dump({{"error": error, "log": log}}, f)
    os.replace(TMP + "/greeter-result.json.tmp", TMP + "/greeter-result.json")
    open(TMP + "/greeter-done", "w").close()
    sys.exit(1 if error else 0)

def login(user, password):
    send({{"type": "login", "user": user}})
    expect("question", kind="secret")
    send({{"type": "answer", "response": password}})

'''

PAM_STACKS = {
    "rediwm-greeter": "auth required pam_permit.so\naccount required pam_permit.so\nsession required pam_permit.so\n",
    # alice and carol may log in with PASSWORD; only alice's session opens.
    "rediwm-dm": (
        "auth requisite pam_succeed_if.so quiet user in alice:carol\n"
        "auth required pam_exec.so expose_authtok quiet {check}\n"
        "auth optional pam_permit.so\n"
        "account required pam_permit.so\n"
        "session requisite pam_succeed_if.so quiet user = alice\n"
        "session required pam_permit.so\n"
    ),
    "rediwm-dm-autologin": "auth required pam_permit.so\naccount required pam_permit.so\nsession required pam_permit.so\n",
}


class Fixture:
    """A temp dir with PAM stacks, installed sessions and a running daemon."""

    def __init__(self, name, greeter_body=None, greeter_command=None, conf_extra=""):
        self.name = name
        self.dir = tempfile.TemporaryDirectory(prefix=f"rediwm-dm-{name}-")
        self.tmp = tmp = Path(self.dir.name)
        pam = tmp / "pam.d"
        pam.mkdir()
        check = tmp / "check-password"
        check.write_text(
            "#!/usr/bin/env python3\nimport sys\n"
            f"sys.exit(0 if sys.stdin.buffer.read().rstrip(b'\\0') == {PASSWORD.encode()!r} else 1)\n")
        check.chmod(0o755)
        for service, stack in PAM_STACKS.items():
            (pam / service).write_text(stack.format(check=check))

        sessions = tmp / "share/wayland-sessions"
        sessions.mkdir(parents=True)
        self.script("run-session", f"""#!/bin/sh
echo $$ > {tmp}/session.pid
env > {tmp}/session-env.txt
grep -E '^Sig(Blk|Ign)' /proc/self/status > {tmp}/session-signals.txt
date +%s%N > {tmp}/session-started.txt
while [ -f {tmp}/session-hold ]; do sleep 0.05; done
date +%s%N > {tmp}/session-ended.txt
""")
        (sessions / "rediwm.desktop").write_text(f"[Desktop Entry]\nName=RediWM Test\nExec={tmp}/run-session %U\nDesktopNames=RediWM;wlroots\n")
        (sessions / "crash.desktop").write_text(f"[Desktop Entry]\nName=Crash\nExec=sh -c \"touch {tmp}/crashed; exit 1\"\n")
        (sessions / "quoted.desktop").write_text(f"[Desktop Entry]\nName=Quoted\nExec=sh -c \"echo \\\"quoted ok\\\" > {tmp}/quoted.txt\"\n")

        if greeter_body is not None:
            greeter = self.script("greeter", HARNESS.format(tmp=str(tmp), password=PASSWORD) + greeter_body)
            greeter_command = str(greeter)
        (tmp / "dm.conf").write_text(f"vt = 1\ngreeter_user = {os.environ.get('USER', 'root')}\ngreeter_command = {greeter_command}\n{conf_extra}")

    def script(self, name, text):
        path = self.tmp / name
        path.write_text(text)
        path.chmod(0o755)
        return path

    def __enter__(self):
        self.log_path = self.tmp / "daemon.log"
        with self.log_path.open("w") as log:
            self.proc = subprocess.Popen(
                [str(DM_BIN), "--test", "--conf", str(self.tmp / "dm.conf"), "--confdir", str(self.tmp / "pam.d"),
                 "--data-dir", str(self.tmp / "share"), "--marker", str(self.tmp / "autologin-marker")],
                stdout=log, stderr=log,
                preexec_fn=lambda: signal.signal(signal.SIGPIPE, signal.SIG_IGN),
            )
        return self

    def __exit__(self, kind, value, tb):
        self.stop()
        if kind is not None:
            print(f"--- {self.name}: daemon log ---\n" + self.log_path.read_text(errors="replace"))
            result = self.tmp / "greeter-result.json"
            if result.exists():
                print("--- greeter result ---\n" + result.read_text())
        self.dir.cleanup()

    def stop(self):
        if self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=15)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait()
                raise AssertionError("rediwm-dm did not stop within 15 s of SIGTERM")

    def path(self, name):
        return self.tmp / name

    def wait(self, predicate, what, timeout=15):
        deadline = time.time() + timeout
        while time.time() < deadline:
            if predicate():
                return
            assert self.proc.poll() is None, f"rediwm-dm exited ({self.proc.returncode}) waiting for {what}"
            time.sleep(0.1)
        raise AssertionError(f"timed out waiting for {what}")

    def wait_file(self, name, timeout=15):
        self.wait(lambda: self.path(name).exists(), name, timeout)

    def greeter_starts(self):
        p = self.path("greeter-pids.txt")
        return len(p.read_text().split()) if p.exists() else 0

    def greeter_result(self):
        self.wait_file("greeter-result.json")
        result = json.loads(self.path("greeter-result.json").read_text())
        assert result["error"] is None, result
        return result


def test_login_session_and_logout():
    body = """
send({"type": "login", "user": "bob"})
expect("denied")
send({"type": "cancel"})
expect("ok")
login("alice", "wrong")
expect("denied")
send({"type": "cancel"})
expect("ok")
quiet()
login("alice", PASSWORD)
expect("ok")
send({"type": "start", "session": "rediwm"})
expect("ok")
open(TMP + "/greeter-exit-time.txt", "w").write(str(__import__("time").time_ns()))
finish()
"""
    with Fixture("login", body) as f:
        f.path("session-hold").write_text("hold")
        f.greeter_result()
        f.wait_file("session-started.txt")
        assert int(f.path("greeter-exit-time.txt").read_text()) <= int(f.path("session-started.txt").read_text())
        env = dict(line.split("=", 1) for line in f.path("session-env.txt").read_text().splitlines() if "=" in line)
        for key, want in {"XDG_SESSION_TYPE": "wayland", "XDG_SESSION_CLASS": "user", "XDG_SESSION_DESKTOP": "rediwm",
                          "XDG_SEAT": "seat0", "XDG_VTNR": "1", "XDG_CURRENT_DESKTOP": "RediWM:wlroots", "USER": "alice"}.items():
            assert env.get(key) == want, (key, env.get(key))
        assert "REDIWM_GREETER_FD" not in env, env
        # The daemon's blocked signals and systemd's ignored SIGPIPE never reach the session.
        signals = dict(line.split(":") for line in f.path("session-signals.txt").read_text().splitlines())
        assert int(signals["SigBlk"], 16) == 0, signals
        assert int(signals["SigIgn"], 16) & (1 << (signal.SIGPIPE - 1)) == 0, signals

        f.path("session-hold").unlink()
        f.wait_file("session-ended.txt")
        f.wait(lambda: f.greeter_starts() == 2, "a greeter after logout")


def test_cancel_mid_prompt():
    body = """
send({"type": "login", "user": "alice"})
expect("question", kind="secret")
send({"type": "cancel"})
expect("ok")
quiet()
login("alice", PASSWORD)
expect("ok")
finish()
"""
    with Fixture("cancel", body) as f:
        f.greeter_result()
        # The greeter left without starting a session: it is replaced.
        f.wait(lambda: f.greeter_starts() == 2, "a replacement greeter")


def test_out_of_order_request_replaces_greeter():
    body = """
send({"type": "start", "session": "rediwm"})
got = recv()
if got is not None:
    finish("expected the daemon to hang up, got " + repr(got))
finish()
"""
    with Fixture("order", body) as f:
        # The daemon may terminate the rejected greeter before it writes a
        # result. Its replacement and the rejection log are the guarantees.
        f.wait(lambda: f.greeter_starts() == 2, "a replacement greeter")
        assert "request out of order" in f.log_path.read_text()


def test_quoted_exec_runs():
    body = """
login("alice", PASSWORD)
expect("ok")
send({"type": "start", "session": "quoted"})
expect("ok")
finish()
"""
    with Fixture("quoted", body) as f:
        f.greeter_result()
        f.wait_file("quoted.txt")
        assert f.path("quoted.txt").read_text() == "quoted ok\n"
        f.wait(lambda: f.greeter_starts() == 2, "a greeter after the session")


def test_session_that_cannot_open_returns_to_greeter():
    body = """
login("carol", PASSWORD)
expect("ok")
send({"type": "start", "session": "rediwm"})
expect("ok")
finish()
"""
    with Fixture("session-fail", body) as f:
        f.greeter_result()
        f.wait(lambda: f.greeter_starts() == 2, "a greeter after the failed session")
        assert not f.path("session-started.txt").exists()
        assert "cannot open the session" in f.log_path.read_text()


def test_killed_greeter_restarted():
    body = "while True:\n    __import__('time').sleep(1)\n"
    with Fixture("killed", body) as f:
        f.wait(lambda: f.greeter_starts() == 1, "the greeter")
        os.kill(int(f.path("greeter-pids.txt").read_text().split()[0]), signal.SIGKILL)
        f.wait(lambda: f.greeter_starts() == 2, "a replacement greeter")


def test_autologin_once_and_stop_ends_session():
    body = "while True:\n    __import__('time').sleep(1)\n"
    with Fixture("autologin", body, conf_extra="autologin_user = alice\nautologin_session = rediwm\n") as f:
        f.path("session-hold").write_text("hold")
        f.wait_file("session-started.txt")
        assert f.greeter_starts() == 0 and f.path("autologin-marker").exists()
        f.path("session-hold").unlink()
        f.wait_file("session-ended.txt")
        f.wait(lambda: f.greeter_starts() == 1, "a greeter after the autologin session")

    # A second boot's worth of daemon, same marker: no autologin. And stopping
    # the daemon ends a running session instead of orphaning it.
    body = """
login("alice", PASSWORD)
expect("ok")
send({"type": "start", "session": "rediwm"})
expect("ok")
finish()
"""
    with Fixture("stop", body, conf_extra="autologin_user = alice\nautologin_session = rediwm\n") as f:
        f.path("autologin-marker").write_text("done")
        f.path("session-hold").write_text("hold")
        f.greeter_result()
        f.wait_file("session-started.txt")
        pid = int(f.path("session.pid").read_text())
        f.stop()
        assert not Path(f"/proc/{pid}").exists(), "the session outlived rediwm-dm"


def test_autologin_quick_crash_falls_back():
    body = "while True:\n    __import__('time').sleep(1)\n"
    with Fixture("crash", body, conf_extra="autologin_user = alice\nautologin_session = crash\n") as f:
        f.wait_file("crashed")
        f.wait(lambda: f.greeter_starts() == 1, "the fallback greeter")
        assert "showing the greeter" in f.log_path.read_text()


def children(pid):
    try:
        return [int(p) for p in Path(f"/proc/{pid}/task/{pid}/children").read_text().split()]
    except FileNotFoundError:
        return []


def test_real_greeter_connects():
    with tempfile.TemporaryDirectory(prefix="rediwm-dm-real-") as runtime:
        home = Path(runtime) / "home"
        home.mkdir()
        env = {
            "WLR_BACKENDS": "headless", "WLR_HEADLESS_OUTPUTS": "1", "WLR_RENDERER": "pixman", "REDIWM_SCALE": "1",
            "XDG_RUNTIME_DIR": runtime, "HOME": str(home),
            "DBUS_SYSTEM_BUS_ADDRESS": "unix:path=/nonexistent-rediwm-test-system-bus",
            "DBUS_SESSION_BUS_ADDRESS": "unix:path=/nonexistent-rediwm-test-session-bus",
        }
        command = "env " + " ".join(f"{k}={v}" for k, v in env.items()) + f" {ROOT / 'zig-out/bin/rediwm'} --greeter"
        with Fixture("real", greeter_command=command) as f:
            connected = lambda n: f.log_path.read_text(errors="replace").count("login service connected") >= n
            f.wait(lambda: connected(1), "the real greeter to adopt its daemon socket", timeout=30)
            # greeter worker -> the compositor (sh -c and env exec in place)
            greeters = [g for w in children(f.proc.pid) for g in children(w)]
            assert len(greeters) == 1, greeters
            os.kill(greeters[0], signal.SIGTERM)
            f.wait(lambda: connected(2), "a replacement real greeter", timeout=30)
            assert "panic:" not in f.log_path.read_text(errors="replace")


TESTS = [
    test_login_session_and_logout,
    test_cancel_mid_prompt,
    test_out_of_order_request_replaces_greeter,
    test_quoted_exec_runs,
    test_session_that_cannot_open_returns_to_greeter,
    test_killed_greeter_restarted,
    test_autologin_once_and_stop_ends_session,
    test_autologin_quick_crash_falls_back,
    test_real_greeter_connects,
]


def main():
    assert DM_BIN.is_file(), f"rediwm-dm binary not found at {DM_BIN}"
    only = sys.argv[1:]
    for test in TESTS:
        if only and test.__name__ not in only:
            continue
        test()
        print(f"PASS: {test.__name__}")


if __name__ == "__main__":
    main()

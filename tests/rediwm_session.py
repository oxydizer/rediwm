#!/usr/bin/env python3
"""rediwm-session's crash-restart loop.

Never runs the installed compositor: the supervisor binary is copied next to a
small fake `rediwm` that exits/signals itself on command, and the system bus
address points nowhere so no login is ever verified. Only a temp HOME is touched.
Usage: rediwm_session.py <rediwm-session binary>
"""
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile

SUPERVISOR = Path(sys.argv[1] if len(sys.argv) > 1 else Path(__file__).resolve().parents[1] / "zig-out/bin/rediwm-session")


def build_wrapper(tmp, body):
    """Returns (supervisor copy, fake compositor path)."""
    wrapper = tmp / "rediwm-session"
    shutil.copy2(SUPERVISOR, wrapper)
    fake = tmp / "rediwm"
    fake.write_text("#!/bin/sh\n" + body)
    fake.chmod(fake.stat().st_mode | stat.S_IEXEC)
    return wrapper, fake


def isolated_env(home):
    env = {**os.environ, "HOME": str(home), "DBUS_SYSTEM_BUS_ADDRESS": "unix:path=/nonexistent/rediwm-test-bus"}
    env.pop("XDG_STATE_HOME", None)
    return env


def run_wrapper(tmp, wrapper):
    home = tmp / "home"
    home.mkdir(exist_ok=True)
    result = subprocess.run([str(wrapper)], env=isolated_env(home), capture_output=True, text=True, timeout=30)
    log_path = home / ".local" / "state" / "rediwm" / "session.log"
    log = log_path.read_text() if log_path.exists() else ""
    return result.returncode, log


def count_runs(fake, word):
    return (fake.parent / f"{fake.name}.count").read_text().count(word)


def test_clean_exit_does_not_restart():
    with tempfile.TemporaryDirectory(prefix="rediwm-session-test-") as directory:
        tmp = Path(directory)
        wrapper, fake = build_wrapper(tmp, "echo ran >>\"$0.count\"\nexit 0\n")
        code, log = run_wrapper(tmp, wrapper)
        assert code == 0, (code, log)
        assert count_runs(fake, "ran") == 1, "should only run once"
        assert "restart" not in log
    print("rediwm-session: a clean exit (0) does not restart")


def test_sigterm_does_not_restart():
    with tempfile.TemporaryDirectory(prefix="rediwm-session-test-") as directory:
        tmp = Path(directory)
        wrapper, fake = build_wrapper(tmp, "echo ran >>\"$0.count\"\nkill -TERM $$\n")
        code, log = run_wrapper(tmp, wrapper)
        assert code == 143, (code, log)
        assert count_runs(fake, "ran") == 1, "should only run once"
        assert "restart" not in log
    print("rediwm-session: SIGTERM (a real logout/shutdown) does not restart")


def test_crash_restarts_then_recovers():
    with tempfile.TemporaryDirectory(prefix="rediwm-session-test-") as directory:
        tmp = Path(directory)
        counter = tmp / "count"
        # Aborts twice, then exits cleanly on the third run.
        wrapper, fake = build_wrapper(tmp, f'''
n=$(cat "{counter}" 2>/dev/null || echo 0)
n=$((n + 1))
echo "$n" >"{counter}"
echo "run $n" >>"$0.count"
if [ "$n" -lt 3 ]; then
    kill -ABRT $$
fi
exit 0
''')
        code, log = run_wrapper(tmp, wrapper)
        assert code == 0, (code, log)
        assert count_runs(fake, "run") == 3, log
        assert log.count("rediwm-session: restart") == 2, log
    print("rediwm-session: a crash (SIGABRT) restarts, and recovery stops the loop")


def test_persistent_crash_gives_up():
    with tempfile.TemporaryDirectory(prefix="rediwm-session-test-") as directory:
        tmp = Path(directory)
        wrapper, fake = build_wrapper(tmp, "echo ran >>\"$0.count\"\nkill -ABRT $$\n")
        code, log = run_wrapper(tmp, wrapper)
        assert code == 1, (code, log)
        assert count_runs(fake, "ran") == 5, "max_restarts=5"
        assert "giving up" in log, log
    print("rediwm-session: a persistent crash gives up after the bounded number of restarts")


def test_crash_while_locked_restarts_locked():
    with tempfile.TemporaryDirectory(prefix="rediwm-session-test-") as directory:
        tmp = Path(directory)
        wrapper = tmp / "rediwm-session"
        shutil.copy2(SUPERVISOR, wrapper)
        fake = tmp / "rediwm"
        # Run 1 reports a lock and aborts at once (the report is still queued
        # when the supervisor sees the exit). Run 2 unlocks, then aborts.
        # Run 3 exits cleanly. Each run records what was queued for it.
        fake.write_text(f'''#!{sys.executable}
import os, signal, socket
from pathlib import Path
runs = Path({str(tmp)!r}) / "runs"
n = len(runs.read_text().splitlines()) + 1 if runs.exists() else 1
session = socket.socket(fileno=int(os.environ["REDIWM_SESSION_FD"]))
try:
    queued = session.recv(64, socket.MSG_DONTWAIT).decode()
except BlockingIOError:
    queued = "-"
with runs.open("a") as f:
    f.write(queued + "\\n")
if n == 1:
    session.send(b"locked")
    os.kill(os.getpid(), signal.SIGABRT)
if n == 2:
    session.send(b"locked")
    session.send(b"unlocked")
    os.kill(os.getpid(), signal.SIGABRT)
''')
        fake.chmod(0o755)
        code, log = run_wrapper(tmp, wrapper)
        assert code == 0, (code, log)
        assert (tmp / "runs").read_text().splitlines() == ["-", "lock", "-"], (tmp / "runs").read_text()
    print("rediwm-session: a crash while locked restarts locked; a crash after unlocking does not")


def test_previous_log_rotated_once_per_login():
    with tempfile.TemporaryDirectory(prefix="rediwm-session-test-") as directory:
        tmp = Path(directory)
        # Stdout (unlike the "$0.count" marker above) is what the supervisor
        # redirects into session.log, so this is what rotation moves around.
        wrapper, fake = build_wrapper(tmp, 'echo "login $(cat "$0.gen" 2>/dev/null || echo 1)"\nexit 0\n')

        run_wrapper(tmp, wrapper)
        (tmp / "rediwm.gen").write_text("2")
        code, log = run_wrapper(tmp, wrapper)
        assert code == 0, (code, log)

        state_dir = tmp / "home" / ".local" / "state" / "rediwm"
        prev = (state_dir / "session.previous.log").read_text()
        assert "login 1" in prev and "login 2" not in prev, prev
        assert "login 2" in log and "login 1" not in log, log
    print("rediwm-session: session.log rotates to session.previous.log once per login")


def test_compositor_environment():
    with tempfile.TemporaryDirectory(prefix="rediwm-session-test-") as directory:
        tmp = Path(directory)
        wrapper, fake = build_wrapper(tmp, 'env >"$0.env"\nexit 0\n')
        home = tmp / "home"
        home.mkdir()
        env = isolated_env(home)
        env.update({"WAYLAND_DISPLAY": "wayland-host", "REDIWM_SESSION_PRIMARY": "1", "PATH": "/usr/bin:/bin"})
        subprocess.run([str(wrapper)], env=env, check=True, timeout=30)
        seen = dict(line.split("=", 1) for line in (tmp / "rediwm.env").read_text().splitlines() if "=" in line)
        assert seen["PATH"] == f"{tmp}:/usr/bin:/bin", seen["PATH"]
        assert seen["XDG_DATA_DIRS"].startswith(f"{tmp.parent}/share:"), seen["XDG_DATA_DIRS"]
        assert seen["XDG_CURRENT_DESKTOP"] == "rediwm" and seen["XDG_SESSION_TYPE"] == "wayland"
        assert "WAYLAND_DISPLAY" not in seen and "REDIWM_SESSION_PRIMARY" not in seen
        assert "REDIWM_LOGIN_SESSION" not in seen, "an unverified login must not claim a session"
        assert int(seen["REDIWM_SESSION_FD"]) >= 3
    print("rediwm-session: the compositor gets the session PATH/XDG environment and no host display")


if __name__ == "__main__":
    test_clean_exit_does_not_restart()
    test_sigterm_does_not_restart()
    test_crash_restarts_then_recovers()
    test_persistent_crash_gives_up()
    test_crash_while_locked_restarts_locked()
    test_previous_log_rotated_once_per_login()
    test_compositor_environment()

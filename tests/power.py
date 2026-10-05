#!/usr/bin/env python3
"""Power commands against a harmless systemctl and private mock logind.

Runs on a private dbus-run-session, pointed at by DBUS_SYSTEM_BUS_ADDRESS so
the compositor's power manager never reaches the host's real system bus
(plan-power-session.md stages 1 and 2). Every test prepends a fake systemctl
to PATH so no test can invoke host reboot/poweroff. Covers:
- Poweroff/reboot command arguments, completion, refusal, missing executable,
  duplicate rejection, and retries without logging out.
- Explicit suspend requests invoking SuspendWithFlags with
  SD_LOGIND_ROOT_CHECK_INHIBITORS and interactive authorization allowed.
- Fallback to legacy Suspend when WithFlags is unsupported or
  returns UnknownMethod.
- Automatic suspend requests never prompting or passing interactive authorization flags,
  and stopping immediately on "challenge" capability.
- Inhibitor inspection via ListInhibitors on OperationInhibited/BlockedByInhibitorLock,
  reporting the inhibiting application and reason without quitting.
- Policy denial (e.g. multiple sessions / AccessDenied) and general action refusal
  logged and reported without quitting.
- Only one request pending at a time.
"""
import json
import os
from pathlib import Path
import re
import select
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
from ipc_client import IPCClient, IPCError, spawn_compositor, stop_process

FAKE_LOGIND = r'''
import json, os, sys, warnings
warnings.simplefilter("ignore", DeprecationWarning)
from gi.repository import Gio, GLib

support_with_flags = os.environ.get("FAKE_LOGIND_SUPPORT_WITH_FLAGS", "yes") != "no"

if support_with_flags:
    XML = ("<node><interface name='org.freedesktop.login1.Manager'>"
           "<method name='CanPowerOff'><arg type='s' direction='out'/></method>"
           "<method name='CanReboot'><arg type='s' direction='out'/></method>"
           "<method name='CanSuspend'><arg type='s' direction='out'/></method>"
           "<method name='PowerOff'><arg type='b' direction='in'/></method>"
           "<method name='Reboot'><arg type='b' direction='in'/></method>"
           "<method name='Suspend'><arg type='b' direction='in'/></method>"
           "<method name='PowerOffWithFlags'><arg type='t' direction='in'/></method>"
           "<method name='RebootWithFlags'><arg type='t' direction='in'/></method>"
           "<method name='SuspendWithFlags'><arg type='t' direction='in'/></method>"
           "<method name='ListInhibitors'><arg type='a(ssssuu)' direction='out'/></method>"
           "<signal name='PrepareForSleep'><arg type='b'/></signal>"
           "<signal name='PrepareForShutdown'><arg type='b'/></signal>"
           "</interface></node>")
else:
    XML = ("<node><interface name='org.freedesktop.login1.Manager'>"
           "<method name='CanPowerOff'><arg type='s' direction='out'/></method>"
           "<method name='CanReboot'><arg type='s' direction='out'/></method>"
           "<method name='CanSuspend'><arg type='s' direction='out'/></method>"
           "<method name='PowerOff'><arg type='b' direction='in'/></method>"
           "<method name='Reboot'><arg type='b' direction='in'/></method>"
           "<method name='Suspend'><arg type='b' direction='in'/></method>"
           "<signal name='PrepareForSleep'><arg type='b'/></signal>"
           "<signal name='PrepareForShutdown'><arg type='b'/></signal>"
           "</interface></node>")

XML = XML.replace("</interface>", "<method name='Inhibit'>"
                  "<arg type='s' direction='in'/><arg type='s' direction='in'/>"
                  "<arg type='s' direction='in'/><arg type='s' direction='in'/>"
                  "<arg type='h' direction='out'/></method>"
                  "<method name='GetSession'><arg type='s' direction='in'/><arg type='o' direction='out'/></method>"
                  "</interface>")
SESSION_XML = ("<node><interface name='org.freedesktop.login1.Session'>"
               "<method name='SetLockedHint'><arg type='b' direction='in'/></method>"
               "<signal name='Lock'/><signal name='Unlock'/>"
               "</interface></node>")
SESSION_PATH = "/org/freedesktop/login1/session/_31"
conn = Gio.bus_get_sync(Gio.BusType.SESSION)

unknown_method_once = os.environ.get("FAKE_LOGIND_UNKNOWN_METHOD_ONCE", "no") == "yes"

def call(c, sender, path, iface, method, params, invocation):
    global unknown_method_once
    if method == "Inhibit":
        what, who, why, mode = params.unpack()
        print(json.dumps({"method": method, "what": what, "mode": mode}), flush=True)
        if os.environ.get("FAKE_LOGIND_INHIBIT_DENIED"):
            invocation.return_dbus_error("org.freedesktop.DBus.Error.AccessDenied", "denied")
            return
        read_fd, write_fd = os.pipe2(os.O_CLOEXEC | os.O_NONBLOCK)
        def released(fd, condition):
            os.close(read_fd)
            print(json.dumps({"inhibitor_released": True}), flush=True)
            return False
        GLib.io_add_watch(read_fd, GLib.IO_HUP, released)
        def respond_inhibit():
            descriptors = Gio.UnixFDList.new()
            index = descriptors.append(write_fd)
            os.close(write_fd)
            invocation.return_value_with_unix_fd_list(GLib.Variant("(h)", (index,)), descriptors)
            return False
        delay = int(os.environ.get("FAKE_LOGIND_INHIBIT_DELAY_MS", "0"))
        if delay:
            GLib.timeout_add(delay, respond_inhibit)
        else:
            respond_inhibit()
    elif method == "GetSession":
        print(json.dumps({"method": method, "id": params.unpack()[0]}), flush=True)
        invocation.return_value(GLib.Variant("(o)", (SESSION_PATH,)))
    elif method == "SetLockedHint":
        print(json.dumps({"method": method, "locked": params.unpack()[0]}), flush=True)
        invocation.return_value(None)
    elif method == "ListInhibitors":
        raw = os.environ.get("FAKE_LOGIND_INHIBITORS", "[]")
        inhs = json.loads(raw)
        items = [(i["what"], i["who"], i["why"], i["mode"], int(i["uid"]), int(i["pid"])) for i in inhs]
        print(json.dumps({"method": "ListInhibitors", "count": len(items)}), flush=True)
        invocation.return_value(GLib.Variant("(a(ssssuu))", (items,)))
    elif method.startswith("Can"):
        print(json.dumps({"method": method}), flush=True)
        cap = os.environ.get("FAKE_LOGIND_CAP", "yes")
        delay = int(os.environ.get("FAKE_LOGIND_DELAY_MS", "0"))
        def respond():
            invocation.return_value(GLib.Variant("(s)", (cap,)))
            return False
        if delay:
            GLib.timeout_add(delay, respond)
        else:
            respond()
    else:
        msg_flags = invocation.get_message().get_flags()
        allow_interactive = bool(msg_flags & Gio.DBusMessageFlags.ALLOW_INTERACTIVE_AUTHORIZATION)
        payload = {"method": method, "allow_interactive": allow_interactive}
        if method.endswith("WithFlags"):
            payload["flags"] = params.unpack()[0]
        else:
            payload["interactive"] = params.unpack()[0]
        print(json.dumps(payload), flush=True)

        if unknown_method_once and method.endswith("WithFlags"):
            unknown_method_once = False
            invocation.return_dbus_error("org.freedesktop.DBus.Error.UnknownMethod", "unknown method")
            return

        err = os.environ.get("FAKE_LOGIND_ERROR", "")
        if err:
            invocation.return_dbus_error(err, "denied by test policy")
        else:
            invocation.return_value(None)

def on_stdin(channel, cond):
    line = sys.stdin.readline()
    if not line:
        return True
    try:
        req = json.loads(line)
        if req.get("action") == "signal":
            sig_name = req["name"]
            sig_val = req.get("value")
            msg = Gio.DBusMessage.new_signal(req.get("path", "/org/freedesktop/login1"),
                                             req.get("interface", "org.freedesktop.login1.Manager"), sig_name)
            if sig_val is not None:
                msg.set_body(GLib.Variant("(b)", (sig_val,)))
            conn.send_message(msg, Gio.DBusSendMessageFlags.NONE)
            conn.flush_sync()
            print(json.dumps({"signal_sent": sig_name, "value": sig_val}), flush=True)
    except Exception as e:
        print(json.dumps({"stdin_error": str(e)}), flush=True)
    return True

GLib.io_add_watch(sys.stdin.fileno(), GLib.IO_IN, on_stdin)

conn.register_object("/org/freedesktop/login1", Gio.DBusNodeInfo.new_for_xml(XML).interfaces[0], call, None, None)
conn.register_object(SESSION_PATH, Gio.DBusNodeInfo.new_for_xml(SESSION_XML).interfaces[0], call, None, None)
Gio.bus_own_name_on_connection(conn, "org.freedesktop.login1", Gio.BusNameOwnerFlags.NONE,
                               lambda *_: print("ready", flush=True), None)
GLib.MainLoop().run()
'''

FAKE_SYSTEMCTL = r'''import json, os, sys, time
from pathlib import Path
tmp = Path(os.environ["FAKE_SYSTEMCTL_DIR"])
config = tmp / "systemctl-config.json"
options = json.loads(config.read_text()) if config.exists() else {}
with (tmp / "systemctl-calls.jsonl").open("a") as calls:
    calls.write(json.dumps(sys.argv[1:]) + "\n")
time.sleep(options.get("delay", 0))
if options.get("error"):
    print(options["error"], file=sys.stderr)
sys.exit(options.get("exit", 0))
'''

CONFIG = """[compositor]
xwayland = false
lock_on_suspend = false
[keybinds]
"F1" = "poweroff"
"F2" = "reboot"
"F3" = "suspend"
"F4" = "poweroff_auto"
"F5" = "reboot_auto"
"F6" = "suspend_auto"
"F7" = "quit"
"""

KEYCODE = {
    "poweroff": 59,
    "reboot": 60,
    "suspend": 61,
    "poweroff_auto": 62,
    "reboot_auto": 63,
    "suspend_auto": 64,
    "quit": 65,
}

CAN_METHOD = {
    "poweroff": "CanPowerOff",
    "reboot": "CanReboot",
    "suspend": "CanSuspend",
    "poweroff_auto": "CanPowerOff",
    "reboot_auto": "CanReboot",
    "suspend_auto": "CanSuspend",
}

ANSI_RE = re.compile(r'\x1b\[[0-9;]*[mK]')


def wait_for(predicate, description, timeout=5.0, interval=0.05):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = predicate()
        if result:
            return result
        time.sleep(interval)
    raise TimeoutError(f"Timed out waiting for: {description}")


def read_line(fake, timeout=5):
    assert select.select([fake.stdout], [], [], timeout)[0], "no output from fake logind"
    line = fake.stdout.readline()
    assert line, "fake logind exited"
    return json.loads(line)


def start_fake(env_extra):
    fake = subprocess.Popen([sys.executable, "-c", FAKE_LOGIND], stdout=subprocess.PIPE, stdin=subprocess.PIPE, text=True,
                             env={**os.environ, **env_extra})
    assert select.select([fake.stdout], [], [], 5)[0], "fake logind did not start"
    assert fake.stdout.readline().strip() == "ready"
    return fake


def emit_signal(fake, name, value):
    fake.stdin.write(json.dumps({"action": "signal", "name": name, "value": value}) + "\n")
    fake.stdin.flush()
    res = read_line(fake)
    assert res.get("signal_sent") == name, f"unexpected response: {res}"
    assert res.get("value") == value


class FakeLines:
    """Reads the fake's lines straight off its pipe. Lines that arrive
    together would otherwise sit in the stream's buffer, where select()
    (see read_line) cannot see them."""

    def __init__(self, fake):
        self.fake = fake
        self.pending = b""

    def next(self, timeout=5):
        deadline = time.monotonic() + timeout
        fd = self.fake.stdout.fileno()
        while b"\n" not in self.pending:
            remaining = deadline - time.monotonic()
            assert remaining > 0 and select.select([fd], [], [], remaining)[0], "no output from fake logind"
            chunk = os.read(fd, 4096)
            assert chunk, "fake logind exited"
            self.pending += chunk
        line, self.pending = self.pending.split(b"\n", 1)
        return json.loads(line)

    def signal(self, name, value, **where):
        self.fake.stdin.write(json.dumps({"action": "signal", "name": name, "value": value, **where}) + "\n")
        self.fake.stdin.flush()
        assert self.next().get("signal_sent") == name


def drain_capability_probe(fake):
    """PowerMenu.create() proactively queries CanPowerOff/CanReboot/CanSuspend
    (power_menu.zig calls Manager.probeCapabilities(), which queries in that
    fixed order) so the menu can show Restart/Suspend/Power Off as disabled
    before the user ever tries one. Every test that opens the power menu
    against the fake logind must consume these three calls before reading
    anything else off `fake`, or an unrelated read_line() picks one up.

    All three calls land within about a millisecond of each other, in one
    kernel-level read. read_line()'s select()-then-readline() (needed
    elsewhere, where calls are spaced out by real compositor work) is wrong
    here: readline()'s internal buffering can pull all three lines out of the
    pipe on the first call, so a select() before the second/third read finds
    the fd already drained and times out even though readline() itself would
    return instantly. Gate on select() once up front instead, then read the
    three lines straight off the buffer it already filled."""
    assert select.select([fake.stdout], [], [], 5)[0], "no output from fake logind"
    for expected in ("CanPowerOff", "CanReboot", "CanSuspend"):
        line = fake.stdout.readline()
        assert line, "fake logind exited"
        assert json.loads(line) == {"method": expected}


def is_pid_running(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def spawn(tmp, system_bus_address, config=CONFIG, env_extra=None):
    # Every compositor in this suite gets a harmless systemctl, even in tests
    # intended to exercise only D-Bus. Never fall through to the host command.
    bin_dir = tmp / "bin"
    bin_dir.mkdir(exist_ok=True)
    command = bin_dir / "systemctl"
    command.write_text("#!/usr/bin/python3\n" + FAKE_SYSTEMCTL)
    command.chmod(0o755)
    return spawn_compositor(tmp, config_content=config, env_extra={
        "PATH": str(bin_dir) + os.pathsep + os.environ.get("PATH", ""),
        "FAKE_SYSTEMCTL_DIR": str(tmp),
        "DBUS_SESSION_BUS_ADDRESS": "",
        "DBUS_SYSTEM_BUS_ADDRESS": system_bus_address,
        **(env_extra or {}),
    })


def log_text(tmp):
    return ANSI_RE.sub('', (tmp / "compositor.log").read_text())


def press(ipc, kind):
    ipc.key_down_up(KEYCODE[kind])


def test_normal_request_calls_with_flags_and_checks_inhibitors(system_bus_address):
    """With modern logind, explicit suspend calls SuspendWithFlags with
    SD_LOGIND_ROOT_CHECK_INHIBITORS (1 << 0) set, never SD_LOGIND_SKIP_INHIBITORS
    (1 << 4), and interactive authorization allowed."""
    with tempfile.TemporaryDirectory(prefix="rediwm-power-test-") as directory:
        tmp = Path(directory)
        fake = start_fake({"FAKE_LOGIND_CAP": "yes"})
        try:
            process, log = spawn(tmp, system_bus_address)
            try:
                with IPCClient(tmp, timeout=15) as ipc:
                    ipc.wait_for("wallpaper_presented", timeout_ms=10000)
                    press(ipc, "suspend")
                    assert read_line(fake) == {"method": "CanSuspend"}
                    call = read_line(fake)
                    assert call["method"] == "SuspendWithFlags"
                    assert call["flags"] == 1, f"expected SD_LOGIND_ROOT_CHECK_INHIBITORS (1), got {call['flags']}"
                    assert (call["flags"] & (1 << 4)) == 0, "SD_LOGIND_SKIP_INHIBITORS must never be set"
                    assert call["allow_interactive"] is True
                    wait_for(lambda: "info(power): Suspend requested via logind" in log_text(tmp),
                             "success log line")
                    assert process.poll() is None, log_text(tmp)
            finally:
                stop_process(process)
                log.close()
        finally:
            fake.terminate()
            fake.wait(timeout=3)
    print("power: explicit request calls WithFlags with SD_LOGIND_ROOT_CHECK_INHIBITORS and interactive auth allowed")


def test_systemctl_power_commands():
    # No logind connection is needed in the compositor to launch systemctl.
    unavailable_bus = "unix:path=/nonexistent-rediwm-power-test-bus"
    for action in ("poweroff", "reboot", "poweroff_auto", "reboot_auto"):
        with tempfile.TemporaryDirectory(prefix="rediwm-systemctl-") as directory:
            tmp = Path(directory)
            (tmp / "systemctl-config.json").write_text(json.dumps({"delay": 0.4}))
            process, log = spawn(tmp, unavailable_bus)
            try:
                with IPCClient(tmp, timeout=15) as ipc:
                    ipc.wait_for("wallpaper_presented", timeout_ms=10000)
                    press(ipc, action)
                    calls = tmp / "systemctl-calls.jsonl"
                    wait_for(lambda: calls.exists() and calls.stat().st_size > 0, "systemctl invoked")
                    expected = [action.removesuffix("_auto")]
                    if action.endswith("_auto"):
                        expected.append("--no-ask-password")
                    assert json.loads(calls.read_text()) == expected
                    press(ipc, "suspend")
                    wait_for(lambda: "is already pending" in log_text(tmp), "duplicate rejected")
                    wait_for(lambda: "requested via systemctl" in log_text(tmp), "command reaped by SIGCHLD")
                    assert len(calls.read_text().splitlines()) == 1
                    assert process.poll() is None, log_text(tmp)
                    assert "terminating compositor session" not in log_text(tmp)
                    assert "requested via logind" not in log_text(tmp)
            finally:
                stop_process(process)
                log.close()
    print("power: poweroff/reboot use systemctl directly, without force flags or early logout")


def test_systemctl_failure_and_retry():
    with tempfile.TemporaryDirectory(prefix="rediwm-systemctl-failure-") as directory:
        tmp = Path(directory)
        options = tmp / "systemctl-config.json"
        options.write_text(json.dumps({"exit": 1, "error": "Shutdown inhibited by test backup"}))
        process, log = spawn(tmp, "unix:path=/nonexistent-rediwm-power-test-bus")
        try:
            with IPCClient(tmp, timeout=15) as ipc:
                ipc.wait_for("wallpaper_presented", timeout_ms=10000)
                press(ipc, "poweroff")
                wait_for(lambda: "systemctl failed" in log_text(tmp), "failure reported")
                assert "Shutdown inhibited by test backup" in log_text(tmp)
                assert process.poll() is None
                options.write_text("{}")
                press(ipc, "reboot")
                wait_for(lambda: "Restart requested via systemctl" in log_text(tmp), "retry succeeds")
                assert process.poll() is None
        finally:
            stop_process(process)
            log.close()
    print("power: systemctl refusal preserves the session and allows a later retry")


def test_systemctl_missing():
    with tempfile.TemporaryDirectory(prefix="rediwm-systemctl-missing-") as directory:
        tmp = Path(directory)
        empty = tmp / "empty"
        empty.mkdir()
        process, log = spawn(tmp, "unix:path=/nonexistent-rediwm-power-test-bus",
                             env_extra={"PATH": str(empty)})
        try:
            with IPCClient(tmp, timeout=15) as ipc:
                ipc.wait_for("wallpaper_presented", timeout_ms=10000)
                press(ipc, "poweroff")
                wait_for(lambda: "Could not start the power command" in log_text(tmp), "spawn failure reported")
                press(ipc, "reboot")
                wait_for(lambda: "Restart: Could not start the power command" in log_text(tmp), "retry after spawn failure")
                assert process.poll() is None
        finally:
            stop_process(process)
            log.close()
    print("power: missing systemctl reports failure without logging out")


def test_legacy_fallback_when_with_flags_unsupported(system_bus_address):
    """When logind does not expose WithFlags in introspection, rediwm falls back
    to calling legacy Suspend(interactive=True)."""
    with tempfile.TemporaryDirectory(prefix="rediwm-power-test-") as directory:
        tmp = Path(directory)
        fake = start_fake({"FAKE_LOGIND_SUPPORT_WITH_FLAGS": "no", "FAKE_LOGIND_CAP": "yes"})
        try:
            process, log = spawn(tmp, system_bus_address)
            try:
                with IPCClient(tmp, timeout=15) as ipc:
                    ipc.wait_for("wallpaper_presented", timeout_ms=10000)
                    press(ipc, "suspend")
                    assert read_line(fake) == {"method": "CanSuspend"}
                    call = read_line(fake)
                    assert call == {"method": "Suspend", "interactive": True, "allow_interactive": True}
                    wait_for(lambda: "info(power): Suspend requested via logind" in log_text(tmp),
                             "success log line")
                    assert process.poll() is None, log_text(tmp)
            finally:
                stop_process(process)
                log.close()
        finally:
            fake.terminate()
            fake.wait(timeout=3)
    print("power: legacy fallback uses Suspend(b) when WithFlags is not in introspected XML")


def test_legacy_fallback_on_unknown_method_error(system_bus_address):
    """When WithFlags method call fails with UnknownMethod, rediwm logs fallback
    and immediately invokes the legacy method."""
    with tempfile.TemporaryDirectory(prefix="rediwm-power-test-") as directory:
        tmp = Path(directory)
        fake = start_fake({"FAKE_LOGIND_CAP": "yes", "FAKE_LOGIND_UNKNOWN_METHOD_ONCE": "yes"})
        try:
            process, log = spawn(tmp, system_bus_address)
            try:
                with IPCClient(tmp, timeout=15) as ipc:
                    ipc.wait_for("wallpaper_presented", timeout_ms=10000)
                    press(ipc, "suspend")
                    assert read_line(fake) == {"method": "CanSuspend"}
                    call1 = read_line(fake)
                    assert call1["method"] == "SuspendWithFlags"
                    call2 = read_line(fake)
                    assert call2 == {"method": "Suspend", "interactive": True, "allow_interactive": True}
                    wait_for(lambda: "WithFlags method not found; falling back to legacy method" in log_text(tmp),
                             "fallback log line")
                    wait_for(lambda: "info(power): Suspend requested via logind" in log_text(tmp),
                             "success log line")
                    assert process.poll() is None, log_text(tmp)
            finally:
                stop_process(process)
                log.close()
        finally:
            fake.terminate()
            fake.wait(timeout=3)
    print("power: UnknownMethod on WithFlags triggers immediate legacy fallback")


def test_challenge_still_proceeds_for_explicit_request(system_bus_address):
    """"challenge" capability allows explicit requests to proceed with interactive
    authorization allowed."""
    with tempfile.TemporaryDirectory(prefix="rediwm-power-test-") as directory:
        tmp = Path(directory)
        fake = start_fake({"FAKE_LOGIND_CAP": "challenge"})
        try:
            process, log = spawn(tmp, system_bus_address)
            try:
                with IPCClient(tmp, timeout=15) as ipc:
                    ipc.wait_for("wallpaper_presented", timeout_ms=10000)
                    press(ipc, "suspend")
                    assert read_line(fake) == {"method": "CanSuspend"}
                    call = read_line(fake)
                    assert call["method"] == "SuspendWithFlags"
                    assert call["allow_interactive"] is True
                    wait_for(lambda: "info(power): Suspend requested via logind" in log_text(tmp),
                             "success log line")
                    assert process.poll() is None, log_text(tmp)
            finally:
                stop_process(process)
                log.close()
        finally:
            fake.terminate()
            fake.wait(timeout=3)
    print("power: \"challenge\" capability still proceeds for explicit user request")


def test_automatic_request_stops_on_challenge_without_prompting(system_bus_address):
    """Automatic requests (e.g. idle timeout / suspend_auto) must never open
    an authentication prompt or call the action method when capability is "challenge"."""
    with tempfile.TemporaryDirectory(prefix="rediwm-power-test-") as directory:
        tmp = Path(directory)
        fake = start_fake({"FAKE_LOGIND_CAP": "challenge"})
        try:
            process, log = spawn(tmp, system_bus_address)
            try:
                with IPCClient(tmp, timeout=15) as ipc:
                    ipc.wait_for("wallpaper_presented", timeout_ms=10000)
                    press(ipc, "suspend_auto")
                    assert read_line(fake) == {"method": "CanSuspend"}
                    wait_for(lambda: "warning(power): Suspend: automatic request denied, interactive authorization required" in log_text(tmp),
                             "automatic denied log line")
                    # No action method was ever called!
                    assert select.select([fake.stdout], [], [], 0.3)[0] == [], \
                        "SuspendWithFlags must not be called for automatic request when capability is 'challenge'"
                    assert process.poll() is None, log_text(tmp)
            finally:
                stop_process(process)
                log.close()
        finally:
            fake.terminate()
            fake.wait(timeout=3)
    print("power: automatic request stops on \"challenge\" capability without prompting")


def test_automatic_request_omits_interactive_auth_flag(system_bus_address):
    """Automatic requests must omit ALLOW_INTERACTIVE_AUTHORIZATION D-Bus header flag."""
    with tempfile.TemporaryDirectory(prefix="rediwm-power-test-") as directory:
        tmp = Path(directory)
        fake = start_fake({"FAKE_LOGIND_CAP": "yes"})
        try:
            process, log = spawn(tmp, system_bus_address)
            try:
                with IPCClient(tmp, timeout=15) as ipc:
                    ipc.wait_for("wallpaper_presented", timeout_ms=10000)
                    press(ipc, "suspend_auto")
                    assert read_line(fake) == {"method": "CanSuspend"}
                    call = read_line(fake)
                    assert call["method"] == "SuspendWithFlags"
                    assert call["flags"] == 1
                    assert call["allow_interactive"] is False, "automatic request must not set ALLOW_INTERACTIVE_AUTHORIZATION"
                    wait_for(lambda: "info(power): Suspend requested via logind" in log_text(tmp),
                             "success log line")
                    assert process.poll() is None, log_text(tmp)
            finally:
                stop_process(process)
                log.close()
        finally:
            fake.terminate()
            fake.wait(timeout=3)
    print("power: automatic request omits ALLOW_INTERACTIVE_AUTHORIZATION flag")


def test_automatic_request_reports_auth_required_without_crashing(system_bus_address):
    """When an automatic request gets InteractiveAuthorizationRequired from logind/polkit,
    it logs and reports without quitting or prompt loops."""
    with tempfile.TemporaryDirectory(prefix="rediwm-power-test-") as directory:
        tmp = Path(directory)
        fake = start_fake({"FAKE_LOGIND_CAP": "yes",
                           "FAKE_LOGIND_ERROR": "org.freedesktop.DBus.Error.InteractiveAuthorizationRequired"})
        try:
            process, log = spawn(tmp, system_bus_address)
            try:
                with IPCClient(tmp, timeout=15) as ipc:
                    ipc.wait_for("wallpaper_presented", timeout_ms=10000)
                    press(ipc, "suspend_auto")
                    assert read_line(fake) == {"method": "CanSuspend"}
                    call = read_line(fake)
                    assert call["method"] == "SuspendWithFlags"
                    assert call["allow_interactive"] is False
                    wait_for(lambda: "warning(power): Suspend: interactive authorization required" in log_text(tmp),
                             "auth required logged")
                    assert process.poll() is None, log_text(tmp)
            finally:
                stop_process(process)
                log.close()
        finally:
            fake.terminate()
            fake.wait(timeout=3)
    print("power: automatic request handles InteractiveAuthorizationRequired cleanly")


def test_inhibitor_blocks_action_and_reports_who_and_why(system_bus_address):
    """When logind returns OperationInhibited, rediwm queries ListInhibitors and
    logs/notifies the inhibiting application and reason without quitting."""
    with tempfile.TemporaryDirectory(prefix="rediwm-power-test-") as directory:
        tmp = Path(directory)
        inhibitors = [
            {"what": "shutdown:sleep", "who": "PackageKit", "why": "Installing system updates",
             "mode": "block", "uid": 0, "pid": 1234}
        ]
        fake = start_fake({
            "FAKE_LOGIND_CAP": "yes",
            "FAKE_LOGIND_ERROR": "org.freedesktop.login1.OperationInhibited",
            "FAKE_LOGIND_INHIBITORS": json.dumps(inhibitors),
        })
        try:
            process, log = spawn(tmp, system_bus_address)
            try:
                with IPCClient(tmp, timeout=15) as ipc:
                    ipc.wait_for("wallpaper_presented", timeout_ms=10000)
                    press(ipc, "suspend")
                    assert read_line(fake) == {"method": "CanSuspend"}
                    assert read_line(fake) == {"method": "SuspendWithFlags", "flags": 1, "allow_interactive": True}
                    assert read_line(fake) == {"method": "ListInhibitors", "count": 1}
                    wait_for(lambda: "warning(power): Suspend: blocked by inhibitor from 'PackageKit' (pid 1234, uid 0): Installing system updates" in log_text(tmp),
                             "inhibitor reason logged")
                    assert process.poll() is None, log_text(tmp)
            finally:
                stop_process(process)
                log.close()
        finally:
            fake.terminate()
            fake.wait(timeout=3)
    print("power: OperationInhibited inspects ListInhibitors and logs blocker details")


def test_inhibitor_without_list_inhibitors_or_unmatched(system_bus_address):
    """When ListInhibitors is unavailable or returns no matching inhibitor,
    rediwm reports generic inhibitor lock block without crashing."""
    with tempfile.TemporaryDirectory(prefix="rediwm-power-test-") as directory:
        tmp = Path(directory)
        fake = start_fake({
            "FAKE_LOGIND_SUPPORT_WITH_FLAGS": "no",
            "FAKE_LOGIND_CAP": "yes",
            "FAKE_LOGIND_ERROR": "org.freedesktop.login1.BlockedByInhibitorLock",
        })
        try:
            process, log = spawn(tmp, system_bus_address)
            try:
                with IPCClient(tmp, timeout=15) as ipc:
                    ipc.wait_for("wallpaper_presented", timeout_ms=10000)
                    press(ipc, "suspend")
                    assert read_line(fake) == {"method": "CanSuspend"}
                    assert read_line(fake) == {"method": "Suspend", "interactive": True, "allow_interactive": True}
                    wait_for(lambda: "warning(power): Suspend: blocked by an active inhibitor lock" in log_text(tmp),
                             "generic inhibitor lock logged")
                    assert process.poll() is None, log_text(tmp)
            finally:
                stop_process(process)
                log.close()
        finally:
            fake.terminate()
            fake.wait(timeout=3)
    print("power: BlockedByInhibitorLock logs generic active inhibitor message without crashing")


def test_denied_and_unavailable_never_call_the_action(system_bus_address):
    """"no" and "na" both stop before the action method is ever called, and
    are reported as distinct reasons."""
    for cap, kind, reason in (("no", "suspend", "denied by system policy"),
                               ("na", "suspend", "not available on this system")):
        with tempfile.TemporaryDirectory(prefix="rediwm-power-test-") as directory:
            tmp = Path(directory)
            fake = start_fake({"FAKE_LOGIND_CAP": cap})
            try:
                process, log = spawn(tmp, system_bus_address)
                try:
                    with IPCClient(tmp, timeout=15) as ipc:
                        ipc.wait_for("wallpaper_presented", timeout_ms=10000)
                        press(ipc, kind)
                        assert read_line(fake) == {"method": CAN_METHOD[kind]}
                        wait_for(lambda: reason in log_text(tmp), f"{reason!r} logged")
                        assert select.select([fake.stdout], [], [], 0.3)[0] == [], \
                            f"{kind} action must not be called when capability is {cap!r}"
                        assert process.poll() is None, log_text(tmp)
                finally:
                    stop_process(process)
                    log.close()
            finally:
                fake.terminate()
                fake.wait(timeout=3)
    print("power: \"no\"/\"na\" capability values are denied/unavailable without calling the action")


def test_policy_denial_for_multiple_sessions_reported_without_terminating(system_bus_address):
    """When an action is denied by system policy (e.g. multiple sessions active / AccessDenied),
    it is logged and reported, not crashing or quitting the compositor."""
    with tempfile.TemporaryDirectory(prefix="rediwm-power-test-") as directory:
        tmp = Path(directory)
        fake = start_fake({"FAKE_LOGIND_CAP": "yes", "FAKE_LOGIND_ERROR": "org.freedesktop.DBus.Error.AccessDenied"})
        try:
            process, log = spawn(tmp, system_bus_address)
            try:
                with IPCClient(tmp, timeout=15) as ipc:
                    ipc.wait_for("wallpaper_presented", timeout_ms=10000)
                    press(ipc, "suspend")
                    assert read_line(fake) == {"method": "CanSuspend"}
                    call = read_line(fake)
                    assert call["method"] == "SuspendWithFlags"
                    wait_for(lambda: "warning(power): Suspend: denied by system policy (org.freedesktop.DBus.Error.AccessDenied)" in log_text(tmp),
                             "policy denial logged")
                    assert process.poll() is None, log_text(tmp)
            finally:
                stop_process(process)
                log.close()
        finally:
            fake.terminate()
            fake.wait(timeout=3)
    print("power: policy denial (AccessDenied) is logged and reported, compositor keeps running")


def test_action_refusal_general_reported_without_terminating(system_bus_address):
    """General action refusal (e.g. DBus.Error.Failed) is logged and reported without quitting."""
    with tempfile.TemporaryDirectory(prefix="rediwm-power-test-") as directory:
        tmp = Path(directory)
        fake = start_fake({"FAKE_LOGIND_CAP": "yes", "FAKE_LOGIND_ERROR": "org.freedesktop.DBus.Error.Failed"})
        try:
            process, log = spawn(tmp, system_bus_address)
            try:
                with IPCClient(tmp, timeout=15) as ipc:
                    ipc.wait_for("wallpaper_presented", timeout_ms=10000)
                    press(ipc, "suspend")
                    assert read_line(fake) == {"method": "CanSuspend"}
                    call = read_line(fake)
                    assert call["method"] == "SuspendWithFlags"
                    wait_for(lambda: "warning(power): Suspend: Logind refused the request. (org.freedesktop.DBus.Error.Failed)" in log_text(tmp),
                             "general refusal logged")
                    assert process.poll() is None, log_text(tmp)
            finally:
                stop_process(process)
                log.close()
        finally:
            fake.terminate()
            fake.wait(timeout=3)
    print("power: general refusal (Failed) is logged and reported, compositor keeps running")


def test_only_one_request_is_pending_at_a_time(system_bus_address):
    """A second explicit action while one is still waiting on logind is
    rejected outright, never queued, and never reaches the bus."""
    with tempfile.TemporaryDirectory(prefix="rediwm-power-test-") as directory:
        tmp = Path(directory)
        fake = start_fake({"FAKE_LOGIND_CAP": "yes", "FAKE_LOGIND_DELAY_MS": "400"})
        try:
            process, log = spawn(tmp, system_bus_address)
            try:
                with IPCClient(tmp, timeout=15) as ipc:
                    ipc.wait_for("wallpaper_presented", timeout_ms=10000)
                    press(ipc, "suspend")
                    assert read_line(fake) == {"method": "CanSuspend"}
                    # Fired while the first request is still waiting on the
                    # (delayed) capability reply.
                    press(ipc, "suspend")
                    wait_for(lambda: "Suspend: rejected, Suspend is already pending" in log_text(tmp),
                             "busy rejection logged")
                    call = read_line(fake)
                    assert call["method"] == "SuspendWithFlags"
                    wait_for(lambda: "info(power): Suspend requested via logind" in log_text(tmp),
                             "first request still completes")
                    assert process.poll() is None, log_text(tmp)
            finally:
                stop_process(process)
                log.close()
        finally:
            fake.terminate()
            fake.wait(timeout=3)
    print("power: a second request while one is pending is rejected, not queued")


def test_prepare_for_sleep_deactivates_and_restores_session(system_bus_address):
    """PrepareForSleep(True) closes menus and deactivates interactive grabs;
    PrepareForSleep(False) reactivates session and schedules redraw."""
    with tempfile.TemporaryDirectory(prefix="rediwm-power-test-") as directory:
        tmp = Path(directory)
        fake = start_fake({"FAKE_LOGIND_CAP": "yes"})
        try:
            process, log = spawn(tmp, system_bus_address)
            try:
                with IPCClient(tmp, timeout=15) as ipc:
                    ipc.wait_for("wallpaper_presented", timeout_ms=10000)
                    ipc.open_power_menu()
                    ipc.wait_for("power_menu_opened", timeout_ms=5000)
                    drain_capability_probe(fake)

                    emit_signal(fake, "PrepareForSleep", True)

                    ipc.wait_for("power_menu_closed", timeout_ms=5000)
                    wait_for(lambda: "PrepareForSleep(true): system is suspending; preparing session" in log_text(tmp),
                             "PrepareForSleep(true) logged")
                    wait_for(lambda: "deactivating session: cancelling grabs, focus and menus" in log_text(tmp),
                             "deactivating session logged")

                    emit_signal(fake, "PrepareForSleep", False)
                    wait_for(lambda: "PrepareForSleep(false): system resumed from sleep; restoring session" in log_text(tmp),
                             "PrepareForSleep(false) logged")
                    wait_for(lambda: "reactivating session: restoring output layout, damage and presentation" in log_text(tmp),
                             "reactivating session logged")

                    assert process.poll() is None, log_text(tmp)
            finally:
                stop_process(process)
                log.close()
        finally:
            fake.terminate()
            fake.wait(timeout=3)
    print("power: PrepareForSleep(true/false) deactivates and restores session cleanly")


def test_prepare_for_shutdown_waits_for_sigterm(system_bus_address):
    """Preparation must not log out and restart the greeter before systemd stops us."""
    from xwayland import build_client

    with tempfile.TemporaryDirectory(prefix="rediwm-power-test-") as directory:
        tmp = Path(directory)
        build_client(tmp)
        fake = start_fake({"FAKE_LOGIND_CAP": "yes"})
        client = None
        try:
            process, log = spawn(tmp, system_bus_address, CONFIG.replace("xwayland = false", "xwayland = true"))
            try:
                with IPCClient(tmp, timeout=15) as ipc:
                    ipc.wait_for("wallpaper_presented", timeout_ms=10000)
                    display = ipc.get_runtime()["xwayland_display"]
                    assert display, log_text(tmp)
                    client = subprocess.Popen(
                        [str(tmp / "x11-client")],
                        env=dict(os.environ, DISPLAY=display, XDG_RUNTIME_DIR=str(tmp)),
                        stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                    )
                    wait_for(lambda: any(w.get("backend") == "xwayland" for w in ipc.get_windows()),
                             "live X11 window before shutdown", timeout=15)
                    ipc.open_power_menu()
                    ipc.wait_for("power_menu_opened", timeout_ms=5000)
                    drain_capability_probe(fake)

                    # A canceled scheduled shutdown must leave the desktop up.
                    emit_signal(fake, "PrepareForShutdown", False)
                    wait_for(lambda: "PrepareForShutdown(false): shutdown canceled" in log_text(tmp),
                             "shutdown cancellation logged")
                    assert process.poll() is None, log_text(tmp)

                    # A different bus peer cannot impersonate logind.
                    subprocess.run(["busctl", "--address=" + system_bus_address,
                                    "emit", "/org/freedesktop/login1",
                                    "org.freedesktop.login1.Manager", "PrepareForShutdown",
                                    "b", "true"], check=True)
                    ipc.get_state()  # Round-trip while the foreign signal is dispatched.
                    assert process.poll() is None, log_text(tmp)
                    assert "PrepareForShutdown(true)" not in log_text(tmp), log_text(tmp)

                    emit_signal(fake, "PrepareForShutdown", True)
                    wait_for(lambda: "PrepareForShutdown(true): waiting for session termination" in log_text(tmp),
                             "shutdown preparation logged")
                    assert process.poll() is None, log_text(tmp)
                    assert client.poll() is None, log_text(tmp)
                    assert any(w.get("backend") == "xwayland" for w in ipc.get_windows())

                    # Even preparation can be canceled; keep the live session.
                    emit_signal(fake, "PrepareForShutdown", False)
                    ipc.get_state()
                    assert process.poll() is None, log_text(tmp)
                    assert client.poll() is None, log_text(tmp)

                    # Model the actual session stop after delay inhibitors finish.
                    emit_signal(fake, "PrepareForShutdown", True)
                    process.terminate()
                    assert process.wait(timeout=5) == 0, log_text(tmp)
                    assert "terminating compositor session" in log_text(tmp)
                    assert "compositor session teardown complete" in log_text(tmp)
                    assert "Restarting Xwayland" not in log_text(tmp), log_text(tmp)
                    assert "cannot destroy all clients" not in log_text(tmp), log_text(tmp)
                    client.wait(timeout=5)

            finally:
                if client is not None:
                    stop_process(client)
                stop_process(process)
                log.close()
        finally:
            fake.terminate()
            fake.wait(timeout=3)
    print("power: shutdown preparation preserves the session; SIGTERM exits without restarting Xwayland")


def test_session_owned_helpers_stopped_on_logout(system_bus_address):
    """Quitting compositor (logout) sends SIGTERM to owned helpers, waits, and exits cleanly."""
    with tempfile.TemporaryDirectory(prefix="rediwm-power-test-") as directory:
        tmp = Path(directory)
        fake = start_fake({"FAKE_LOGIND_CAP": "yes"})
        try:
            process, log = spawn(tmp, system_bus_address)
            try:
                with IPCClient(tmp, timeout=15) as ipc:
                    ipc.wait_for("wallpaper_presented", timeout_ms=10000)
                    res = ipc.action("spawn", {"argv": ["/bin/sleep", "3600"]})

                    def get_helper_pids():
                        try:
                            out = subprocess.check_output(["pgrep", "-f", "sleep 3600"], text=True)
                            return [int(p) for p in out.strip().split() if p]
                        except subprocess.CalledProcessError:
                            return []

                    wait_for(lambda: len(get_helper_pids()) > 0, "sleep helper running")
                    helper_pids = get_helper_pids()

                    try:
                        press(ipc, "quit")
                    except EOFError:
                        pass  # Quit can close IPC before its reply is flushed.

                    rc = process.wait(timeout=5)
                    assert rc == 0, f"compositor exited with code {rc}"
                    wait_for(lambda: "stopping 1 session-owned helper(s)" in log_text(tmp),
                             "stopping owned helper logged")
                    wait_for(lambda: "terminating compositor session" in log_text(tmp),
                             "terminating session logged")
                    wait_for(lambda: all(not is_pid_running(p) for p in helper_pids),
                             "owned helper terminated")
            finally:
                if process.poll() is None:
                    stop_process(process)
                log.close()
        finally:
            fake.terminate()
            fake.wait(timeout=3)
    print("power: session-owned helpers are stopped with SIGTERM and reaped on logout")


def test_compositor_clean_termination_on_sigterm(system_bus_address):
    """Compositor catches SIGTERM, terminates owned helpers, and exits cleanly with 0."""
    with tempfile.TemporaryDirectory(prefix="rediwm-power-test-") as directory:
        tmp = Path(directory)
        fake = start_fake({"FAKE_LOGIND_CAP": "yes"})
        try:
            process, log = spawn(tmp, system_bus_address)
            try:
                with IPCClient(tmp, timeout=15) as ipc:
                    ipc.wait_for("wallpaper_presented", timeout_ms=10000)
                    res = ipc.action("spawn", {"argv": ["/bin/sleep", "3601"]})

                    def get_helper_pids():
                        try:
                            out = subprocess.check_output(["pgrep", "-f", "sleep 3601"], text=True)
                            return [int(p) for p in out.strip().split() if p]
                        except subprocess.CalledProcessError:
                            return []

                    wait_for(lambda: len(get_helper_pids()) > 0, "sleep helper running")
                    helper_pids = get_helper_pids()

                    process.terminate()
                    rc = process.wait(timeout=5)
                    assert rc == 0, f"compositor exited with code {rc}"
                    wait_for(lambda: "received SIGTERM; requesting clean termination" in log_text(tmp),
                             "SIGTERM receipt logged")
                    wait_for(lambda: "stopping 1 session-owned helper(s)" in log_text(tmp),
                             "stopping owned helper logged")
                    wait_for(lambda: all(not is_pid_running(p) for p in helper_pids),
                             "owned helper terminated")
            finally:
                if process.poll() is None:
                    stop_process(process)
                log.close()
        finally:
            fake.terminate()
            fake.wait(timeout=3)
    print("power: compositor catches SIGTERM, cleans up helpers, and exits with code 0")


def test_stuck_helper_does_not_block_shutdown(system_bus_address):
    with tempfile.TemporaryDirectory(prefix="rediwm-shutdown-test-") as directory:
        tmp = Path(directory)
        hook = tmp / "wait_hook.so"
        subprocess.run(["cc", "-shared", "-fPIC", "-Wall", "-Wextra", "-Werror",
                        str(Path(__file__).with_name("shutdown_wait_hook.c")),
                        "-o", str(hook), "-ldl"], check=True)
        marker = tmp / "stuck.pid"
        helper = tmp / "helper.py"
        helper.write_text("import os, signal, time\nsignal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
                          + f"open({str(marker)!r}, 'w').write(str(os.getpid()))\ntime.sleep(60)\n")
        process, log = spawn_compositor(tmp, config_content=CONFIG, env_extra={
            "DBUS_SESSION_BUS_ADDRESS": "", "DBUS_SYSTEM_BUS_ADDRESS": system_bus_address,
            "LD_PRELOAD": str(hook), "REDIWM_TEST_STUCK_PID": str(marker),
        })
        try:
            with IPCClient(tmp, timeout=15) as ipc:
                ipc.wait_for("wallpaper_presented", timeout_ms=10000)
                ipc.action("spawn", {"argv": [sys.executable, str(helper)]})
                wait_for(lambda: marker.exists() and marker.read_text().strip(), "helper ready")
                process.terminate()
                assert process.wait(timeout=5) == 0, log_text(tmp)
                assert "leaving 1 killed helper(s) to session teardown" in log_text(tmp)
        finally:
            stop_process(process)
            log.close()
    print("power: a killed helper stuck in kernel I/O cannot block compositor shutdown")


def test_lid_ignore_inhibitor(system_bus_address):
    """Real FD lifetime: startup, reload, logind restart, explicit sleep, exit."""
    expected = {"method": "Inhibit", "what": "handle-lid-switch", "mode": "block"}
    config = CONFIG.replace("[compositor]", '[compositor]\nlid_close = "ignore"')
    with tempfile.TemporaryDirectory(prefix="rediwm-lid-test-") as directory:
        tmp = Path(directory)
        fake = start_fake({})
        process = log = None
        try:
            process, log = spawn(tmp, system_bus_address, config=config)
            with IPCClient(tmp, timeout=15) as ipc:
                assert read_line(fake) == expected
                wait_for(lambda: "logind lid handling inhibited" in log_text(tmp), "inhibitor retained")
                # A lid inhibitor must not suppress a deliberate Sleep command.
                press(ipc, "suspend")
                assert read_line(fake) == {"method": "CanSuspend"}
                assert read_line(fake)["method"] == "SuspendWithFlags"
                for action in ("display_off", "lock", "suspend"):
                    (tmp / "rediwm-config.toml").write_text(config.replace('lid_close = "ignore"', f'lid_close = "{action}"'))
                    ipc.reload_config()
                    assert read_line(fake) == {"inhibitor_released": True}
                    (tmp / "rediwm-config.toml").write_text(config)
                    ipc.reload_config()
                    assert read_line(fake) == expected
                # Changing owners invalidates the old descriptor and reacquires.
                stop_process(fake)
                fake = start_fake({})
                assert read_line(fake) == expected
                stop_process(process)
                assert read_line(fake) == {"inhibitor_released": True}
        finally:
            if process is not None:
                stop_process(process)
            if log is not None:
                log.close()
            stop_process(fake)
    print("power: Do nothing holds only a lid inhibitor, releases on reload/exit, reacquires after logind restart")


def test_lid_inhibitor_late_reply_and_denial(system_bus_address):
    config = CONFIG.replace("[compositor]", '[compositor]\nlid_close = "ignore"')
    for denied in (False, True):
        with tempfile.TemporaryDirectory(prefix="rediwm-lid-reply-test-") as directory:
            tmp = Path(directory)
            fake = start_fake({"FAKE_LOGIND_INHIBIT_DENIED": "yes"} if denied else {"FAKE_LOGIND_INHIBIT_DELAY_MS": "1500"})
            process = log = None
            try:
                process, log = spawn(tmp, system_bus_address, config=config)
                with IPCClient(tmp, timeout=15) as ipc:
                    assert read_line(fake)["method"] == "Inhibit"
                    if denied:
                        wait_for(lambda: "logind refused lid inhibitor" in log_text(tmp), "denial reported")
                    else:
                        (tmp / "rediwm-config.toml").write_text(CONFIG)
                        ipc.reload_config()
                        assert read_line(fake) == {"inhibitor_released": True}
                        assert "logind lid handling inhibited" not in log_text(tmp)
                    assert process.poll() is None, log_text(tmp)
            finally:
                if process is not None:
                    stop_process(process)
                if log is not None:
                    log.close()
                stop_process(fake)
    print("power: denied and obsolete lid inhibitor replies are safe")


def test_lock_on_suspend(system_bus_address):
    """A sleep delay inhibitor is held; PrepareForSleep(true) locks and lets it
    go once the lock is on screen; resuming takes a new one for the next sleep."""
    expected = {"method": "Inhibit", "what": "sleep", "mode": "delay"}
    config = CONFIG.replace("lock_on_suspend = false", "lock_on_suspend = true")
    with tempfile.TemporaryDirectory(prefix="rediwm-sleep-lock-test-") as directory:
        tmp = Path(directory)
        fake = start_fake({})
        process = log = None
        try:
            process, log = spawn(tmp, system_bus_address, config=config)
            lines = FakeLines(fake)
            with IPCClient(tmp, timeout=15) as ipc:
                ipc.wait_for("wallpaper_presented", timeout_ms=10000)
                assert lines.next() == expected
                wait_for(lambda: "logind sleep delayed until the screen is locked" in log_text(tmp), "sleep inhibitor retained")
                lines.signal("PrepareForSleep", True)
                assert lines.next() == {"inhibitor_released": True}
                assert "the lock is on screen; the system may sleep" in log_text(tmp), log_text(tmp)
                try:
                    ipc.get_state()
                    raise AssertionError("the session was not locked before sleep")
                except IPCError as err:
                    assert "SessionLocked" in str(err), err
                lines.signal("PrepareForSleep", False)
                assert lines.next() == expected
                assert process.poll() is None, log_text(tmp)
        finally:
            if process is not None:
                stop_process(process)
            if log is not None:
                log.close()
            stop_process(fake)
    print("power: sleep waits for the lock to reach the screen, and the delay is taken again on resume")


def test_logind_lock_and_locked_hint(system_bus_address):
    """A verified login follows logind's Lock (only for its own session),
    ignores Unlock, and keeps LockedHint current."""
    session = {"path": "/org/freedesktop/login1/session/_31", "interface": "org.freedesktop.login1.Session"}
    with tempfile.TemporaryDirectory(prefix="rediwm-logind-lock-test-") as directory:
        tmp = Path(directory)
        fake = start_fake({})
        process = log = None
        try:
            process, log = spawn(tmp, system_bus_address, env_extra={"REDIWM_LOGIN_SESSION": "1"})
            lines = FakeLines(fake)
            with IPCClient(tmp, timeout=15) as ipc:
                ipc.wait_for("wallpaper_presented", timeout_ms=10000)
                assert lines.next() == {"method": "GetSession", "id": "1"}
                assert lines.next() == {"method": "SetLockedHint", "locked": False}
                # Another session's Lock is not ours.
                lines.signal("Lock", None, path="/org/freedesktop/login1/session/_32", interface=session["interface"])
                ipc.get_state()
                lines.signal("Lock", None, **session)
                assert lines.next() == {"method": "SetLockedHint", "locked": True}
                for request in ("get_state", "Unlock"):
                    if request == "Unlock":
                        lines.signal("Unlock", None, **session)
                    try:
                        ipc.get_state()
                        raise AssertionError(f"session not locked ({request})")
                    except IPCError as err:
                        assert "SessionLocked" in str(err), err
                assert process.poll() is None, log_text(tmp)
        finally:
            if process is not None:
                stop_process(process)
            if log is not None:
                log.close()
            stop_process(fake)
    print("power: logind Lock locks only its own session, Unlock is ignored, LockedHint follows the lock")


def main():
    if "--private" not in sys.argv:
        sys.exit(subprocess.call(["dbus-run-session", "--", sys.executable, __file__, "--private"]))
    system_bus_address = os.environ["DBUS_SESSION_BUS_ADDRESS"]
    test_lid_ignore_inhibitor(system_bus_address)
    test_lid_inhibitor_late_reply_and_denial(system_bus_address)
    test_lock_on_suspend(system_bus_address)
    test_logind_lock_and_locked_hint(system_bus_address)
    test_systemctl_power_commands()
    test_systemctl_failure_and_retry()
    test_systemctl_missing()
    test_normal_request_calls_with_flags_and_checks_inhibitors(system_bus_address)
    test_legacy_fallback_when_with_flags_unsupported(system_bus_address)
    test_legacy_fallback_on_unknown_method_error(system_bus_address)
    test_challenge_still_proceeds_for_explicit_request(system_bus_address)
    test_automatic_request_stops_on_challenge_without_prompting(system_bus_address)
    test_automatic_request_omits_interactive_auth_flag(system_bus_address)
    test_automatic_request_reports_auth_required_without_crashing(system_bus_address)
    test_inhibitor_blocks_action_and_reports_who_and_why(system_bus_address)
    test_inhibitor_without_list_inhibitors_or_unmatched(system_bus_address)
    test_denied_and_unavailable_never_call_the_action(system_bus_address)
    test_policy_denial_for_multiple_sessions_reported_without_terminating(system_bus_address)
    test_action_refusal_general_reported_without_terminating(system_bus_address)
    test_only_one_request_is_pending_at_a_time(system_bus_address)
    test_prepare_for_sleep_deactivates_and_restores_session(system_bus_address)
    test_prepare_for_shutdown_waits_for_sigterm(system_bus_address)
    test_session_owned_helpers_stopped_on_logout(system_bus_address)
    test_compositor_clean_termination_on_sigterm(system_bus_address)
    test_stuck_helper_does_not_block_shutdown(system_bus_address)


if __name__ == "__main__":
    main()

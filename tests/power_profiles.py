#!/usr/bin/env python3
"""Power profile OSD against a private fake PowerProfiles daemon.

Runs on a private dbus-run-session, pointed at by DBUS_SYSTEM_BUS_ADDRESS, so
the compositor never reaches the host's real power-profiles-daemon or asusd.
Covers:
- No OSD for the profile found at startup or after the service restarts.
- An external change (asus-wmi's Fn+F5 cycling, relayed by the daemon) shows
  the OSD with one filled segment per profile step.
- power_profile_cycle sets the next offered profile, wrapping and skipping
  profiles the daemon does not offer; the OSD follows the daemon's
  confirmation, not the request.
- PropertiesChanged from a connection that does not own the service name is
  ignored.
- Losing the service leaves the compositor running and the action inert.
Requires PyGObject, Pillow and dbus-run-session.
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

from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
from ipc_client import IPCClient, spawn_compositor, stop_process

FAKE_PPD = r'''
import json, os, sys, warnings
warnings.simplefilter("ignore", DeprecationWarning)
from gi.repository import Gio, GLib

NAME = "org.freedesktop.UPower.PowerProfiles"
PATH = "/org/freedesktop/UPower/PowerProfiles"
XML = ("<node><interface name='org.freedesktop.UPower.PowerProfiles'>"
       "<property name='ActiveProfile' type='s' access='readwrite'/>"
       "<property name='Profiles' type='aa{sv}' access='read'/>"
       "<property name='PerformanceDegraded' type='s' access='read'/>"
       "</interface></node>")

offered = os.environ.get("FAKE_PPD_PROFILES", "power-saver,balanced,performance").split(",")
state = {"active": os.environ.get("FAKE_PPD_ACTIVE", "balanced")}
address = os.environ["DBUS_SESSION_BUS_ADDRESS"]
conn = Gio.bus_get_sync(Gio.BusType.SESSION)

def profiles():
    return GLib.Variant("aa{sv}", [{"Profile": GLib.Variant("s", p), "Driver": GLib.Variant("s", "fake")} for p in offered])

def changed(connection, profile):
    body = GLib.Variant("(sa{sv}as)", (NAME, {"ActiveProfile": GLib.Variant("s", profile)}, []))
    connection.emit_signal(None, PATH, "org.freedesktop.DBus.Properties", "PropertiesChanged", body)
    connection.flush_sync()

def get_property(c, sender, path, iface, prop):
    if prop == "ActiveProfile":
        return GLib.Variant("s", state["active"])
    if prop == "Profiles":
        return profiles()
    return GLib.Variant("s", "")

def set_property(c, sender, path, iface, prop, value):
    profile = value.get_string()
    print(json.dumps({"set": profile}), flush=True)
    if profile not in offered:
        return False
    state["active"] = profile
    changed(conn, profile)
    return True

def on_stdin(channel, cond):
    line = sys.stdin.readline()
    if not line:
        return False
    req = json.loads(line)
    if req["action"] == "external":
        state["active"] = req["profile"]
        changed(conn, req["profile"])
    elif req["action"] == "spoof":
        # A different connection claiming the same path and interface.
        other = Gio.DBusConnection.new_for_address_sync(
            address, Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION, None, None)
        changed(other, req["profile"])
        other.close_sync(None)
    print(json.dumps({"done": req["action"]}), flush=True)
    return True

GLib.io_add_watch(sys.stdin.fileno(), GLib.IO_IN, on_stdin)
conn.register_object(PATH, Gio.DBusNodeInfo.new_for_xml(XML).interfaces[0], None, get_property, set_property)
Gio.bus_own_name_on_connection(conn, NAME, Gio.BusNameOwnerFlags.NONE, lambda *_: print("ready", flush=True), None)
GLib.MainLoop().run()
'''

CONFIG = '[keybinds]\n"F9" = "power_profile_cycle"\n'
F9 = 67
ANSI_RE = re.compile(r'\x1b\[[0-9;]*[mK]')


def wait_for(predicate, description, timeout=5.0, interval=0.05):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(interval)
    raise AssertionError(f"timed out waiting for {description}")


def read_line(fake, timeout=5):
    assert select.select([fake.stdout], [], [], timeout)[0], "no output from fake power profiles daemon"
    line = fake.stdout.readline()
    assert line, "fake power profiles daemon exited"
    return json.loads(line)


def start_fake(active="balanced", offered="power-saver,balanced,performance"):
    fake = subprocess.Popen([sys.executable, "-c", FAKE_PPD], stdout=subprocess.PIPE, stdin=subprocess.PIPE, text=True,
                            env={**os.environ, "FAKE_PPD_ACTIVE": active, "FAKE_PPD_PROFILES": offered})
    assert select.select([fake.stdout], [], [], 5)[0], "fake power profiles daemon did not start"
    assert fake.stdout.readline().strip() == "ready"
    return fake


def command(fake, action, profile):
    fake.stdin.write(json.dumps({"action": action, "profile": profile}) + "\n")
    fake.stdin.flush()
    assert read_line(fake) == {"done": action}


def stop_fake(fake):
    fake.terminate()
    fake.wait(timeout=5)


def log_text(tmp):
    return ANSI_RE.sub('', (tmp / "compositor.log").read_text())


def test_power_profile_osd(system_bus_address):
    with tempfile.TemporaryDirectory(prefix="rediwm-power-profiles-test-") as directory:
        tmp = Path(directory)
        fake = start_fake()
        process, log = spawn_compositor(tmp, config_content=CONFIG, env_extra={
            "DBUS_SESSION_BUS_ADDRESS": "",
            "DBUS_SYSTEM_BUS_ADDRESS": system_bus_address,
        })
        try:
            with IPCClient(tmp, timeout=15) as ipc:
                ipc.wait_for("wallpaper_presented", timeout_ms=10000)

                def segments(name):
                    """Filled OSD segments, from the red pixels in the OSD's
                    bottom-centre slot; 0 when no OSD is showing."""
                    ipc.wait_for_frame(timeout_ms=2000)
                    path = tmp / (name + ".png")
                    ipc.screenshot(path=str(path))
                    wait_for(path.exists, "screenshot " + name)
                    image = Image.open(path).convert("RGB")
                    if os.environ.get("REDIWM_OSD_PREVIEW"):
                        dest = Path(os.environ["REDIWM_OSD_PREVIEW"])
                        dest.mkdir(parents=True, exist_ok=True)
                        image.save(dest / ("power-profile-" + name + ".png"))
                    w, h = image.size
                    pixels = image.crop((w // 2 - 190, h - 195, w // 2 + 190, h - 70)).tobytes()
                    red = sum(r > 170 and r > g * 2 and r > b * 2 for r, g, b in zip(pixels[0::3], pixels[1::3], pixels[2::3]))
                    count = round(red / 250)
                    assert abs(red - count * 250) < 60, f"{name}: {red} red pixels is not a whole number of segments"
                    return count

                def settle():
                    # Longer than the OSD's 1.1 s hold plus its fade.
                    time.sleep(1.5)

                wait_for(lambda: "active profile balanced" in log_text(tmp), "baseline profile")
                assert segments("startup") == 0, "the startup profile must not show the OSD"

                command(fake, "external", "performance")
                wait_for(lambda: "power profile changed to performance" in log_text(tmp), "external change")
                assert segments("external-performance") == 3

                # Cycling wraps from performance; the OSD follows the confirmation.
                ipc.key_down_up(F9)
                assert read_line(fake) == {"set": "power-saver"}
                wait_for(lambda: "power profile changed to power-saver" in log_text(tmp), "cycled change")
                assert segments("cycled-power-saver") == 1
                settle()

                command(fake, "spoof", "performance")
                time.sleep(0.2)
                assert segments("spoofed") == 0, "a signal from a non-owner moved the OSD"
                assert "changed to performance" not in log_text(tmp).split("changed to power-saver", 1)[1]
                ipc.key_down_up(F9)
                assert read_line(fake) == {"set": "balanced"}, "the spoof changed the tracked profile"
                wait_for(lambda: "power profile changed to balanced" in log_text(tmp), "second cycle")
                settle()

                # A restarted daemon is a fresh baseline: no OSD for it, and
                # cycling skips a profile it does not offer.
                stop_fake(fake)
                wait_for(lambda: "power profile service left the bus" in log_text(tmp), "service loss")
                ipc.key_down_up(F9)
                fake = start_fake(active="balanced", offered="power-saver,balanced")
                wait_for(lambda: log_text(tmp).count("active profile balanced") == 2, "second baseline")
                assert segments("restarted") == 0, "a restarted service must not show the OSD"
                ipc.key_down_up(F9)
                assert read_line(fake) == {"set": "power-saver"}, "cycling must skip the unoffered performance profile"
                wait_for(lambda: log_text(tmp).count("power profile changed to power-saver") == 2, "cycle after restart")
                assert segments("restarted-cycle") == 1

                stop_fake(fake)
                fake = None
                wait_for(lambda: log_text(tmp).count("power profile service left the bus") == 2, "second service loss")
                ipc.key_down_up(F9)
                ipc.wait_for_frame(timeout_ms=2000)
                assert process.poll() is None, log_text(tmp)
        finally:
            if fake is not None:
                stop_fake(fake)
            stop_process(process)
            log.close()
    print("power_profiles: OSD on confirmed changes only, cycling, spoofing and service restarts")


def test_without_service(system_bus_address):
    with tempfile.TemporaryDirectory(prefix="rediwm-power-profiles-test-") as directory:
        tmp = Path(directory)
        process, log = spawn_compositor(tmp, config_content=CONFIG, env_extra={
            "DBUS_SESSION_BUS_ADDRESS": "",
            "DBUS_SYSTEM_BUS_ADDRESS": system_bus_address,
        })
        try:
            with IPCClient(tmp, timeout=15) as ipc:
                ipc.wait_for("wallpaper_presented", timeout_ms=10000)
                wait_for(lambda: "no power profile service on the system bus" in log_text(tmp), "absent service")
                ipc.key_down_up(F9)
                ipc.wait_for_frame(timeout_ms=2000)
                assert "no power profile service to switch" in log_text(tmp)
                assert process.poll() is None, log_text(tmp)
        finally:
            stop_process(process)
            log.close()
    print("power_profiles: no service leaves the action inert")


def main():
    if "--private" not in sys.argv:
        sys.exit(subprocess.call(["dbus-run-session", "--", sys.executable, __file__, "--private"]))
    system_bus_address = os.environ["DBUS_SESSION_BUS_ADDRESS"]
    test_without_service(system_bus_address)
    test_power_profile_osd(system_bus_address)


if __name__ == "__main__":
    main()

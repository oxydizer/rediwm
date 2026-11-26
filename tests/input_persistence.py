#!/usr/bin/env python3
"""Per-device settings through the real UI, reload, hotplug, and restart paths.

The noninstalled preload fixture supplies libinput devices and observes backend
state; no host input hardware or production testing hook is used.
"""
import json
import math
import os
import shlex
import struct
import subprocess
import tempfile
import time
import tomllib
from pathlib import Path

from ipc_client import IPCClient, spawn_compositor, stop_process
from ui_driver import UIDriver

ROOT = Path(__file__).resolve().parents[1]
INITIAL = '''# keep this comment
[input]
invert_scroll = false
pointer_speed = -0.4
pointer_speed_touchpad = 0.3
natural_scroll = true
left_handed = false
tap_to_click = true
tap_drag = false
disable_while_typing = false
disable_while_typing_touchpad = true

# keep this disconnected device
[[input_device]]
id = "stale-device"
natural_scroll = false # preserve this inline comment

[compositor]
xwayland = false
'''


def wait(condition, description):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        result = condition()
        if result:
            return result
        time.sleep(.05)
    raise AssertionError(description)


class Fixture:
    def __init__(self, directory, hook, config):
        self.directory = directory
        self.fifo = directory / "pointer-commands"
        self.state_file = directory / "pointer-state.json"
        self.config_file = directory / "rediwm-config.toml"
        os.mkfifo(self.fifo, 0o600)
        self.fd = os.open(self.fifo, os.O_RDWR | os.O_NONBLOCK)
        self.connected = []
        self.process, self.log = spawn_compositor(directory, scale=os.getenv("REDIWM_TEST_SCALE", "1"), config_content=config, env_extra={
            "LD_PRELOAD": str(hook),
            "REDIWM_TEST_POINTER_COMMANDS": str(self.fifo),
            "REDIWM_TEST_POINTER_STATE": str(self.state_file),
            "DBUS_SESSION_BUS_ADDRESS": "unix:path=/nonexistent/rediwm-test-bus",
            "PULSE_SERVER": "unix:/nonexistent/rediwm-test-audio",
            "REDIWM_THEME": "",
            "HOME": str(directory / "home"),
            "XDG_CONFIG_HOME": str(directory / "config"),
            "XDG_DATA_HOME": str(directory / "data"),
            "XDG_CACHE_HOME": str(directory / "cache"),
            "REDIWM_APP_SCOPES": "0",
        })

    def close(self):
        stop_process(self.process)
        self.log.close()
        os.close(self.fd)

    def state(self):
        return json.loads(self.state_file.read_text())

    def command(self, command, index):
        os.write(self.fd, struct.pack("II", command, index))
        if command in (1, 2):
            wait(lambda: self.state()[index]["live"] == (command == 1), "pointer hotplug")
            if command == 1:
                self.connected.append(index)
            else:
                self.connected.remove(index)
        else:
            # Commands and IPC use separate fds; wait for a fresh snapshot.
            before = self.state_file.stat().st_mtime_ns
            os.write(self.fd, struct.pack("II", 3, index))
            wait(lambda: self.state_file.stat().st_mtime_ns != before, "fixture command")

    def select(self, ui, ipc, device):
        # The synthetic pointer is present only in the optional full list.
        index = self.connected.index(device) + int(ui.find("pointer_show_all")["checked"])
        self.select_index(ui, ipc, index)

    def select_index(self, ui, ipc, index):
        ui.click(ui.scroll_into_view("pointer_device"), panel="control_center")
        ui.wait_settled("control_center")
        ipc.key_down_up(102)  # Home
        for _ in range(index):
            ipc.key_down_up(108)  # Down
        ipc.key_down_up(28)  # Return
        ui.wait_settled("control_center")
        wait(lambda: ui.find("pointer_device")["selected_index"] == index and not ui.find("pointer_device")["open"], "selected device")

    def click(self, ui, name, fraction=None):
        ui.wait_settled("control_center")
        widget = ui.scroll_into_view(name)
        assert not widget["is_disabled"], widget
        ui.click(widget, panel="control_center", fraction=fraction)
        ui.wait_settled("control_center")

    def saved(self):
        return tomllib.loads(self.config_file.read_text())


def verify_failures(fixture, ui, ipc):
    # Backend failure must not publish or persist the requested value.
    fixture.select(ui, ipc, 0)
    before = fixture.config_file.read_text()
    fixture.command(4, 0)
    fixture.click(ui, "natural_scroll")
    assert not fixture.state()[0]["natural"]
    assert fixture.state()[0]["failures"] == 1
    assert fixture.config_file.read_text() == before
    assert any(w["label"] == "The device could not apply this setting." for w in ui.widgets())
    assert ui.find("natural_scroll")["on"] is False

    # A failed atomic save rolls back the backend change as well.
    backup = fixture.config_file.with_suffix(".backup")
    fixture.config_file.rename(backup)
    fixture.config_file.mkdir()
    try:
        fixture.click(ui, "natural_scroll")
        assert not fixture.state()[0]["natural"]
        assert any(w["label"] == "Could not save. The previous settings were restored." for w in ui.widgets())
    finally:
        fixture.config_file.rmdir()
        backup.rename(fixture.config_file)
    assert fixture.config_file.read_text() == before
    print("PASS: backend and persistence failures leave the prior setting intact")



def assert_origins(ui, expected):
    for name, origin in expected.items():
        assert ui.find(name + "_origin")["label"] == origin, (name, ui.find(name + "_origin"))


def setting_values(device):
    return {key: device[key] for key in ("speed", "natural", "left", "tap", "drag", "dwt")}


def capture_input(ui, ipc, suffix, menu_open=False):
    preview = os.getenv("REDIWM_SETTINGS_PREVIEW")
    if not preview:
        return
    if not menu_open:
        ui.scroll_into_view("pointer_reset")
    ui.wait_settled("control_center")
    scale = os.getenv("REDIWM_TEST_SCALE", "1")
    path = Path(preview) / f"rediwm-input-{scale}-{suffix}.png"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.unlink(missing_ok=True)
    ipc.screenshot(str(path))


def verify_primary_devices(fixture, ui, ipc):
    def last_device(index):
        ui.click(ui.scroll_into_view("pointer_device"), panel="control_center")
        ipc.key_down_up(107)  # End
        ipc.key_down_up(28)   # Return
        ui.wait_settled("control_center")
        selector = ui.find("pointer_device")
        assert selector["selected_index"] == index, selector

    # One mouse and one touchpad expose consumer controls, mouse macros, a
    # compatibility mouse, and a keyboard's phantom mouse interface as well.
    for device in (6, 7, 8, 9):
        fixture.command(1, device)
    ui.wait_settled("control_center")
    last_device(1)
    ui.click(ui.find("pointer_device"), panel="control_center")
    capture_input(ui, ipc, "primary-devices", menu_open=True)
    ipc.key_down_up(1)
    ui.wait_settled("control_center")

    fixture.click(ui, "pointer_show_all")
    last_device(6)
    fixture.select_index(ui, ipc, 0)
    assert ui.find("pointer_speed")["role"] != "slider"
    assert ui.find("natural_scroll")["is_disabled"]
    fixture.select(ui, ipc, 7)
    assert not ui.find("natural_scroll")["is_disabled"]
    fixture.click(ui, "pointer_show_all")
    assert ui.find("pointer_device")["selected_index"] == 0
    last_device(1)

    # The mouse interface remains usable if its touchpad peer is removed.
    fixture.command(2, 1)
    ui.wait_settled("control_center")
    last_device(1)
    fixture.command(1, 1)
    ui.wait_settled("control_center")
    assert ui.find("pointer_device")["selected_index"] == 0
    last_device(1)

    # A real pointing stick sharing the pad's group and a keyboard interface
    # must stay visible, unlike the touchpad's compatibility mouse.
    fixture.command(1, 10)
    ui.wait_settled("control_center")
    last_device(2)
    for device in (6, 7, 8, 9, 10):
        fixture.command(2, device)
    ui.wait_settled("control_center")
    fixture.select(ui, ipc, 0)
    print("PASS: primary device list hides synthetic and auxiliary interfaces; full list, pointing sticks and peer hotplug remain usable")


def verify_trackball_profile(fixture, ui, ipc):
    # udev identifies this unnamed device as a trackball; its display fallback
    # is Kensington Expert Mouse, which deliberately omits the word trackball.
    fixture.command(1, 5)
    fixture.select(ui, ipc, 5)
    before_records = fixture.saved()["input_device"]
    peers = fixture.state()[:5]
    assert_origins(ui, {"pointer_speed": "Default", "natural_scroll": "Default", "left_handed": "Default",
                        "tap_to_click": "Not supported", "tap_drag": "Not supported", "disable_while_typing": "Not supported"})
    assert ui.find("pointer_reset")["is_disabled"]
    for name, fraction in (("pointer_speed", .85), ("natural_scroll", None), ("left_handed", None)):
        fixture.click(ui, name, fraction)
    assert_origins(ui, {"pointer_speed": "Custom", "natural_scroll": "Custom", "left_handed": "Custom"})
    assert not ui.find("pointer_reset")["is_disabled"]
    custom = setting_values(fixture.state()[5])
    assert custom["speed"] > .4 and not custom["natural"] and custom["left"]
    assert fixture.state()[:5] == peers, "trackball changes touched another device"
    new_record = next(r for r in fixture.saved()["input_device"] if r["id"] not in {r["id"] for r in before_records})
    profile_id = new_record["id"]
    saved = fixture.config_file.read_text()

    ui.scroll_into_view("pointer_reset")
    ui.click(ui.find("pointer_device"), panel="control_center")
    capture_input(ui, ipc, "devices-open", menu_open=True)
    ipc.key_down_up(1)  # Escape closes the dropdown without changing selection.
    ui.wait_settled("control_center")

    # Failing the second setter tests rollback after pointer speed already
    # changed, rather than only refusing a reset before it touches the backend.
    fixture.command(5, 5)
    fixture.click(ui, "pointer_reset")
    assert setting_values(fixture.state()[5]) == custom
    assert fixture.state()[:5] == peers
    assert fixture.config_file.read_text() == saved
    assert_origins(ui, {"pointer_speed": "Custom", "natural_scroll": "Custom", "left_handed": "Custom"})
    assert any(w["label"] == "Could not reset. The previous settings were restored." for w in ui.widgets())

    backup = fixture.config_file.with_suffix(".backup")
    fixture.config_file.rename(backup)
    fixture.config_file.mkdir()
    try:
        fixture.click(ui, "pointer_reset")
        assert setting_values(fixture.state()[5]) == custom
        assert fixture.state()[:5] == peers
        assert any(w["label"] == "Could not save. The previous settings were restored." for w in ui.widgets())
    finally:
        fixture.config_file.rmdir()
        backup.rename(fixture.config_file)
    assert fixture.config_file.read_text() == saved

    fixture.click(ui, "pointer_reset")
    current = fixture.state()[5]
    assert math.isclose(current["speed"], -.4, abs_tol=1e-6) and current["natural"] and not current["left"]
    assert fixture.state()[:5] == peers
    records = fixture.saved()["input_device"]
    assert next(r for r in records if r["id"] == profile_id) == {"id": profile_id}
    assert [r for r in records if r["id"] != profile_id] == before_records
    assert_origins(ui, {"pointer_speed": "Default", "natural_scroll": "Default", "left_handed": "Default"})
    assert ui.find("pointer_reset")["is_disabled"]
    assert "# keep this comment" in fixture.config_file.read_text()
    assert "# preserve this inline comment" in fixture.config_file.read_text()

    # Reset means inheritance, including later defaults and reconnect/restart.
    fixture.config_file.write_text(fixture.config_file.read_text().replace("pointer_speed = -0.4", "pointer_speed = -0.2", 1))
    ipc.reload_config()
    wait(lambda: math.isclose(fixture.state()[5]["speed"], -.2, abs_tol=1e-6), "reset profile inherits reloaded defaults")
    assert fixture.state()[0]["speed"] > .4
    peers = fixture.state()[:5]
    fixture.command(2, 5)
    fixture.command(1, 5)
    fixture.select(ui, ipc, 5)
    assert math.isclose(fixture.state()[5]["speed"], -.2, abs_tol=1e-6)
    assert fixture.state()[:5] == peers
    assert_origins(ui, {"pointer_speed": "Default", "natural_scroll": "Default", "left_handed": "Default"})
    print("PASS: trackball profile, default/custom badges, atomic reset rollback, and reset inheritance after reload/replug")



def run_session(fixture, restart):
    with IPCClient(fixture.directory, timeout=15) as ipc:
        ipc.wait_for("wallpaper_presented", timeout_ms=10000)
        fixture.command(1, 0)  # mouse
        fixture.command(1, 1)  # touchpad
        ui = UIDriver(ipc)
        ipc.action("open_control_center")
        ui.wait_settled("control_center")
        ui.click("Input", panel="control_center")
        ui.wait_settled("control_center")
        fixture.select(ui, ipc, 0)
        state = fixture.state()
        if restart:
            assert state[0]["natural"] is False and state[1]["natural"] is True, state
            assert state[0]["speed"] > .4 and math.isclose(state[1]["speed"], .6, abs_tol=1e-6), state
            assert state[0]["left"] is True and state[1]["left"] is False, state
            assert state[1]["tap"] is False and state[1]["drag"] is True and state[1]["dwt"] is False, state
            assert ui.find("natural_scroll")["on"] is False
            fixture.select(ui, ipc, 1)
            assert ui.find("natural_scroll")["on"] is True
            assert ui.find("tap_to_click")["on"] is False
            assert_origins(ui, {"pointer_speed": "Default", "natural_scroll": "Default", "tap_to_click": "Custom"})
            fixture.command(1, 5)
            fixture.select(ui, ipc, 5)
            assert math.isclose(fixture.state()[5]["speed"], -.2, abs_tol=1e-6)
            assert fixture.state()[5]["natural"] and not fixture.state()[5]["left"]
            assert ui.find("pointer_reset")["is_disabled"]
            assert_origins(ui, {"pointer_speed": "Default", "natural_scroll": "Default", "left_handed": "Default"})
            print("PASS: per-device settings and reset-to-default inheritance restored after compositor restart")
            return

        verify_primary_devices(fixture, ui, ipc)
        state = fixture.state()

        # Global-only configurations still select the appropriate device defaults.
        assert math.isclose(state[0]["speed"], -.4, abs_tol=1e-6) and math.isclose(state[1]["speed"], .3, abs_tol=1e-6), state
        assert state[0]["natural"] and state[1]["natural"], state
        assert state[1]["tap"] and not state[1]["drag"] and state[1]["dwt"], state
        assert ui.find("tap_to_click")["is_disabled"]
        assert ui.find("tap_drag")["is_disabled"]
        assert ui.find("disable_while_typing")["is_disabled"]
        assert_origins(ui, {"pointer_speed": "Default", "natural_scroll": "Default", "left_handed": "Default", "tap_to_click": "Not supported"})
        assert ui.find("pointer_reset")["is_disabled"]
        untouched = state[1].copy()
        fixture.click(ui, "natural_scroll")
        fixture.click(ui, "pointer_speed", .85)
        fixture.click(ui, "left_handed")
        state = fixture.state()
        assert state[0]["natural"] is False and state[0]["speed"] > .4 and state[0]["left"] is True, state
        assert state[1] == untouched, (state[1], untouched)
        assert_origins(ui, {"pointer_speed": "Custom", "natural_scroll": "Custom", "left_handed": "Custom"})
        fixture.select(ui, ipc, 1)
        assert ui.find("natural_scroll")["on"] is True
        assert abs(ui.find("pointer_speed")["value"] - .3) < .001
        for name in ("tap_to_click", "tap_drag", "disable_while_typing"):
            assert not ui.find(name)["is_disabled"]
            fixture.click(ui, name)
        state = fixture.state()
        assert not state[1]["tap"] and state[1]["drag"] and not state[1]["dwt"], state
        assert_origins(ui, {"pointer_speed": "Default", "natural_scroll": "Default", "tap_to_click": "Custom", "tap_drag": "Custom", "disable_while_typing": "Custom"})
        capture_input(ui, ipc, "touchpad")
        saved = fixture.saved()
        records = saved["input_device"]
        assert len(records) == 3, records
        assert next(r for r in records if r["id"] == "stale-device") == {"id": "stale-device", "natural_scroll": False}
        assert saved["input"]["pointer_speed"] == -.4 and saved["input"]["natural_scroll"] is True
        assert "# keep this comment" in fixture.config_file.read_text()
        assert "# preserve this inline comment" in fixture.config_file.read_text()
        print("PASS: independent natural scrolling, speed and touchpad capabilities; partial records preserve unrelated config")

        # Reload changes inherited defaults without erasing either override.
        text = fixture.config_file.read_text().replace("pointer_speed_touchpad = 0.3", "pointer_speed_touchpad = 0.6")
        fixture.config_file.write_text(text.replace("natural_scroll = true", "natural_scroll = false", 1))
        ipc.reload_config()
        wait(lambda: math.isclose(fixture.state()[1]["speed"], .6, abs_tol=1e-6), "inherited pointer speed on reload")
        assert fixture.state()[0]["speed"] == state[0]["speed"]
        assert not fixture.state()[1]["natural"]
        fixture.config_file.write_text(text)
        ipc.reload_config()
        wait(lambda: fixture.state()[1]["natural"], "inherited natural scrolling on reload")
        assert not fixture.state()[0]["natural"]
        print("PASS: configuration reload preserves overrides and updates inherited defaults")

        verify_failures(fixture, ui, ipc)

        # Same labels/model, different physical ports: the new mouse inherits
        # defaults, then has a separate override and leaves the first untouched.
        fixture.command(1, 2)
        fixture.select(ui, ipc, 2)
        assert fixture.state()[2]["natural"] and math.isclose(fixture.state()[2]["speed"], -.4, abs_tol=1e-6)
        original = fixture.state()[0].copy()
        fixture.click(ui, "pointer_speed", .25)
        assert fixture.state()[2]["speed"] < -.45
        assert fixture.state()[0] == original
        assert len(fixture.saved()["input_device"]) == 4

        # Remove the selected device with its dropdown open. Stale live pointer
        # dereferences abort the fixture; reconnect uses a changed event number.
        fixture.select(ui, ipc, 0)
        ui.click(ui.scroll_into_view("pointer_device"), panel="control_center")
        fixture.command(2, 0)
        ui.wait_settled("control_center")
        assert fixture.process.poll() is None
        assert ui.find("pointer_device")["open"] is False
        peer = fixture.state()[1].copy()
        fixture.command(1, 0)
        fixture.select(ui, ipc, 0)
        assert not fixture.state()[0]["natural"] and fixture.state()[0]["speed"] == original["speed"]
        assert fixture.state()[1] == peer
        print("PASS: identical device names use distinct paths; removal and reconnection preserve selection safety and settings")

        # An actual identity collision refuses overrides on both devices. The
        # survivor remains ambiguous until both instances have been disconnected.
        fixture.command(1, 3)
        fixture.select(ui, ipc, 0)
        assert fixture.state()[0]["natural"] and fixture.state()[3]["natural"]
        assert ui.find("natural_scroll")["is_disabled"]
        fixture.command(2, 3)
        ui.wait_settled("control_center")
        assert ui.find("natural_scroll")["is_disabled"]
        fixture.command(2, 0)
        fixture.command(1, 0)
        fixture.select(ui, ipc, 0)
        assert not ui.find("natural_scroll")["is_disabled"]
        assert not fixture.state()[0]["natural"]

        fixture.command(1, 4)
        fixture.click(ui, "pointer_show_all")
        fixture.select(ui, ipc, 4)
        for name in ("natural_scroll", "left_handed", "tap_to_click", "tap_drag", "disable_while_typing"):
            assert ui.find(name)["is_disabled"]
        assert ui.find("pointer_speed")["role"] != "slider"
        assert fixture.state()[4]["writes"] == 0 and fixture.state()[4]["failures"] == 0
        print("PASS: ambiguous identities and unsupported backend capabilities are unavailable")

        verify_trackball_profile(fixture, ui, ipc)

        # Genuinely global controls still use ordinary [input] persistence.
        for name in ("repeat_delay", "repeat_rate"):
            fixture.click(ui, name, .9)
        saved = fixture.saved()["input"]
        assert saved["key_repeat_delay"] != 400 and saved["key_repeat_rate"] != 25
        assert "invert_scroll" not in saved and saved["tap_drag"] is False


def run():
    with tempfile.TemporaryDirectory(prefix="rediwm-input-save-") as directory:
        root = Path(directory)
        flags = shlex.split(subprocess.check_output(
            ["pkg-config", "--cflags", "--libs", "wlroots-0.20", "wayland-server", "libinput", "libudev"], text=True))
        hook = root / "pointer-settings.so"
        subprocess.run(["cc", "-shared", "-fPIC", "-Wall", "-Wextra", "-Werror",
                        str(ROOT / "tests/pointer_settings_hook.c"), "-o", str(hook), *flags, "-ldl"], check=True)
        config = INITIAL
        for restart in range(2):
            runtime = root / str(restart)
            runtime.mkdir(mode=0o700)
            fixture = Fixture(runtime, hook, config)
            try:
                run_session(fixture, restart)
                config = fixture.config_file.read_text()
            except Exception:
                fixture.log.flush()
                print(Path(fixture.log.name).read_text()[-6000:])
                raise
            finally:
                fixture.close()


if __name__ == "__main__":
    run()

#!/usr/bin/env python3
"""Basic settings, start-menu shortcuts and SVGs on an isolated desktop.

Uses private PipeWire sinks and a fake brightnessctl; never changes host settings.
"""
import argparse
import json
import subprocess
import os
from pathlib import Path
import tempfile
import time

from PIL import Image, ImageChops
from hardware_keys import private_audio, wait
from ipc_client import IPCClient, spawn_compositor, stop_process
from ui_driver import UIDriver


def run(scale):
    with tempfile.TemporaryDirectory(prefix="rediwm-settings-") as directory:
        tmp = Path(directory)
        with private_audio(tmp) as (audio_env, pactl):
            pactl("load-module", "module-null-sink", "sink_name=settings_test", "sink_properties=device.description=Studio")
            helpers = tmp / "bin"
            helpers.mkdir()
            brightness = helpers / "brightnessctl"
            brightness.write_text('''#!/usr/bin/env python3
import os, sys, time
from pathlib import Path
root = Path(os.environ['SETTINGS_TEST_DIR'])
if (root / 'fail-brightness').exists(): sys.exit(1)
state = root / 'brightness'
value = int(state.read_text()) if state.exists() else 60
if sys.argv[-2] == 'set':
    value = int(sys.argv[-1].rstrip('%'))
    state.write_text(str(value))
time.sleep(.04)
print(f'fixture,backlight,{value},{value}%,100')
''')
            brightness.chmod(0o755)
            env = {key: audio_env[key] for key in ("PIPEWIRE_RUNTIME_DIR", "PULSE_SERVER", "DBUS_SESSION_BUS_ADDRESS")}
            # A translucent window background: only the chrome may show it.
            (tmp / "theme.toml").write_text('[theme]\nwindow_bg = "rgba(16,18,21,0.5)"\napp_bg = "#101215"\n')
            env.update(PATH=str(helpers) + os.pathsep + os.environ["PATH"], SETTINGS_TEST_DIR=str(tmp), REDIWM_THEME=str(tmp / "theme.toml"))
            process, log = spawn_compositor(tmp, scale=scale, renderer=os.environ.get("REDIWM_TEST_RENDERER", "pixman"), config_content="[input]\ninvert_scroll = false\n", env_extra=env)
            try:
                with IPCClient(tmp, timeout=15) as ipc:
                    ipc.wait_for("wallpaper_presented", timeout_ms=10000)
                    ipc.wait_for("catalog_published", timeout_ms=10000)

                    ui = UIDriver(ipc)

                    def widgets(panel="control_center"):
                        return ui.widgets(panel)

                    def named(name, panel="control_center"):
                        role = "button" if panel == "start_menu" else None
                        return ui.find(name, panel=panel, role=role)

                    def click(widget, panel="control_center", fraction=.5):
                        ui.click(widget, panel=panel, fraction=fraction)

                    def page(name):
                        click(named(name))
                        wait(lambda: ipc.get_shell_state()["control_center"]["category"] == name.lower(), "page " + name)

                    def settings_window():
                        return next((w for w in ipc.get_windows() if w.get("app_id") == "rediwm-settings"), None)

                    def close_settings():
                        ipc.close_window(settings_window()["id"])
                        ui.wait_absent("control_center")

                    def capture(name):
                        path = tmp / (name + ".png")
                        ipc.screenshot(str(path))
                        with Image.open(path) as image:
                            result = image.convert("RGB")
                        if dest := os.environ.get("REDIWM_SETTINGS_PREVIEW"):
                            Path(dest).mkdir(parents=True, exist_ok=True)
                            result.save(Path(dest) / (name + "-" + scale + ".png"))
                        return result

                    ipc.action('open_start_menu')
                    ipc.wait_for("menu_opened", timeout_ms=5000)
                    settings = named("Settings", "start_menu")
                    power = named("Power", "start_menu")
                    assert settings["box"]["x"] < power["box"]["x"]
                    capture("start-menu")
                    click(settings, "start_menu")
                    ipc.wait_for("menu_closed", timeout_ms=5000)
                    ui.wait_settled("control_center")
                    wait(lambda: any(w["label"] == "60%" for w in widgets()), "brightness query")
                    box = ipc.get_shell_state()["control_center"]["box"]
                    assert box["width"] > 380 and box["x"] >= 0 and box["y"] >= 0
                    assert box["y"] + box["height"] <= 720 - 64
                    # It is an ordinary, focused window with an opaque body.
                    window = settings_window()
                    assert window is not None and window["is_focused"], ipc.get_windows()
                    # Check the first frame while the resize is held: waiting
                    # for settlement hides a body painted one size behind chrome.
                    title = next(w for w in widgets(f"window/{window['id']}") if w["role"] == "titlebar")["global_box"]
                    for horizontal, vertical in ((1, 0), (0, 1), (-1, 0), (0, -1), (-1, -1), (1, -1), (-1, 1), (1, 1)):
                        x = box["x"] + ({-1: -1, 0: box["width"] // 2, 1: box["width"]}[horizontal])
                        y = {-1: title["y"] + 2, 0: box["y"] + box["height"] // 2, 1: box["y"] + box["height"] + 2}[vertical]
                        ipc.move_cursor(x, y)
                        ipc.pointer_button(272, True)
                        assert ipc.get_input_state()["cursor_mode"] == "resize"
                        for delta in (-32, -64, -96, -48):
                            ipc.move_cursor(x + horizontal * delta, y + vertical * delta)
                            ipc.wait_for_frame()
                            raster = ipc.dump_buffer("control_center")
                            expected = dict(box)
                            if horizontal:
                                expected["width"] += delta
                                if horizontal < 0:
                                    expected["x"] -= delta
                            if vertical:
                                expected["height"] += delta
                                if vertical < 0:
                                    expected["y"] -= delta
                            # Top/left resizes must keep the opposite edge fixed.
                            actual = ipc.get_shell_state()["control_center"]["box"]
                            assert actual == expected, (horizontal, vertical, delta, actual, expected)
                            for axis in ("width", "height"):
                                pixels = round(expected[axis] * float(scale))
                                assert raster[axis] == pixels, (axis, delta, raster[axis], pixels)
                        # Release before another frame applies the final motion.
                        ipc.move_cursor(x, y)
                        ipc.pointer_button(272, False)
                        ui.wait_settled("control_center")
                        assert ipc.get_shell_state()["control_center"]["box"] == box
                    body = capture("opaque-body").getpixel((round((box["x"] + box["width"] - 30) * float(scale)), round((box["y"] + box["height"] - 12) * float(scale))))
                    assert body == (16, 18, 21), body
                    # Outside clicks, Escape and opening another shell panel leave settings alive.
                    ipc.move_cursor(4, 4)
                    ipc.pointer_button(272, True)
                    ipc.pointer_button(272, False)
                    ipc.key_down_up(1)
                    assert ipc.get_shell_state()["control_center"]["state"] == "open"
                    ipc.action('open_start_menu')
                    ipc.wait_for("menu_opened", timeout_ms=5000)
                    assert ipc.get_shell_state()["control_center"]["state"] == "open"
                    click(named("Settings", "start_menu"), "start_menu")
                    ipc.wait_for("menu_closed", timeout_ms=5000)
                    ui.wait_settled("control_center")
                    # Drag by the window titlebar and preserve the position across page changes.
                    ipc.move_cursor(box["x"] + 120, box["y"] - 12)
                    ipc.pointer_button(272, True)
                    ipc.move_cursor(box["x"] + 200, box["y"] + 48)
                    ipc.pointer_button(272, False)
                    ipc.wait_for_frame()
                    moved = ipc.get_shell_state()["control_center"]["box"]
                    assert moved["x"] == box["x"] + 80 and moved["y"] == box["y"] + 60, (box, moved)
                    page("Input")
                    assert ipc.get_shell_state()["control_center"]["box"] == moved
                    page("General")
                    # Return to the initial position for the remaining pixel checks.
                    ipc.move_cursor(moved["x"] + 120, moved["y"] - 12)
                    ipc.pointer_button(272, True)
                    ipc.move_cursor(box["x"] + 120, box["y"] - 12)
                    ipc.pointer_button(272, False)
                    ipc.wait_for_frame()
                    assert ipc.get_shell_state()["control_center"]["box"] == box
                    # Minimize and restore like any window.
                    ipc.minimize(settings_window()["id"])
                    wait(lambda: ipc.get_shell_state()["control_center"]["state"] == "minimized", "minimized")
                    ipc.open_control_center()
                    wait(lambda: ipc.get_shell_state()["control_center"]["state"] == "open", "restored")
                    ui.wait_settled("control_center")
                    assert ipc.get_shell_state()["control_center"]["box"] == box
                    assert settings_window()["is_focused"]
                    sliders = [w for w in widgets() if w["role"] == "slider"]
                    assert len(sliders) == 2 and all(w["box"]["width"] > 300 and w["box"]["height"] >= 20 for w in sliders)
                    click(sliders[0], fraction=.78)
                    wait(lambda: abs(ipc.action('get_audio_state')["master_volume"] - .8) < .01, "master volume changed")
                    click([w for w in widgets() if w["role"] == "slider"][1], fraction=.6)
                    wait(lambda: (tmp / "brightness").exists(), "absolute brightness applied")
                    assert int((tmp / "brightness").read_text()) in (60, 61)
                    ipc.wait_for_frame()
                    capture("general")

                    page("Input")
                    assert any(w["label"] == "Natural scroll" for w in widgets())
                    click(next(w for w in widgets() if w["role"] == "toggle"))
                    capture("input")
                    page("Displays")
                    assert any(w["label"] == "Resolution" for w in widgets())
                    assert not any(w["label"] == "Duplicate" for w in widgets())
                    capture("displays")
                    page("Appearance")
                    assert not any(w["role"] == "swatch" or w.get("label") == "Accent colour" for w in widgets())
                    assert any(w.get("name") == "theme" for w in widgets())
                    capture("appearance")
                    # A held scrollbar keeps working beyond the window edge.
                    def content_scroll():
                        return next(w for w in widgets() if w["role"] == "scroll_container")

                    viewport = content_scroll()["global_box"]
                    assert content_scroll()["content_size"] > viewport["height"]
                    bar_x = viewport["x"] + viewport["width"] - 7
                    bar_y = viewport["y"] + 8
                    outside_x = box["x"] - 40
                    ipc.move_cursor(bar_x, bar_y)
                    ipc.pointer_button(272, True)
                    ipc.move_cursor(outside_x, bar_y + 30)
                    first_offset = content_scroll()["scroll_offset"]
                    assert first_offset > 0, "scrollbar stopped outside Settings"
                    ipc.move_cursor(outside_x, bar_y + 60)
                    assert content_scroll()["scroll_offset"] > first_offset
                    ipc.pointer_button(272, False)
                    released_offset = content_scroll()["scroll_offset"]
                    ipc.move_cursor(bar_x, bar_y + 90)
                    assert content_scroll()["scroll_offset"] == released_offset, "scrollbar kept dragging after release"
                    page("Audio")
                    ipc.move_cursor(box["x"] + box["width"] - 80, box["y"] + box["height"] - 80)
                    ipc.scroll(0, 600)
                    ipc.wait_for_frame()
                    capture("audio-before-selection")
                    click(named("Studio"))
                    # This private server has no session manager. Verify the
                    # requested default, then publish its effective selection
                    # as a session manager would and check the live UI update.
                    def requested_default():
                        metadata = subprocess.check_output(["pw-metadata", "-n", "default"], env=audio_env, text=True)
                        return any("default.configured.audio.sink" in line and "settings_test" in line for line in metadata.splitlines())
                    wait(requested_default, "output device request")
                    subprocess.run(["pw-metadata", "0", "default.audio.sink", json.dumps({"name": "settings_test"}), "Spa:String:JSON"],
                                   env=audio_env, check=True, capture_output=True)
                    wait(lambda: "Default Sink: settings_test" in pactl("info"), "effective output device")
                    ipc.wait_for_frame()
                    capture("audio")
                    # Switching defaults externally must refresh the open panel.
                    subprocess.run(["pw-metadata", "0", "default.audio.sink", json.dumps({"name": "osd_test"}), "Spa:String:JSON"],
                                   env=audio_env, check=True, capture_output=True)
                    ipc.wait_for_frame()
                    page("General")
                    assert any(w["label"] == "Master volume" for w in widgets())
                    # Widget damage must restore the same pixels after hover.
                    ipc.move_cursor(box["x"] + 10, box["y"] + 10)
                    ui.wait_settled("control_center")
                    baseline = capture("before-hover")
                    nav = named("Audio")["box"]
                    ipc.move_cursor(box["x"] + nav["x"] + 8, box["y"] + nav["y"] + 8)
                    ipc.wait_for_frame()
                    ipc.move_cursor(box["x"] + 10, box["y"] + 10)
                    ui.wait_settled("control_center")
                    # The taskbar clock can cross a minute during this check.
                    # Compare the panel's retained pixels, not the whole output.
                    crop = tuple(round(v * float(scale)) for v in (box["x"], box["y"], box["x"] + box["width"], box["y"] + box["height"]))
                    assert ImageChops.difference(baseline.crop(crop), capture("after-hover").crop(crop)).getbbox() is None
                    close_settings()
                    ipc.action('open_appearance')
                    wait(lambda: ipc.get_shell_state()["control_center"]["category"] == "appearance", "appearance shortcut")
                    # Compositor shortcuts work while settings has the keyboard.
                    ui.wait_settled("control_center")
                    ipc.key(125, True)
                    ipc.key_down_up(16)  # Super+Q: close_window
                    ipc.key(125, False)
                    ui.wait_absent("control_center")
                    # A failed helper is an unavailable control, never a fake 0%.
                    (tmp / "fail-brightness").touch()
                    ipc.action('open_control_center')
                    wait(lambda: any(w["label"] == "No supported backlight" for w in widgets()), "backlight failure")
                    assert len([w for w in widgets() if w["role"] == "slider"]) == 1
                    close_settings()
                    ipc.action('open_start_menu')
                    ipc.wait_for("menu_opened", timeout_ms=5000)
                    click(named("Power", "start_menu"), "start_menu")
                    wait(lambda: ipc.get_shell_state().get("power_menu") is not None, "power button")
                    assert ipc.get_perf()["output_failed_commits"] == 0
                print(f"PASS: basic settings, isolated audio/backlight, menu shortcuts and repaint history at {scale}x")
            except Exception:
                log.flush()
                print((tmp / "compositor.log").read_text()[-5000:])
                raise
            finally:
                stop_process(process)
                log.close()


def unavailable_services(scale):
    """Missing audio must not read an uninitialized device-name length."""
    with tempfile.TemporaryDirectory(prefix="rediwm-settings-unavailable-") as directory:
        tmp = Path(directory)
        helper = tmp / "brightnessctl"
        helper.write_text("#!/bin/sh\nexit 1\n")
        helper.chmod(0o755)
        process, log = spawn_compositor(tmp, scale=scale, renderer=os.environ.get("REDIWM_TEST_RENDERER", "pixman"), env_extra={
            "PULSE_SERVER": "unix:" + str(tmp / "no-audio"), "DBUS_SESSION_BUS_ADDRESS": "",
            "PATH": str(tmp) + os.pathsep + os.environ["PATH"],
        })
        try:
            with IPCClient(tmp, timeout=15) as ipc:
                ipc.action('open_control_center')
                wait(lambda: any(w["label"] == "No supported backlight"
                                 for w in ipc.get_widget_tree("control_center")["widgets"]), "unavailable backlight")
                tree = ipc.get_widget_tree("control_center")["widgets"]
                assert any(w["label"] == "Audio unavailable" for w in tree)
                assert not any(w["role"] == "slider" for w in tree)
                ipc.key_down_up(1)
            print(f"PASS: settings without audio or backlight at {scale}x")
        finally:
            stop_process(process)
            log.close()


def default_applications(scale):
    """Installed-app choices persist and drive shortcuts and folder launches."""
    import tomllib
    with tempfile.TemporaryDirectory(prefix="rediwm-default-apps-") as directory:
        tmp = Path(directory)
        apps = tmp / "data/applications"
        apps.mkdir(parents=True)
        desktop = tmp / "Desktop"
        folder = desktop / "Folder #1"
        folder.mkdir(parents=True)
        helper = tmp / "record launch"
        helper.write_text("#!/usr/bin/python3\nimport json, sys\nfrom pathlib import Path\n"
                          f"Path({str(tmp)!r}, sys.argv[1]).write_text(json.dumps(sys.argv[2:]))\n")
        helper.chmod(0o755)
        for kind, category in (("files", "FileManager"), ("terminal", "TerminalEmulator")):
            (apps / f"test-{kind}.desktop").write_text(
                f'[Desktop Entry]\nType=Application\nName=Test {kind}\nCategories={category};\n'
                f'Exec="{helper}" {kind} --fixture %f\nMimeType=inode/directory;\n')
        (apps / "test-cli.desktop").write_text(
            '[Desktop Entry]\nType=Application\nName=CLI\nExec=echo "hello world"\nTerminal=true\n')
        env = {"XDG_DATA_HOME": str(tmp / "data"), "XDG_DATA_DIRS": str(tmp / "empty"),
               "XDG_CONFIG_HOME": str(tmp / "config"), "XDG_CACHE_HOME": str(tmp / "cache"),
               "REDIWM_DESKTOP_DIR": str(desktop), "DBUS_SESSION_BUS_ADDRESS": "",
               "PULSE_SERVER": "unix:" + str(tmp / "no-audio")}
        process, log = spawn_compositor(tmp, scale=scale, env_extra=env,
                                        config_content='[desktop]\nenabled = true\n')
        try:
            with IPCClient(tmp, timeout=15) as ipc:
                ipc.wait_for("wallpaper_presented", timeout_ms=10000)
                ipc.wait_for("catalog_published", timeout_ms=10000)
                ipc.open_control_center()
                ui = UIDriver(ipc)
                ui.wait_settled("control_center")
                for kind, app in (("file_manager", "files"), ("terminal", "terminal")):
                    ui.click(ui.scroll_into_view("default_" + kind), panel="control_center")
                    ipc.key_press("Down")
                    ipc.key_press("Return")
                    def saved():
                        cfg = tomllib.loads((tmp / "rediwm-config.toml").read_text())
                        return cfg.get("compositor", {}).get("default_" + kind) == f"test-{app}.desktop"
                    wait(saved, "saved default " + kind)
                    ipc.wait_for_frame()
                association = (tmp / "config/mimeapps.list").read_text()
                assert "inode/directory=test-files.desktop" in association, association
                # Reapply the current choice after another app changes the association.
                association_path = tmp / "config/mimeapps.list"
                association_path.write_text(association.replace(
                    "inode/directory=test-files.desktop", "inode/directory=test-terminal.desktop"))
                ui.click(ui.scroll_into_view("default_file_manager"), panel="control_center")
                ipc.key_press("Return")
                wait(lambda: "inode/directory=test-files.desktop" in association_path.read_text(),
                     "reselecting the file manager restores the folder association")
                window = next(w for w in ipc.get_windows() if w.get("app_id") == "rediwm-settings")
                ipc.close_window(window["id"])
                ui.wait_absent("control_center")
                for key, marker in ((18, "files"), (20, "terminal")):
                    ipc.key(125, True)
                    ipc.key_down_up(key)
                    ipc.key(125, False)
                    wait(lambda: (tmp / marker).exists(), "default shortcut " + marker)
                    assert json.loads((tmp / marker).read_text()) == ["--fixture"]
                ipc.action('launch_app', {"desktop_id": "test-cli.desktop"})
                wait(lambda: json.loads((tmp / "terminal").read_text()) ==
                     ["--fixture", "-e", "echo", "hello world"], "preferred terminal wraps CLI")
                (tmp / "files").unlink()
                # The only desktop icon is the folder, in the top-right cell.
                ipc.move_cursor(1200, 60)
                for _ in range(2):
                    ipc.pointer_button(272, True)
                    ipc.pointer_button(272, False)
                    time.sleep(.08)
                wait(lambda: (tmp / "files").exists(), "folder uses selected file manager")
                assert json.loads((tmp / "files").read_text()) == ["--fixture", str(folder)]
                ipc.open_control_center()
                ui.wait_settled("control_center")
                for kind, app in (("file_manager", "files"), ("terminal", "terminal")):
                    widget = ui.find("default_" + kind, panel="control_center")
                    assert widget["selected_index"] == 1, widget
                print("PASS: default app dropdowns, persistence, folder association, shortcuts and terminal wrapping")
        except Exception:
            log.flush()
            print((tmp / "compositor.log").read_text()[-5000:])
            raise
        finally:
            stop_process(process)
            log.close()


# This fixture deliberately lives on a private bus. It never contacts PID 1.
FAKE_SYSTEMD = r'''
import json, os, sys
from pathlib import Path
from gi.repository import Gio, GLib
NAME = "org.freedesktop.systemd1"
PATH = "/org/freedesktop/systemd1"
IFACE = NAME + ".Manager"
UNIT = NAME + ".Unit"
SERVICE = NAME + ".Service"
conn = Gio.bus_get_sync(Gio.BusType.SESSION)
xml = """<node><interface name='org.freedesktop.systemd1.Manager'>
<method name='Subscribe'/><method name='Reload'/>
<method name='LoadUnit'><arg type='s' direction='in'/><arg type='o' direction='out'/></method>
<method name='RefUnit'><arg type='s' direction='in'/></method>
<method name='ListUnits'><arg type='a(ssssssouso)' direction='out'/></method>
<method name='ListUnitFiles'><arg type='a(ss)' direction='out'/></method>
<method name='EnableUnitFiles'><arg type='as' direction='in'/><arg type='b' direction='in'/><arg type='b' direction='in'/><arg type='b' direction='out'/><arg type='a(sss)' direction='out'/></method>
<method name='DisableUnitFiles'><arg type='as' direction='in'/><arg type='b' direction='in'/><arg type='a(sss)' direction='out'/></method>
<method name='StartUnit'><arg type='s' direction='in'/><arg type='s' direction='in'/><arg type='o' direction='out'/></method>
<method name='StopUnit'><arg type='s' direction='in'/><arg type='s' direction='in'/><arg type='o' direction='out'/></method>
<method name='RestartUnit'><arg type='s' direction='in'/><arg type='s' direction='in'/><arg type='o' direction='out'/></method>
<property name='FinishTimestampMonotonic' type='t' access='read'/>
<signal name='UnitFilesChanged'/><signal name='JobRemoved'><arg type='u'/><arg type='o'/><arg type='s'/><arg type='s'/></signal>
<signal name='Reloading'><arg type='b'/></signal>
</interface></node>"""
unit_xml = """<node><interface name='org.freedesktop.systemd1.Unit'>
<property name='InactiveExitTimestampMonotonic' type='t' access='read'/>
<property name='ActiveEnterTimestampMonotonic' type='t' access='read'/>
<property name='TriggeredBy' type='as' access='read'/>
<property name='LoadState' type='s' access='read'/>
</interface></node>"""
service_xml = """<node><interface name='org.freedesktop.systemd1.Service'>
<property name='Type' type='s' access='read'/>
</interface></node>"""
polkit_xml = """<node><interface name='org.freedesktop.PolicyKit1.Authority'>
<method name='CheckAuthorization'><arg type='(sa{sv})' direction='in'/><arg type='s' direction='in'/><arg type='a{ss}' direction='in'/><arg type='u' direction='in'/><arg type='s' direction='in'/><arg type='(bba{ss})' direction='out'/></method>
<method name='CancelCheckAuthorization'><arg type='s' direction='in'/></method>
</interface></node>"""
units = {
 'alpha.service': ['Alpha server', 'active', 'running', 'enabled', 125000],
 'beta.service': ['Beta printer', 'inactive', 'dead', 'disabled', 0],
 'failed.service': ['Failed worker', 'failed', 'failed', 'enabled', 0],
 'masked.service': ['Masked worker', 'inactive', 'dead', 'masked', 0],
 'slow.service': ['Slow startup', 'active', 'running', 'static', 2100000],
}
for i in range(40):
 units[f'worker-{i:02}.service'] = ['Background worker', 'active', 'running', 'enabled', 10000]
paths = {key: PATH + '/unit/u' + str(i) for i, key in enumerate(units)}
paths['unloaded.service'] = PATH + '/unit/unloaded'
types = {key: 'simple' for key in paths}
types.update({'alpha.service': 'notify', 'beta.service': 'exec', 'slow.service': 'oneshot', 'unloaded.service': 'forking'})
types.update({'worker-00.service': 'idle', 'worker-01.service': 'notify-reload'})
log = open(os.environ['SYSTEMD_TEST_LOG'], 'a', buffering=1)
delay_next = False
def record(method, args=None, flags=0):
 log.write(json.dumps({'method': method, 'args': args, 'flags': flags}) + '\n')
def emit(member, signature='()', values=()):
 conn.emit_signal(None, PATH, IFACE, member, GLib.Variant(signature, values))
def method(c, sender, object_path, iface, member, params, invocation):
 global delay_next
 args = params.unpack()
 record(member, args, int(invocation.get_message().get_flags()))
 if member == 'ListUnits':
  rows = [(key, v[0], 'loaded', v[1], v[2], '', paths[key], 0, '', '/') for key,v in units.items()]
  if delay_next:
   delay_next = False
   GLib.timeout_add(1000, lambda: (invocation.return_value(GLib.Variant('(a(ssssssouso))', (rows,))), False)[1])
  else:
   invocation.return_value(GLib.Variant('(a(ssssssouso))', (rows,)))
 elif member == 'ListUnitFiles':
  rows = [('/usr/lib/systemd/system/' + key, v[3]) for key,v in units.items()]
  rows.append(('/usr/lib/systemd/system/unloaded.service', 'disabled'))
  invocation.return_value(GLib.Variant('(a(ss))', (rows,)))
 elif member == 'LoadUnit':
  invocation.return_value(GLib.Variant('(o)', (paths[args[0]],)))
 elif member == 'Reload':
  for key in types:
   dropin = Path(os.environ['SYSTEMD_TEST_ROOT']) / 'etc/systemd/system' / (key + '.d') / 'zz-rediwm-notify.conf'
   if dropin.exists(): types[key] = dropin.read_text().split('Type=')[1].strip()
  invocation.return_value(GLib.Variant('()', ()))
 elif member in ('EnableUnitFiles', 'DisableUnitFiles'):
  key = args[0][0]
  if key == 'failed.service':
   invocation.return_dbus_error('org.freedesktop.DBus.Error.AccessDenied', 'Fixture authorization denied')
   return
  units[key][3] = 'enabled' if member == 'EnableUnitFiles' else 'disabled'
  invocation.return_value(GLib.Variant('(ba(sss))', (True, [])) if member == 'EnableUnitFiles' else GLib.Variant('(a(sss))', ([],)))
  emit('UnitFilesChanged')
 elif member in ('StartUnit', 'StopUnit', 'RestartUnit'):
  key = args[0]
  units[key][1:3] = ['inactive', 'dead'] if member == 'StopUnit' else ['active', 'running']
  job = PATH + '/job/1'
  invocation.return_value(GLib.Variant('(o)', (job,)))
  GLib.timeout_add(30, lambda: (emit('JobRemoved', '(uoss)', (1, job, key, 'done')), False)[1])
 else:
  invocation.return_value(GLib.Variant('()', ()))
pending_check = None
def authority(c, sender, object_path, iface, member, params, invocation):
 # delay-unlock holds the prompt open; deny-unlock models a cancelled dialog.
 global pending_check
 record(member, params.unpack(), int(invocation.get_message().get_flags()))
 root = Path(os.environ['SYSTEMD_TEST_ROOT'])
 if member == 'CheckAuthorization':
  if (root / 'delay-unlock').exists():
   pending_check = invocation
  else:
   invocation.return_value(GLib.Variant('((bba{ss}))', ((not (root / 'deny-unlock').exists(), False, {}),)))
 else:
  if pending_check:
   pending_check.return_dbus_error('org.freedesktop.PolicyKit1.Error.Cancelled', 'cancelled')
   pending_check = None
  invocation.return_value(GLib.Variant('()', ()))
def prop(c, sender, object_path, iface, key):
 record('Property:' + key)
 if key == 'FinishTimestampMonotonic': return GLib.Variant('t', 3500000)
 unit = next(k for k,v in paths.items() if v == object_path)
 if key == 'Type': return GLib.Variant('s', types[unit])
 if key == 'LoadState': return GLib.Variant('s', 'loaded')
 if key == 'TriggeredBy': return GLib.Variant('as', ['alpha.socket'] if unit == 'alpha.service' else [])
 duration = units[unit][4] if unit in units else 0
 return GLib.Variant('t', 1000000 if key.startswith('Inactive') else 1000000 + duration)
conn.register_object('/org/freedesktop/PolicyKit1/Authority', Gio.DBusNodeInfo.new_for_xml(polkit_xml).interfaces[0], authority, None, None)
conn.register_object(PATH, Gio.DBusNodeInfo.new_for_xml(xml).interfaces[0], method, prop, None)
for object_path in paths.values():
 conn.register_object(object_path, Gio.DBusNodeInfo.new_for_xml(unit_xml).interfaces[0], None, prop, None)
 conn.register_object(object_path, Gio.DBusNodeInfo.new_for_xml(service_xml).interfaces[0], None, prop, None)
def stdin_ready(*_):
 global delay_next
 cmd = sys.stdin.readline().strip()
 if cmd == 'delay':
  delay_next = True
  record('delay_ready')
 elif cmd == 'change':
  units['alpha.service'][1:3] = ['failed', 'failed']
  conn.emit_signal(None, paths['alpha.service'], 'org.freedesktop.DBus.Properties', 'PropertiesChanged', GLib.Variant('(sa{sv}as)', (UNIT, {}, ['ActiveState'])))
 elif cmd == 'type':
  types['alpha.service'] = 'dbus'
  conn.emit_signal(None, paths['alpha.service'], 'org.freedesktop.DBus.Properties', 'PropertiesChanged', GLib.Variant('(sa{sv}as)', (SERVICE, {}, ['Type'])))
 elif cmd == 'reload-type':
  types['alpha.service'] = 'simple'
  emit('Reloading', '(b)', (False,))
 elif cmd == 'spoof':
  other = Gio.DBusConnection.new_for_address_sync(os.environ['DBUS_SESSION_BUS_ADDRESS'], Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION, None, None)
  other.emit_signal(None, PATH, IFACE, 'UnitFilesChanged', GLib.Variant('()', ()))
  other.flush_sync(None)
  other.close_sync(None)
 return True
GLib.io_add_watch(sys.stdin, GLib.IO_IN, stdin_ready)
Gio.bus_own_name_on_connection(conn, 'org.freedesktop.PolicyKit1', Gio.BusNameOwnerFlags.NONE, None, None)
Gio.bus_own_name_on_connection(conn, NAME, Gio.BusNameOwnerFlags.NONE, lambda *_: print('ready', flush=True), None)
GLib.MainLoop().run()
'''

# Redirect only the authorized editor in the test compositor. No production
# hook or configurable privileged executable; real pkexec/PID 1 are never run.
SYSTEMD_EDIT_HOOK = r'''
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>
int execve(const char *path, char *const argv[], char *const envp[]) {
 int (*real_execve)(const char *, char *const [], char *const []) = dlsym(RTLD_NEXT, "execve");
 if (!strcmp(path, "/usr/bin/pkexec") || !strcmp(path, "/bin/pkexec"))
  return real_execve(getenv("SYSTEMD_TEST_EDITOR"), argv, envp);
 return real_execve(path, argv, envp);
}
'''
FAKE_SYSTEMD_EDIT = r'''#!/usr/bin/python3
import json, os, sys, time
from pathlib import Path
args = sys.argv[1:]
with open(os.environ['SYSTEMD_TEST_LOG'], 'a') as log:
 log.write(json.dumps({'method': 'EditorArgs', 'args': args, 'flags': 0}) + '\n')
assert args[:1] == ['--disable-internal-agent'], args
assert args[1] in ('/usr/bin/systemctl', '/bin/systemctl'), args
assert args[2:-1] == ['--system', '--no-reload', '--stdin', '--drop-in=zz-rediwm-notify.conf', 'edit', '--'], args
contents = sys.stdin.read()
assert contents in ['[Service]\nType=' + v + '\n' for v in ('exec', 'dbus', 'simple', 'forking', 'notify', 'oneshot', 'idle', 'notify-reload')], contents
with open(os.environ['SYSTEMD_TEST_LOG'], 'a') as log:
 log.write(json.dumps({'method': 'EditType', 'args': args, 'contents': contents, 'flags': 0}) + '\n')
if args[-1] == 'failed.service': sys.exit(126)
if (Path(os.environ['SYSTEMD_TEST_ROOT']) / 'delay-edit').exists(): time.sleep(30)
# Model the privileged writer in a scratch root; systemctl edit cannot use
# --root. No system bus or host unit directory is available to this fixture.
root = Path(os.environ['SYSTEMD_TEST_ROOT'])
assert (root / 'usr/lib/systemd/system' / args[-1]).is_file()
dropin = root / 'etc/systemd/system' / (args[-1] + '.d') / 'zz-rediwm-notify.conf'
dropin.parent.mkdir(parents=True, exist_ok=True)
temporary = dropin.with_suffix('.tmp')
temporary.write_text(contents)
temporary.replace(dropin)
'''


def systemd_services(scale):
    import sys
    import select
    if not os.environ.get('REDIWM_PRIVATE_SYSTEMD_TEST'):
        env = dict(os.environ, REDIWM_PRIVATE_SYSTEMD_TEST='1')
        subprocess.run(['dbus-run-session', '--', sys.executable, __file__, '--services-only', '--scale', scale], env=env, check=True)
        return
    with tempfile.TemporaryDirectory(prefix='rediwm-systemd-') as directory:
        tmp = Path(directory)
        fixture = tmp / 'systemd.py'
        fixture.write_text(FAKE_SYSTEMD)
        calls = tmp / 'calls.jsonl'
        root = tmp / 'root'
        unitdir = root / 'usr/lib/systemd/system'
        unitdir.mkdir(parents=True)
        for unit in ('alpha', 'failed', 'unloaded'):
            (unitdir / (unit + '.service')).write_text('[Service]\nExecStart=/usr/bin/true\n')
        override = root / 'etc/systemd/system/alpha.service.d/override.conf'
        override.parent.mkdir(parents=True)
        override.write_text('[Service]\nRestart=on-failure\n')
        editor = tmp / 'editor.py'
        editor.write_text(FAKE_SYSTEMD_EDIT)
        editor.chmod(0o700)
        hook_source = tmp / 'edit_hook.c'
        hook_source.write_text(SYSTEMD_EDIT_HOOK)
        hook = tmp / 'edit_hook.so'
        subprocess.run(['cc', '-shared', '-fPIC', '-o', str(hook), str(hook_source), '-ldl'], check=True)
        env = dict(os.environ, SYSTEMD_TEST_LOG=str(calls), SYSTEMD_TEST_ROOT=str(root))
        fake = None
        def start_fake():
            result = subprocess.Popen([sys.executable, str(fixture)], env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            assert select.select([result.stdout], [], [], 10)[0], 'fake systemd startup'
            assert result.stdout.readline().strip() == 'ready'
            return result
        process, log = spawn_compositor(tmp, scale=scale, renderer=os.environ.get('REDIWM_TEST_RENDERER', 'pixman'), env_extra={'DBUS_SYSTEM_BUS_ADDRESS': os.environ['DBUS_SESSION_BUS_ADDRESS'], 'GIO_USE_VFS': 'local', 'LD_PRELOAD': str(hook), 'SYSTEMD_TEST_EDITOR': str(editor), 'SYSTEMD_TEST_ROOT': str(root), 'SYSTEMD_TEST_LOG': str(calls)}, config_content='[input]\ninvert_scroll = false\n')
        try:
            with IPCClient(tmp, timeout=15) as ipc:
                ipc.open_control_center()
                ui = UIDriver(ipc)
                ui.wait_settled('control_center')
                assert not any(w['name'] == 'services' for w in ui.widgets())
                fake = start_fake()
                wait(lambda: any(w['name'] == 'services' for w in ui.widgets()), 'systemd availability')
                def labels(): return [w['label'] or '' for w in ui.widgets()]
                def records():
                    result = []
                    for line in calls.read_text().splitlines():
                        try: result.append(json.loads(line))
                        except ValueError: pass  # a writer is mid-append
                    return result
                def checks(): return [r for r in records() if r['method'] == 'CheckAuthorization']
                def scroll_service_into_view(name):
                    for _ in range(40):
                        widget = ui.find(name)
                        if widget['visible'] and not widget['clipped']:
                            return widget
                        filters = name in ('All', 'Enabled', 'Slow', 'Disabled', 'Failed')
                        viewport = ui.find('services_filters' if filters else 'services_table_scroll')['global_box']
                        box = widget['global_box']
                        ipc.move_cursor(viewport['x'] + viewport['width'] // 2, viewport['y'] + viewport['height'] // 2)
                        if filters:
                            ipc.scroll(70 if box['x'] > viewport['x'] else -70, 0)
                        else:
                            delta = box['y'] + box['height'] - viewport['y'] - viewport['height'] if box['y'] >= viewport['y'] else box['y'] - viewport['y']
                            ipc.scroll(0, max(-70, min(70, delta)))
                        time.sleep(.15)
                    raise AssertionError(('could not scroll service control into view: ' + name, widget, viewport))

                def click(name, fraction=None):
                    # The tree is rebuilt a frame after client state changes;
                    # a click on a button that only looks enabled is dropped.
                    ui.wait_settled('control_center')
                    wait(lambda: not ui.find(name)['is_disabled'], 'control ready: ' + name)
                    ui.click(scroll_service_into_view(name), panel='control_center', fraction=fraction)
                    ui.wait_settled('control_center')
                # While the first list is on its way, its placeholder is a row
                # inside the table, not a line above it.
                fake.stdin.write('delay\n'); fake.stdin.flush()
                wait(lambda: any(r['method'] == 'delay_ready' for r in records()), 'delayed first list armed')
                ui.click('services', panel='control_center')
                wait(lambda: 'Loading services…' in labels(), 'loading placeholder')
                table = ui.find('services_table')['global_box']
                loading = next(w for w in ui.widgets() if w['label'] == 'Loading services…')['global_box']
                assert table['x'] <= loading['x'] and loading['x'] + loading['width'] <= table['x'] + table['width'], (table, loading)
                assert table['y'] <= loading['y'] and loading['y'] + loading['height'] <= table['y'] + table['height'], (table, loading)
                assert 'No matching services.' not in labels()
                if dest := os.environ.get('REDIWM_SETTINGS_PREVIEW'):
                    Path(dest).mkdir(parents=True, exist_ok=True)
                    (Path(dest) / ('services-loading-' + scale + '.png')).unlink(missing_ok=True)
                    ipc.screenshot(str(Path(dest) / ('services-loading-' + scale + '.png')))
                wait(lambda: any('46 services' in label for label in labels()), 'merged service list')
                assert 'Loading services…' not in labels() and 'No matching services.' not in labels()
                search_box = ui.find('services_search')['global_box']
                filter_box = ui.find('services_filters')['global_box']
                assert abs(search_box['y'] + search_box['height'] / 2 - filter_box['y'] - filter_box['height'] / 2) <= 1, (search_box, filter_box)
                assert search_box['x'] + search_box['width'] <= filter_box['x'], (search_box, filter_box)
                table_box = ui.find('services_table')['global_box']
                assert search_box['y'] + search_box['height'] <= table_box['y'], (search_box, table_box)
                first_y = ui.find('alpha.service')['global_box']['y']
                scroll_service_into_view('notify:worker-10.service')
                assert ui.find('alpha.service')['global_box']['y'] < first_y
                assert ui.find('services_search')['global_box'] == search_box
                scroll_service_into_view('notify:alpha.service')

                assert any(w['name'] == 'unloaded.service' for w in ui.widgets())
                assert not any('Property:FinishTimestampMonotonic' == r['method'] for r in records())
                assert ui.find('services_optimize')['is_disabled'] is True
                assert ui.find('startup:masked.service')['is_disabled'] is True
                assert ui.find('startup:slow.service')['is_disabled'] is True
                assert ui.find('notify:alpha.service')['selected_index'] == 4
                assert ui.find('notify:beta.service')['selected_index'] == 0
                assert ui.find('notify:unloaded.service')['selected_index'] == 3
                assert ui.find('notify:masked.service')['is_disabled'] is True
                assert any(w['name'] == 'Notify' for w in ui.widgets())
                assert ui.find('notify:worker-00.service')['selected_index'] == 6
                assert ui.find('notify:worker-01.service')['selected_index'] == 7
                # At the normal Settings width this is a compact table, with
                # two text lines per service and controls in aligned columns.
                assert ui.find('alpha.service')['global_box']['height'] == 54
                header = ui.find('Notify')['global_box']
                control = ui.find('notify:alpha.service')['global_box']
                assert abs(header['x'] + 4 - control['x']) < 1 and header['width'] - 8 == control['width'], (header, control)
                # Changes stay locked until polkit agrees; reading never needs it.
                assert 'Unlock to make service changes.' in labels()
                for name in ('startup:alpha.service', 'notify:alpha.service', 'notify:slow.service', 'notify:beta.service'):
                    assert ui.find(name)['is_disabled'] is True, name
                if dest := os.environ.get('REDIWM_SETTINGS_PREVIEW'):
                    (Path(dest) / ('services-locked-' + scale + '.png')).unlink(missing_ok=True)
                    ipc.screenshot(str(Path(dest) / ('services-locked-' + scale + '.png')))
                (root / 'deny-unlock').touch()
                click('services_unlock')
                wait(lambda: 'Authentication was cancelled or denied.' in labels(), 'unlock refusal')
                assert 'Unlock to make service changes.' in labels()
                assert ui.find('notify:alpha.service')['is_disabled'] is True
                (root / 'deny-unlock').unlink()
                click('services_unlock')
                wait(lambda: 'Service changes are unlocked for this session.' in labels(), 'unlocked')
                assert 'Authentication was cancelled or denied.' not in labels()
                assert len(checks()) == 2, checks()
                subject, action, details, flags, cancellation = checks()[0]['args']
                assert subject[0] == 'system-bus-name' and subject[1]['name'].startswith(':'), subject
                assert action == 'org.freedesktop.systemd1.manage-unit-files' and flags == 1, checks()[0]
                assert not any(r['method'] in ('EnableUnitFiles', 'DisableUnitFiles', 'StartUnit', 'StopUnit', 'RestartUnit', 'Reload', 'EditType') for r in records())
                assert not ui.find('notify:slow.service')['is_disabled']
                click('Notify')
                rows = [w['name'] for w in ui.widgets() if w['role'] == 'row' and (w['name'] or '').endswith('.service')]
                assert rows[0] == 'beta.service', rows
                click('Service')
                click('notify:unloaded.service')
                ipc.key_press('Down')
                ipc.key_press('Return')
                wait(lambda: ui.find('notify:unloaded.service')['selected_index'] == 4, 'edit initially unloaded service')
                assert (root / 'etc/systemd/system/unloaded.service.d/zz-rediwm-notify.conf').read_text() == '[Service]\nType=notify\n'
                assert not any(label == '125 ms' for label in labels())
                if dest := os.environ.get('REDIWM_SETTINGS_PREVIEW'):
                    scroll_service_into_view('services_columns')
                    Path(dest).mkdir(parents=True, exist_ok=True)
                    (Path(dest) / ('services-list-' + scale + '.png')).unlink(missing_ok=True)
                    ipc.screenshot(str(Path(dest) / ('services-list-' + scale + '.png')))
                click('services_analyze')
                wait(lambda: '125 ms' in labels() and '2.10 s' in labels(), 'startup timings')
                assert any('Boot time: 3.50 s' in label for label in labels())
                click('Slow')
                wait(lambda: len([w for w in ui.widgets() if w['role'] == 'row' and (w['name'] or '').endswith('.service')]) == 1, 'slow filter')
                assert ui.find('slow.service')
                click('Disabled')
                assert ui.find('unloaded.service')
                click('Failed')
                assert ui.find('failed.service')
                click('All')
                click('services_search')
                ipc.type_text('failed')
                wait(lambda: ui.find('services_search')['text_length'] == 6, 'failed search')
                click('startup:failed.service')
                ipc.key_press('Down')
                ipc.key_press('Return')
                wait(lambda: 'org.freedesktop.DBus.Error.AccessDenied' in labels(), 'authorization refusal')
                wait(lambda: not ui.find('startup:failed.service')['is_disabled'], 'refused action finished')
                assert ui.find('startup:failed.service')['selected_index'] == 0
                click('notify:failed.service')
                ipc.key_press('Down')
                ipc.key_press('Return')
                wait(lambda: 'Authentication was cancelled or denied. Notify setting is unchanged.' in labels(), 'type authorization refusal')
                wait(lambda: not ui.find('notify:failed.service')['is_disabled'], 'refused type finished')
                assert ui.find('notify:failed.service')['selected_index'] == 2
                assert not (root / 'etc/systemd/system/failed.service.d/zz-rediwm-notify.conf').exists()
                click('services_search')
                ipc.key(29, True)
                ipc.key_press('a')
                ipc.key(29, False)
                ipc.type_text('alpha')
                wait(lambda: ui.find('services_search')['text_length'] == 5, 'search text survives refresh')
                wait(lambda: len([w for w in ui.widgets() if w['role'] == 'row' and (w['name'] or '').endswith('.service')]) == 1, 'search results')
                click('alpha.service', fraction=0.1)
                assert 'Activated by: alpha.socket' in labels()
                # Locking disables every control again; unlocking asks again.
                click('services_unlock')
                wait(lambda: 'Unlock to make service changes.' in labels(), 'locked again')
                for name in ('services_start', 'services_stop', 'services_restart', 'startup:alpha.service', 'notify:alpha.service'):
                    assert ui.find(name)['is_disabled'] is True, name
                assert len(checks()) == 2, checks()
                click('services_unlock')
                wait(lambda: 'Service changes are unlocked for this session.' in labels(), 'unlocked again')
                assert len(checks()) == 3, checks()
                click('services_stop')
                wait(lambda: any(r['method'] == 'StopUnit' for r in records()), 'stop requested')
                wait(lambda: 'inactive' in labels(), 'stop status')
                click('services_start')
                wait(lambda: 'active' in labels(), 'start status')
                click('startup:alpha.service')
                ipc.key_press('Down')
                ipc.key_press('Return')
                wait(lambda: any(r['method'] == 'DisableUnitFiles' for r in records()), 'disable startup')
                wait(lambda: ui.find('startup:alpha.service')['selected_index'] == 1, 'confirmed startup setting')
                assert any(r['method'] == 'Reload' for r in records())
                assert 'active' in labels(), 'disable must not stop service'
                click('notify:alpha.service')
                ipc.key_press('Down')
                ipc.key_press('Return')
                wait(lambda: ui.find('notify:alpha.service')['selected_index'] == 5, 'confirmed type setting')
                assert (override.parent / 'zz-rediwm-notify.conf').read_text() == '[Service]\nType=oneshot\n'
                assert override.read_text() == '[Service]\nRestart=on-failure\n'
                assert 'active' in labels(), 'type change must not restart service'
                click('notify:alpha.service')
                ipc.key_press('Up')
                ipc.key_press('Return')
                wait(lambda: ui.find('notify:alpha.service')['selected_index'] == 4, 'replace type override')
                assert (override.parent / 'zz-rediwm-notify.conf').read_text() == '[Service]\nType=notify\n'
                # Deferred is visible but unavailable; keyboard cannot commit it.
                before = len(records())
                click('startup:alpha.service')
                ipc.key_press('Down')
                ipc.key_press('Return')
                assert ui.find('startup:alpha.service')['selected_index'] == 1
                ipc.key_press('Escape')
                assert not any(r['method'] in ('EnableUnitFiles', 'DisableUnitFiles') for r in records()[before:])
                # A forged signal must not trigger a refresh.
                ui.wait_settled('control_center')
                time.sleep(.2)
                before = len(records())
                fake.stdin.write('spoof\n'); fake.stdin.flush()
                time.sleep(.25)
                assert len(records()) == before
                fake.stdin.write('change\n'); fake.stdin.flush()
                wait(lambda: 'failed' in labels(), 'live state update')
                assert ui.find('services_search')['text_length'] == 5
                fake.stdin.write('type\n'); fake.stdin.flush()
                wait(lambda: ui.find('notify:alpha.service')['selected_index'] == 1, 'live type update')
                fake.stdin.write('reload-type\n'); fake.stdin.flush()
                wait(lambda: ui.find('notify:alpha.service')['selected_index'] == 2, 'type update after external daemon reload')
                for r in records():
                    if r['method'] in ('StartUnit', 'StopUnit', 'DisableUnitFiles', 'Reload'):
                        assert r['flags'] & 4, r
                if dest := os.environ.get('REDIWM_SETTINGS_PREVIEW'):
                    Path(dest).mkdir(parents=True, exist_ok=True)
                    (Path(dest) / ('services-' + scale + '.png')).unlink(missing_ok=True)
                    ipc.screenshot(str(Path(dest) / ('services-' + scale + '.png')))
                stop_process(fake); fake = None
                wait(lambda: not any(w['name'] == 'services' for w in ui.widgets()), 'systemd disappears')
                assert ipc.get_shell_state()['control_center']['category'] == 'general'
                fake = start_fake()
                wait(lambda: any(w['name'] == 'services' for w in ui.widgets()), 'systemd returns')
                click('services')
                wait(lambda: any('46 services' in label for label in labels()), 'reload after daemon restart')
                # Services enforces enough space for fixed controls and its table.
                window = next(w for w in ipc.get_windows() if w.get('app_id') == 'rediwm-settings')
                ipc.action('set_window_size', {'id': window['id'], 'width': 1120, 'height': 580})
                ui.wait_settled('control_center')
                header = ui.find('Notify')['global_box']
                control = ui.find('notify:alpha.service')['global_box']
                assert abs(header['x'] + 4 - control['x']) < 1 and header['width'] - 8 == control['width'], (header, control)
                if dest := os.environ.get('REDIWM_SETTINGS_PREVIEW'):
                    scroll_service_into_view('Notify')
                    preview = Path(dest) / ('services-column-' + scale + '.png')
                    preview.unlink(missing_ok=True)
                    ipc.screenshot(str(preview))
                ipc.action('set_window_size', {'id': window['id'], 'width': 420, 'height': 320})
                ui.wait_settled('control_center')
                nav = ui.find('services')['global_box']
                box = ipc.get_shell_state()['control_center']['box']
                assert box['width'] >= 1040 and box['height'] >= 640, box
                assert nav['y'] + nav['height'] <= box['y'] + box['height'], (nav, box)
                control = scroll_service_into_view('startup:alpha.service')
                assert control['visible'] and not control['clipped'], control
                control = scroll_service_into_view('notify:alpha.service')
                assert control['visible'] and not control['clipped'], control
                ipc.action('set_window_size', {'id': window['id'], 'width': 960, 'height': 580})
                ui.wait_settled('control_center')
                fake.stdin.write('delay\n'); fake.stdin.flush()
                wait(lambda: any(r['method'] == 'delay_ready' for r in records()), 'delayed reply armed')
                click('services_refresh')
                window = next(w for w in ipc.get_windows() if w.get('app_id') == 'rediwm-settings')
                ipc.close_window(window['id'])
                ui.wait_absent('control_center')
                time.sleep(1.1)
                assert process.poll() is None
                # A new Settings window starts locked. Closing it while polkit
                # is asking withdraws the prompt.
                ipc.open_control_center()
                wait(lambda: any(w['name'] == 'services' for w in ui.widgets()), 'services navigation after reopening')
                click('services')
                wait(lambda: 'Unlock to make service changes.' in labels(), 'locked after reopening')
                (root / 'delay-unlock').touch()
                before = len(checks())
                click('services_unlock')
                wait(lambda: len(checks()) > before, 'unlock prompt started')
                wait(lambda: 'Waiting for authentication…' in labels(), 'unlock pending')
                assert ui.find('services_unlock')['is_disabled'] is True
                window = next(w for w in ipc.get_windows() if w.get('app_id') == 'rediwm-settings')
                ipc.close_window(window['id'])
                ui.wait_absent('control_center')
                wait(lambda: any(r['method'] == 'CancelCheckAuthorization' for r in records()), 'unlock prompt cancelled')
                assert process.poll() is None
                (root / 'delay-unlock').unlink()
                # Closing during authorization cancels and reaps the editor.
                ipc.open_control_center()
                wait(lambda: any(w['name'] == 'services' for w in ui.widgets()), 'services navigation after reopening again')
                click('services')
                wait(lambda: any('46 services' in label for label in labels()), 'list after reopening again')
                click('services_unlock')
                wait(lambda: not ui.find('notify:alpha.service')['is_disabled'], 'type editor after reopening')
                (root / 'delay-edit').touch()
                before = len([r for r in records() if r['method'] == 'EditType'])
                click('notify:alpha.service')
                ipc.key_press('Down')
                ipc.key_press('Return')
                wait(lambda: len([r for r in records() if r['method'] == 'EditType']) > before, 'delayed editor started')
                window = next(w for w in ipc.get_windows() if w.get('app_id') == 'rediwm-settings')
                ipc.close_window(window['id'])
                ui.wait_absent('control_center')
                assert process.poll() is None
                print('PASS: systemd discovery, in-table loading, unlock/lock, services, Notify reads/edits/sorting, isolated drop-ins, timing, search, actions, authorization refusal, live updates, owner loss and close')
        except Exception:
            log.flush()
            print((tmp / 'compositor.log').read_text()[-4000:])
            print('Services status:', [label for label in labels() if 'Notify' in label or 'Authentication' in label or 'service edit' in label])
            if calls.exists(): print(calls.read_text()[-2500:])
            raise
        finally:
            if fake: stop_process(fake)
            stop_process(process)
            log.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scale", default="1")
    parser.add_argument("--services-only", action="store_true")
    args = parser.parse_args()
    systemd_services(args.scale)
    if args.services_only:
        raise SystemExit(0)
    default_applications(args.scale)
    run(args.scale)
    unavailable_services(args.scale)

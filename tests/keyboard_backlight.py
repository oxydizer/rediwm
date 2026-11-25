#!/usr/bin/env python3
"""Keyboard backlight OSD over private D-Bus with two fake LED devices."""
import os
from pathlib import Path
import select
import subprocess
import sys
import tempfile
import time

from PIL import Image, ImageChops

from ipc_client import IPCClient, spawn_compositor, stop_process
from power_profiles import wait_for


FAKE_UPOWER = r'''
import sys
import warnings
warnings.simplefilter("ignore", DeprecationWarning)
from gi.repository import Gio, GLib

NAME = "org.freedesktop.UPower"
IFACE = NAME + ".KbdBacklight"
ROOT = "/org/freedesktop/UPower/KbdBacklight"
PATHS = {"2": ROOT, "3": ROOT + "/testookbd_backlight"}
XML = f"<node><interface name='{IFACE}'><method name='GetMaxBrightness'><arg type='i' direction='out'/></method></interface></node>"
conn = Gio.bus_get_sync(Gio.BusType.SESSION)

def maximum(c, sender, path, interface, method, parameters, invocation):
    invocation.return_value(GLib.Variant("(i)", (2 if path == ROOT else 3,)))

def on_stdin(channel, condition):
    line = sys.stdin.readline()
    if not line:
        return False
    device, level, source = line.split()
    conn.emit_signal(None, PATHS[device], IFACE, "BrightnessChangedWithSource", GLib.Variant("(is)", (int(level), source)))
    conn.flush_sync()
    print("emitted", flush=True)
    return True

interface = Gio.DBusNodeInfo.new_for_xml(XML).interfaces[0]
for path in PATHS.values():
    conn.register_object(path, interface, maximum, None, None)
GLib.io_add_watch(sys.stdin.fileno(), GLib.IO_IN, on_stdin)
Gio.bus_own_name_on_connection(conn, NAME, Gio.BusNameOwnerFlags.NONE, lambda *_: print("ready", flush=True), None)
GLib.MainLoop().run()
'''


def fills(image, scale):
    """Lengths of the accent runs along the centre of the segment bar."""
    y = round(40 * scale)
    row = image.crop((round(54 * scale), y, round(196 * scale), y + 1)).tobytes()
    mask = bytes(r > 170 and r > 2 * g and r > 2 * b for r, g, b in zip(row[::3], row[1::3], row[2::3]))
    return [len(run) for run in mask.split(b'\0') if run]


def exercise(scale):
    with tempfile.TemporaryDirectory(prefix="rediwm-kbd-osd-") as directory:
        tmp = Path(directory)
        wallpaper = tmp / "wallpaper.png"
        Image.new("RGB", (32, 32), (12, 13, 14)).save(wallpaper)
        config = f'''[compositor]
xwayland = false
dock_enabled = false
taskbar_position = "top"
mini_map_enabled = false
wallpaper = "{wallpaper}"
[desktop]
enabled = false
[theme]
shell_accent = "#ff3737"
'''
        with subprocess.Popen([sys.executable, "-c", FAKE_UPOWER], stdin=subprocess.PIPE,
                              stdout=subprocess.PIPE, text=True) as fake:
            try:
                assert select.select([fake.stdout], [], [], 5)[0], "fake UPower did not start"
                assert fake.stdout.readline().strip() == "ready"
                process, log = spawn_compositor(tmp, scale=scale, config_content=config, env_extra={
                    "DBUS_SESSION_BUS_ADDRESS": "",
                    "DBUS_SYSTEM_BUS_ADDRESS": os.environ["DBUS_SESSION_BUS_ADDRESS"],
                })
                try:
                    with IPCClient(tmp) as ipc:
                        ipc.wait_for("wallpaper_presented", timeout_ms=10000)
                        path = tmp / "frame.png"
                        s = float(scale)
                        output = ipc.get_outputs()[0]
                        x = (output['logical_width'] - 212) // 2
                        y = output['logical_height'] - 80
                        box = tuple(round(v * s) for v in (x, y, x + 212, y + 60))

                        def capture():
                            ipc.wait_for_frame(timeout_ms=2000)
                            path.unlink(missing_ok=True)
                            ipc.screenshot(path=str(path))
                            wait_for(path.exists, "screenshot")
                            with Image.open(path) as image:
                                return image.convert("RGB").crop(box)

                        def send(device, level, source="internal"):
                            fake.stdin.write(f"{device} {level} {source}\n")
                            fake.stdin.flush()
                            assert select.select([fake.stdout], [], [], 5)[0], "fake UPower did not emit the signal"
                            assert fake.stdout.readline().strip() == "emitted"

                        baseline = capture()

                        def first_press():
                            send(3, 1)
                            return len(fills(capture(), s)) == 1

                        def filled(count):
                            segments = fills(capture(), s)
                            return segments if len(segments) == count else None

                        wait_for(first_press, "per-device brightness OSD")
                        send(3, 3)
                        full = wait_for(lambda: filled(3), "three lit segments")
                        send(3, 0)

                        def off_shown():
                            frame = capture()
                            return not fills(frame, s) and ImageChops.difference(frame, baseline).getbbox() is not None

                        wait_for(off_shown, "visible OSD for Off")
                        send(2, 2)
                        full_two = wait_for(lambda: filled(2), "two lit segments")
                        assert min(full_two) > max(full), (full_two, full)

                        time.sleep(1.5)
                        send(2, 1, "external")
                        time.sleep(0.2)
                        assert ImageChops.difference(capture(), baseline).getbbox() is None, "external adjustment showed an OSD"
                finally:
                    stop_process(process)
                    log.close()
            finally:
                fake.terminate()
    print(f"PASS keyboard backlight OSD at scale {scale}")


if __name__ == "__main__":
    if sys.platform != "linux":
        sys.exit(0)
    if "--private" not in sys.argv:
        sys.exit(subprocess.call(["dbus-run-session", "--", sys.executable, __file__, "--private"]))
    for scale in ("1", "1.5"):
        exercise(scale)

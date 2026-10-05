#!/usr/bin/env python3
"""[compositor] dark_mode through the compositor's Settings portal backend.

Runs on a private dbus-run-session. First drives
org.freedesktop.impl.portal.Settings directly, then (when xdg-desktop-portal is
installed) through a real xdg-desktop-portal using data/rediwm.portal and
data/rediwm-portals.conf, which is the path browsers read.
"""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
import time

from ipc_client import IPCClient, ROOT, spawn_compositor, stop_process

BACKEND = "org.freedesktop.impl.portal.desktop.rediwm"
PORTAL = "org.freedesktop.portal.Desktop"
PATH = "/org/freedesktop/portal/desktop"
IMPL_IFACE = "org.freedesktop.impl.portal.Settings"
PORTAL_IFACE = "org.freedesktop.portal.Settings"
XDP_CANDIDATES = ("/usr/lib/xdg-desktop-portal", "/usr/libexec/xdg-desktop-portal")


def busctl(dest, iface, member, *args, check=True):
    cmd = ["busctl", "--user", "--timeout=5", "call", dest, PATH, iface, member, *map(str, args)]
    return subprocess.run(cmd, capture_output=True, text=True, timeout=10, check=check)


def wait_for(predicate, description, timeout=5.0, interval=0.05):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = predicate()
        if result:
            return result
        time.sleep(interval)
    raise TimeoutError(f"Timed out waiting for: {description}")


def name_owned(name):
    return subprocess.run(["busctl", "--user", "status", name], capture_output=True).returncode == 0


class SettingChangedWatcher:
    """Collects SettingChanged color-scheme values seen on one interface."""

    def __init__(self, iface):
        self.values = []
        self.proc = subprocess.Popen(
            ["dbus-monitor", "--session", f"type='signal',interface='{iface}',member='SettingChanged'"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        self.thread = threading.Thread(target=self._read, daemon=True)
        self.thread.start()
        # dbus-monitor prints its own NameAcquired/NameLost chatter first; give
        # the match rule time to be installed before anything is emitted.
        time.sleep(0.3)

    def _read(self):
        in_signal = False
        for line in self.proc.stdout:
            if line.startswith("signal "):
                in_signal = "member=SettingChanged" in line
            elif in_signal and "uint32" in line:
                self.values.append(int(line.split()[-1]))
                in_signal = False

    def close(self):
        self.proc.terminate()
        self.proc.wait(timeout=3)


def set_dark_mode(config_path, ipc, dark, extra=""):
    config_path.write_text(f"[compositor]\ndark_mode = {'true' if dark else 'false'}\n{extra}")
    ipc.reload_config()


def test_backend(tmp_dir, config_path, ipc):
    wait_for(lambda: name_owned(BACKEND), f"{BACKEND} acquired")

    read = busctl(BACKEND, IMPL_IFACE, "Read", "ss", "org.freedesktop.appearance", "color-scheme")
    assert read.stdout.strip() == "v u 2", read.stdout
    print("1. default dark_mode = false answers color-scheme 2 (prefer light)")

    everything = busctl(BACKEND, IMPL_IFACE, "ReadAll", "as", 0).stdout.strip()
    assert everything == 'a{sa{sv}} 1 "org.freedesktop.appearance" 1 "color-scheme" u 2', everything
    globbed = busctl(BACKEND, IMPL_IFACE, "ReadAll", "as", 2, "org.gnome.*", "org.freedesktop.*").stdout.strip()
    assert globbed == everything, globbed
    other = busctl(BACKEND, IMPL_IFACE, "ReadAll", "as", 1, "org.gnome.*").stdout.strip()
    assert other == "a{sa{sv}} 0", other
    print("2. ReadAll honours empty, exact and trailing-* namespace patterns")

    missing = busctl(BACKEND, IMPL_IFACE, "Read", "ss", "org.gnome.desktop.interface", "gtk-theme", check=False)
    assert missing.returncode != 0 and "Requested setting not found" in missing.stderr, missing
    print("3. other settings report NotFound so the next backend (gtk) answers them")

    watcher = SettingChangedWatcher(IMPL_IFACE)
    try:
        set_dark_mode(config_path, ipc, True)
        wait_for(lambda: watcher.values == [1], "SettingChanged color-scheme 1")
        read = busctl(BACKEND, IMPL_IFACE, "Read", "ss", "org.freedesktop.appearance", "color-scheme")
        assert read.stdout.strip() == "v u 1", read.stdout
        print("4. reloading dark_mode = true emits SettingChanged 1 and Read follows")

        set_dark_mode(config_path, ipc, True, extra="window_gap = 9\n")
        time.sleep(0.5)
        assert watcher.values == [1], watcher.values
        print("5. a reload that leaves dark_mode alone emits nothing")
    finally:
        watcher.close()


def test_through_xdg_desktop_portal(tmp_dir, config_path, ipc):
    xdp = os.environ.get("REDIWM_TEST_XDP") or next((p for p in XDP_CANDIDATES if os.access(p, os.X_OK)), None)
    if not xdp:
        print("6. SKIP: xdg-desktop-portal not installed")
        return
    portals = tmp_dir / "portals"
    portals.mkdir()
    # Only the shipped descriptor and conf: gtk being absent proves the answer
    # comes from the compositor, and the conf's "rediwm;gtk" order is exercised.
    shutil.copy(ROOT / "data/rediwm.portal", portals)
    shutil.copy(ROOT / "data/rediwm-portals.conf", portals)
    env = dict(os.environ, XDG_DESKTOP_PORTAL_DIR=str(portals), XDG_CURRENT_DESKTOP="rediwm")
    env.pop("WAYLAND_DISPLAY", None)
    env.pop("DISPLAY", None)
    log = (tmp_dir / "xdg-desktop-portal.log").open("w")
    portal = subprocess.Popen([xdp, "--verbose"], env=env, stdout=log, stderr=subprocess.STDOUT)
    watcher = None
    try:
        wait_for(lambda: name_owned(PORTAL), f"{PORTAL} started", timeout=10)
        read = busctl(PORTAL, PORTAL_IFACE, "ReadOne", "ss", "org.freedesktop.appearance", "color-scheme")
        assert read.stdout.strip() == "v u 1", (read.stdout, read.stderr)
        print("6. xdg-desktop-portal with data/rediwm.portal serves color-scheme 1 from the compositor")

        watcher = SettingChangedWatcher(PORTAL_IFACE)
        set_dark_mode(config_path, ipc, False)
        wait_for(lambda: watcher.values == [2], "portal forwards SettingChanged color-scheme 2")
        read = busctl(PORTAL, PORTAL_IFACE, "ReadOne", "ss", "org.freedesktop.appearance", "color-scheme")
        assert read.stdout.strip() == "v u 2", read.stdout
        print("7. xdg-desktop-portal forwards the live change to apps")
    finally:
        if watcher is not None:
            watcher.close()
        portal.terminate()
        try:
            portal.wait(timeout=3)
        except subprocess.TimeoutExpired:
            portal.kill()
        log.close()


def run(tmp_dir):
    compositor, log = spawn_compositor(tmp_dir, env_extra={"REDIWM_FORCE_DBUS": "1"})
    config_path = tmp_dir / "rediwm-config.toml"
    try:
        with IPCClient(tmp_dir) as ipc:
            test_backend(tmp_dir, config_path, ipc)
            test_through_xdg_desktop_portal(tmp_dir, config_path, ipc)
        print("Settings portal: dark_mode tests passed")
    except BaseException:
        log.flush()
        sys.stderr.write((tmp_dir / "compositor.log").read_text()[-4000:])
        raise
    finally:
        stop_process(compositor)
        log.close()


def main():
    if "--private" not in sys.argv:
        sys.exit(subprocess.call(["dbus-run-session", "--", sys.executable, __file__, "--private"]))
    with tempfile.TemporaryDirectory(prefix="rediwm-settings-portal-") as directory:
        run(Path(directory))


if __name__ == "__main__":
    main()

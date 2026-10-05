#!/usr/bin/env python3
"""wlr-output-management, wlr-foreign-toplevel, wlr-screencopy, virtual-pointer
and ext-session-lock with real clients (wlr-randr, wlrctl, swaylock) where they
are installed, and tests/wlr_protocols_client.c for the rest."""
import os
import select
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

from desktop_zoom import ROOT, build_client
from ipc_client import IPCClient, IPCError, spawn_compositor, stop_process
from xwayland import wait_for, wayland_display_name


def compile_fixture(tmp):
    build_client(tmp)
    system = Path(subprocess.check_output(
        ["pkg-config", "--variable=pkgdatadir", "wayland-protocols"], text=True).strip())
    sources = []
    for name, path in (("ext-session-lock-v1", system / "staging/ext-session-lock/ext-session-lock-v1.xml"),
                       ("wlr-screencopy-unstable-v1", ROOT / "protocol/wlr-screencopy-unstable-v1.xml"),
                       ("security-context-v1", system / "staging/security-context/security-context-v1.xml")):
        for mode, suffix in (("client-header", "client-protocol.h"), ("private-code", "protocol.c")):
            subprocess.run(["wayland-scanner", mode, str(path), str(tmp / f"{name}-{suffix}")], check=True)
        sources.append(str(tmp / f"{name}-protocol.c"))
    for name, relative in [("xdg-shell", "stable/xdg-shell/xdg-shell.xml")] + [
            (name + "-v1", f"staging/{name}/{name}-v1.xml") for name in
            ("xdg-toplevel-tag", "content-type", "tearing-control", "color-management",
             "color-representation", "ext-workspace")]:
        for mode, suffix in (("client-header", "client-protocol.h"), ("private-code", "protocol.c")):
            subprocess.run(["wayland-scanner", mode, str(system / relative), str(tmp / f"{name}-{suffix}")], check=True)
        sources.append(str(tmp / f"{name}-protocol.c"))
    subprocess.run(["cc", "-Wall", "-Wextra", "-Werror", f"-I{tmp}", str(ROOT / "tests/wlr_protocols_client.c"),
                    *sources, "-lwayland-client", "-o", str(tmp / "fixture")], check=True)


def locked(ipc):
    try:
        ipc.get_windows()
    except IPCError as exc:
        assert "SessionLocked" in str(exc), exc
        return True
    return False


class Session:
    def __init__(self, tmp, outputs="1", config="[compositor]\nxwayland = false\n", scale="1"):
        self.tmp = tmp
        self.process, self.log = spawn_compositor(tmp, scale=scale, outputs=outputs, config_content=config)
        self.ipc = IPCClient(tmp, timeout=15).connect()
        self.ipc.wait_for("wallpaper_presented", timeout_ms=10000)
        self.env = dict(os.environ, XDG_RUNTIME_DIR=str(tmp), WAYLAND_DISPLAY=wayland_display_name(tmp))
        self.env.pop("DISPLAY", None)
        self.children = []

    def run(self, *argv, ok=True):
        result = subprocess.run(argv, env=self.env, capture_output=True, text=True, timeout=15)
        if ok is not None:
            assert (result.returncode == 0) == ok, (argv, result.returncode, result.stdout, result.stderr)
        return result

    def spawn(self, *argv, stdin=None, stderr=subprocess.DEVNULL):
        child = subprocess.Popen(argv, env=self.env, stdin=stdin, stdout=subprocess.PIPE,
                                 stderr=stderr, text=True)
        self.children.append(child)
        return child

    def window(self, app_id):
        return next((w for w in self.ipc.get_windows() if w["app_id"] == app_id), None)

    def output(self, name):
        return next(o for o in self.ipc.get_outputs() if o["name"] == name)

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


def expect_line(child, wanted, timeout=10):
    """Next stdout line of a fixture, which must be `wanted`."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        ready, _, _ = select.select([child.stdout], [], [], 0.1)
        if ready:
            line = child.stdout.readline().strip()
            assert line == wanted, (line, wanted)
            return
    raise AssertionError(f"fixture did not print {wanted!r}")


def output_management(tmp):
    # REDIWM_SCALE=1 would pin the scale; clients cannot override it.
    s = Session(tmp, outputs="2", scale="auto")
    try:
        listing = s.run("wlr-randr").stdout
        assert "HEADLESS-1" in listing and "HEADLESS-2" in listing, listing

        s.run("wlr-randr", "--output", "HEADLESS-1", "--pos", "2000,100")
        wait_for(lambda: (s.output("HEADLESS-1")["x"], s.output("HEADLESS-1")["y"]) == (2000, 100), "position not applied")
        s.run("wlr-randr", "--output", "HEADLESS-1", "--transform", "90")
        wait_for(lambda: s.output("HEADLESS-1")["transform"] == "90", "transform not applied")
        s.run("wlr-randr", "--output", "HEADLESS-1", "--scale", "1.5")
        wait_for(lambda: s.output("HEADLESS-1")["scale"] == 1.5, "scale not applied")
        s.run("wlr-randr", "--output", "HEADLESS-1", "--scale", "0.5", ok=False)
        assert s.output("HEADLESS-1")["scale"] == 1.5

        # Client changes persist like Settings changes.
        saved = (tmp / "rediwm-config.toml").read_text()
        assert 'name = "HEADLESS-1"' in saved and "x = 2000" in saved, saved

        s.run("wlr-randr", "--output", "HEADLESS-2", "--off")
        wait_for(lambda: not s.output("HEADLESS-2")["enabled"], "output not disabled")
        s.run("wlr-randr", "--output", "HEADLESS-1", "--off", ok=False)
        assert s.output("HEADLESS-1")["enabled"], "last output was disabled"
        s.run("wlr-randr", "--output", "HEADLESS-2", "--on")
        wait_for(lambda: s.output("HEADLESS-2")["enabled"], "output not re-enabled")
        # A fresh listing reflects everything above.
        listing = s.run("wlr-randr").stdout
        assert "Position: 2000,100" in listing and "Scale: 1.500000" in listing, listing
    finally:
        s.close()
    print("PASS: wlr-output-management (wlr-randr)")


def foreign_toplevel(tmp):
    s = Session(tmp)
    try:
        for name in ("one", "two"):
            s.spawn(str(tmp / "client"), "--app-id", f"fixture.{name}", "--title", name.title())
        wait_for(lambda: s.window("fixture.one") and s.window("fixture.two"), "fixtures did not map")
        # The most recently mapped window starts active.
        wait_for(lambda: s.run("wlrctl", "toplevel", "find", "app_id:fixture.two", "state:active", ok=None).returncode == 0,
                 "newly mapped window not reported active")
        listing = s.run("wlrctl", "toplevel", "list").stdout
        assert "fixture.one: One" in listing and "fixture.two: Two" in listing, listing

        s.run("wlrctl", "toplevel", "minimize", "app_id:fixture.one")
        wait_for(lambda: s.window("fixture.one")["is_minimized"], "not minimized")
        s.run("wlrctl", "toplevel", "find", "app_id:fixture.one", "state:minimized")
        s.run("wlrctl", "toplevel", "focus", "app_id:fixture.one")
        wait_for(lambda: not s.window("fixture.one")["is_minimized"] and s.window("fixture.one")["is_focused"],
                 "not restored and focused")
        s.run("wlrctl", "toplevel", "find", "app_id:fixture.one", "state:active")
        s.run("wlrctl", "toplevel", "find", "app_id:fixture.two", "state:active", ok=False)

        s.run("wlrctl", "toplevel", "maximize", "app_id:fixture.two")
        wait_for(lambda: s.window("fixture.two")["is_maximized"], "not maximized")
        # wlrctl 0.2.2 cannot match state:maximized (its enum value is 0,
        # which contains_value rejects); IPC above checks the round trip.
        s.run("wlrctl", "toplevel", "fullscreen", "app_id:fixture.two")
        wait_for(lambda: s.run("wlrctl", "toplevel", "find", "app_id:fixture.two", "state:fullscreen", ok=None).returncode == 0,
                 "not fullscreen")

        s.run("wlrctl", "toplevel", "close", "app_id:fixture.two")
        wait_for(lambda: s.window("fixture.two") is None, "not closed")
        wait_for(lambda: "fixture.two" not in s.run("wlrctl", "toplevel", "list").stdout, "closed window still listed")
    finally:
        s.close()
    print("PASS: wlr-foreign-toplevel-management (wlrctl)")


def screencopy_and_virtual_pointer(tmp):
    s = Session(tmp)
    try:
        copy = s.run(str(tmp / "fixture"), "screencopy").stdout.split()
        assert copy[:3] == ["ready", "1280", "720"] and int(copy[3].split("=")[1]) > 0, copy

        before = s.ipc.get_input_state()
        s.run("wlrctl", "pointer", "move", "40", "30")
        wait_for(lambda: (s.ipc.get_input_state()["pointer_x"], s.ipc.get_input_state()["pointer_y"]) ==
                 (before["pointer_x"] + 40, before["pointer_y"] + 30), "virtual pointer did not move the cursor")
    finally:
        s.close()
    print("PASS: wlr-screencopy and virtual-pointer")


def session_lock(tmp):
    s = Session(tmp, outputs="2", config='[compositor]\nxwayland = false\n[keybinds]\n"F12" = "lock_screen"\n')
    fixture = str(tmp / "fixture")
    try:
        state = s.ipc.get_input_state()
        before = (state["pointer_x"], state["pointer_y"])
        lock = s.spawn(fixture, "lock", stdin=subprocess.PIPE)
        expect_line(lock, "locked")
        assert locked(s.ipc)
        # Everything else is refused while locked.
        refused = s.spawn(fixture, "lock")
        expect_line(refused, "finished")
        copy = s.run(fixture, "screencopy", ok=None)
        assert copy.returncode == 3 and copy.stdout.strip() == "disconnected", (copy.returncode, copy.stdout)
        s.run("wlrctl", "pointer", "move", "300", "200", ok=None)
        s.run("wlrctl", "toplevel", "list")  # the client may list, but not act

        lock.stdin.write("unlock\n")
        lock.stdin.flush()
        expect_line(lock, "unlocked")
        wait_for(lambda: not locked(s.ipc), "client unlock did not unlock")
        state = s.ipc.get_input_state()
        assert (state["pointer_x"], state["pointer_y"]) == before, "virtual pointer moved behind the lock"

        # A lock client that dies leaves the session locked; a new one may take over.
        if shutil.which("swaylock"):
            swaylock = s.spawn("swaylock", "-c", "102030")
            wait_for(lambda: locked(s.ipc), "swaylock did not lock")
            time.sleep(0.3)
            swaylock.kill()
            swaylock.wait()
        else:
            dying = s.spawn(fixture, "lock", stdin=subprocess.PIPE)
            expect_line(dying, "locked")
            dying.stdin.write("exit\n")
            dying.stdin.flush()
            dying.wait()
        time.sleep(0.3)
        assert locked(s.ipc), "session unlocked when the lock client died"
        takeover = s.spawn(fixture, "lock", stdin=subprocess.PIPE)
        expect_line(takeover, "locked")
        takeover.stdin.write("unlock\n")
        takeover.stdin.flush()
        expect_line(takeover, "unlocked")
        wait_for(lambda: not locked(s.ipc), "takeover unlock did not unlock")

        # The built-in lock is never handed to a client.
        try:
            s.ipc.key_press("F12")
        except IPCError as exc:  # the release already meets the lock
            assert "SessionLocked" in str(exc), exc
        wait_for(lambda: locked(s.ipc), "built-in lock did not engage")
        refused = s.spawn(fixture, "lock")
        expect_line(refused, "finished")
        assert locked(s.ipc)
    finally:
        s.close()
    print("PASS: ext-session-lock")


def extra_protocols(tmp):
    config = '[compositor]\nxwayland = false\nallow_tearing = true\n[[window_rules]]\ntag = "settings"\nopacity = 0.75\n'
    s = Session(tmp, outputs="2", config=config)
    try:
        fixture = str(tmp / "fixture")
        registry = s.run(fixture, "dump-registry").stdout
        for interface in ("ext_workspace_manager_v1", "wp_color_manager_v1",
                          "wp_color_representation_manager_v1", "xdg_toplevel_tag_manager_v1",
                          "wp_content_type_manager_v1", "wp_tearing_control_manager_v1",
                          "xdg_activation_v1"):
            assert interface in registry, interface
        assert "wp_drm_lease_device_v1" not in registry, "headless backend must not offer DRM leases"
        with open(tmp / "extras-client.log", "w") as client_log:
            child = s.spawn(fixture, "extras", stdin=subprocess.PIPE, stderr=client_log)
        try:
            expect_line(child, "extras-ready")
        except Exception:
            print((tmp / "extras-client.log").read_text())
            raise
        wait_for(lambda: s.window("rediwm.protocol-extras"), "extras window missing")
        window = s.window("rediwm.protocol-extras")
        assert window["tag"] == "settings" and window["description"] == "Settings window", window
        assert window["content_type"] == "video" and window["workspace_id"] == 1, window
        rules = s.ipc.request(query="get_window_rules", params={"id": window["id"]})
        assert rules["live"]["opacity"] == 0.75, rules
        workspaces = s.ipc.request(query="workspaces")
        assert workspaces == [{"id": 1, "name": "Canvas", "is_focused": True}], workspaces
        child.stdin.write("update\n"); child.stdin.flush()
        expect_line(child, "extras-updated")
        wait_for(lambda: s.window("rediwm.protocol-extras")["content_type"] == "game", "content hint did not update")
        assert s.window("rediwm.protocol-extras")["tag"] == "main"
        rules = s.ipc.request(query="get_window_rules", params={"id": window["id"]})
        assert rules["live"]["opacity"] is None, rules
        child.stdin.write("exit\n"); child.stdin.flush()
        assert child.wait(timeout=5) == 0
        wait_for(lambda: not s.window("rediwm.protocol-extras"), "destroyed extras window remained")
    finally:
        s.close()
    print("PASS: workspace, tags, content hints, tearing hints and renderer colour negotiation")


def run():
    for case in (extra_protocols, output_management, foreign_toplevel, screencopy_and_virtual_pointer, session_lock):
        with tempfile.TemporaryDirectory(prefix="rediwm-wlr-protocols-") as directory:
            tmp = Path(directory)
            compile_fixture(tmp)
            try:
                case(tmp)
            except Exception:
                log = tmp / "compositor.log"
                if log.exists():
                    print(log.read_text()[-6000:])
                raise


if __name__ == "__main__":
    run()

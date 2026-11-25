#!/usr/bin/env python3
"""wlr-output-management, wlr-foreign-toplevel, wlr-screencopy, virtual-pointer
and ext-session-lock with real clients (wlr-randr, wlrctl, swaylock) where they
are installed, and tests/wlr_protocols_client.c for the rest."""
from collections import Counter
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
                       ("xdg-foreign-unstable-v1", system / "unstable/xdg-foreign/xdg-foreign-unstable-v1.xml"),
                       ("xdg-foreign-unstable-v2", system / "unstable/xdg-foreign/xdg-foreign-unstable-v2.xml"),
                       ("wlr-screencopy-unstable-v1", ROOT / "protocol/wlr-screencopy-unstable-v1.xml"),
                       ("security-context-v1", system / "staging/security-context/security-context-v1.xml")):
        for mode, suffix in (("client-header", "client-protocol.h"), ("private-code", "protocol.c")):
            subprocess.run(["wayland-scanner", mode, str(path), str(tmp / f"{name}-{suffix}")], check=True)
        sources.append(str(tmp / f"{name}-protocol.c"))
    for name, relative in [("xdg-shell", "stable/xdg-shell/xdg-shell.xml")] + [
            (name + "-v1", f"staging/{name}/{name}-v1.xml") for name in
            ("xdg-toplevel-tag", "xdg-system-bell", "content-type", "tearing-control", "color-management",
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
    def __init__(self, tmp, outputs="1", config="[compositor]\nxwayland = false\n", scale="1", env_extra=None):
        self.tmp = tmp
        self.process, self.log = spawn_compositor(tmp, scale=scale, outputs=outputs, config_content=config, env_extra=env_extra)
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


def read_line(child, timeout=10):
    assert select.select([child.stdout], [], [], timeout)[0], "timed out waiting for fixture output"
    line = child.stdout.readline()
    assert line, f"fixture exited before replying: {child.poll()}"
    return line.strip()


def expect_line(child, wanted, timeout=10):
    line = read_line(child, timeout)
    assert line == wanted, (line, wanted)


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
        # Headless cannot run variable refresh: switching it on is refused,
        # and the mode stays as configured.
        s.run("wlr-randr", "--output", "HEADLESS-1", "--adaptive-sync", "enabled", ok=False)
        assert s.output("HEADLESS-1")["adaptive_sync"] == "auto"
        # Headless outputs persist HDR settings and keep an SDR signal.
        out = s.output("HEADLESS-2")
        assert (out["hdr"], out["hdr_supported"], out["hdr_active"], out["sdr_white"]) == ("off", False, False, 203), out
        s.ipc.request(query="set_output_config", params={"output": "HEADLESS-2", "hdr": "on", "sdr_white": 250})
        wait_for(lambda: (s.output("HEADLESS-2")["hdr"], s.output("HEADLESS-2")["sdr_white"]) == ("on", 250), "hdr not saved")
        assert not s.output("HEADLESS-2")["hdr_active"]
        for params in ({"sdr_white": 79}, {"sdr_white": 1001}, {"hdr": "auto"}):
            try:
                s.ipc.request(query="set_output_config", params={"output": "HEADLESS-2", **params})
            except IPCError:
                pass
            else:
                raise AssertionError(f"accepted {params}")
        assert s.output("HEADLESS-2")["sdr_white"] == 250

        # Client changes persist like Settings changes.
        saved = (tmp / "rediwm-config.toml").read_text()
        assert 'name = "HEADLESS-1"' in saved and "x = 2000" in saved, saved
        assert 'hdr = "on"' in saved and "sdr_white = 250" in saved, saved

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
        # Keep stdin open until the lock client receives the compositor's reply.
        refused = s.spawn(fixture, "lock", stdin=subprocess.PIPE)
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
        refused = s.spawn(fixture, "lock", stdin=subprocess.PIPE)
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
        registry = s.run(fixture, "dump-registry", "--versions").stdout
        globals_ = [line.split() for line in registry.splitlines() if line and line != "done"]
        versions = {name: int(version) for name, version in globals_}
        assert versions["wl_fixes"] == 1, versions
        # delete_id acknowledges the server released this particular registry.
        released = subprocess.run([fixture, "release-registry"], env=dict(s.env, WAYLAND_DEBUG="client"),
                                  capture_output=True, text=True, check=True, timeout=15)
        registry_id = int(released.stdout.strip())
        assert f".delete_id({registry_id})" in released.stderr, released.stderr
        assert versions["xdg_wm_base"] == 7 and versions["zwlr_layer_shell_v1"] == 5, versions
        assert versions["xdg_system_bell_v1"] == 1, versions
        if "zwp_linux_dmabuf_v1" in versions:
            assert versions["zwp_linux_dmabuf_v1"] == 5, versions
        for interface in ("ext_workspace_manager_v1", "wp_color_manager_v1",
                          "wp_color_representation_manager_v1", "xdg_toplevel_tag_manager_v1",
                          "wp_content_type_manager_v1", "wp_tearing_control_manager_v1",
                          "xdg_activation_v1", "wp_fifo_manager_v1"):
            assert interface in versions, interface
        assert "wp_drm_lease_device_v1" not in versions, "headless backend must not offer DRM leases"
        # Every global is advertised once. linux-dmabuf used to be created both
        # by wlr_renderer_init_wl_display and by setup.zig, and Mesa's WSI bound
        # both and leaked one. Only per-device globals repeat: one wl_output
        # per output (two here), and a seat per seat.
        counts = Counter(name for name, _ in globals_)
        repeated = {name: n for name, n in counts.items() if n > 1 and name not in ("wl_output", "wl_seat")}
        assert not repeated, f"globals advertised more than once: {repeated}"
        assert counts["wl_output"] == 2, counts
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
        # The focused fullscreen window asks for async presentation: its output
        # (and only that one) may tear. Headless never flips asynchronously.
        tearing = lambda: [o["name"] for o in s.ipc.get_outputs() if o["tearing_allowed"]]
        wait_for(lambda: len(tearing()) == 1, "fullscreen async window did not allow tearing")
        assert not any(o["tearing_active"] or o["tearing_paused"] for o in s.ipc.get_outputs())
        # Variable refresh in "auto" (the default) is wanted on the game's
        # output only; headless cannot run it, so it stays off.
        vrr = lambda: [o["name"] for o in s.ipc.get_outputs() if o["adaptive_sync_wanted"]]
        assert vrr() == tearing(), (vrr(), tearing())
        for o in s.ipc.get_outputs():
            assert o["adaptive_sync"] == "auto" and not o["adaptive_sync_supported"], o
            assert not o["adaptive_sync_active"] and not o["adaptive_sync_needs_modeset"], o
        game_output = vrr()[0]
        s.ipc.request(query="set_output_config", params={"output": game_output, "adaptive_sync": "off"})
        wait_for(lambda: not vrr(), "adaptive_sync = off still wanted")
        assert 'adaptive_sync = "off"' in (tmp / "rediwm-config.toml").read_text()
        s.ipc.request(query="set_output_config", params={"output": game_output, "adaptive_sync": "auto"})
        wait_for(lambda: vrr() == [game_output], "adaptive_sync = auto not wanted again")
        workspaces = s.ipc.request(query="workspaces")
        assert workspaces == [{"id": 1, "name": "Canvas", "is_focused": True,
                               "is_visible": True, "output": None, "automatic": False,
                               "window_gap": 0, "nodes": []}], workspaces
        child.stdin.write("update\n"); child.stdin.flush()
        expect_line(child, "extras-updated")
        wait_for(lambda: s.window("rediwm.protocol-extras")["content_type"] == "game", "content hint did not update")
        assert s.window("rediwm.protocol-extras")["tag"] == "main"
        wait_for(lambda: not tearing(), "a vsync hint still allowed tearing")
        # Variable refresh does not depend on the hint: a vsync game still wants it.
        assert vrr() == [game_output], vrr()
        rules = s.ipc.request(query="get_window_rules", params={"id": window["id"]})
        assert rules["live"]["opacity"] is None, rules
        child.stdin.write("exit\n"); child.stdin.flush()
        assert child.wait(timeout=5) == 0
        wait_for(lambda: not s.window("rediwm.protocol-extras"), "destroyed extras window remained")
    finally:
        s.close()
    print("PASS: workspace, tags, content hints, tearing hints and renderer colour negotiation")


def system_bell(tmp):
    theme = tmp / "sounds/bell-test/stereo"
    theme.mkdir(parents=True)
    sound = theme / "bell.wav"
    sound.touch()
    calls = tmp / "playbacks"
    calls.touch()
    player = tmp / "paplay"
    player.write_text('#!/bin/sh\nprintf "%s\\n" "$4" >> "$XDG_RUNTIME_DIR/playbacks"\n')
    player.chmod(0o700)
    config = '[compositor]\nxwayland = false\nsound_theme = "bell-test"\n'
    s = Session(tmp, config=config, env_extra={"XDG_DATA_HOME": str(tmp), "PATH": f"{tmp}:{os.environ['PATH']}"})
    try:
        fixture = str(tmp / "fixture")
        child = s.spawn(fixture, "extras", stdin=subprocess.PIPE)
        expect_line(child, "extras-ready")

        def ring(command, total):
            child.stdin.write(command + "\n")
            child.stdin.flush()
            expect_line(child, "rang")
            wait_for(lambda: len(calls.read_text().splitlines()) >= total, f"{command}: expected {total} playbacks")
            # Catch extra launches in the burst and start the next check outside the cooldown.
            time.sleep(0.35)
            assert calls.read_text().splitlines() == [str(sound)] * total, (command, calls.read_text())

        ring("bell-surface", 1)
        ring("bell-burst", 2)
        for setting in ('sound_disabled_events = ["bell"]', 'sound_enabled = false'):
            (tmp / "rediwm-config.toml").write_text(config + setting + "\n")
            s.ipc.reload_config()
            ring("bell-surface", 2)
        (tmp / "rediwm-config.toml").write_text(config)
        s.ipc.reload_config()
        marker = theme / "bell.disabled"
        marker.touch()
        ring("bell-surface", 2)
        marker.unlink()

        lock = s.spawn(fixture, "lock", stdin=subprocess.PIPE)
        expect_line(lock, "locked")
        ring("bell-burst", 2)
        lock.stdin.write("unlock\n")
        lock.stdin.flush()
        expect_line(lock, "unlocked")
        ring("bell-surface", 3)
        child.stdin.write("exit\n")
        child.stdin.flush()
        assert child.wait(timeout=5) == 0
        result = s.ipc.action("play_sound", {"event": "bell"})
        assert result["event"] == "bell" and result["pid"] > 0, result
        wait_for(lambda: calls.read_text().splitlines() == [str(sound)] * 4, "IPC sound did not play")
    finally:
        s.close()
    print("PASS: xdg-system-bell playback, burst coalescing, mute and session lock")


def xdg_foreign(tmp):
    s = Session(tmp, config='[compositor]\nxwayland = false\ndesktop_mode = "workspaces"\n')
    try:
        def launch(version, *args):
            return s.spawn(str(tmp / "fixture"), "xdg-foreign", str(version), *args, stdin=subprocess.PIPE)

        def advance(client):
            client.stdin.write("\n")
            client.stdin.flush()

        def finish(client):
            advance(client)
            assert client.wait(timeout=5) == 0

        for export_version, import_version in ((1, 1), (2, 2), (1, 2), (2, 1)):
            parent = launch(export_version)
            handle = read_line(parent)
            assert handle
            child = launch(import_version, handle)
            expect_line(child, "parented")
            child_id = s.window("rediwm.foreign-child")["id"]
            parent_id = s.window("rediwm.foreign-parent")["id"]

            # Moving the child to another workspace carries its actual owner with it.
            s.ipc.action("move_to_workspace", {"id": child_id, "workspace": 2})
            assert s.window("rediwm.foreign-parent")["workspace_id"] == 2
            advance(parent)
            expect_line(child, "revoked")
            s.ipc.action("move_to_workspace", {"id": parent_id, "workspace": 1})
            assert s.window("rediwm.foreign-child")["workspace_id"] == 2
            finish(child)

            stale = launch(import_version, handle)
            expect_line(stale, "revoked")
            finish(stale)
            finish(parent)
    finally:
        s.close()
    print("PASS: xdg-foreign v1/v2 parenting, cross-version handles and revocation")


def run():
    for case in (xdg_foreign, system_bell, extra_protocols, output_management, foreign_toplevel, screencopy_and_virtual_pointer, session_lock):
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

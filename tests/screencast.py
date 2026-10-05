#!/usr/bin/env python3
"""Portal packaging, picker, child environment and Stop sharing integration.
See docs/screen-sharing.md. The full portal/PipeWire consumer path is not
exercised here, even when xdg-desktop-portal-wlr is installed.
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

from desktop_zoom import ROOT, wait_for
from ipc_client import IPCClient, spawn_compositor, stop_process

from capture import build_client, get_capture_state, wait_for_capture_sessions

PICKER = ROOT / "zig-out/bin/rediwm-share-picker"
PORTALS_CONF = ROOT / "zig-out/share/xdg-desktop-portal/rediwm-portals.conf"

# Must match src/share_picker/client.zig.
HEADER_H = 64
ROW_H = 44


def run_picker(args, stdin_text="", extra_env=None, timeout=10):
    env = dict(os.environ)
    if extra_env:
        env.update(extra_env)
    result = subprocess.run(
        [str(PICKER), *args],
        input=stdin_text,
        capture_output=True,
        text=True,
        timeout=timeout,
        env=env,
    )
    return result


def test_picker_dmenu_select_and_cancel():
    labels = "Monitor: eDP-1 Built-in\nMonitor: HDMI-A-1\n"
    selected = run_picker(["--xdpw-dmenu", "--select-index", "1"], labels)
    assert selected.returncode == 0, selected.stderr
    assert selected.stdout == "Monitor: HDMI-A-1\n", selected.stdout
    assert selected.stderr == "", selected.stderr

    cancelled = run_picker(["--xdpw-dmenu", "--cancel"], labels)
    assert cancelled.returncode == 0, cancelled.stderr
    assert cancelled.stdout == "", cancelled.stdout

    missing = run_picker(["--xdpw-dmenu", "--select-index", "9"], labels)
    assert missing.returncode == 0, missing.stderr
    assert missing.stdout == "", missing.stdout
    print("screencast: picker dmenu select/cancel/out-of-range match the xdpw contract")


def test_picker_duplicate_and_malformed_titles():
    labels = "same title\n\nnot a source at all\nsame title\nWindow: (untitled)\n"
    first = run_picker(["--xdpw-dmenu", "--select-index", "0"], labels)
    second = run_picker(["--xdpw-dmenu", "--select-index", "2"], labels)
    assert first.stdout == "same title\n", first.stdout
    assert second.stdout == "same title\n", second.stdout
    exact = run_picker(["--xdpw-dmenu", "--select-label", "not a source at all"], labels)
    assert exact.stdout == "not a source at all\n", exact.stdout
    declined = run_picker(["--xdpw-dmenu", "--select-label", "same title "], labels)
    assert declined.stdout == "", declined.stdout
    print("screencast: picker keeps duplicate and malformed titles as opaque labels")


def test_picker_diagnose_finds_packaged_portals_conf():
    assert PORTALS_CONF.is_file(), PORTALS_CONF
    text = PORTALS_CONF.read_text()
    assert "org.freedesktop.impl.portal.ScreenCast=wlr" in text, text
    assert "Screenshot" not in text, text
    data_dirs = str(ROOT / "zig-out/share") + ":" + os.environ.get("XDG_DATA_DIRS", "/usr/share")
    result = run_picker(["--diagnose"], extra_env={"XDG_DATA_DIRS": data_dirs})
    assert result.returncode == 0, result.stderr
    combined = result.stdout + result.stderr
    assert "rediwm-portals.conf: ok" in combined, combined
    print("screencast: packaged rediwm-portals.conf is found by --diagnose")


def test_child_env_desktop_identity_and_nested_activation():
    with tempfile.TemporaryDirectory(prefix="rediwm-screencast-env-") as directory:
        tmp = Path(directory)
        compositor, log = spawn_compositor(
            tmp, scale="1", outputs="1",
            config_content="[compositor]\nxwayland = false\n",
            env_extra={
                "XDG_CACHE_HOME": str(tmp / "cache"),
                "XDG_CONFIG_HOME": str(tmp / "config"),
                "XDG_DATA_HOME": str(tmp / "data"),
                "XDG_CURRENT_DESKTOP": "sway",
            })
        try:
            with IPCClient(socket_path=tmp, timeout=15) as ipc:
                env_path = tmp / "child.env"
                ipc.action("spawn", {"argv": ["/bin/sh", "-c", f"env > {env_path}"]})
                wait_for(lambda: env_path.exists() and env_path.stat().st_size > 0, "child env not written")
                child = env_path.read_text()
                assert "XDG_CURRENT_DESKTOP=rediwm" in child, child
                assert "XDG_SESSION_TYPE=wayland" in child, child
                assert "WAYLAND_DISPLAY=" in child, child

                info = ipc.query("get_runtime_info")
                assert info["current_desktop"] == "rediwm", info
                assert info["nested"] is True, info

                log_text = (tmp / "compositor.log").read_text()
                assert "not publishing to the host bus" in log_text, log_text
                xdpw_config = tmp / "config" / "xdg-desktop-portal-wlr" / "rediwm"
                assert not xdpw_config.exists(), xdpw_config
                print("screencast: children get XDG_CURRENT_DESKTOP=rediwm; nested does not touch the host bus")
        except Exception:
            print((tmp / "compositor.log").read_text()[-6000:])
            raise
        finally:
            if compositor.poll() is None:
                stop_process(compositor)
            log.close()


def test_capture_indicator_stops_sharing(client_binary):
    with tempfile.TemporaryDirectory(prefix="rediwm-screencast-indicator-") as directory:
        tmp = Path(directory)
        compositor, log = spawn_compositor(
            tmp, scale="1", outputs="1",
            config_content="[compositor]\nxwayland = false\n",
            env_extra={"XDG_CACHE_HOME": str(tmp / "cache")})
        client = None
        client_log = tmp / "client.log"
        try:
            display = wait_for(lambda: next((p.name for p in tmp.glob("wayland-*")
                                             if not p.name.endswith(".lock")), None),
                               "WAYLAND_DISPLAY missing")
            env = dict(os.environ, XDG_RUNTIME_DIR=str(tmp), WAYLAND_DISPLAY=display)
            with client_log.open("w") as output:
                client = subprocess.Popen([str(client_binary)], stdin=subprocess.PIPE,
                                          stdout=output, stderr=output, text=True, env=env)
            with IPCClient(socket_path=tmp, timeout=15) as ipc:
                wait_for(lambda: next((w for w in ipc.get_windows()
                                       if w["app_id"] == "rediwm.capture-fixture"), None),
                         "capture-fixture toplevel did not map")
                wait_for(lambda: "presented\n" in client_log.read_text(), "first frame not presented")
                ipc.wait_for_frame()

                client.stdin.write("capture\n")
                client.stdin.flush()
                wait_for(lambda: "ready" in client_log.read_text(), "capture session did not become ready")
                state = wait_for_capture_sessions(ipc, 1, "session missing")
                indicator = wait_for(lambda: (s := get_capture_state(ipc)).get("indicator") or None,
                                     "capture indicator did not appear")
                box = indicator["box"]
                assert box["width"] > 0 and box["height"] > 0, indicator
                hit = ipc.query("hit_test", {
                    "x": box["x"] + box["width"] // 2,
                    "y": box["y"] + box["height"] // 2,
                })
                assert hit["target_type"] == "taskbar", hit
                assert hit["widget"] == "capture_indicator", hit

                ipc.click_at(box["x"] + box["width"] // 2, box["y"] + box["height"] // 2)
                wait_for_capture_sessions(ipc, 0, "Stop sharing did not clear capture sessions")
                wait_for(lambda: client.poll() is not None, "capturing client was not disconnected")
                state = get_capture_state(ipc)
                assert state["last_failure"] == "stop_all", state
                assert state.get("indicator") is None, state
                print("screencast: taskbar Stop sharing indicator revokes a live session")

                for keycode in (125, 42):
                    ipc.action("key", {"keycode": keycode, "pressed": True})
                try:
                    ipc.action("key", {"keycode": 18, "pressed": True})
                except EOFError:
                    pass
            compositor.wait(timeout=10)
            assert compositor.returncode == 0, (tmp / "compositor.log").read_text()
        except Exception:
            print((tmp / "compositor.log").read_text()[-6000:])
            if client_log.exists():
                print(client_log.read_text())
            raise
        finally:
            if client and client.poll() is None:
                stop_process(client)
            if compositor.poll() is None:
                stop_process(compositor)
            log.close()


def test_picker_gui_select_and_escape():
    labels = "Monitor: HEADLESS-1\nMonitor: other\n"

    def run_gui(click_first: bool):
        with tempfile.TemporaryDirectory(prefix="rediwm-screencast-picker-") as directory:
            tmp = Path(directory)
            compositor, log = spawn_compositor(
                tmp, scale="1", outputs="1",
                config_content="[compositor]\nxwayland = false\n",
                env_extra={"XDG_CACHE_HOME": str(tmp / "cache")})
            picker = None
            picker_err = tmp / "picker.err"
            try:
                display = wait_for(lambda: next((p.name for p in tmp.glob("wayland-*")
                                                 if not p.name.endswith(".lock")), None),
                                   "WAYLAND_DISPLAY missing")
                env = dict(os.environ, XDG_RUNTIME_DIR=str(tmp), WAYLAND_DISPLAY=display)
                with picker_err.open("w") as err:
                    picker = subprocess.Popen(
                        [str(PICKER), "--xdpw-dmenu"],
                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=err,
                        text=True, env=env)
                picker.stdin.write(labels)
                picker.stdin.close()
                with IPCClient(socket_path=tmp, timeout=15) as ipc:
                    win = wait_for(lambda: next((w for w in ipc.get_windows()
                                                 if w["app_id"] == "rediwm-share-picker"), None),
                                   "share picker did not map")
                    ipc.action("focus_window", {"id": win["id"]})
                    ipc.wait_for_frame()
                    debug = ipc.get_window_debug(win["id"])
                    box = debug["client_box"]
                    if click_first:
                        ipc.click_at(box["x"] + box["width"] // 2,
                                     box["y"] + HEADER_H + ROW_H // 2)
                    else:
                        ipc.key_press("Escape")
                    stdout, _ = picker.communicate(timeout=10)
                    if click_first:
                        assert stdout == "Monitor: HEADLESS-1\n", (stdout, picker_err.read_text())
                    else:
                        assert stdout == "", (stdout, picker_err.read_text())
                    assert picker.returncode != 127, picker_err.read_text()
                print("screencast: picker GUI {} via the production --xdpw-dmenu path".format(
                    "selected the first label" if click_first else "cancelled on Escape"))
            except Exception:
                print((tmp / "compositor.log").read_text()[-6000:])
                if picker_err.exists():
                    print(picker_err.read_text())
                raise
            finally:
                if picker and picker.poll() is None:
                    stop_process(picker)
                if compositor.poll() is None:
                    stop_process(compositor)
                log.close()

    run_gui(True)
    run_gui(False)


def test_portal_screencast_skipped_without_xdpw():
    if shutil.which("xdg-desktop-portal-wlr"):
        print("screencast: xdg-desktop-portal-wlr is installed; isolated portal/PipeWire drive is not automated here yet")
        return
    print("screencast: xdg-desktop-portal-wlr not installed — portal/PipeWire consumer path untested, not passing")


def main():
    assert PICKER.is_file(), f"rediwm-share-picker missing; run zig build first ({PICKER})"
    test_picker_dmenu_select_and_cancel()
    test_picker_duplicate_and_malformed_titles()
    test_picker_diagnose_finds_packaged_portals_conf()
    test_child_env_desktop_identity_and_nested_activation()

    with tempfile.TemporaryDirectory(prefix="rediwm-screencast-build-") as directory:
        tmp = Path(directory)
        build_client(tmp)
        test_capture_indicator_stops_sharing(tmp / "client")

    test_picker_gui_select_and_escape()
    test_portal_screencast_skipped_without_xdpw()
    print("screencast: stage 2 desktop integration checks passed")


if __name__ == "__main__":
    main()

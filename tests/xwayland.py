#!/usr/bin/env python3
"""Xwayland environment and connection tests. Run after zig build.

Does not use the host DISPLAY. The compositor owns a lazy Xwayland display
and publishes it through GetRuntimeInfo / child spawn env.
"""
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def wait_for(check, message, timeout=15):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = check()
        if result:
            return result
        time.sleep(0.03)
    raise AssertionError(message() if callable(message) else message)


def start_compositor(tmp, config_text, env_overrides=None):
    (tmp / "config.toml").write_text(config_text)
    env = dict(
        os.environ,
        XDG_RUNTIME_DIR=str(tmp),
        WLR_BACKENDS="headless",
        WLR_HEADLESS_OUTPUTS="1",
        WLR_RENDERER="pixman",
        REDIWM_SCALE="1",
        REDIWM_CONFIG=str(tmp / "config.toml"),
        REDIWM_IPC_AUTOMATION="1",
    )
    env.update(env_overrides or {})
    env.pop("WAYLAND_DISPLAY", None)
    env.pop("REDIWM_SOCKET", None)
    # Host X11 must not leak into the compositor process: children inherit
    # through applyChildEnv, and the nested backend (if any) is Wayland.
    env.pop("DISPLAY", None)
    env.pop("XAUTHORITY", None)
    log = (tmp / "compositor.log").open("w")
    compositor = subprocess.Popen(
        [str(ROOT / "zig-out/bin/rediwm")],
        env=env,
        stdout=log,
        stderr=log,
        start_new_session=True,
    )
    return compositor, log


def ipc_connect(tmp):
    path = wait_for(lambda: next(tmp.glob("rediwm-*.sock"), None), "IPC socket did not appear")
    sock = socket.socket(socket.AF_UNIX)
    sock.settimeout(10)
    sock.connect(str(path))
    return sock, sock.makefile("r")


def wayland_display_name(tmp):
    path = wait_for(
        lambda: next((p for p in tmp.glob("wayland-*") if not p.name.endswith(".lock")), None),
        "Wayland socket did not appear",
    )
    return path.name


def request(sock, reader, value):
    sock.sendall((json.dumps(value) + "\n").encode())
    result = json.loads(reader.readline())
    assert "Ok" in result, result
    return result["Ok"]


def test_enabled():
    with tempfile.TemporaryDirectory(prefix="rediwm-xwayland-") as directory:
        tmp = Path(directory)
        compositor, log = start_compositor(tmp, "[compositor]\nxwayland = true\n")
        try:
            sock, reader = ipc_connect(tmp)
            with sock:
                info = request(sock, reader, {'version': 1, 'command': 'get_runtime_info'})["RuntimeInfo"]
                assert info["xwayland_enabled"] is True, info
                display = info["xwayland_display"]
                assert display and display.startswith(":"), display

                # First X client, immediately after startup, before ready.
                env_path = tmp / "child.env"
                request(sock, reader, {"version": 1, "command": 'spawn', "params": {"argv": [
                    "/bin/sh", "-c", f"env > {env_path}",
                ]}})
                wait_for(lambda: env_path.exists() and env_path.stat().st_size > 0, "child env not written")
                child_env = env_path.read_text()
                assert f"DISPLAY={display}" in child_env, child_env
                assert "WAYLAND_DISPLAY=" in child_env, child_env
                assert "REDIWM_SOCKET=" in child_env, child_env

                probe = subprocess.run(
                    ["xdpyinfo", "-display", display],
                    capture_output=True,
                    text=True,
                    timeout=10,
                    env=dict(os.environ, DISPLAY=display),
                )
                assert probe.returncode == 0, probe.stderr + probe.stdout
                print(f"PASS: enabled Xwayland on {display}")
        finally:
            compositor.terminate()
            compositor.wait(timeout=5)
            log.close()


def test_native_scaling_root_geometry(factor=2, output_policy=False):
    """When xwayland_native_scaling is enabled, Xwayland root geometry is scaled
    by N = ceil(max_scale) and RESOURCE_MANAGER properties (Xft.dpi and Xcursor.size)
    are set.
    """
    with tempfile.TemporaryDirectory(prefix="rediwm-xwayland-native-scaling-") as directory:
        tmp = Path(directory)
        compositor, log = start_compositor(
            tmp,
            "[compositor]\nxwayland = true\nxwayland_native_scaling = true\n" +
            (f"xwayland_scale = {factor}\n" if factor != 2 else "") +
            ('[[outputs]]\nname = "HEADLESS-1"\nscale = 1.5\n' if output_policy else ""),
            {"REDIWM_SCALE": "auto" if output_policy else "1.5"},
        )
        try:
            sock, reader = ipc_connect(tmp)
            with sock:
                info = request(sock, reader, {'version': 1, 'command': 'get_runtime_info'})["RuntimeInfo"]
                assert info["xwayland_enabled"] is True, info
                assert info["xwayland_native_scaling"] is True, info
                assert info["xwayland_scale"] == factor, info
                assert info["xwayland_scale_pending"] is None, info
                display = info["xwayland_display"]
                assert display and display.startswith(":"), display

                # Native scaling must reserve DISPLAY without launching the
                # server. The first connection still gets settled output scale.
                time.sleep(.2)
                startup = request(sock, reader, {'version': 1, 'command': 'get_performance_stats'})["PerformanceStats"]["startup"]
                assert startup["xwayland_ready_ns"] == 0, startup

                probe = subprocess.run(
                    ["xdpyinfo", "-display", display],
                    capture_output=True,
                    text=True,
                    timeout=10,
                    env=dict(os.environ, DISPLAY=display),
                )
                assert probe.returncode == 0, probe.stderr + probe.stdout
                # Default headless output 1920x1080 @ 1.5x -> 1280x720 logical; * N(2) -> 2560x1440
                assert f"{round(1280 * factor)}x{round(720 * factor)} pixels" in probe.stdout, probe.stdout

                rdb = subprocess.run(
                    ["xrdb", "-display", display, "-query"],
                    capture_output=True,
                    text=True,
                    timeout=10,
                    env=dict(os.environ, DISPLAY=display),
                )
                assert rdb.returncode == 0, rdb.stderr + rdb.stdout
                assert abs(float(next(line.split(":", 1)[1] for line in rdb.stdout.splitlines() if line.startswith("Xft.dpi:"))) - 96 * factor) < 0.01, rdb.stdout
                assert "Xcursor.size:\t24" in rdb.stdout or "Xcursor.size: 24" in rdb.stdout, rdb.stdout
                print(f"PASS: native scaling root geometry and RESOURCE_MANAGER hints on {display}")
        finally:
            compositor.terminate()
            compositor.wait(timeout=5)
            log.close()


def test_disabled():
    with tempfile.TemporaryDirectory(prefix="rediwm-xwayland-off-") as directory:
        tmp = Path(directory)
        compositor, log = start_compositor(tmp, "[compositor]\nxwayland = false\n")
        try:
            sock, reader = ipc_connect(tmp)
            with sock:
                info = request(sock, reader, {'version': 1, 'command': 'get_runtime_info'})["RuntimeInfo"]
                assert info["xwayland_enabled"] is False, info
                assert info["xwayland_display"] is None, info

                env_path = tmp / "child.env"
                request(sock, reader, {"version": 1, "command": 'spawn', "params": {"argv": [
                    "/bin/sh", "-c", f"env > {env_path}",
                ]}})
                wait_for(lambda: env_path.exists() and env_path.stat().st_size > 0, "child env not written")
                child_env = env_path.read_text()
                for line in child_env.splitlines():
                    assert not line.startswith("DISPLAY="), child_env
                    assert not line.startswith("XAUTHORITY="), child_env
                assert "WAYLAND_DISPLAY=" in child_env, child_env
                print("PASS: disabled Xwayland strips host DISPLAY")
        finally:
            compositor.terminate()
            compositor.wait(timeout=5)
            log.close()


def test_missing_executable():
    """An enabled configuration remains a usable native compositor when
    Xwayland is absent from PATH, and never republishes the host DISPLAY.
    """
    with tempfile.TemporaryDirectory(prefix="rediwm-xwayland-missing-") as directory:
        tmp = Path(directory)
        empty_path = tmp / "empty-bin"
        empty_path.mkdir()
        compositor, log = start_compositor(
            tmp, "[compositor]\nxwayland = true\n", {"PATH": str(empty_path)}
        )
        try:
            sock, reader = ipc_connect(tmp)
            with sock:
                info = request(sock, reader, {'version': 1, 'command': 'get_runtime_info'})["RuntimeInfo"]
                assert info["xwayland_enabled"] is False, info
                assert info["xwayland_display"] is None, info
                env_path = tmp / "missing.env"
                request(sock, reader, {"version": 1, "command": 'spawn', "params": {"argv": [
                    "/bin/sh", "-c", f"env > {env_path}",
                ]}})
                wait_for(lambda: env_path.exists(), "native child did not launch without Xwayland")
                assert not any(line.startswith("DISPLAY=") for line in env_path.read_text().splitlines())
                print("PASS: missing Xwayland leaves native clients usable and strips DISPLAY")
        finally:
            compositor.terminate()
            compositor.wait(timeout=5)
            log.close()


def test_server_stop_cleanup():
    """Stopping the owned Xwayland wrapper removes its published DISPLAY while the
    compositor and its native IPC surface remain alive. A later compositor
    must then be able to reserve and start a fresh Xwayland instance.
    """
    with tempfile.TemporaryDirectory(prefix="rediwm-xwayland-crash-") as directory:
        tmp = Path(directory)
        build_client(tmp)
        compositor, log = start_compositor(tmp, "[compositor]\nxwayland = true\n", {
            "MALLOC_PERTURB_": "165", "GLIBC_TUNABLES": "glibc.malloc.tcache_count=0",
        })
        client = None
        try:
            sock, reader = ipc_connect(tmp)
            with sock:
                display = request(sock, reader, {'version': 1, 'command': 'get_runtime_info'})["RuntimeInfo"]["xwayland_display"]
                client = subprocess.Popen(
                    [str(tmp / "x11-client")],
                    env=dict(os.environ, DISPLAY=display, XDG_RUNTIME_DIR=str(tmp)),
                    stdin=subprocess.PIPE,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    text=True,
                )
                wait_for(
                    lambda: any(w.get("backend") == "xwayland" for w in request(sock, reader, {'version': 1, 'command': 'windows'})["Windows"]),
                    "live X11 client did not map before stop test",
                    timeout=20,
                )
                # One read callback sees both requests before idle dispatch.
                # They must coalesce rather than queue two frees of the wrapper.
                sock.sendall((json.dumps({"StopXwayland": {}}) + "\n").encode() * 2)
                for _ in range(2):
                    reply = json.loads(reader.readline())
                    assert "Ok" in reply, reply
                retired = wait_for(
                    lambda: (info if not (info := request(sock, reader, {'version': 1, 'command': 'get_runtime_info'})["RuntimeInfo"])["xwayland_enabled"] else None),
                    "compositor did not retire the stopped Xwayland instance",
                )
                assert retired["xwayland_display"] is None, retired
                assert compositor.poll() is None, "Xwayland disconnect terminated the compositor"
                print("PASS: Xwayland failure leaves the native compositor usable")
        finally:
            if client and client.poll() is None:
                client.terminate()
                client.wait(timeout=5)
            compositor.terminate()
            compositor.wait(timeout=5)
            log.close()

        # A clean next session catches stale X sockets or ownership left by
        # the forced teardown above.
        next_runtime = tmp / "next"
        next_runtime.mkdir(mode=0o700)
        compositor, log = start_compositor(next_runtime, "[compositor]\nxwayland = true\n")
        try:
            sock, reader = ipc_connect(next_runtime)
            with sock:
                display = request(sock, reader, {'version': 1, 'command': 'get_runtime_info'})["RuntimeInfo"]["xwayland_display"]
                probe = subprocess.run(["xdpyinfo", "-display", display], capture_output=True, timeout=10)
                assert probe.returncode == 0, probe.stderr
                print("PASS: a subsequent session starts a fresh Xwayland server")
        finally:
            compositor.terminate()
            compositor.wait(timeout=5)
            log.close()


def build_client(tmp):
    subprocess.run(
        ["cc", "-Wall", "-Wextra", str(ROOT / "tests/xwayland_client.c"), "-lxcb", "-o", str(tmp / "x11-client")],
        check=True,
    )


def test_managed_window():
    with tempfile.TemporaryDirectory(prefix="rediwm-xwayland-win-") as directory:
        tmp = Path(directory)
        build_client(tmp)
        compositor, log = start_compositor(tmp, "[compositor]\nxwayland = true\n")
        client = None
        try:
            sock, reader = ipc_connect(tmp)
            with sock:
                info = request(sock, reader, {'version': 1, 'command': 'get_runtime_info'})["RuntimeInfo"]
                display = info["xwayland_display"]
                assert display

                client_log = tmp / "client.log"
                client_env = dict(os.environ, DISPLAY=display, XDG_RUNTIME_DIR=str(tmp))
                client_env.pop("WAYLAND_DISPLAY", None)
                with client_log.open("w") as clog:
                    client = subprocess.Popen(
                        [str(tmp / "x11-client")],
                        env=client_env,
                        stdin=subprocess.PIPE,
                        stdout=clog,
                        stderr=clog,
                        text=True,
                    )

                def windows():
                    return request(sock, reader, {'version': 1, 'command': 'windows'})["Windows"]

                win = wait_for(
                    lambda: next((w for w in windows() if w.get("backend") == "xwayland"), None),
                    "X11 window did not appear",
                    timeout=20,
                )
                assert win["backend"] == "xwayland"
                assert win["app_id"] == "XwaylandFixture" or win["x11_class"] == "XwaylandFixture", win
                assert win["is_minimized"] is False
                wid = win["id"]

                request(sock, reader, {"version": 1, "command": 'focus_window', "params": {"id": wid}})
                focused = request(sock, reader, {'version': 1, 'command': 'focused_window'})["FocusedWindow"]
                assert focused and focused["id"] == wid, focused

                debug = request(sock, reader, {"version": 1, "command": 'get_window_debug', "params": {"id": wid}})["WindowDebug"]
                assert debug["chrome_box"]["width"] > 0 and debug["chrome_box"]["height"] > 0, debug

                client.stdin.write("title Live X11 Title\n")
                client.stdin.flush()
                wait_for(lambda: next((w for w in windows() if w["id"] == wid and w["title"] == "Live X11 Title"), None),
                         "live X11 title change did not reach IPC/taskbar state")
                client.stdin.write("class live-instance LiveX11Class\n")
                client.stdin.flush()
                wait_for(lambda: next((w for w in windows() if w["id"] == wid and w.get("x11_class") == "LiveX11Class"), None),
                         "live WM_CLASS change did not reach IPC/taskbar state")
                print("PASS: live X11 title and WM_CLASS changes update shared window state")

                request(sock, reader, {"version": 1, "command": 'minimize_window', "params": {"id": wid}})
                wait_for(lambda: next((w for w in windows() if w["id"] == wid and w["is_minimized"]), None),
                         "X11 minimize did not apply")
                request(sock, reader, {"version": 1, "command": 'restore_window', "params": {"id": wid}})
                wait_for(lambda: next((w for w in windows() if w["id"] == wid and not w["is_minimized"]), None),
                         "X11 restore from minimized did not apply")
                print("PASS: X11 minimize and restore work through shared shell controls")

                request(sock, reader, {"version": 1, "command": 'set_window_size', "params": {"id": wid, "width": 480, "height": 320}})
                wait_for(
                    lambda: (d := request(sock, reader, {"version": 1, "command": 'get_window_debug', "params": {"id": wid}})["WindowDebug"])
                    and d["client_box"]["width"] == 480 and d["client_box"]["height"] == 320,
                    "resize did not apply",
                )

                request(sock, reader, {"version": 1, "command": 'move_window_to', "params": {"id": wid, "x": 180, "y": 140}})
                original = wait_for(
                    lambda: next((w for w in windows() if w["id"] == wid and w["x"] == 180 and w["y"] == 140), None),
                    "window did not reach restore-test position",
                )
                original_geometry = (original["x"], original["y"], original["width"], original["height"])

                request(sock, reader, {"version": 1, "command": 'maximize_window', "params": {"id": wid}})
                wait_for(
                    lambda: next((w for w in windows() if w["id"] == wid and w["is_maximized"] and w["width"] > original["width"]), None),
                    lambda: (f"X11 maximize did not apply: {next((w for w in windows() if w['id'] == wid), None)}; "
                             f"client events: {client_log.read_text()!r}"),
                )
                request(sock, reader, {"version": 1, "command": 'restore_window', "params": {"id": wid}})
                wait_for(
                    lambda: next((w for w in windows() if w["id"] == wid and not w["is_maximized"] and
                                  (w["x"], w["y"], w["width"], w["height"]) == original_geometry), None),
                    "X11 un-maximize did not restore position and size",
                )
                print("PASS: X11 maximize restores saved geometry")

                request(sock, reader, {"version": 1, "command": 'fullscreen_window', "params": {"id": wid}})
                wait_for(
                    lambda: request(sock, reader, {"version": 1, "command": 'get_window_debug', "params": {"id": wid}})["WindowDebug"]["fullscreen"],
                    "X11 fullscreen did not apply",
                )
                request(sock, reader, {"version": 1, "command": 'fullscreen_window', "params": {"id": wid}})
                wait_for(
                    lambda: (not request(sock, reader, {"version": 1, "command": 'get_window_debug', "params": {"id": wid}})["WindowDebug"]["fullscreen"] and
                             (lambda w: (w["x"], w["y"], w["width"], w["height"]) == original_geometry)(
                                 next(w for w in windows() if w["id"] == wid))),
                    "X11 leaving fullscreen did not restore position and size",
                )
                print("PASS: X11 fullscreen restores saved geometry")

                client.stdin.write("unmap\n")
                client.stdin.flush()
                wait_for(lambda: all(w["id"] != wid for w in windows()), "X11 unmap left a visible window")
                client.stdin.write("map\n")
                client.stdin.flush()
                wait_for(lambda: any(w["id"] == wid for w in windows()), "X11 remap did not restore the same window")
                print("PASS: X11 window unmaps and remaps with a stable id")

                role_box = request(sock, reader, {"version": 1, "command": 'get_window_debug', "params": {"id": wid}})["WindowDebug"]["client_box"]
                role_x, role_y = role_box["x"] + 20, role_box["y"] + 20
                client.stdin.write("unmap\n")
                client.stdin.flush()
                wait_for(lambda: all(w["id"] != wid for w in windows()), "managed-to-override transition kept a taskbar window")
                client.stdin.write("override 1\n")
                client.stdin.flush()
                time.sleep(0.1)
                client.stdin.write("map\n")
                client.stdin.flush()
                hit = wait_for(
                    lambda: (h if (h := request(sock, reader, {"version": 1, "command": 'hit_test', "params": {"x": role_x, "y": role_y}})["HitTest"])["target_type"] == "xwayland_unmanaged" else None),
                    lambda: (f"managed-to-override transition did not create an unmanaged hit target: "
                             f"{request(sock, reader, {"version": 1, "command": 'hit_test', "params": {'x': role_x, 'y': role_y}})['HitTest']}; "
                             f"events={client_log.read_text()!r}"),
                )
                assert hit["target_type"] == "xwayland_unmanaged"

                client.stdin.write("unmap\n")
                client.stdin.flush()
                time.sleep(0.1)
                client.stdin.write("override 0\n")
                client.stdin.flush()
                time.sleep(0.1)
                client.stdin.write("map\n")
                client.stdin.flush()
                transitioned = wait_for(
                    lambda: next((w for w in windows() if w.get("backend") == "xwayland"), None),
                    "override-to-managed transition did not recreate a managed window",
                )
                wid = transitioned["id"]
                print("PASS: live override-redirect role changes work in both directions")

                client.stdin.write("popup\n")
                client.stdin.flush()
                time.sleep(0.3)
                box = request(sock, reader, {"version": 1, "command": 'get_window_debug', "params": {"id": wid}})["WindowDebug"]["client_box"]
                hit = request(sock, reader, {"version": 1, "command": 'hit_test', "params": {"x": box["x"] + 30, "y": box["y"] + 30}})["HitTest"]
                assert hit["target_type"] in ("xwayland_unmanaged", "window"), hit
                print("PASS: override-redirect popup is hittable")

                request(sock, reader, {"version": 1, "command": 'close_window', "params": {"id": wid}})
                wait_for(lambda: all(w["id"] != wid for w in windows()), "X11 window did not close")
                print("PASS: managed X11 window maps, focuses, resizes, closes")
        finally:
            if client and client.poll() is None:
                client.terminate()
                client.wait(timeout=5)
            compositor.terminate()
            compositor.wait(timeout=5)
            log.close()


def test_native_scaling_managed_window(factor=2):
    """Managed X11 window scaling, projection, input coordinates, resize,
    maximize/restore, and unmanaged popup hit testing with a selectable rendering factor.
    """
    import math
    from PIL import Image

    with tempfile.TemporaryDirectory(prefix="rediwm-xwayland-native-win-") as directory:
        tmp = Path(directory)
        build_client(tmp)
        compositor, log = start_compositor(
            tmp,
            f"[compositor]\nxwayland = true\nxwayland_native_scaling = true\nxwayland_scale = {factor}\n",
            {"REDIWM_SCALE": "1.5"},
        )
        client = None
        try:
            sock, reader = ipc_connect(tmp)
            with sock:
                info = request(sock, reader, {'version': 1, 'command': 'get_runtime_info'})["RuntimeInfo"]
                assert info["xwayland_native_scaling"] is True
                assert info["xwayland_scale"] == factor
                display = info["xwayland_display"]
                assert display

                client_log = tmp / "client.log"
                client_env = dict(os.environ, DISPLAY=display, XDG_RUNTIME_DIR=str(tmp))
                client_env.pop("WAYLAND_DISPLAY", None)
                with client_log.open("w") as clog:
                    client = subprocess.Popen(
                        [str(tmp / "x11-client")],
                        env=client_env,
                        stdin=subprocess.PIPE,
                        stdout=clog,
                        stderr=clog,
                        text=True,
                    )

                def windows():
                    return request(sock, reader, {'version': 1, 'command': 'windows'})["Windows"]

                win = wait_for(
                    lambda: next((w for w in windows() if w.get("backend") == "xwayland"), None),
                    "X11 window did not appear",
                    timeout=20,
                )
                wid = win["id"]

                # Surface pixels map back to logical client dimensions.
                dbg = request(sock, reader, {"version": 1, "command": 'get_window_debug', "params": {"id": wid}})["WindowDebug"]
                cbox = dbg["client_box"]
                assert dbg["titlebar_height"] == 41, dbg
                assert cbox["width"] == math.ceil(400 / factor) and cbox["height"] == math.ceil(300 / factor), f"Unexpected client geometry at factor {factor}: {cbox}"

                # Focus window
                request(sock, reader, {"version": 1, "command": 'focus_window', "params": {"id": wid}})

                # Screenshot check at a 1.5x output scale.
                shot_path = tmp / "shot.png"
                time.sleep(0.3)
                request(sock, reader, {"version": 1, "command": 'screenshot', "params": {"path": str(shot_path)}})
                wait_for(lambda: shot_path.exists() and shot_path.stat().st_size > 0, "screenshot not saved")
                with Image.open(shot_path) as img:
                    white_coords = [
                        (x, y)
                        for y in range(round((cbox["y"] + 10) * 1.5), round((cbox["y"] + 20) * 1.5))
                        for x in range(img.width)
                        if img.getpixel((x, y))[:3] == (255, 255, 255)
                    ]
                    assert white_coords, "no white pixels found in screenshot"
                    min_x = min(x for x, y in white_coords)
                    max_x = max(x for x, y in white_coords)
                    min_y = min(y for x, y in white_coords)
                    # Measure an interior band, excluding text, corners and skirt.
                    assert abs(max_x - min_x + 1 - 600 / factor) <= 1, f"Expected device width near {600 / factor}, got {max_x - min_x + 1}"
                    client_crop = img.crop((min_x, min_y, min_x + int(600 / factor) - 1, min_y + 10))
                    assert client_crop.convert("RGB").getextrema() == ((255, 255), (255, 255), (255, 255)), "client area not solid white"
                print("PASS: native scaled X11 window renders downscaled buffer at expected device pixels")

                # Avoid exact fractional-to-integer boundaries in X11 event truncation.
                request(sock, reader, {"version": 1, "command": 'move_cursor', "params": {"x": cbox["x"] + 51, "y": cbox["y"] + 41}})
                request(sock, reader, {'version': 1, 'command': 'pointer_button', 'params': {"button": 272, "pressed": True}})
                request(sock, reader, {'version': 1, 'command': 'pointer_button', 'params': {"button": 272, "pressed": False}})

                def get_client_lines():
                    if not client_log.exists():
                        return []
                    return [l.strip() for l in client_log.read_text().splitlines() if l.strip()]

                wait_for(
                    lambda: f"button-press 1 {math.floor(51 * factor)} {math.floor(41 * factor)}" in get_client_lines(),
                    lambda: f"Expected scaled button event in log, got: {get_client_lines()}",
                    timeout=5,
                )
                print("PASS: pointer button click scales world coordinates x N into X11 coordinates")

                # Pointer motion with implicit grab: drag outside window
                client.stdin.write("log-motion 1\n")
                client.stdin.flush()
                time.sleep(0.1)
                request(sock, reader, {"version": 1, "command": 'move_cursor', "params": {"x": cbox["x"] + 51, "y": cbox["y"] + 41}})
                request(sock, reader, {'version': 1, 'command': 'pointer_button', 'params': {"button": 272, "pressed": True}})
                request(sock, reader, {"version": 1, "command": 'move_cursor', "params": {"x": cbox["x"] + 251, "y": cbox["y"] + 201}})
                request(sock, reader, {'version': 1, 'command': 'pointer_button', 'params': {"button": 272, "pressed": False}})
                client.stdin.write("log-motion 0\n")
                client.stdin.flush()

                wait_for(
                    lambda: f"motion {math.floor(251 * factor)} {math.floor(201 * factor)}" in get_client_lines(),
                    lambda: f"Expected scaled grab motion in log, got: {get_client_lines()}",
                    timeout=5,
                )
                print("PASS: pointer motion grab extrapolates correctly with scale N")

                # Odd logical sizes must round trip without accumulating pixels.
                request(sock, reader, {"version": 1, "command": 'set_window_size', "params": {"id": wid, "width": 481, "height": 321}})
                wait_for(
                    lambda: any(f"{math.floor(481 * factor + 1e-9)} {math.floor(321 * factor + 1e-9)}" in l for l in get_client_lines() if l.startswith("configure")),
                    lambda: f"Expected scaled configure dimensions in log, got: {get_client_lines()}",
                    timeout=5,
                )
                wait_for(
                    lambda: (d := request(sock, reader, {"version": 1, "command": 'get_window_debug', "params": {"id": wid}})["WindowDebug"])
                    and d["client_box"]["width"] == 481 and d["client_box"]["height"] == 321,
                    "resize to 481x321 did not apply in compositor debug box",
                    timeout=5,
                )
                print("PASS: SetWindowSize scales dimensions by N when configuring X11 window")

                # Maximize and Restore
                request(sock, reader, {"version": 1, "command": 'move_window_to', "params": {"id": wid, "x": 180, "y": 140}})
                original = wait_for(
                    lambda: next((w for w in windows() if w["id"] == wid and w["x"] == 180 and w["y"] == 140), None),
                    "window did not reach restore-test position",
                )
                original_geometry = (original["x"], original["y"], original["width"], original["height"])

                request(sock, reader, {"version": 1, "command": 'maximize_window', "params": {"id": wid}})
                wait_for(
                    lambda: next((w for w in windows() if w["id"] == wid and w["is_maximized"] and w["width"] > original["width"]), None),
                    "X11 maximize did not apply",
                    timeout=5,
                )
                request(sock, reader, {"version": 1, "command": 'restore_window', "params": {"id": wid}})
                wait_for(
                    lambda: next((w for w in windows() if w["id"] == wid and not w["is_maximized"] and
                                  (w["x"], w["y"], w["width"], w["height"]) == original_geometry), None),
                    "X11 un-maximize did not restore position and size",
                    timeout=5,
                )
                print("PASS: Maximize and Restore roundtrip correctly under native scaling")

                time.sleep(0.3)  # Let the restore presentation settle.

                # Unmanaged override-redirect popup hit testing
                cbox = request(sock, reader, {"version": 1, "command": 'get_window_debug', "params": {"id": wid}})["WindowDebug"]["client_box"]
                client.stdin.write("popup\n")
                client.stdin.flush()

                hit = wait_for(
                    lambda: (
                        h
                        if (h := request(sock, reader, {"version": 1, "command": 'hit_test', "params": {"x": cbox["x"] + round(60 / factor), "y": cbox["y"] + round(40 / factor)}})["HitTest"])["target_type"] == "xwayland_unmanaged"
                        else None
                    ),
                    lambda: f"override-redirect popup was not hittable: {request(sock, reader, {"version": 1, "command": 'hit_test', "params": {'x': cbox['x'] + 20, 'y': cbox['y'] + 15}})['HitTest']}",
                    timeout=5,
                )
                assert hit["target_type"] == "xwayland_unmanaged", f"Expected xwayland_unmanaged, got {hit}"
                print("PASS: override-redirect popup is positioned and hit-tested with scale 1/N")

                # Click the visibly scaled close control.
                dbg = request(sock, reader, {"version": 1, "command": 'get_window_debug', "params": {"id": wid}})["WindowDebug"]
                frame = dbg["chrome_box"]
                request(sock, reader, {"version": 1, "command": 'move_cursor', "params": {"x": frame["x"] + frame["width"] - 1 - 22, "y": frame["y"] + dbg["titlebar_height"] // 2}})
                request(sock, reader, {'version': 1, 'command': 'pointer_button', 'params': {"button": 272, "pressed": True}})
                request(sock, reader, {'version': 1, 'command': 'pointer_button', 'params': {"button": 272, "pressed": False}})
                wait_for(lambda: all(w["id"] != wid for w in windows()), "X11 window did not close")
                print("PASS: native scaled managed X11 window lifecycle completed successfully")
        finally:
            if client and client.poll() is None:
                client.terminate()
                client.wait(timeout=5)
            compositor.terminate()
            compositor.wait(timeout=5)
            log.close()


def start_x11_client(tmp, display, log_path, *args):
    client_env = dict(os.environ, DISPLAY=display, XDG_RUNTIME_DIR=str(tmp))
    client_env.pop("WAYLAND_DISPLAY", None)
    with log_path.open("w") as clog:
        return subprocess.Popen(
            [str(tmp / "x11-client"), *args],
            env=client_env,
            stdin=subprocess.PIPE,
            stdout=clog,
            stderr=clog,
            text=True,
        )


def test_unmapped_window_has_no_chrome():
    """An X11 window that is configured and titled but never mapped must not
    show a frame. Its chrome used to be painted and hit-testable at the
    configured position, and clicking it focused a toplevel that was never
    linked into the window stack, crashing the compositor (seen live with
    ONLYOFFICE, which creates windows it never maps)."""
    with tempfile.TemporaryDirectory(prefix="rediwm-xwayland-unmapped-") as directory:
        tmp = Path(directory)
        build_client(tmp)
        compositor, log = start_compositor(tmp, "[compositor]\nxwayland = true\n")
        client = None
        try:
            sock, reader = ipc_connect(tmp)
            with sock:
                display = request(sock, reader, {'version': 1, 'command': 'get_runtime_info'})["RuntimeInfo"]["xwayland_display"]
                client_log = tmp / "client.log"
                client = start_x11_client(tmp, display, client_log, "--no-map", "--title", "Never Mapped")
                wait_for(lambda: "created" in client_log.read_text(), "X11 client did not start", timeout=20)
                client.stdin.write("configure 200 150 500 400\n")
                client.stdin.flush()
                time.sleep(0.3)  # The retitle must see the configured size.
                client.stdin.write("title Never Mapped Retitled\n")
                client.stdin.flush()
                time.sleep(0.5)

                points = [(450, 160), (450, 180), (210, 300), (450, 350), (699, 300)]
                for x, y in points:
                    hit = request(sock, reader, {"version": 1, "command": 'hit_test', "params": {"x": x, "y": y}})["HitTest"]
                    assert hit["target_type"] == "none", (x, y, hit)
                    request(sock, reader, {"version": 1, "command": 'move_cursor', "params": {"x": x, "y": y}})
                    request(sock, reader, {'version': 1, 'command': 'pointer_button', 'params': {"button": 272, "pressed": True}})
                    request(sock, reader, {'version': 1, 'command': 'pointer_button', 'params': {"button": 272, "pressed": False}})
                assert compositor.poll() is None, "compositor died clicking where an unmapped X11 window sits"
                assert all(w.get("backend") != "xwayland" for w in request(sock, reader, {'version': 1, 'command': 'windows'})["Windows"])

                client.stdin.write("map\n")
                client.stdin.flush()
                win = wait_for(
                    lambda: next((w for w in request(sock, reader, {'version': 1, 'command': 'windows'})["Windows"]
                                  if w.get("backend") == "xwayland"), None),
                    "X11 window did not appear once mapped",
                )
                debug = request(sock, reader, {"version": 1, "command": 'get_window_debug', "params": {"id": win["id"]}})["WindowDebug"]
                title_x = debug["chrome_box"]["x"] + debug["chrome_box"]["width"] // 2
                title_y = debug["chrome_box"]["y"] + 10
                hit = request(sock, reader, {"version": 1, "command": 'hit_test', "params": {"x": title_x, "y": title_y}})["HitTest"]
                assert hit["target_type"] == "chrome", hit
                print("PASS: an unmapped X11 window has no visible or clickable frame until it maps")
        finally:
            if client and client.poll() is None:
                client.terminate()
                client.wait(timeout=5)
            compositor.terminate()
            compositor.wait(timeout=5)
            log.close()


def test_withdrawn_window_survives_close_animation():
    """Unmapping without destroying (an X11 withdraw, a tray app hiding its
    window) plays the close animation. When it finished, the toplevel used to
    be freed while the X11 surface still had its listeners attached, so the
    next map or destroy ran on freed memory."""
    with tempfile.TemporaryDirectory(prefix="rediwm-xwayland-withdraw-") as directory:
        tmp = Path(directory)
        build_client(tmp)
        compositor, log = start_compositor(tmp, "[compositor]\nxwayland = true\n")
        client = None
        try:
            sock, reader = ipc_connect(tmp)
            with sock:
                display = request(sock, reader, {'version': 1, 'command': 'get_runtime_info'})["RuntimeInfo"]["xwayland_display"]
                client_log = tmp / "client.log"
                client = start_x11_client(tmp, display, client_log)

                def windows():
                    return request(sock, reader, {'version': 1, 'command': 'windows'})["Windows"]

                wid = wait_for(
                    lambda: next((w["id"] for w in windows() if w.get("backend") == "xwayland"), None),
                    "X11 window did not appear",
                    timeout=20,
                )
                for _ in range(2):
                    time.sleep(0.8)  # Let the open animation settle.
                    client.stdin.write("unmap\n")
                    client.stdin.flush()
                    wait_for(lambda: all(w["id"] != wid for w in windows()), "X11 unmap left a visible window")
                    time.sleep(1.5)  # Outlast the close animation.
                    assert compositor.poll() is None, "compositor died finishing a withdrawn window's close animation"
                    client.stdin.write("title Withdrawn And Back\n")
                    client.stdin.flush()
                    client.stdin.write("map\n")
                    client.stdin.flush()
                    wait_for(lambda: any(w["id"] == wid for w in windows()),
                             "withdrawn X11 window did not come back with its id")
                client.stdin.write("close\n")
                client.stdin.flush()
                wait_for(lambda: all(w["id"] != wid for w in windows()), "X11 window did not close")
                time.sleep(1.5)
                assert compositor.poll() is None, "compositor died destroying a previously withdrawn window"
                request(sock, reader, {'version': 1, 'command': 'windows'})
                print("PASS: a withdrawn X11 window outlives its close animation and remaps")
        finally:
            if client and client.poll() is None:
                client.terminate()
                client.wait(timeout=5)
            compositor.terminate()
            compositor.wait(timeout=5)
            log.close()


def test_gtk_menu_alignment():
    """A real GtkMenu's override-redirect popup carries a WM_TRANSIENT_FOR
    hint, unlike tests/xwayland_client.c's synthetic popup. This exercises
    xwayland_unmanaged.zig's parent-relative syncPosition() math (not just
    the parentless x/y-equals-root-coordinates fallback) against a parent
    that has been moved, and exercises the popup keyboard-focus grant added
    for grab_focus / wantsKeyboard() (Escape dismissal) - twice, at two
    different parent positions, to catch focus/position bugs that only show
    up on a second interaction.

    Each right-click lands at a different surface-local offset from the
    previous one. wlr_seat's pointer motion is deduplicated by surface-local
    position: a synthetic PointerButton with no preceding wl_pointer.motion
    (because the local position happened to repeat) never reaches Xwayland's
    X11 translation, even with input.seat.pointerNotifyFrame() called after
    every motion/button (see warpCursor / SyntheticPointer.sendButton). Two
    clicks at the exact same local offset is the one case this harness can't
    yet drive reliably; varying the offset sidesteps it without masking it.
    """
    with tempfile.TemporaryDirectory(prefix="rediwm-xwayland-gtk-") as directory:
        tmp = Path(directory)
        compositor, log = start_compositor(tmp, "[compositor]\nxwayland = true\n")
        client = None
        try:
            sock, reader = ipc_connect(tmp)
            with sock:
                info = request(sock, reader, {'version': 1, 'command': 'get_runtime_info'})["RuntimeInfo"]
                display = info["xwayland_display"]
                assert display

                client_log = tmp / "gtk-client.log"
                client_env = dict(
                    os.environ,
                    DISPLAY=display,
                    XDG_RUNTIME_DIR=str(tmp),
                    GDK_BACKEND="x11",
                )
                client_env.pop("WAYLAND_DISPLAY", None)
                with client_log.open("w") as clog:
                    client = subprocess.Popen(
                        [sys.executable, str(ROOT / "tests/xwayland_gtk_client.py")],
                        env=client_env,
                        stdin=subprocess.PIPE,
                        stdout=clog,
                        stderr=clog,
                        text=True,
                    )

                def windows():
                    return request(sock, reader, {'version': 1, 'command': 'windows'})["Windows"]

                win = wait_for(
                    lambda: next(
                        (w for w in windows() if w.get("backend") == "xwayland"
                         and "Gtk" in (w.get("x11_class") or "")),
                        None,
                    ),
                    "GTK X11 window did not appear",
                    timeout=20,
                )
                wid = win["id"]

                def client_box():
                    return request(sock, reader, {"version": 1, "command": 'get_window_debug', "params": {"id": wid}})["WindowDebug"]["client_box"]

                def hit_type(x, y):
                    return request(sock, reader, {"version": 1, "command": 'hit_test', "params": {"x": x, "y": y}})["HitTest"]["target_type"]

                def right_click(x, y):
                    request(sock, reader, {"version": 1, "command": 'move_cursor', "params": {"x": x, "y": y}})
                    request(sock, reader, {'version': 1, 'command': 'pointer_button', 'params': {"button": 273, "pressed": True}})
                    request(sock, reader, {'version': 1, 'command': 'pointer_button', 'params': {"button": 273, "pressed": False}})

                # Move the parent to two different positions and click at two
                # different local offsets each time: syncPosition()'s parent-
                # offset math and the popup focus grant must not be an
                # artifact of whatever position/offset happened to be used
                # once (see the docstring for why the offset must vary).
                for (target_x, target_y), (ox, oy) in (
                    ((250, 220), (60, 60)),
                    ((700, 120), (100, 90)),
                ):
                    request(sock, reader, {"version": 1, "command": 'move_window_to', "params": {"id": wid, "x": target_x, "y": target_y}})
                    wait_for(lambda: abs(client_box()["x"] - target_x) < 4, "window did not move")

                    box = client_box()
                    px, py = box["x"] + ox, box["y"] + oy
                    right_click(px, py)
                    wait_for(
                        lambda: hit_type(px + 5, py + 5) == "xwayland_unmanaged",
                        f"context menu not aligned to pointer at parent ({target_x},{target_y})",
                        timeout=5,
                    )
                    print(f"PASS: GTK context menu aligned with parent at ({target_x},{target_y})")

                    request(sock, reader, {'version': 1, 'command': 'key_press', 'params': {"key": "Escape"}})
                    wait_for(
                        lambda: hit_type(px + 5, py + 5) != "xwayland_unmanaged",
                        "context menu did not dismiss on Escape",
                        timeout=5,
                    )
                    print("PASS: Escape dismisses a real GTK context menu (keyboard focus grant)")

                client.stdin.write("quit\n")
                client.stdin.flush()
        finally:
            if client and client.poll() is None:
                client.terminate()
                client.wait(timeout=5)
            compositor.terminate()
            compositor.wait(timeout=5)
            log.close()


def test_gtk_transient_dialog():
    """A managed (non-override-redirect) GtkDialog with WM_TRANSIENT_FOR set
    exercises Toplevel.owner(), World.raiseTransientChildren() and the
    focus-restore-to-owner path in Toplevel.handleUnmapped() - none of which
    xwayland_gtk_client.py's override-redirect popup touches, since dialogs
    go through the ordinary managed-window path, not xwayland_unmanaged.zig.
    """
    with tempfile.TemporaryDirectory(prefix="rediwm-xwayland-dialog-") as directory:
        tmp = Path(directory)
        compositor, log = start_compositor(tmp, "[compositor]\nxwayland = true\n")
        client = None
        try:
            sock, reader = ipc_connect(tmp)
            with sock:
                info = request(sock, reader, {'version': 1, 'command': 'get_runtime_info'})["RuntimeInfo"]
                display = info["xwayland_display"]
                assert display

                client_log = tmp / "gtk-dialog-client.log"
                client_env = dict(
                    os.environ,
                    DISPLAY=display,
                    XDG_RUNTIME_DIR=str(tmp),
                    GDK_BACKEND="x11",
                )
                client_env.pop("WAYLAND_DISPLAY", None)
                with client_log.open("w") as clog:
                    client = subprocess.Popen(
                        [sys.executable, str(ROOT / "tests/xwayland_gtk_dialog_client.py")],
                        env=client_env,
                        stdin=subprocess.PIPE,
                        stdout=clog,
                        stderr=clog,
                        text=True,
                    )

                def windows():
                    return request(sock, reader, {'version': 1, 'command': 'windows'})["Windows"]

                def find(title):
                    return next((w for w in windows() if w.get("title") == title), None)

                main_win = wait_for(
                    lambda: find("GTK Dialog Fixture"), "main window did not appear", timeout=20
                )
                main_id = main_win["id"]
                request(sock, reader, {"version": 1, "command": 'move_window_to', "params": {"id": main_id, "x": 100, "y": 100}})

                client.stdin.write("dialog\n")
                client.stdin.flush()
                dialog_win = wait_for(lambda: find("Dialog"), "dialog window did not appear", timeout=10)
                dialog_id = dialog_win["id"]
                assert dialog_id != main_id
                # Deliberately overlap the two: stacking is only interesting
                # to assert where they actually cover the same pixels.
                request(sock, reader, {"version": 1, "command": 'move_window_to', "params": {"id": dialog_id, "x": 150, "y": 150}})
                wait_for(lambda: find("Dialog")["x"] == 150, "dialog did not move")

                def top_at(x, y):
                    return request(sock, reader, {"version": 1, "command": 'hit_test', "params": {"x": x, "y": y}})["HitTest"].get("window_id")

                overlap = find("Dialog")
                ox, oy = overlap["x"] + 20, overlap["y"] + 20
                wait_for(lambda: top_at(ox, oy) == dialog_id, "dialog is not on top of its owner after opening")
                print("PASS: transient dialog opens above its owner")

                # Raise the owner (taskbar click, alt-tab, ...): the dialog
                # must be re-raised with it, not left behind underneath.
                request(sock, reader, {"version": 1, "command": 'focus_window', "params": {"id": main_id}})
                wait_for(
                    lambda: top_at(ox, oy) == dialog_id,
                    "raising the owner left the transient dialog behind it",
                )
                print("PASS: raising the owner keeps the transient dialog above it")

                # Put keyboard focus back on the dialog itself before closing
                # it, so the owner-restore path below is actually exercised
                # instead of trivially true because focus was left on the
                # owner by the FocusWindow call above.
                request(sock, reader, {"version": 1, "command": 'focus_window', "params": {"id": dialog_id}})
                wait_for(
                    lambda: (f := request(sock, reader, {'version': 1, 'command': 'focused_window'})["FocusedWindow"]) and f["id"] == dialog_id,
                    "could not focus the dialog before closing it",
                )

                client.stdin.write("close_dialog\n")
                client.stdin.flush()
                wait_for(lambda: find("Dialog") is None, "dialog did not close")
                wait_for(
                    lambda: (f := request(sock, reader, {'version': 1, 'command': 'focused_window'})["FocusedWindow"]) and f["id"] == main_id,
                    "focus did not return to the dialog's owner on close",
                )
                print("PASS: closing the transient dialog restores focus to its owner")

                client.stdin.write("dialog\n")
                client.stdin.flush()
                wait_for(lambda: find("Dialog"), "second dialog did not appear")
                client.stdin.write("destroy_owner\n")
                client.stdin.flush()
                wait_for(
                    lambda: find("GTK Dialog Fixture") is None and find("Dialog") is not None,
                    "destroying the owner also lost or corrupted its live child",
                )
                assert request(sock, reader, {'version': 1, 'command': 'get_runtime_info'})["RuntimeInfo"]["xwayland_enabled"]
                client.stdin.write("close_dialog\n")
                client.stdin.flush()
                client.wait(timeout=5)
                client = None
                wait_for(lambda: not any(w.get("backend") == "xwayland" for w in windows()),
                         "owner-first destruction left an X11 child behind")
                print("PASS: destroying a transient owner first preserves then cleans up its child")
        finally:
            if client and client.poll() is None:
                client.terminate()
                client.wait(timeout=5)
            compositor.terminate()
            compositor.wait(timeout=5)
            log.close()


def x11_pointer_window_name(display):
    """Read X11's actual input target, independently of the scene HitTest."""
    import ctypes as c
    xlib = c.CDLL("libX11.so.6")
    ptr, window, integer = c.c_void_p, c.c_ulong, c.c_int
    xlib.XOpenDisplay.argtypes = [c.c_char_p]
    xlib.XOpenDisplay.restype = ptr
    xlib.XDefaultRootWindow.argtypes = [ptr]
    xlib.XDefaultRootWindow.restype = window
    xlib.XQueryPointer.argtypes = [ptr, window, c.POINTER(window), c.POINTER(window),
                                  *[c.POINTER(integer)] * 4, c.POINTER(c.c_uint)]
    xlib.XFetchName.argtypes = [ptr, window, c.POINTER(c.c_char_p)]
    xlib.XFree.argtypes = [ptr]
    xlib.XCloseDisplay.argtypes = [ptr]
    connection = xlib.XOpenDisplay(display.encode())
    assert connection, display
    try:
        root, child = window(), window()
        rx, ry, wx, wy = integer(), integer(), integer(), integer()
        mask = c.c_uint()
        xlib.XQueryPointer(connection, xlib.XDefaultRootWindow(connection),
                           c.byref(root), c.byref(child), c.byref(rx), c.byref(ry),
                           c.byref(wx), c.byref(wy), c.byref(mask))
        if not child.value:
            return None
        name = c.c_char_p()
        xlib.XFetchName(connection, child, c.byref(name))
        try:
            return name.value.decode() if name.value else None
        finally:
            if name.value is not None:
                xlib.XFree(name)
    finally:
        xlib.XCloseDisplay(connection)


def test_gtk_file_dialog(native=False, factor=0):
    """Check X11's input target before any move/resize and click GTK Cancel,
    then raise the owner and repeat. HitTest alone cannot prove delivery.
    """
    with tempfile.TemporaryDirectory(prefix="rediwm-xwayland-filedialog-") as directory:
        tmp = Path(directory)
        compositor, log = start_compositor(
            tmp, "[compositor]\nxwayland = true\nxwayland_native_scaling = " + str(native).lower() + f"\nxwayland_scale = {factor}\n",
            env_overrides={"REDIWM_SCALE": "1.5" if native else "1"},
        )
        client = None
        try:
            sock, reader = ipc_connect(tmp)
            with sock:
                info = request(sock, reader, {'version': 1, 'command': 'get_runtime_info'})["RuntimeInfo"]
                display = info["xwayland_display"]
                assert display

                client_log = tmp / "gtk-client.log"
                client_env = dict(
                    os.environ,
                    DISPLAY=display,
                    XDG_RUNTIME_DIR=str(tmp),
                    GDK_BACKEND="x11",
                    GSETTINGS_BACKEND="memory",
                    GDK_SCALE="1",
                    GDK_DPI_SCALE="1",
                )
                client_env.pop("WAYLAND_DISPLAY", None)
                with client_log.open("w") as clog:
                    client = subprocess.Popen(
                        [sys.executable, str(ROOT / "tests/xwayland_gtk_dialog_client.py")],
                        env=client_env,
                        stdin=subprocess.PIPE,
                        stdout=clog,
                        stderr=clog,
                        text=True,
                    )

                def windows():
                    return request(sock, reader, {'version': 1, 'command': 'windows'})["Windows"]

                def find(title):
                    return next((w for w in windows() if w.get("title") == title), None)

                main_win = wait_for(lambda: find("GTK Dialog Fixture"), "main window did not appear", timeout=20)
                main_id = main_win["id"]

                request(sock, reader, {"version": 1, "command": 'move_window_to', "params": {"id": main_id, "x": 0, "y": 0}})
                request(sock, reader, {"version": 1, "command": 'set_window_size', "params": {"id": main_id, "width": 1200, "height": 620}})
                time.sleep(0.3)
                client.stdin.write("filedialog\n")
                client.stdin.flush()
                fd_win = wait_for(lambda: find("Open File"), "file dialog did not appear", timeout=10)
                fd_id = fd_win["id"]
                assert fd_id != main_id

                time.sleep(0.5)
                box = request(sock, reader, {"version": 1, "command": 'get_window_debug', "params": {"id": fd_id}})["WindowDebug"]["client_box"]
                # Inspect a visible client point before any dialog move/resize.
                request(sock, reader, {"version": 1, "command": 'move_cursor', "params": {"x": box["x"] + 40, "y": box["y"] + 100}})
                wait_for(lambda: x11_pointer_window_name(display) == "Open File",
                         lambda: f"X11 routes pointer to {x11_pointer_window_name(display)!r} on initial map (native={native})", timeout=3)
                # GTK's natural chooser size can put its bottom action row
                # off-screen. First establish correct initial X11 routing,
                # then fit the dialog for an actual GTK button activation.
                request(sock, reader, {"version": 1, "command": 'set_window_size', "params": {"id": fd_id, "width": 800, "height": 450}})
                wait_for(lambda: (d := request(sock, reader, {"version": 1, "command": 'get_window_debug', "params": {"id": fd_id}})["WindowDebug"])["client_box"]["width"] <= 800 and d["client_box"]["height"] <= 450,
                         "file dialog did not commit the fitted size")
                request(sock, reader, {"version": 1, "command": 'move_window_to', "params": {"id": fd_id, "x": 40, "y": 40}})
                time.sleep(0.3)
                for raised_owner in (False, True):
                    if raised_owner:
                        request(sock, reader, {"version": 1, "command": 'focus_window', "params": {"id": main_id}})
                        time.sleep(0.2)
                    client.stdin.write("filedialog_geometry\n")
                    client.stdin.flush()
                    marker = "filedialog-button "
                    row = wait_for(lambda: next((l[len(marker):] for l in reversed(client_log.read_text().splitlines()) if l.startswith(marker)), None), "missing button geometry")
                    pos = json.loads(row)
                    box = request(sock, reader, {"version": 1, "command": 'get_window_debug', "params": {"id": fd_id}})["WindowDebug"]["client_box"]
                    n = factor or (2 if native else 1)
                    x, y = round(box["x"] + pos["x"] / n), round(box["y"] + pos["y"] / n)
                    before = client_log.read_text().count("filedialog-response -6")
                    request(sock, reader, {"version": 1, "command": 'move_cursor', "params": {"x": x - 3, "y": y - 2}})
                    request(sock, reader, {"version": 1, "command": 'move_cursor', "params": {"x": x, "y": y}})
                    wait_for(lambda: x11_pointer_window_name(display) == "Open File",
                             lambda: f"X11 routes pointer to {x11_pointer_window_name(display)!r} instead of dialog (native={native}, raised_owner={raised_owner})", timeout=3)
                    request(sock, reader, {'version': 1, 'command': 'pointer_button', 'params': {"button": 272, "pressed": True}})
                    request(sock, reader, {'version': 1, 'command': 'pointer_button', 'params': {"button": 272, "pressed": False}})
                    wait_for(lambda: client_log.read_text().count("filedialog-response -6") > before,
                             lambda: f"Cancel not activated (native={native}, raised_owner={raised_owner}): {client_log.read_text()}", timeout=3)
                print(f"PASS: GTK file dialog receives actual button clicks (native={native})")

                request(sock, reader, {'version': 1, 'command': 'key_press', 'params': {"key": "Escape"}})
                wait_for(lambda: find("Open File") is None, "file dialog did not close on Escape")
                wait_for(
                    lambda: (f := request(sock, reader, {'version': 1, 'command': 'focused_window'})["FocusedWindow"]) and f["id"] == main_id,
                    "focus did not return to the file dialog's owner on close",
                )
                print("PASS: Escape closes the file dialog and restores focus to its owner")

                client.stdin.write("quit\n")
                client.stdin.flush()
        finally:
            if client and client.poll() is None:
                client.terminate()
                client.wait(timeout=5)
            compositor.terminate()
            compositor.wait(timeout=5)
            log.close()


def test_gtk_combo_and_tooltip():
    """Real GTK combo and tooltip override-redirect surfaces are attached,
    placed over their owning X11 window, clickable, and dismiss cleanly."""
    with tempfile.TemporaryDirectory(prefix="rediwm-xwayland-widgets-") as directory:
        tmp = Path(directory)
        compositor, log = start_compositor(tmp, "[compositor]\nxwayland = true\n")
        client = None
        try:
            sock, reader = ipc_connect(tmp)
            with sock:
                display = request(sock, reader, {'version': 1, 'command': 'get_runtime_info'})["RuntimeInfo"]["xwayland_display"]
                client_env = dict(os.environ, DISPLAY=display, XDG_RUNTIME_DIR=str(tmp), GDK_BACKEND="x11")
                client_env.pop("WAYLAND_DISPLAY", None)
                client = subprocess.Popen(
                    [sys.executable, str(ROOT / "tests/xwayland_gtk_client.py")],
                    env=client_env, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL, text=True,
                )

                def windows():
                    return request(sock, reader, {'version': 1, 'command': 'windows'})["Windows"]

                win = wait_for(
                    lambda: next((w for w in windows() if w.get("backend") == "xwayland"), None),
                    "GTK widget fixture did not appear", timeout=20,
                )
                request(sock, reader, {"version": 1, "command": 'move_window_to', "params": {"id": win["id"], "x": 100, "y": 100}})

                def box():
                    return request(sock, reader, {"version": 1, "command": 'get_window_debug', "params": {"id": win["id"]}})["WindowDebug"]["client_box"]

                wait_for(lambda: abs(box()["x"] - 100) < 4, "GTK widget fixture did not move")
                b = box()

                def hit(x, y):
                    return request(sock, reader, {"version": 1, "command": 'hit_test', "params": {"x": x, "y": y}})["HitTest"]["target_type"]

                client.stdin.write("combo\n")
                client.stdin.flush()
                wait_for(
                    lambda: hit(b["x"] + 210, b["y"] + 75) == "xwayland_unmanaged",
                    "GTK combo popup was not aligned with its owner", timeout=5,
                )
                print("PASS: real GTK combo popup is aligned and clickable")
                request(sock, reader, {'version': 1, 'command': 'key_press', 'params': {"key": "Escape"}})
                wait_for(lambda: hit(b["x"] + 210, b["y"] + 75) != "xwayland_unmanaged",
                         "GTK combo popup did not dismiss")

                px, py = b["x"] + 210, b["y"] + 120
                request(sock, reader, {"version": 1, "command": 'move_cursor', "params": {"x": px, "y": py}})
                client.stdin.write("tooltip\n")
                client.stdin.flush()
                candidates = [(px + dx, py + dy) for dx in (-60, -20, 20, 60) for dy in (20, 40, 60)]
                wait_for(
                    lambda: any(hit(x, y) == "xwayland_unmanaged" for x, y in candidates),
                    "GTK tooltip did not appear near its owner", timeout=5,
                )
                print("PASS: real GTK tooltip is attached near its owner")
                client.stdin.write("quit\n")
                client.stdin.flush()
        finally:
            if client and client.poll() is None:
                client.terminate()
                client.wait(timeout=5)
            compositor.terminate()
            compositor.wait(timeout=5)
            log.close()


def test_gtk_menu_alignment_zoomed():
    """Same real-GTK-menu alignment check as test_gtk_menu_alignment, but
    under camera zoom and pan. xwayland_unmanaged.zig's own comment claims
    the popup is "positioned in world coordinates ... so camera pan/zoom
    stays presentation-only" - this is what actually proves that for a real
    toolkit popup, not just at the fixture's default 100%/unpanned camera.

    Window/popup geometry (client_box, HitTest hit coordinates) all live in
    two different spaces: GetWindowDebug/MoveWindowTo work in *world*
    coordinates (camera-independent - confirmed empirically: client_box is
    identical before and after SetZoom/SetCamera), while MoveCursor/HitTest
    work in *layout* (on-screen) coordinates. world_to_screen() below is the
    same conversion tests/desktop_zoom.py already relies on:
    screen = (world - camera_offset) * zoom_percent / 100.
    """
    with tempfile.TemporaryDirectory(prefix="rediwm-xwayland-gtk-zoom-") as directory:
        tmp = Path(directory)
        compositor, log = start_compositor(tmp, "[compositor]\nxwayland = true\n")
        client = None
        try:
            sock, reader = ipc_connect(tmp)
            with sock:
                info = request(sock, reader, {'version': 1, 'command': 'get_runtime_info'})["RuntimeInfo"]
                display = info["xwayland_display"]
                assert display

                client_log = tmp / "gtk-client.log"
                client_env = dict(
                    os.environ,
                    DISPLAY=display,
                    XDG_RUNTIME_DIR=str(tmp),
                    GDK_BACKEND="x11",
                )
                client_env.pop("WAYLAND_DISPLAY", None)
                with client_log.open("w") as clog:
                    client = subprocess.Popen(
                        [sys.executable, str(ROOT / "tests/xwayland_gtk_client.py")],
                        env=client_env,
                        stdin=subprocess.PIPE,
                        stdout=clog,
                        stderr=clog,
                        text=True,
                    )

                def windows():
                    return request(sock, reader, {'version': 1, 'command': 'windows'})["Windows"]

                win = wait_for(
                    lambda: next(
                        (w for w in windows() if w.get("backend") == "xwayland"
                         and "Gtk" in (w.get("x11_class") or "")),
                        None,
                    ),
                    "GTK X11 window did not appear",
                    timeout=20,
                )
                wid = win["id"]

                def client_box():
                    return request(sock, reader, {"version": 1, "command": 'get_window_debug', "params": {"id": wid}})["WindowDebug"]["client_box"]

                def camera():
                    return request(sock, reader, {'version': 1, 'command': 'get_camera'})["Camera"]

                def world_to_screen(wx, wy):
                    cam = camera()
                    z = cam["zoom_percent"] / 100
                    return (wx - cam["x"]) * z, (wy - cam["y"]) * z

                def hit_type(x, y):
                    return request(sock, reader, {"version": 1, "command": 'hit_test', "params": {"x": x, "y": y}})["HitTest"]["target_type"]

                def right_click_screen(x, y):
                    request(sock, reader, {"version": 1, "command": 'move_cursor', "params": {"x": round(x), "y": round(y)}})
                    request(sock, reader, {'version': 1, 'command': 'pointer_button', 'params': {"button": 273, "pressed": True}})
                    request(sock, reader, {'version': 1, 'command': 'pointer_button', 'params': {"button": 273, "pressed": False}})

                request(sock, reader, {"version": 1, "command": 'move_window_to', "params": {"id": wid, "x": 300, "y": 200}})
                wait_for(lambda: abs(client_box()["x"] - 300) < 4, "window did not move")

                request(sock, reader, {'version': 1, 'command': 'set_zoom', 'params': {"percent": 70}})
                request(sock, reader, {'version': 1, 'command': 'set_camera', 'params': {"x": 20, "y": 15}})
                wait_for(lambda: camera()["zoom_percent"] == 70 and camera()["x"] == 20, "zoom/pan did not apply")
                # GetCamera reflects the new state immediately, but a click
                # fired in the same instant can still race the projection
                # pipeline settling onto it (confirmed empirically: ~20%
                # flake rate with no delay here, 0/30 with this one) - a real
                # zoom/pan gesture and the next click are never this close
                # together in practice.
                time.sleep(0.15)

                box = client_box()
                assert box["x"] == 301, f"MoveWindowTo/client_box drifted with the camera: {box}"
                wx, wy = box["x"] + 60, box["y"] + 60
                sx, sy = world_to_screen(wx, wy)
                right_click_screen(sx, sy)

                hx, hy = world_to_screen(wx + 5, wy + 5)
                wait_for(
                    lambda: hit_type(round(hx), round(hy)) == "xwayland_unmanaged",
                    "context menu not aligned under 70% zoom + (20,15) pan",
                    timeout=5,
                )
                print("PASS: GTK context menu aligned under 70% zoom + (20,15) pan")

                request(sock, reader, {'version': 1, 'command': 'key_press', 'params': {"key": "Escape"}})
                wait_for(
                    lambda: hit_type(round(hx), round(hy)) != "xwayland_unmanaged",
                    "context menu did not dismiss on Escape under zoom/pan",
                    timeout=5,
                )
                print("PASS: Escape dismisses the menu under zoom/pan too")

                client.stdin.write("quit\n")
                client.stdin.flush()
        finally:
            if client and client.poll() is None:
                client.terminate()
                client.wait(timeout=5)
            compositor.terminate()
            compositor.wait(timeout=5)
            log.close()


def test_gtk_menu_multi_output():
    """Placement, hit-testing and a real GTK popup click on the second output.

    Advertising xdg-output supplies the logical layout Xwayland needs for
    RandR. Without it, both monitors appeared at 0,0. xdg_output.py --xwayland
    checks the corrected RandR geometry itself. A real GTK click still does
    not reach this output, so that distinct pinned-wlroots limitation remains.
    """
    with tempfile.TemporaryDirectory(prefix="rediwm-xwayland-multi-") as directory:
        tmp = Path(directory)
        compositor, log = start_compositor(
            tmp, "[compositor]\nxwayland = true\n", env_overrides={"WLR_HEADLESS_OUTPUTS": "2"}
        )
        client = None
        try:
            sock, reader = ipc_connect(tmp)
            with sock:
                info = request(sock, reader, {'version': 1, 'command': 'get_runtime_info'})["RuntimeInfo"]
                display = info["xwayland_display"]
                assert display

                outputs = request(sock, reader, {'version': 1, 'command': 'outputs'})["Outputs"]
                assert len(outputs) == 2, outputs
                second = max(outputs, key=lambda o: o["x"])
                assert second["x"] > 0, f"second output did not get a nonzero origin: {outputs}"

                client_log = tmp / "gtk-client.log"
                client_env = dict(
                    os.environ,
                    DISPLAY=display,
                    XDG_RUNTIME_DIR=str(tmp),
                    GDK_BACKEND="x11",
                )
                client_env.pop("WAYLAND_DISPLAY", None)
                with client_log.open("w") as clog:
                    client = subprocess.Popen(
                        [sys.executable, str(ROOT / "tests/xwayland_gtk_client.py")],
                        env=client_env,
                        stdin=subprocess.PIPE,
                        stdout=clog,
                        stderr=clog,
                        text=True,
                    )

                def windows():
                    return request(sock, reader, {'version': 1, 'command': 'windows'})["Windows"]

                win = wait_for(
                    lambda: next(
                        (w for w in windows() if w.get("backend") == "xwayland"
                         and "Gtk" in (w.get("x11_class") or "")),
                        None,
                    ),
                    "GTK X11 window did not appear",
                    timeout=20,
                )
                wid = win["id"]

                def window_debug():
                    return request(sock, reader, {"version": 1, "command": 'get_window_debug', "params": {"id": wid}})["WindowDebug"]

                def hit_type(x, y):
                    # Like MoveCursor, HitTest coordinates are output-local.
                    return request(sock, reader, {"version": 1, "command": 'hit_test', "params": {
                        "x": x - second["x"], "y": y - second["y"], "output": second["name"],
                    }})["HitTest"]

                target_x, target_y = second["x"] + 100, second["y"] + 100
                request(sock, reader, {"version": 1, "command": 'move_window_to', "params": {"id": wid, "x": target_x, "y": target_y}})
                wait_for(
                    lambda: abs(window_debug()["client_box"]["x"] - target_x) < 4,
                    "window did not move to the second output",
                )
                debug = window_debug()
                assert second["name"] in debug["outputs"], debug
                print(f"PASS: window placed on second output (origin x={second['x']})")

                box = debug["client_box"]
                hit = hit_type(box["x"] + 60, box["y"] + 60)
                assert hit["target_type"] == "window" and hit["window_id"] == wid, hit
                assert hit["local_x"] == 60 and hit["local_y"] == 60, hit
                print("PASS: scene hit-testing on the second output resolves to the right window and local coordinates")

                client.stdin.write("quit\n")
                client.stdin.flush()
        finally:
            if client and client.poll() is None:
                client.terminate()
                client.wait(timeout=5)
            compositor.terminate()
            compositor.wait(timeout=5)
            log.close()


def test_negative_output_origin():
    """Compositor-side placement and hit-testing on a configured negative origin.

    xdg_output.py separately verifies native clients receive negative logical
    positions. This test does not verify X11 pointer delivery at negative origins.
    """
    with tempfile.TemporaryDirectory(prefix="rediwm-xwayland-negorigin-") as directory:
        tmp = Path(directory)
        config = (
            "[compositor]\nxwayland = true\n"
            "\n[[outputs]]\nname = \"HEADLESS-1\"\nx = 0\ny = 0\n"
            "\n[[outputs]]\nname = \"HEADLESS-2\"\nx = -1280\ny = 0\n"
        )
        compositor, log = start_compositor(tmp, config, env_overrides={"WLR_HEADLESS_OUTPUTS": "2"})
        client = None
        try:
            sock, reader = ipc_connect(tmp)
            with sock:
                info = request(sock, reader, {'version': 1, 'command': 'get_runtime_info'})["RuntimeInfo"]
                display = info["xwayland_display"]
                assert display

                outputs = request(sock, reader, {'version': 1, 'command': 'outputs'})["Outputs"]
                assert len(outputs) == 2, outputs
                assert {(o["name"], o["x"], o["y"]) for o in outputs} == {
                    ("HEADLESS-1", 0, 0), ("HEADLESS-2", -1280, 0),
                }, outputs
                neg = next(o for o in outputs if o["x"] < 0)
                print(f"PASS: {neg['name']} placed at its configured negative origin ({neg['x']},{neg['y']})")

                client_log = tmp / "gtk-client.log"
                client_env = dict(
                    os.environ,
                    DISPLAY=display,
                    XDG_RUNTIME_DIR=str(tmp),
                    GDK_BACKEND="x11",
                )
                client_env.pop("WAYLAND_DISPLAY", None)
                with client_log.open("w") as clog:
                    client = subprocess.Popen(
                        [sys.executable, str(ROOT / "tests/xwayland_gtk_client.py")],
                        env=client_env,
                        stdin=subprocess.PIPE,
                        stdout=clog,
                        stderr=clog,
                        text=True,
                    )

                def windows():
                    return request(sock, reader, {'version': 1, 'command': 'windows'})["Windows"]

                win = wait_for(
                    lambda: next(
                        (w for w in windows() if w.get("backend") == "xwayland"
                         and "Gtk" in (w.get("x11_class") or "")),
                        None,
                    ),
                    "GTK X11 window did not appear",
                    timeout=20,
                )
                wid = win["id"]

                def window_debug():
                    return request(sock, reader, {"version": 1, "command": 'get_window_debug', "params": {"id": wid}})["WindowDebug"]

                target_x, target_y = neg["x"] + 100, neg["y"] + 100
                request(sock, reader, {"version": 1, "command": 'move_window_to', "params": {"id": wid, "x": target_x, "y": target_y}})
                wait_for(
                    lambda: window_debug()["client_box"]["x"] - target_x in (0, 1),
                    "window did not move to the negative-origin output",
                )
                debug = window_debug()
                assert neg["name"] in debug["outputs"], debug
                print(f"PASS: window placed at negative world coordinates ({target_x},{target_y})")

                box = debug["client_box"]
                hit = request(sock, reader, {"version": 1, "command": 'hit_test', "params": {
                    "x": box["x"] + 60 - neg["x"], "y": box["y"] + 60 - neg["y"], "output": neg["name"],
                }})["HitTest"]
                assert hit["target_type"] == "window" and hit["window_id"] == wid, hit
                assert hit["local_x"] == 60 and hit["local_y"] == 60, hit
                assert hit["layout_x"] < 0, hit
                print("PASS: scene hit-testing at negative layout coordinates resolves to the right window")

                client.stdin.write("quit\n")
                client.stdin.flush()
        finally:
            if client and client.poll() is None:
                client.terminate()
                client.wait(timeout=5)
            compositor.terminate()
            compositor.wait(timeout=5)
            log.close()


def test_gtk_menu_fractional_scale(scale="1.5"):
    """Output scale must not leak into logical/world coordinates:
    X11 has no per-output-scale concept, so the compositor has to present the
    same logical geometry to an Xwayland client at scaled output sizes,
    scaling only the rendered buffer (plan: "Begin with compositor scaling
    of X buffers; do not ... emulate Wayland per-surface fractional scale").
    """
    with tempfile.TemporaryDirectory(prefix="rediwm-xwayland-scale-") as directory:
        tmp = Path(directory)
        compositor, log = start_compositor(
            tmp, "[compositor]\nxwayland = true\n", env_overrides={"REDIWM_SCALE": scale}
        )
        client = None
        try:
            sock, reader = ipc_connect(tmp)
            with sock:
                info = request(sock, reader, {'version': 1, 'command': 'get_runtime_info'})["RuntimeInfo"]
                display = info["xwayland_display"]
                assert display

                outputs = request(sock, reader, {'version': 1, 'command': 'outputs'})["Outputs"]
                assert abs(outputs[0]["scale"] - float(scale)) < 0.01, outputs

                client_log = tmp / "gtk-client.log"
                client_env = dict(
                    os.environ,
                    DISPLAY=display,
                    XDG_RUNTIME_DIR=str(tmp),
                    GDK_BACKEND="x11",
                )
                client_env.pop("WAYLAND_DISPLAY", None)
                with client_log.open("w") as clog:
                    client = subprocess.Popen(
                        [sys.executable, str(ROOT / "tests/xwayland_gtk_client.py")],
                        env=client_env,
                        stdin=subprocess.PIPE,
                        stdout=clog,
                        stderr=clog,
                        text=True,
                    )

                def windows():
                    return request(sock, reader, {'version': 1, 'command': 'windows'})["Windows"]

                win = wait_for(
                    lambda: next(
                        (w for w in windows() if w.get("backend") == "xwayland"
                         and "Gtk" in (w.get("x11_class") or "")),
                        None,
                    ),
                    "GTK X11 window did not appear",
                    timeout=20,
                )
                wid = win["id"]

                def client_box():
                    return request(sock, reader, {"version": 1, "command": 'get_window_debug', "params": {"id": wid}})["WindowDebug"]["client_box"]

                def hit_type(x, y):
                    return request(sock, reader, {"version": 1, "command": 'hit_test', "params": {"x": x, "y": y}})["HitTest"]["target_type"]

                def right_click(x, y):
                    request(sock, reader, {"version": 1, "command": 'move_cursor', "params": {"x": x, "y": y}})
                    request(sock, reader, {'version': 1, 'command': 'pointer_button', 'params': {"button": 273, "pressed": True}})
                    request(sock, reader, {'version': 1, 'command': 'pointer_button', 'params': {"button": 273, "pressed": False}})

                request(sock, reader, {"version": 1, "command": 'move_window_to', "params": {"id": wid, "x": 300, "y": 200}})
                wait_for(lambda: abs(client_box()["x"] - 300) < 4, "window did not move")

                box = client_box()
                px, py = box["x"] + 60, box["y"] + 60
                right_click(px, py)
                wait_for(
                    lambda: hit_type(px + 5, py + 5) == "xwayland_unmanaged",
                    f"context menu not aligned at {scale}x output scale",
                    timeout=5,
                )
                print(f"PASS: GTK context menu aligned at {scale}x output scale")

                request(sock, reader, {'version': 1, 'command': 'key_press', 'params': {"key": "Escape"}})
                wait_for(
                    lambda: hit_type(px + 5, py + 5) != "xwayland_unmanaged",
                    f"context menu did not dismiss on Escape at {scale}x scale",
                    timeout=5,
                )
                print(f"PASS: Escape dismisses the menu at {scale}x scale too")

                client.stdin.write("quit\n")
                client.stdin.flush()
        finally:
            if client and client.poll() is None:
                client.terminate()
                client.wait(timeout=5)
            compositor.terminate()
            compositor.wait(timeout=5)
            log.close()


def test_clipboard_bidirectional():
    """Clipboard between a real X11 client and a real native Wayland client
    (clipboard_gtk_client.py runs as both - GDK's clipboard API is backend-
    agnostic). Exercises wlroots' own XWM selection bridge: there is no
    compositor-side clipboard code at all beyond wlr.DataDeviceManager.create()
    in Server.zig and wlr_xwayland.setSeat() in Xwayland.zig.

    Both directions work, but not symmetrically, and the difference matters
    for real usage - confirmed by reading src/xwayland/selection/{incoming,
    outgoing}.c's DEBUG/ERROR log lines while writing this test, and cross-
    checked against a real upstream report (swaywm/sway#4678) of the same
    "denying write access to clipboard: no xwayland surface focused" line:

    - Wayland owns the selection, X11 requests it (outgoing.c): works
      regardless of current focus. Confirmed below with the Wayland side
      long gone from focus by the time X11 pastes.
    - X11 owns the selection, Wayland requests it (incoming.c): wlroots'
      XWM refuses to relay X11's selection content unless an Xwayland
      surface is *currently* focused at the moment Wayland asks for it -
      not at copy time. Since pasting into a Wayland app requires that app
      to be focused, this makes "copy in an X11 app, click a Wayland app,
      paste" - probably the single most common mixed-session clipboard
      workflow - fail every time, not an edge case. test_x11_to_wayland_
      clipboard_focus_limitation below pins this exact behavior so a
      wlroots upgrade that fixes it will make that test fail and flag
      itself for review.

    The tests here stay in the direction/focus combinations that actually
    work, so this test is a real regression check, not just documentation.
    """
    with tempfile.TemporaryDirectory(prefix="rediwm-xwayland-clipboard-") as directory:
        tmp = Path(directory)
        compositor, log = start_compositor(tmp, "[compositor]\nxwayland = true\n")
        x11_client = None
        try:
            sock, reader = ipc_connect(tmp)
            with sock:
                info = request(sock, reader, {'version': 1, 'command': 'get_runtime_info'})["RuntimeInfo"]
                display = info["xwayland_display"]
                assert display
                wl_display = wayland_display_name(tmp)
                fixture = str(ROOT / "tests/clipboard_gtk_client.py")

                def windows():
                    return request(sock, reader, {'version': 1, 'command': 'windows'})["Windows"]

                def send(client, line):
                    client.stdin.write(line + "\n")
                    client.stdin.flush()

                def last_line(log_path):
                    lines = [
                        ln for ln in log_path.read_text().splitlines()
                        if ln and "DeprecationWarning" not in ln and not ln.strip().startswith("window.")
                    ]
                    return lines[-1] if lines else ""

                x11_env = dict(os.environ, DISPLAY=display, XDG_RUNTIME_DIR=str(tmp), GDK_BACKEND="x11")
                x11_env.pop("WAYLAND_DISPLAY", None)
                x11_log_path = tmp / "x11-clip.log"
                with x11_log_path.open("w") as x11_log:
                    x11_client = subprocess.Popen(
                        [sys.executable, fixture], env=x11_env,
                        stdin=subprocess.PIPE, stdout=x11_log, stderr=x11_log, text=True,
                    )
                wait_for(lambda: any(w.get("backend") == "xwayland" for w in windows()),
                         "X11 clipboard client did not appear", timeout=20)
                time.sleep(0.3)

                # X11 -> Wayland while X11 is still the (only, so focused)
                # window: this is the case wlroots' incoming.c actually
                # supports (see docstring).
                send(x11_client, "copy hello-from-x11")
                wait_for(lambda: last_line(x11_log_path).startswith("copied"), "X11 client did not copy")
                wl_env = dict(os.environ, WAYLAND_DISPLAY=wl_display, XDG_RUNTIME_DIR=str(tmp))
                wl_env.pop("DISPLAY", None)
                r = subprocess.run(["wl-paste"], env=wl_env, capture_output=True, text=True, timeout=10)
                assert r.returncode == 0 and r.stdout == "hello-from-x11\n", r
                print("PASS: clipboard text copied on X11 (still focused) reaches a native Wayland reader")

                # Large transfer, same (working) direction/focus combination.
                big = "y" * 200_000
                send(x11_client, f"copy {big}")
                wait_for(lambda: last_line(x11_log_path) == "copied 200000 bytes", "X11 client did not copy large text")
                r = subprocess.run(["wl-paste"], env=wl_env, capture_output=True, text=True, timeout=10)
                assert r.returncode == 0 and r.stdout == big + "\n", "large transfer did not arrive intact"
                print("PASS: large (200KB) clipboard transfer from X11 arrives intact")

                # Selection owner exit: close the owning client and confirm
                # the compositor and a subsequent, unrelated client are both
                # still healthy - not that content survives, which nothing
                # in this compositor implements (no clipboard-manager
                # persistence), so "nothing copied" is the correct outcome.
                send(x11_client, "quit")
                x11_client.wait(timeout=5)
                x11_client = None
                r = subprocess.run(["wl-paste"], env=wl_env, capture_output=True, text=True, timeout=10)
                assert r.returncode != 0, f"stale clipboard content survived the owner's exit: {r.stdout!r}"
                print("PASS: clipboard cleanly reports empty after its owner's process exits")

                # Wayland -> X11: works regardless of current focus. Prove it
                # by letting focus land on the *replacement* X11 client
                # (created last, so focused per this compositor's map policy)
                # well after the Wayland side copied and lost focus.
                wl_log_path = tmp / "wl-clip.log"
                with wl_log_path.open("w") as wl_log:
                    wl_client = subprocess.Popen(
                        [sys.executable, fixture], env=wl_env | {"GDK_BACKEND": "wayland"},
                        stdin=subprocess.PIPE, stdout=wl_log, stderr=wl_log, text=True,
                    )
                try:
                    wait_for(lambda: any(w.get("backend") == "xdg" for w in windows()),
                             "native Wayland clipboard client did not appear", timeout=20)
                    send(wl_client, "copy hello-from-wayland")
                    wait_for(lambda: last_line(wl_log_path).startswith("copied"), "Wayland client did not copy")

                    x11_log2_path = tmp / "x11-clip-2.log"
                    with x11_log2_path.open("w") as x11_log2:
                        x11_client = subprocess.Popen(
                            [sys.executable, fixture], env=x11_env,
                            stdin=subprocess.PIPE, stdout=x11_log2, stderr=x11_log2, text=True,
                        )
                    wait_for(lambda: sum(1 for w in windows() if w.get("backend") == "xwayland") >= 1,
                             "replacement X11 client did not appear", timeout=20)
                    time.sleep(0.3)
                    send(x11_client, "paste")
                    wait_for(
                        lambda: last_line(x11_log2_path) == "pasted 18 bytes: 'hello-from-wayland'",
                        lambda: f"X11 could not read Wayland-sourced clipboard: {last_line(x11_log2_path)!r}",
                        timeout=5,
                    )
                    print("PASS: clipboard text copied on native Wayland reaches X11 even after Wayland lost focus")
                finally:
                    if wl_client.poll() is None:
                        wl_client.terminate()
                        wl_client.wait(timeout=5)
        finally:
            if x11_client and x11_client.poll() is None:
                x11_client.terminate()
                x11_client.wait(timeout=5)
            compositor.terminate()
            compositor.wait(timeout=5)
            log.close()


def test_x11_to_wayland_clipboard_focus_limitation():
    """Pins a real, confirmed wlroots XWM limitation (not a bug in this
    compositor - there is no clipboard API surface in the pinned wlroots
    0.20 Xwayland bindings to influence this from application code): once
    keyboard focus has moved away from every Xwayland surface, wlroots
    refuses to relay X11-sourced clipboard content to a Wayland requester,
    logging "denying write access to clipboard: no xwayland surface
    focused" (src/xwayland/selection/incoming.c). Since pasting into a
    Wayland app requires that app to be focused, this breaks "copy in an
    X11 app, click a Wayland app, paste" - not a rare edge case.

    This intentionally asserts the CURRENT broken behavior. If a wlroots
    upgrade fixes it, this assertion starts failing - the failure is a
    signal to update this test (and re-check the plan's clipboard item),
    not a regression to chase.
    """
    with tempfile.TemporaryDirectory(prefix="rediwm-xwayland-clipboard-limit-") as directory:
        tmp = Path(directory)
        compositor, log = start_compositor(tmp, "[compositor]\nxwayland = true\n")
        x11_client = None
        wl_client = None
        try:
            sock, reader = ipc_connect(tmp)
            with sock:
                info = request(sock, reader, {'version': 1, 'command': 'get_runtime_info'})["RuntimeInfo"]
                display = info["xwayland_display"]
                assert display
                wl_display = wayland_display_name(tmp)
                fixture = str(ROOT / "tests/clipboard_gtk_client.py")

                def windows():
                    return request(sock, reader, {'version': 1, 'command': 'windows'})["Windows"]

                def send(client, line):
                    client.stdin.write(line + "\n")
                    client.stdin.flush()

                def last_line(log_path):
                    lines = [
                        ln for ln in log_path.read_text().splitlines()
                        if ln and "DeprecationWarning" not in ln and not ln.strip().startswith("window.")
                    ]
                    return lines[-1] if lines else ""

                x11_env = dict(os.environ, DISPLAY=display, XDG_RUNTIME_DIR=str(tmp), GDK_BACKEND="x11")
                x11_env.pop("WAYLAND_DISPLAY", None)
                x11_log_path = tmp / "x11.log"
                with x11_log_path.open("w") as x11_log:
                    x11_client = subprocess.Popen(
                        [sys.executable, fixture], env=x11_env,
                        stdin=subprocess.PIPE, stdout=x11_log, stderr=x11_log, text=True,
                    )
                wait_for(lambda: any(w.get("backend") == "xwayland" for w in windows()), "no x11", timeout=20)

                wl_env = dict(os.environ, WAYLAND_DISPLAY=wl_display, XDG_RUNTIME_DIR=str(tmp), GDK_BACKEND="wayland")
                wl_env.pop("DISPLAY", None)
                wl_log_path = tmp / "wl.log"
                with wl_log_path.open("w") as wl_log:
                    wl_client = subprocess.Popen(
                        [sys.executable, fixture], env=wl_env,
                        stdin=subprocess.PIPE, stdout=wl_log, stderr=wl_log, text=True,
                    )
                wait_for(lambda: any(w.get("backend") == "xdg" for w in windows()), "no wl", timeout=20)

                time.sleep(0.3)
                send(x11_client, "copy hello-from-x11")
                wait_for(lambda: last_line(x11_log_path).startswith("copied"), "X11 client did not copy")

                wl_win = next(w for w in windows() if w.get("backend") == "xdg")
                request(sock, reader, {"version": 1, "command": 'focus_window', "params": {"id": wl_win["id"]}})
                wait_for(
                    lambda: (f := request(sock, reader, {'version': 1, 'command': 'focused_window'})["FocusedWindow"]) and f["id"] == wl_win["id"],
                    "could not focus the Wayland window",
                )

                KEY_LEFTCTRL, KEY_V = 29, 47
                for keycode, pressed in ((KEY_LEFTCTRL, True), (KEY_V, True), (KEY_V, False), (KEY_LEFTCTRL, False)):
                    request(sock, reader, {"version": 1, "command": 'key', "params": {"keycode": keycode, "pressed": pressed}})

                wait_for(lambda: last_line(wl_log_path) in ("pasted-none", "pasted 14 bytes: 'hello-from-x11'"),
                         "Ctrl+V produced no reaction at all", timeout=5)
                result = last_line(wl_log_path)
                assert result == "pasted-none", (
                    f"X11-to-Wayland clipboard now works after a focus switch (got {result!r}) - "
                    "wlroots appears to have fixed the incoming.c focus check; update this test and "
                    "TESTING.md/plan-xwayland.md, this is good news, not a failure to chase blindly"
                )
                print("PASS (documents a known limitation): X11 clipboard content is unavailable to a "
                      "focused Wayland app once focus has left every Xwayland surface")
        finally:
            for c in (x11_client, wl_client):
                if c and c.poll() is None:
                    c.terminate()
                    c.wait(timeout=5)
            compositor.terminate()
            compositor.wait(timeout=5)
            log.close()


def _dnd_client_env(backend, display, wl_display, tmp):
    if backend == "x11":
        env = dict(os.environ, DISPLAY=display, XDG_RUNTIME_DIR=str(tmp), GDK_BACKEND="x11")
        env.pop("WAYLAND_DISPLAY", None)
    else:
        env = dict(os.environ, WAYLAND_DISPLAY=wl_display, XDG_RUNTIME_DIR=str(tmp), GDK_BACKEND="wayland")
        env.pop("DISPLAY", None)
    return env


def _run_drag(sock, reader, tmp, display, wl_display, src_backend, dst_backend):
    """Drives one drag gesture between a source and destination
    dnd_gtk_client.py instance (each either X11 or native Wayland) and
    returns (dst_log_text, src_log_text). The gesture is composed from raw
    MoveCursor/PointerButton calls rather than the compositor's built-in
    Drag IPC action: Drag's fixed 10-step interpolation moves too fast for
    DnD's async per-motion accept handshake between destination and source
    (confirmed while writing this test - GTK's drag-motion status round trip
    needs more, and slower, motion events than a plain resize/move drag
    does).
    """
    fixture = str(ROOT / "tests/dnd_gtk_client.py")

    def windows():
        return request(sock, reader, {'version': 1, 'command': 'windows'})["Windows"]

    wanted_backend = {"x11": "xwayland", "wayland": "xdg"}

    src_log_path = tmp / "dnd-src.log"
    with src_log_path.open("w") as src_log:
        src = subprocess.Popen(
            [sys.executable, fixture, "source"],
            env=_dnd_client_env(src_backend, display, wl_display, tmp),
            stdin=subprocess.PIPE, stdout=src_log, stderr=src_log, text=True,
        )
    wait_for(lambda: any(w.get("backend") == wanted_backend[src_backend] for w in windows()),
             "drag source client did not appear", timeout=20)

    dst_log_path = tmp / "dnd-dst.log"
    with dst_log_path.open("w") as dst_log:
        dst = subprocess.Popen(
            [sys.executable, fixture, "dest"],
            env=_dnd_client_env(dst_backend, display, wl_display, tmp),
            stdin=subprocess.PIPE, stdout=dst_log, stderr=dst_log, text=True,
        )
    if src_backend == dst_backend:
        wait_for(lambda: sum(1 for w in windows() if w.get("backend") == wanted_backend[dst_backend]) >= 2,
                 "drag destination client did not appear", timeout=20)
    else:
        wait_for(lambda: any(w.get("backend") == wanted_backend[dst_backend] for w in windows()),
                 "drag destination client did not appear", timeout=20)

    try:
        wlist = windows()
        src_win = next(w for w in wlist if "source" in w["title"])
        dst_win = next(w for w in wlist if "dest" in w["title"])
        request(sock, reader, {"version": 1, "command": 'move_window_to', "params": {"id": src_win["id"], "x": 100, "y": 100}})
        request(sock, reader, {"version": 1, "command": 'move_window_to', "params": {"id": dst_win["id"], "x": 500, "y": 100}})

        def box(wid):
            return request(sock, reader, {"version": 1, "command": 'get_window_debug', "params": {"id": wid}})["WindowDebug"]["client_box"]

        wait_for(lambda: abs(box(src_win["id"])["x"] - 100) <= 1, "drag source did not move")
        wait_for(lambda: abs(box(dst_win["id"])["x"] - 500) <= 1, "drag destination did not move")
        sbox, dbox = box(src_win["id"]), box(dst_win["id"])
        fx, fy = sbox["x"] + 50, sbox["y"] + 50
        tx, ty = dbox["x"] + 50, dbox["y"] + 50

        def move(x, y):
            request(sock, reader, {"version": 1, "command": 'move_cursor', "params": {"x": round(x), "y": round(y)}})

        move(fx, fy)
        request(sock, reader, {'version': 1, 'command': 'pointer_button', 'params': {"button": 272, "pressed": True}})
        time.sleep(0.05)
        steps = 12
        for i in range(1, steps + 1):
            t = i / steps
            move(fx + (tx - fx) * t, fy + (ty - fy) * t)
            time.sleep(0.05)
        for _ in range(3):
            time.sleep(0.1)
            move(tx, ty)
        time.sleep(0.3)
        request(sock, reader, {'version': 1, 'command': 'pointer_button', 'params': {"button": 272, "pressed": False}})
        # The data-fetch round trip after "drag-drop" is async and, for a
        # cross-process/cross-backend destination, can take a little longer
        # than the fixed delays used to drive the gesture above - poll for
        # it rather than guessing a single sleep length.
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline and "drag-data-received" not in dst_log_path.read_text():
            time.sleep(0.05)
        request(sock, reader, {"version": 1, "command": 'close_window', "params": {"id": src_win["id"]}})
        request(sock, reader, {"version": 1, "command": 'close_window', "params": {"id": dst_win["id"]}})
    finally:
        for c in (src, dst):
            if c.poll() is None:
                c.terminate()
                c.wait(timeout=5)
    return dst_log_path.read_text(), src_log_path.read_text()


def test_drag_and_drop():
    """Real-GTK drag-and-drop (URI target, text/uri-list) between a source
    and a destination window, for the three source/destination combinations
    that actually work: X11->X11, native Wayland->X11, and native
    Wayland->native Wayland.

    Getting this working required two real fixes in src/Input.zig, neither
    Xwayland-specific (confirmed with two native Wayland clients, Xwayland
    disabled entirely):

    - passthroughMotion only kept an implicit pointer grab (motion routed to
      the surface a button went down on, not whatever's now under the
      cursor) for layer-shell surfaces. For ordinary client content it kept
      re-hit-testing during a held-button drag, silently re-entering
      whatever the cursor crossed into and invalidating the seat's pointer
      grab serial before the source client could recognize the gesture and
      call wl_data_device.start_drag.
    - Even with that fixed, clicking an *unfocused* window to start a drag
      from it still failed: World.focusSurface()'s keyboard-enter call ran
      after pointerNotifyButton, so the client saw a keyboard-focus-change
      event (a separate, later serial) right after the button press, and
      GTK's start_drag request ended up referencing that later serial
      instead of the button's. wlroots then rejects the drag as stale
      ("Pointer grab serial validation failed", wlr_seat_pointer.c). Fixed
      by requesting the focus change before pointerNotifyButton instead of
      after. Clicking an unfocused window to drag from it is an entirely
      ordinary gesture, not a rare edge case - both bugs would have hit any
      real multi-window drag, X11 or native.

    The fourth combination, X11 source -> native Wayland destination, still
    doesn't work - see test_x11_source_drag_to_wayland_limitation.

    Only the URI target is checked here even though the fixture offers both
    text/uri-list and text/plain: GTK's own target negotiation consistently
    picks text/uri-list first in practice (observed while writing this
    test), and forcing text/plain instead isn't worth the added complexity
    for what these fixes needed to prove.

    Each combination gets its own compositor instance: a second drag within
    one session was unreliable even for a combination that passes reliably
    as the only drag in its session (the source's drag-data-get was never
    even asked for) - another instance of the same "state left over from an
    earlier interaction confuses the next one" class this session already
    hit for clicks (see test_gtk_menu_alignment_zoomed's settle-delay note)
    and for two clicks at an identical local pixel (test_gtk_menu_alignment).
    Not worth its own investigation on top of those; giving each combination
    a clean seat sidesteps it the same way test_gtk_menu_multi_output and
    test_gtk_menu_fractional_scale already do for unrelated reasons.
    """
    for src_backend, dst_backend, label in (
        ("x11", "x11", "X11 -> X11"),
        ("wayland", "x11", "native Wayland -> X11"),
        ("wayland", "wayland", "native Wayland -> native Wayland"),
    ):
        with tempfile.TemporaryDirectory(prefix="rediwm-xwayland-dnd-") as directory:
            tmp = Path(directory)
            compositor, log = start_compositor(tmp, "[compositor]\nxwayland = true\n")
            try:
                sock, reader = ipc_connect(tmp)
                with sock:
                    info = request(sock, reader, {'version': 1, 'command': 'get_runtime_info'})["RuntimeInfo"]
                    display = info["xwayland_display"]
                    assert display
                    wl_display = wayland_display_name(tmp)

                    dst_text, src_text = _run_drag(sock, reader, tmp, display, wl_display, src_backend, dst_backend)
                    assert "drag-data-received text/uri-list ['file:///tmp/drag-test-file.txt']" in dst_text, (
                        f"{label}: destination did not receive the dropped URI\nsrc: {src_text}\ndst: {dst_text}"
                    )
                    print(f"PASS: drag-and-drop works {label}")
            finally:
                compositor.terminate()
                compositor.wait(timeout=5)
                log.close()


def test_x11_source_drag_to_wayland_limitation():
    """Pins a real, confirmed limitation of the pinned wlroots (0.20.x): a
    drag started on an X11 window never reaches a native Wayland
    destination. Unlike test_drag_and_drop's two fixes, this isn't
    something this compositor's code can influence - Input.zig's
    requestStartDrag (src/Input.zig) never fires at all for an X11-sourced
    drag (confirmed by temporarily logging inside it while writing this
    test), meaning Xwayland's XWM never asks our seat to start a Wayland
    drag for it in the first place. There is no drag/DnD API in the pinned
    wlroots 0.20 Xwayland bindings (checked the vendored zig-wlroots source,
    same as the clipboard and multi-output findings elsewhere in this file)
    for the compositor to influence this. X11 -> X11 drags keep working
    (confirmed in test_drag_and_drop) because XDND between two Xwayland
    windows never needs to leave Xwayland's own embedded X server.

    This intentionally asserts the CURRENT broken behavior. If a wlroots
    upgrade fixes it, this assertion starts failing - update this test (and
    test_drag_and_drop to cover the newly-working combination) rather than
    treating the failure as a regression to chase.
    """
    with tempfile.TemporaryDirectory(prefix="rediwm-xwayland-dnd-limit-") as directory:
        tmp = Path(directory)
        compositor, log = start_compositor(tmp, "[compositor]\nxwayland = true\n")
        try:
            sock, reader = ipc_connect(tmp)
            with sock:
                info = request(sock, reader, {'version': 1, 'command': 'get_runtime_info'})["RuntimeInfo"]
                display = info["xwayland_display"]
                assert display
                wl_display = wayland_display_name(tmp)

                dst_text, src_text = _run_drag(sock, reader, tmp, display, wl_display, "x11", "wayland")
                assert "drag-data-received" not in dst_text, (
                    "X11-to-Wayland drag-and-drop now works (a wlroots upgrade may have fixed the "
                    "underlying XWM gap) - update this test and test_drag_and_drop, this is good "
                    f"news, not a failure to chase blindly\nsrc: {src_text}\ndst: {dst_text}"
                )
                print("PASS (documents a known limitation): a drag started on an X11 window never "
                      "reaches a native Wayland destination")
        finally:
            compositor.terminate()
            compositor.wait(timeout=5)
            log.close()


def test_primary_selection_bidirectional():
    """PRIMARY selection (X11's separate "select text, middle-click to
    paste" selection - distinct from CLIPBOARD) between a real X11 client
    and wl-paste/wl-copy --primary.

    Landing this required real compositor changes, unlike clipboard/DnD
    which only needed tests: this project had no primary-selection protocol
    at all before this session (no wlr_primary_selection_v1_device_manager,
    no seat request_set_primary_selection listener - grep found zero
    matches). Added both, mirroring the existing CLIPBOARD wiring exactly
    (Server.zig: wlr.PrimarySelectionDeviceManagerV1.create() next to
    wlr.DataDeviceManager.create(); Input.zig: requestSetPrimarySelection
    next to requestSetSelection, same one-line body).

    Bidirectional transfer through wlroots' XWM bridge works immediately
    with no further changes, at the same X11-must-be-focused-to-relay-to-
    Wayland asymmetry documented for CLIPBOARD above (same
    xwayland/selection/incoming.c code path, just XA_PRIMARY instead of
    CLIPBOARD) - not re-verified separately here to avoid redundant
    investigation of a limitation already characterized in detail.

    The Wayland-to-X11 direction uses an actual middle click. Input.zig holds
    the press until motion distinguishes a camera pan from a click; a click
    is then delivered to the client as button 2 and GTK pulls PRIMARY.
    """
    with tempfile.TemporaryDirectory(prefix="rediwm-xwayland-primary-") as directory:
        tmp = Path(directory)
        compositor, log = start_compositor(tmp, "[compositor]\nxwayland = true\n")
        x11_client = None
        try:
            sock, reader = ipc_connect(tmp)
            with sock:
                info = request(sock, reader, {'version': 1, 'command': 'get_runtime_info'})["RuntimeInfo"]
                display = info["xwayland_display"]
                assert display
                wl_display = wayland_display_name(tmp)
                fixture = str(ROOT / "tests/clipboard_gtk_client.py")

                def windows():
                    return request(sock, reader, {'version': 1, 'command': 'windows'})["Windows"]

                def send(client, line):
                    client.stdin.write(line + "\n")
                    client.stdin.flush()

                def last_line(log_path):
                    lines = [
                        ln for ln in log_path.read_text().splitlines()
                        if ln and "DeprecationWarning" not in ln and not ln.strip().startswith("window.")
                    ]
                    return lines[-1] if lines else ""

                x11_env = dict(
                    os.environ, DISPLAY=display, XDG_RUNTIME_DIR=str(tmp),
                    GDK_BACKEND="x11", CLIPBOARD_SELECTION="primary",
                )
                x11_env.pop("WAYLAND_DISPLAY", None)
                x11_log_path = tmp / "x11-primary.log"
                with x11_log_path.open("w") as x11_log:
                    x11_client = subprocess.Popen(
                        [sys.executable, fixture], env=x11_env,
                        stdin=subprocess.PIPE, stdout=x11_log, stderr=x11_log, text=True,
                    )
                wait_for(lambda: any(w.get("backend") == "xwayland" for w in windows()),
                         "X11 client did not appear", timeout=20)
                time.sleep(0.3)

                # X11 -> Wayland, X11 still focused (see docstring).
                send(x11_client, "copy primary-from-x11")
                wait_for(lambda: last_line(x11_log_path).startswith("copied"), "X11 client did not copy")
                wl_env = dict(os.environ, WAYLAND_DISPLAY=wl_display, XDG_RUNTIME_DIR=str(tmp))
                wl_env.pop("DISPLAY", None)
                r = subprocess.run(["wl-paste", "--primary"], env=wl_env, capture_output=True, text=True, timeout=10)
                assert r.returncode == 0 and r.stdout == "primary-from-x11\n", r
                print("PASS: PRIMARY selection set on X11 (still focused) reaches a native Wayland reader")

                # Wayland -> X11, via a fresh client so focus naturally lands
                # there (mirrors test_clipboard_bidirectional's own pattern).
                send(x11_client, "quit")
                x11_client.wait(timeout=5)
                x11_client = None
                wc = subprocess.Popen(["wl-copy", "--primary", "primary-from-wayland"], env=wl_env,
                                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                try:
                    time.sleep(0.3)
                    x11_log2_path = tmp / "x11-primary-2.log"
                    with x11_log2_path.open("w") as x11_log2:
                        x11_client = subprocess.Popen(
                            [sys.executable, fixture], env=x11_env,
                            stdin=subprocess.PIPE, stdout=x11_log2, stderr=x11_log2, text=True,
                        )
                    wait_for(lambda: any(w.get("backend") == "xwayland" for w in windows()),
                             "replacement X11 client did not appear", timeout=20)
                    time.sleep(0.3)
                    x11_window = next(w for w in windows() if w.get("backend") == "xwayland")
                    box = request(sock, reader, {"version": 1, "command": 'get_window_debug', "params": {"id": x11_window["id"]}})["WindowDebug"]["client_box"]
                    request(sock, reader, {"version": 1, "command": 'move_cursor', "params": {
                        "x": box["x"] + box["width"] // 2,
                        "y": box["y"] + box["height"] // 2,
                    }})
                    request(sock, reader, {'version': 1, 'command': 'pointer_button', 'params': {"button": 274, "pressed": True}})
                    request(sock, reader, {'version': 1, 'command': 'pointer_button', 'params': {"button": 274, "pressed": False}})
                    wait_for(
                        lambda: last_line(x11_log2_path) == "pasted 20 bytes: 'primary-from-wayland'",
                        lambda: f"X11 could not read Wayland-sourced PRIMARY selection: {last_line(x11_log2_path)!r}",
                        timeout=5,
                    )
                    print("PASS: a real X11 middle click pastes PRIMARY set by native Wayland")
                finally:
                    if wc.poll() is None:
                        wc.terminate()
        finally:
            if x11_client and x11_client.poll() is None:
                x11_client.terminate()
                x11_client.wait(timeout=5)
            compositor.terminate()
            compositor.wait(timeout=5)
            log.close()


def run():
    test_enabled()
    test_native_scaling_root_geometry()
    test_native_scaling_root_geometry(output_policy=True)
    test_disabled()
    test_missing_executable()
    test_server_stop_cleanup()
    test_managed_window()
    test_native_scaling_managed_window()
    test_unmapped_window_has_no_chrome()
    test_withdrawn_window_survives_close_animation()
    test_gtk_menu_alignment()
    test_gtk_menu_alignment_zoomed()
    test_gtk_menu_multi_output()
    test_negative_output_origin()
    test_gtk_menu_fractional_scale()
    test_gtk_menu_fractional_scale("2")
    test_gtk_transient_dialog()
    test_gtk_file_dialog()
    test_gtk_file_dialog(native=True)
    test_gtk_combo_and_tooltip()
    test_clipboard_bidirectional()
    test_x11_to_wayland_clipboard_focus_limitation()
    test_drag_and_drop()
    test_x11_source_drag_to_wayland_limitation()
    test_primary_selection_bidirectional()
    print("Xwayland environment, connection and managed-window tests passed")


if __name__ == "__main__":
    run()

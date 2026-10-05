#!/usr/bin/env python3
"""Exercise real image-capture protocols against isolated headless compositors.
Check SHM pixels, optional GBM/DMA-BUF frames, native-window isolation,
source lifetime, capture status, Stop sharing and screenshot coexistence.
See docs/screen-sharing.md for the contract and qualification limits.
"""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile

from PIL import Image

from desktop_zoom import ROOT, wait_for
from ipc_client import IPCClient, spawn_compositor, stop_process

# wl_shm's legacy codes; every other format shares its number with the DRM
# fourcc code. See AGENTS.md: 8888 shm formats here are premultiplied,
# native-endian 0xAARRGGBB, so memory order on this little-endian host is
# B, G, R, A.
SHM_FORMAT_ARGB8888 = 0
SHM_FORMAT_XRGB8888 = 1

# DRM fourcc codes ("AR24"/"XR24"), used only by the dmabuf path's ready line.
DRM_FORMAT_ARGB8888 = 0x34325241
DRM_FORMAT_XRGB8888 = 0x34325258


def build_client(tmp):
    protocols = Path(subprocess.check_output(
        ["pkg-config", "--variable=pkgdatadir", "wayland-protocols"], text=True).strip())
    sources = []
    for name, path in (
        ("xdg-shell", "stable/xdg-shell/xdg-shell.xml"),
        ("viewporter", "stable/viewporter/viewporter.xml"),
        ("single-pixel-buffer", "staging/single-pixel-buffer/single-pixel-buffer-v1.xml"),
        ("linux-dmabuf-v1", "stable/linux-dmabuf/linux-dmabuf-v1.xml"),
        ("ext-image-copy-capture-v1", "staging/ext-image-copy-capture/ext-image-copy-capture-v1.xml"),
        ("ext-image-capture-source-v1", "staging/ext-image-capture-source/ext-image-capture-source-v1.xml"),
        # Stage 3: the client binds this directly to discover its own
        # toplevel handle and request a per-window capture source through
        # ext-image-capture-source-v1's foreign-toplevel manager.
        ("ext-foreign-toplevel-list-v1", "staging/ext-foreign-toplevel-list/ext-foreign-toplevel-list-v1.xml"),
    ):
        for mode, suffix in (("client-header", "client-protocol.h"), ("private-code", "protocol.c")):
            subprocess.run(["wayland-scanner", mode, str(protocols / path),
                            str(tmp / f"{name}-{suffix}")], check=True)
        sources.append(str(tmp / f"{name}-protocol.c"))
    subprocess.run(["cc", "-Wall", "-Wextra", "-Werror", f"-I{tmp}",
                    str(ROOT / "tests/capture_client.c"), *sources,
                    "-lwayland-client", "-lgbm", "-o", str(tmp / "client")], check=True)


def run_case(client_binary, renderer, command, valid_formats, argb_format, label):
    """Present a known solid-color window, capture the output through
    `command` ("capture" or "capture_dmabuf"), and check a sampled pixel.
    """
    with tempfile.TemporaryDirectory(prefix="rediwm-capture-") as directory:
        tmp = Path(directory)
        compositor, log = spawn_compositor(
            tmp, scale="1", outputs="1", renderer=renderer,
            config_content="[compositor]\nxwayland = false\n",
            env_extra={"XDG_CACHE_HOME": str(tmp / "cache"), "WLR_RENDERER_ALLOW_SOFTWARE": "1"})
        client = None
        client_log = tmp / "client.log"
        try:
            socket_path = wait_for(lambda: next(tmp.glob("rediwm-*.sock"), None), "IPC unavailable")
            display = next(p.name for p in tmp.glob("wayland-*") if not p.name.endswith(".lock"))
            env = dict(os.environ, XDG_RUNTIME_DIR=str(tmp), WAYLAND_DISPLAY=display)
            with client_log.open("w") as output:
                client = subprocess.Popen([str(client_binary)], stdin=subprocess.PIPE,
                                          stdout=output, stderr=output, text=True, env=env)

            with IPCClient(socket_path) as ipc:
                win = wait_for(lambda: next((w for w in ipc.get_windows()
                                             if w["app_id"] == "rediwm.capture-fixture"), None),
                               "capture-fixture toplevel did not map")
                assert (win["width"], win["height"]) == (200, 150), win
                wait_for(lambda: "presented\n" in client_log.read_text(), "first frame not presented")

                # Pin down world/camera placement so a captured buffer pixel maps
                # to a known surface-local coordinate by simple addition.
                ipc.action("move_window_to", {"id": win["id"], "x": 0, "y": 0})
                ipc.action("reset_camera")
                camera = ipc.action("get_camera")
                assert (camera["x"], camera["y"], camera["zoom_percent"]) == (0, 0, 100), camera
                win = next(w for w in ipc.get_windows() if w["id"] == win["id"])
                assert (win["x"], win["y"], win["zoom_percent"]) == (0, 0, 100), win

                outputs = ipc.get_outputs()
                assert len(outputs) == 1, outputs
                out = outputs[0]

                before = client_log.read_text()

                def send(command_line):
                    client.stdin.write(command_line + "\n")
                    client.stdin.flush()

                def wait_line(prefix):
                    nonlocal before

                    def find():
                        text = client_log.read_text()
                        lines = text[len(before):].splitlines()
                        for i, candidate in enumerate(lines):
                            if candidate.startswith(prefix):
                                return i, lines
                        return None

                    match = wait_for(find, f"no reply to a command expecting {prefix!r} (log so far: {client_log.read_text()[len(before):]!r})")
                    index, lines = match
                    before += "".join(l + "\n" for l in lines[:index + 1])
                    return lines[index]

                send(command)
                ready = wait_line("ready").split()
                _, buf_w, buf_h, fmt = ready
                buf_w, buf_h, fmt = int(buf_w), int(buf_h), int(fmt)
                # The session must report the monitor's real buffer size, not the
                # small fixture window's size — this is a full-output source.
                assert (buf_w, buf_h) == (out["buffer_width"], out["buffer_height"]), (ready, out)
                assert fmt in valid_formats, ready

                def sample(x, y):
                    send(f"sample {x} {y}")
                    _, sx, sy, b0, b1, b2, b3 = wait_line("pixel").split()
                    assert (int(sx), int(sy)) == (x, y)
                    # Premultiplied native-endian 0xAARRGGBB -> little-endian bytes B,G,R,A.
                    return (int(b2), int(b1), int(b0), int(b3))

                # (50, 50) sits inside the 200x150 fixture window, which was
                # pinned to content-origin (0, 0) with no camera pan/zoom, so
                # it maps directly onto that buffer coordinate.
                r, g, b, a = sample(50, 50)
                assert (r, g, b) == (255, 0, 0), (r, g, b, a)
                if fmt == argb_format:
                    assert a == 255, a

                print(f"capture: {label} monitor session returned real pixels ({buf_w}x{buf_h}, fmt={fmt:#x})")

                send("quit")

                # A live session/frame must not wedge or crash teardown.
                for keycode in (125, 42):
                    ipc.action("key", {"keycode": keycode, "pressed": True})
                try:
                    ipc.action("key", {"keycode": 18, "pressed": True})
                except EOFError:
                    pass
            compositor.wait(timeout=10)
            assert compositor.returncode == 0, (tmp / "compositor.log").read_text()
            client.wait(timeout=5)
            print(f"capture: {label} compositor shut down cleanly with an open capture session")
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


def run_window_capture_case(client_binary):
    """Stage 3 (docs/screen-sharing.md): request a capture source for the
    fixture's own toplevel through ext-foreign-toplevel-list-v1 +
    ext-foreign-toplevel-image-capture-source-manager-v1
    (`window_capture`), instead of the output manager `run_case` uses. This
    is the validation checkpoint the plan called for: it settles, with real
    protocol traffic, whether `wlr_ext_image_capture_source_v1_create_with_scene_node`
    renders on its own (expected) rather than needing the compositor to
    manually drive a swapchain, which the stage 0 spike could only guess at
    from an ephemeral, disconnected probe.
    """
    with tempfile.TemporaryDirectory(prefix="rediwm-window-capture-") as directory:
        tmp = Path(directory)
        compositor, log = spawn_compositor(
            tmp, scale="1", outputs="1", renderer="pixman",
            config_content="[compositor]\nxwayland = false\n",
            env_extra={"XDG_CACHE_HOME": str(tmp / "cache"), "WLR_RENDERER_ALLOW_SOFTWARE": "1"})
        client = None
        client_log = tmp / "client.log"
        try:
            socket_path = wait_for(lambda: next(tmp.glob("rediwm-*.sock"), None), "IPC unavailable")
            display = next(p.name for p in tmp.glob("wayland-*") if not p.name.endswith(".lock"))
            env = dict(os.environ, XDG_RUNTIME_DIR=str(tmp), WAYLAND_DISPLAY=display)
            with client_log.open("w") as output:
                client = subprocess.Popen([str(client_binary)], stdin=subprocess.PIPE,
                                          stdout=output, stderr=output, text=True, env=env)

            with IPCClient(socket_path) as ipc:
                win = wait_for(lambda: next((w for w in ipc.get_windows()
                                             if w["app_id"] == "rediwm.capture-fixture"), None),
                               "capture-fixture toplevel did not map")
                assert (win["width"], win["height"]) == (200, 150), win
                wait_for(lambda: "presented\n" in client_log.read_text(), "first frame not presented")

                before = client_log.read_text()

                def send(command_line):
                    client.stdin.write(command_line + "\n")
                    client.stdin.flush()

                def wait_line(prefix):
                    nonlocal before

                    def find():
                        text = client_log.read_text()
                        lines = text[len(before):].splitlines()
                        for i, candidate in enumerate(lines):
                            if candidate.startswith(prefix):
                                return i, lines
                        return None

                    match = wait_for(find, f"no reply to a command expecting {prefix!r} (log so far: {client_log.read_text()[len(before):]!r})")
                    index, lines = match
                    before += "".join(l + "\n" for l in lines[:index + 1])
                    return lines[index]

                send("window_capture")
                ready = wait_line("ready").split()
                _, buf_w, buf_h, fmt = ready
                buf_w, buf_h, fmt = int(buf_w), int(buf_h), int(fmt)
                # The session must report the *window's* own content size, not
                # a monitor-sized buffer or a crop of one.
                assert (buf_w, buf_h) == (200, 150), (ready, win)
                assert fmt in (SHM_FORMAT_ARGB8888, SHM_FORMAT_XRGB8888), ready

                def sample(x, y):
                    send(f"sample {x} {y}")
                    _, sx, sy, b0, b1, b2, b3 = wait_line("pixel").split()
                    assert (int(sx), int(sy)) == (x, y)
                    return (int(b2), int(b1), int(b0), int(b3))

                r, g, b, a = sample(50, 50)
                assert (r, g, b) == (255, 0, 0), (r, g, b, a)
                if fmt == SHM_FORMAT_ARGB8888:
                    assert a == 255, a

                print(f"capture: window session returned real pixels at its own {buf_w}x{buf_h} "
                      f"content size, not the monitor's (fmt={fmt:#x})")

                send("quit")

                # A live window-capture session must not wedge or crash teardown.
                for keycode in (125, 42):
                    ipc.action("key", {"keycode": keycode, "pressed": True})
                try:
                    ipc.action("key", {"keycode": 18, "pressed": True})
                except EOFError:
                    pass
            compositor.wait(timeout=10)
            assert compositor.returncode == 0, (tmp / "compositor.log").read_text()
            client.wait(timeout=5)
            print("capture: compositor shut down cleanly with an open window-capture session")
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


def run_window_occlusion_case(client_binary):
    """Stage 3: two overlapping fixture windows; capture the bottom
    (visually occluded) one and confirm its own known color, not the
    occluder's or black — docs/screen-sharing.md: "Occlusion and camera pan
    must not reveal another window or crop the chosen one." Relies on the
    compositor's own map-time cascade offset (each newly mapped window at
    the default (0, 0) position gets placed 30 world px further than the
    last) for the overlap, rather than moving a window after mapping —
    `run_window_capture_case` found that races the capture source's
    internal alignment; `run_window_camera_case` covers a deliberate move.
    """
    with tempfile.TemporaryDirectory(prefix="rediwm-window-occlusion-") as directory:
        tmp = Path(directory)
        compositor, log = spawn_compositor(
            tmp, scale="1", outputs="1", renderer="pixman",
            config_content="[compositor]\nxwayland = false\n",
            env_extra={"XDG_CACHE_HOME": str(tmp / "cache"), "WLR_RENDERER_ALLOW_SOFTWARE": "1"})
        bottom = top = None
        bottom_log = tmp / "bottom.log"
        top_log = tmp / "top.log"
        try:
            socket_path = wait_for(lambda: next(tmp.glob("rediwm-*.sock"), None), "IPC unavailable")
            display = next(p.name for p in tmp.glob("wayland-*") if not p.name.endswith(".lock"))
            base_env = dict(os.environ, XDG_RUNTIME_DIR=str(tmp), WAYLAND_DISPLAY=display)

            with bottom_log.open("w") as out:
                bottom = subprocess.Popen(
                    [str(client_binary)], stdin=subprocess.PIPE, stdout=out, stderr=out, text=True,
                    env=dict(base_env, CAPTURE_APP_ID="rediwm.capture-fixture-bottom"))

            with IPCClient(socket_path) as ipc:
                wait_for(lambda: next((w for w in ipc.get_windows()
                                       if w["app_id"] == "rediwm.capture-fixture-bottom"), None),
                         "bottom fixture toplevel did not map")
                wait_for(lambda: "presented\n" in bottom_log.read_text(), "bottom frame not presented")

                with top_log.open("w") as out:
                    top = subprocess.Popen(
                        [str(client_binary)], stdin=subprocess.PIPE, stdout=out, stderr=out, text=True,
                        env=dict(base_env, CAPTURE_APP_ID="rediwm.capture-fixture-top", CAPTURE_GREEN="1"))
                wait_for(lambda: next((w for w in ipc.get_windows()
                                       if w["app_id"] == "rediwm.capture-fixture-top"), None),
                         "top fixture toplevel did not map")
                wait_for(lambda: "presented\n" in top_log.read_text(), "top frame not presented")

                bottom_win = next(w for w in ipc.get_windows() if w["app_id"] == "rediwm.capture-fixture-bottom")
                top_win = next(w for w in ipc.get_windows() if w["app_id"] == "rediwm.capture-fixture-top")
                # Confirm the assumed cascade overlap actually happened before
                # trusting the result below (both fixtures are 200x150).
                assert 0 < top_win["x"] - bottom_win["x"] < 200, (bottom_win, top_win)
                assert 0 < top_win["y"] - bottom_win["y"] < 150, (bottom_win, top_win)

                before = bottom_log.read_text()

                def send(command_line):
                    bottom.stdin.write(command_line + "\n")
                    bottom.stdin.flush()

                def wait_line(prefix):
                    nonlocal before

                    def find():
                        text = bottom_log.read_text()
                        lines = text[len(before):].splitlines()
                        for i, candidate in enumerate(lines):
                            if candidate.startswith(prefix):
                                return i, lines
                        return None

                    match = wait_for(find, f"no reply to a command expecting {prefix!r} (log so far: {bottom_log.read_text()[len(before):]!r})")
                    index, lines = match
                    before += "".join(l + "\n" for l in lines[:index + 1])
                    return lines[index]

                send("window_capture")
                ready = wait_line("ready").split()
                buf_w, buf_h = int(ready[1]), int(ready[2])
                assert (buf_w, buf_h) == (200, 150), ready

                state = get_capture_state(ipc)
                assert state["sessions"] == [{"output": None, "window_id": bottom_win["id"]}], (state, bottom_win, top_win)

                send("sample 50 50")
                _, sx, sy, b0, b1, b2, b3 = wait_line("pixel").split()
                r, g, b = int(b2), int(b1), int(b0)
                # (50, 50) local to the bottom window falls inside the region
                # the top (green) window visually covers on the real display.
                # A window source must still return the bottom window's own
                # red — not green (the occluder) and not black (empty/wrong).
                assert (r, g, b) == (255, 0, 0), (r, g, b)

                print("capture: window capture of an occluded window returned its own pixels, not the occluder's")

                send("quit")
                top.stdin.write("quit\n")
                top.stdin.flush()
                for keycode in (125, 42):
                    ipc.action("key", {"keycode": keycode, "pressed": True})
                try:
                    ipc.action("key", {"keycode": 18, "pressed": True})
                except EOFError:
                    pass
            compositor.wait(timeout=10)
            assert compositor.returncode == 0, (tmp / "compositor.log").read_text()
            bottom.wait(timeout=5)
            top.wait(timeout=5)
        except Exception:
            print((tmp / "compositor.log").read_text()[-6000:])
            if bottom_log.exists():
                print("bottom client:", bottom_log.read_text())
            if top_log.exists():
                print("top client:", top_log.read_text())
            raise
        finally:
            if bottom and bottom.poll() is None:
                stop_process(bottom)
            if top and top.poll() is None:
                stop_process(top)
            if compositor.poll() is None:
                stop_process(compositor)
            log.close()


def run_window_camera_case(client_binary):
    """Stage 3: move the window far off any output and pan the world camera
    away too, then capture it — docs/screen-sharing.md: "camera
    independence" / "Occlusion and camera pan must not reveal another
    window or crop the chosen one." `WindowCaptureSource` renders purely
    from `content_tree`-local buffer positions (`wlr_scene_node_for_each_buffer`),
    never touching world/output/camera coordinates at all, so this is
    mostly a regression guard against ever reintroducing a
    position-dependent implementation (the earlier
    `create_with_scene_node`-based one effectively was one).
    """
    with tempfile.TemporaryDirectory(prefix="rediwm-window-camera-") as directory:
        tmp = Path(directory)
        compositor, log = spawn_compositor(
            tmp, scale="1", outputs="1", renderer="pixman",
            config_content="[compositor]\nxwayland = false\n",
            env_extra={"XDG_CACHE_HOME": str(tmp / "cache"), "WLR_RENDERER_ALLOW_SOFTWARE": "1"})
        client = None
        client_log = tmp / "client.log"
        try:
            socket_path = wait_for(lambda: next(tmp.glob("rediwm-*.sock"), None), "IPC unavailable")
            display = next(p.name for p in tmp.glob("wayland-*") if not p.name.endswith(".lock"))
            env = dict(os.environ, XDG_RUNTIME_DIR=str(tmp), WAYLAND_DISPLAY=display)
            with client_log.open("w") as output:
                client = subprocess.Popen([str(client_binary)], stdin=subprocess.PIPE,
                                          stdout=output, stderr=output, text=True, env=env)

            with IPCClient(socket_path) as ipc:
                win = wait_for(lambda: next((w for w in ipc.get_windows()
                                             if w["app_id"] == "rediwm.capture-fixture"), None),
                               "capture-fixture toplevel did not map")
                wait_for(lambda: "presented\n" in client_log.read_text(), "first frame not presented")

                # Move the window far outside any output's bounds and pan the
                # camera somewhere unrelated. A real repaint must actually
                # happen before capturing, or a stale render could pass for
                # the wrong reason — `get_window_debug` round-trips through
                # the compositor's own IPC handler, which only answers after
                # processing the preceding actions on the same connection.
                ipc.action("move_window_to", {"id": win["id"], "x": 9000, "y": -6000})
                ipc.action("set_camera", {"x": -20000, "y": 15000})
                moved = ipc.query("get_window_debug", {"id": win["id"]})
                assert moved is not None, "window vanished after moving off-screen"

                before = client_log.read_text()

                def send(command_line):
                    client.stdin.write(command_line + "\n")
                    client.stdin.flush()

                def wait_line(prefix):
                    nonlocal before

                    def find():
                        text = client_log.read_text()
                        lines = text[len(before):].splitlines()
                        for i, candidate in enumerate(lines):
                            if candidate.startswith(prefix):
                                return i, lines
                        return None

                    match = wait_for(find, f"no reply to a command expecting {prefix!r} (log so far: {client_log.read_text()[len(before):]!r})")
                    index, lines = match
                    before += "".join(l + "\n" for l in lines[:index + 1])
                    return lines[index]

                send("window_capture")
                ready = wait_line("ready").split()
                assert (int(ready[1]), int(ready[2])) == (200, 150), ready

                send("sample 50 50")
                _, sx, sy, b0, b1, b2, b3 = wait_line("pixel").split()
                r, g, b = int(b2), int(b1), int(b0)
                assert (r, g, b) == (255, 0, 0), (r, g, b)

                print("capture: window capture unaffected by moving the window off-output and panning the camera")

                send("quit")
                for keycode in (125, 42):
                    ipc.action("key", {"keycode": keycode, "pressed": True})
                try:
                    ipc.action("key", {"keycode": 18, "pressed": True})
                except EOFError:
                    pass
            compositor.wait(timeout=10)
            assert compositor.returncode == 0, (tmp / "compositor.log").read_text()
            client.wait(timeout=5)
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


def run_window_minimize_case(client_binary):
    """Stage 3: minimizing (unlike a real close) hides the frame without
    destroying `content_tree`, so `WindowCaptureSource`'s destroy-triggered
    graceful stop never fires for it — `Toplevel.minimize` calls
    `Manager.stopForWindow` explicitly instead, the same bounded
    hard-disconnect fallback `run_idle_blank_case` already proves for
    output idle-blanking. This is the failure contract's "minimize: End
    the selected source's session" row.
    """
    with tempfile.TemporaryDirectory(prefix="rediwm-window-minimize-") as directory:
        tmp = Path(directory)
        compositor, log = spawn_compositor(
            tmp, scale="1", outputs="1", renderer="pixman",
            config_content="[compositor]\nxwayland = false\n",
            env_extra={"XDG_CACHE_HOME": str(tmp / "cache"), "WLR_RENDERER_ALLOW_SOFTWARE": "1"})
        client = None
        client_log = tmp / "client.log"
        try:
            socket_path = wait_for(lambda: next(tmp.glob("rediwm-*.sock"), None), "IPC unavailable")
            display = next(p.name for p in tmp.glob("wayland-*") if not p.name.endswith(".lock"))
            env = dict(os.environ, XDG_RUNTIME_DIR=str(tmp), WAYLAND_DISPLAY=display)
            with client_log.open("w") as output:
                client = subprocess.Popen([str(client_binary)], stdin=subprocess.PIPE,
                                          stdout=output, stderr=output, text=True, env=env)

            with IPCClient(socket_path) as ipc:
                win = wait_for(lambda: next((w for w in ipc.get_windows()
                                             if w["app_id"] == "rediwm.capture-fixture"), None),
                               "capture-fixture toplevel did not map")
                wait_for(lambda: "presented\n" in client_log.read_text(), "first frame not presented")

                before = client_log.read_text()

                def send(command_line):
                    client.stdin.write(command_line + "\n")
                    client.stdin.flush()

                def wait_line(prefix):
                    nonlocal before

                    def find():
                        text = client_log.read_text()
                        lines = text[len(before):].splitlines()
                        for i, candidate in enumerate(lines):
                            if candidate.startswith(prefix):
                                return i, lines
                        return None

                    match = wait_for(find, f"no reply to a command expecting {prefix!r} (log so far: {client_log.read_text()[len(before):]!r})")
                    index, lines = match
                    before += "".join(l + "\n" for l in lines[:index + 1])
                    return lines[index]

                send("window_capture")
                wait_line("ready")

                ipc.action("minimize_window", {"id": win["id"]})
                # A hard disconnect (no protocol `stopped` event first, same
                # as stopAll/stopForOutput elsewhere), so the client's own
                # `wl_display_dispatch` loop errors out and it exits cleanly
                # rather than hanging — the same signal `run_idle_blank_case`
                # and `run_output_destroy_case` check for the output case.
                client.wait(timeout=10)
                assert client.returncode == 0, (client_log.read_text(), client.returncode)
                print("capture: minimizing the captured window disconnected its capturing client")

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


def run_window_resize_case(client_binary):
    """Stage 3: resize the fixture mid-lifetime; a fresh window_capture
    request afterward must reflect the new size, not hang or return
    stale-size memory (docs/screen-sharing.md's failure contract: "Output
    size/scale/transform changes: Renegotiate coherently ... never send
    old-size memory as a new frame" — the same principle applied to a
    resized window source). Tests a fresh request after the resize, not
    live renegotiation of an already-open session against a continuously
    polling consumer — a real gap, noted in TESTING.md.
    """
    with tempfile.TemporaryDirectory(prefix="rediwm-window-resize-") as directory:
        tmp = Path(directory)
        compositor, log = spawn_compositor(
            tmp, scale="1", outputs="1", renderer="pixman",
            config_content="[compositor]\nxwayland = false\n",
            env_extra={"XDG_CACHE_HOME": str(tmp / "cache"), "WLR_RENDERER_ALLOW_SOFTWARE": "1"})
        client = None
        client_log = tmp / "client.log"
        try:
            socket_path = wait_for(lambda: next(tmp.glob("rediwm-*.sock"), None), "IPC unavailable")
            display = next(p.name for p in tmp.glob("wayland-*") if not p.name.endswith(".lock"))
            env = dict(os.environ, XDG_RUNTIME_DIR=str(tmp), WAYLAND_DISPLAY=display)
            with client_log.open("w") as output:
                client = subprocess.Popen([str(client_binary)], stdin=subprocess.PIPE,
                                          stdout=output, stderr=output, text=True, env=env)

            with IPCClient(socket_path) as ipc:
                win = wait_for(lambda: next((w for w in ipc.get_windows()
                                             if w["app_id"] == "rediwm.capture-fixture"), None),
                               "capture-fixture toplevel did not map")
                wait_for(lambda: "presented\n" in client_log.read_text(), "first frame not presented")

                before = client_log.read_text()

                def send(command_line):
                    client.stdin.write(command_line + "\n")
                    client.stdin.flush()

                def wait_line(prefix):
                    nonlocal before

                    def find():
                        text = client_log.read_text()
                        lines = text[len(before):].splitlines()
                        for i, candidate in enumerate(lines):
                            if candidate.startswith(prefix):
                                return i, lines
                        return None

                    match = wait_for(find, f"no reply to a command expecting {prefix!r} (log so far: {client_log.read_text()[len(before):]!r})")
                    index, lines = match
                    before += "".join(l + "\n" for l in lines[:index + 1])
                    return lines[index]

                send("window_capture")
                ready = wait_line("ready").split()
                assert (int(ready[1]), int(ready[2])) == (200, 150), ready

                send("resize 320 240")
                resized = wait_line("resized").split()
                assert (int(resized[1]), int(resized[2])) == (320, 240), resized
                wait_for(lambda: next(w for w in ipc.get_windows() if w["id"] == win["id"])["width"] == 320,
                         "compositor did not observe the resize")

                send("window_capture")
                ready2 = wait_line("ready").split()
                assert (int(ready2[1]), int(ready2[2])) == (320, 240), ready2

                send("sample 50 50")
                _, sx, sy, b0, b1, b2, b3 = wait_line("pixel").split()
                r, g, b = int(b2), int(b1), int(b0)
                assert (r, g, b) == (255, 0, 0), (r, g, b)

                print("capture: window resize reflected in a fresh capture request (200x150 -> 320x240)")

                send("quit")
                for keycode in (125, 42):
                    ipc.action("key", {"keycode": keycode, "pressed": True})
                try:
                    ipc.action("key", {"keycode": 18, "pressed": True})
                except EOFError:
                    pass
            compositor.wait(timeout=10)
            assert compositor.returncode == 0, (tmp / "compositor.log").read_text()
            client.wait(timeout=5)
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


def run_window_destroy_case(client_binary):
    """Stage 3: a window closing while a *different* client watches it
    ends the watcher's session gracefully — a real `stopped` event via
    `WindowCaptureSource.destroy()`'s `finish()` call firing the source's
    `destroy` signal, which the core ext-image-copy-capture machinery
    listens for internally — rather than only the crash-safety already
    covered by `run_window_capture_case` closing its own capturing client
    on full compositor shutdown. This is the failure contract's "window
    destruction/minimize: End the selected source's session" row, checked
    end to end instead of trusted from the design alone.
    """
    with tempfile.TemporaryDirectory(prefix="rediwm-window-destroy-") as directory:
        tmp = Path(directory)
        compositor, log = spawn_compositor(
            tmp, scale="1", outputs="1", renderer="pixman",
            config_content="[compositor]\nxwayland = false\n",
            env_extra={"XDG_CACHE_HOME": str(tmp / "cache"), "WLR_RENDERER_ALLOW_SOFTWARE": "1"})
        owner = watcher = None
        owner_log = tmp / "owner.log"
        watcher_log = tmp / "watcher.log"
        try:
            socket_path = wait_for(lambda: next(tmp.glob("rediwm-*.sock"), None), "IPC unavailable")
            display = next(p.name for p in tmp.glob("wayland-*") if not p.name.endswith(".lock"))
            base_env = dict(os.environ, XDG_RUNTIME_DIR=str(tmp), WAYLAND_DISPLAY=display)

            with owner_log.open("w") as out:
                owner = subprocess.Popen(
                    [str(client_binary)], stdin=subprocess.PIPE, stdout=out, stderr=out, text=True,
                    env=dict(base_env, CAPTURE_APP_ID="rediwm.capture-fixture-owner"))

            with IPCClient(socket_path) as ipc:
                wait_for(lambda: next((w for w in ipc.get_windows()
                                       if w["app_id"] == "rediwm.capture-fixture-owner"), None),
                         "owner fixture toplevel did not map")
                wait_for(lambda: "presented\n" in owner_log.read_text(), "owner frame not presented")

                with watcher_log.open("w") as out:
                    watcher = subprocess.Popen(
                        [str(client_binary)], stdin=subprocess.PIPE, stdout=out, stderr=out, text=True,
                        env=dict(base_env, CAPTURE_APP_ID="rediwm.capture-fixture-watcher",
                                 CAPTURE_TARGET_APP_ID="rediwm.capture-fixture-owner"))
                wait_for(lambda: next((w for w in ipc.get_windows()
                                       if w["app_id"] == "rediwm.capture-fixture-watcher"), None),
                         "watcher fixture toplevel did not map")
                wait_for(lambda: "presented\n" in watcher_log.read_text(), "watcher frame not presented")

                before = watcher_log.read_text()

                def send(command_line):
                    watcher.stdin.write(command_line + "\n")
                    watcher.stdin.flush()

                def wait_line(prefix):
                    nonlocal before

                    def find():
                        text = watcher_log.read_text()
                        lines = text[len(before):].splitlines()
                        for i, candidate in enumerate(lines):
                            if candidate.startswith(prefix):
                                return i, lines
                        return None

                    match = wait_for(find, f"no reply to a command expecting {prefix!r} (log so far: {watcher_log.read_text()[len(before):]!r})")
                    index, lines = match
                    before += "".join(l + "\n" for l in lines[:index + 1])
                    return lines[index]

                send("window_capture")
                ready = wait_line("ready").split()
                assert (int(ready[1]), int(ready[2])) == (200, 150), ready

                # Close the *owner*, not the watcher, while the watcher's
                # session on the owner's window is still open.
                owner.stdin.write("quit\n")
                owner.stdin.flush()
                owner.wait(timeout=5)

                wait_for(lambda: "stopped" in watcher_log.read_text()[len(before):],
                         "watcher never received a stopped event after the captured window closed")
                print("capture: closing a captured window gracefully stopped a different client's session")

                send("quit")
                for keycode in (125, 42):
                    ipc.action("key", {"keycode": keycode, "pressed": True})
                try:
                    ipc.action("key", {"keycode": 18, "pressed": True})
                except EOFError:
                    pass
            compositor.wait(timeout=10)
            assert compositor.returncode == 0, (tmp / "compositor.log").read_text()
            watcher.wait(timeout=5)
        except Exception:
            print((tmp / "compositor.log").read_text()[-6000:])
            if owner_log.exists():
                print("owner:", owner_log.read_text())
            if watcher_log.exists():
                print("watcher:", watcher_log.read_text())
            raise
        finally:
            if owner and owner.poll() is None:
                stop_process(owner)
            if watcher and watcher.poll() is None:
                stop_process(watcher)
            if compositor.poll() is None:
                stop_process(compositor)
            log.close()


def run_stop_all_case(client_binary):
    """The public wlroots 0.20 API has no general per-session stop call, so
    the "Stop all sharing" control (docs/screen-sharing.md's "Capture
    visibility, stop, and locking") falls back to disconnecting the client
    holding the session (`capture.Manager.stopAll`, wired to the
    `stop_all_capture` IPC action). Prove that actually revokes a live
    session rather than just being a plausible-looking no-op.
    """
    with tempfile.TemporaryDirectory(prefix="rediwm-capture-stopall-") as directory:
        tmp = Path(directory)
        compositor, log = spawn_compositor(
            tmp, scale="1", outputs="1",
            config_content="[compositor]\nxwayland = false\n",
            env_extra={"XDG_CACHE_HOME": str(tmp / "cache")})
        client = None
        client_log = tmp / "client.log"
        try:
            socket_path = wait_for(lambda: next(tmp.glob("rediwm-*.sock"), None), "IPC unavailable")
            display = next(p.name for p in tmp.glob("wayland-*") if not p.name.endswith(".lock"))
            env = dict(os.environ, XDG_RUNTIME_DIR=str(tmp), WAYLAND_DISPLAY=display)
            with client_log.open("w") as output:
                client = subprocess.Popen([str(client_binary)], stdin=subprocess.PIPE,
                                          stdout=output, stderr=output, text=True, env=env)

            with IPCClient(socket_path) as ipc:
                wait_for(lambda: next((w for w in ipc.get_windows()
                                       if w["app_id"] == "rediwm.capture-fixture"), None),
                         "capture-fixture toplevel did not map")
                wait_for(lambda: "presented\n" in client_log.read_text(), "first frame not presented")

                client.stdin.write("capture\n")
                client.stdin.flush()
                wait_for(lambda: "ready" in client_log.read_text(), "capture session did not become ready")

                ipc.action("stop_all_capture")

                # The client's whole connection is severed (the documented
                # bounded fallback ends every session on it, not just this
                # one), so its poll loop sees a dispatch error and exits —
                # a stale/no-op stop would instead leave it running forever.
                # Note this is a hard disconnect, not graceful revocation:
                # the client never receives the protocol's own `stopped`
                # event, since wl_client_destroy doesn't flush one first.
                client.wait(timeout=10)
                assert client.returncode == 0, (client_log.read_text(), client.returncode)

                # Revoking one client's sessions must not disturb the compositor
                # itself — only its own owned connection was touched.
                assert compositor.poll() is None, "compositor exited after stopAll"

                print("capture: stop_all_capture disconnected the client and ended its live session")

                for keycode in (125, 42):
                    ipc.action("key", {"keycode": keycode, "pressed": True})
                try:
                    ipc.action("key", {"keycode": 18, "pressed": True})
                except EOFError:
                    pass
            compositor.wait(timeout=10)
            assert compositor.returncode == 0, (tmp / "compositor.log").read_text()
            print("capture: compositor shut down cleanly after a client-initiated stop-all")
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


def get_capture_state(ipc):
    return ipc.request(query="get_capture_state")


def wait_for_capture_sessions(ipc, count, message):
    def check():
        state = get_capture_state(ipc)
        return state if state["active_sessions"] == count else None

    return wait_for(check, message)


def run_capture_state_case(client_binary):
    """Stage 1's `get_capture_state` diagnostics (docs/screen-sharing.md
    section 5: "Compositor diagnostics can report capture counts, source
    identity") must reflect a real client's session lifetime and the output
    it actually targets, not just compile.
    """
    with tempfile.TemporaryDirectory(prefix="rediwm-capture-state-") as directory:
        tmp = Path(directory)
        compositor, log = spawn_compositor(
            tmp, scale="1", outputs="1",
            config_content="[compositor]\nxwayland = false\n",
            env_extra={"XDG_CACHE_HOME": str(tmp / "cache")})
        client = None
        client_log = tmp / "client.log"
        try:
            socket_path = wait_for(lambda: next(tmp.glob("rediwm-*.sock"), None), "IPC unavailable")
            display = next(p.name for p in tmp.glob("wayland-*") if not p.name.endswith(".lock"))
            env = dict(os.environ, XDG_RUNTIME_DIR=str(tmp), WAYLAND_DISPLAY=display)
            with client_log.open("w") as output:
                client = subprocess.Popen([str(client_binary)], stdin=subprocess.PIPE,
                                          stdout=output, stderr=output, text=True, env=env)

            with IPCClient(socket_path) as ipc:
                wait_for(lambda: next((w for w in ipc.get_windows()
                                       if w["app_id"] == "rediwm.capture-fixture"), None),
                         "capture-fixture toplevel did not map")
                wait_for(lambda: "presented\n" in client_log.read_text(), "first frame not presented")

                state = get_capture_state(ipc)
                assert state["supported"] is True, state
                assert state["active_sessions"] == 0, state
                assert state["sessions"] == [], state
                assert state.get("indicator") is None, state

                out_name = ipc.get_outputs()[0]["name"]

                client.stdin.write("capture\n")
                client.stdin.flush()
                wait_for(lambda: "ready" in client_log.read_text(), "capture session did not become ready")

                state = wait_for_capture_sessions(ipc, 1, "session missing from capture status")
                assert state["sessions"] == [{"output": out_name, "window_id": None}], state

                client.stdin.write("quit\n")
                client.stdin.flush()
                client.wait(timeout=5)

                state = wait_for_capture_sessions(ipc, 0, "session did not clear from status after client quit")
                assert state["supported"] is True, state
                assert state["active_sessions"] == 0, state
                assert state["sessions"] == [], state
                assert state.get("indicator") is None, state

                print("capture: get_capture_state reflects session count and target output across a real lifetime")

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


def run_idle_blank_case(client_binary):
    """Failure contract: "Output idle blanking -> Initially close affected
    monitor streams." A disabled output stops receiving frame commits, so
    without `capture.Manager.stopForOutput` wired into `Output.setIdleBlanked`
    a live session's next frame request would simply hang forever instead of
    failing or completing. Like `stop_all_capture`, wlroots 0.20 gives no way
    to end just one session, so this is the same bounded fallback (whole
    client disconnect) scoped to the blanked output's sessions — the client
    holding the session sees a hard disconnect, not the protocol's own
    `stopped` event. Also proves the failure contract's minimum recovery
    promise: a fresh request from a new client succeeds after the output
    wakes again.
    """
    with tempfile.TemporaryDirectory(prefix="rediwm-capture-idleblank-") as directory:
        tmp = Path(directory)
        compositor, log = spawn_compositor(
            tmp, scale="1", outputs="1",
            config_content="[compositor]\nxwayland = false\n",
            env_extra={"XDG_CACHE_HOME": str(tmp / "cache")})
        client = None
        second_client = None
        client_log = tmp / "client.log"
        second_client_log = tmp / "client2.log"
        try:
            socket_path = wait_for(lambda: next(tmp.glob("rediwm-*.sock"), None), "IPC unavailable")
            display = next(p.name for p in tmp.glob("wayland-*") if not p.name.endswith(".lock"))
            env = dict(os.environ, XDG_RUNTIME_DIR=str(tmp), WAYLAND_DISPLAY=display)
            with client_log.open("w") as output:
                client = subprocess.Popen([str(client_binary)], stdin=subprocess.PIPE,
                                          stdout=output, stderr=output, text=True, env=env)

            with IPCClient(socket_path) as ipc:
                wait_for(lambda: next((w for w in ipc.get_windows()
                                       if w["app_id"] == "rediwm.capture-fixture"), None),
                         "capture-fixture toplevel did not map")
                wait_for(lambda: "presented\n" in client_log.read_text(), "first frame not presented")

                client.stdin.write("capture\n")
                client.stdin.flush()
                wait_for(lambda: "ready" in client_log.read_text(), "capture session did not become ready")
                wait_for_capture_sessions(ipc, 1, "session missing from status before blank")

                ipc.action("set_idle_config", {"enabled": True, "blank_after_seconds": 10, "suspend_after_seconds": 0})
                ipc.action("advance_idle_time", {"seconds": 15})

                # The bounded fallback disconnects the whole client (no
                # `stopped\n` from this client), same as stop_all_capture.
                client.wait(timeout=10)
                assert client.returncode == 0, (client_log.read_text(), client.returncode)
                assert compositor.poll() is None, "compositor exited on idle blank"
                wait_for_capture_sessions(ipc, 0, "session still reported active after idle blank")

                # Wake with a real key press, like production input, then
                # prove a fresh request from a new client actually recovers
                # rather than staying blocked under a stale policy state.
                ipc.action("key", {"keycode": 30, "pressed": True})
                ipc.action("key", {"keycode": 30, "pressed": False})
                idle_state = wait_for(
                    lambda: ipc.request(query="get_idle_state") if ipc.request(query="get_idle_state")["state"] == "active" else None,
                    "displays did not wake")
                assert idle_state["state"] == "active", idle_state

                with second_client_log.open("w") as output:
                    second_client = subprocess.Popen([str(client_binary)], stdin=subprocess.PIPE,
                                                      stdout=output, stderr=output, text=True, env=env)
                wait_for(lambda: "presented\n" in second_client_log.read_text(), "second client's first frame not presented")
                second_client.stdin.write("capture\n")
                second_client.stdin.flush()
                wait_for(lambda: "ready" in second_client_log.read_text(),
                         "a fresh capture request did not recover after wake")
                wait_for_capture_sessions(ipc, 1, "recovered session missing from status")

                print("capture: idle blanking disconnected the capturing client; a fresh request recovered after wake")

                second_client.stdin.write("quit\n")
                second_client.stdin.flush()
                second_client.wait(timeout=5)

                for keycode in (125, 42):
                    ipc.action("key", {"keycode": keycode, "pressed": True})
                try:
                    ipc.action("key", {"keycode": 18, "pressed": True})
                except EOFError:
                    pass
            compositor.wait(timeout=10)
            assert compositor.returncode == 0, (tmp / "compositor.log").read_text()
            print("capture: compositor shut down cleanly after the idle-blank capture policy test")
        except Exception:
            print((tmp / "compositor.log").read_text()[-6000:])
            if client_log.exists():
                print(client_log.read_text())
            if second_client_log.exists():
                print(second_client_log.read_text())
            raise
        finally:
            if client and client.poll() is None:
                stop_process(client)
            if second_client and second_client.poll() is None:
                stop_process(second_client)
            if compositor.poll() is None:
                stop_process(compositor)
            log.close()


def run_output_destroy_case(client_binary):
    """Failure contract: "Output unplug/disable or window destruction/
    minimize -> End the selected source's session; never switch to another
    source." Reuses output_destroy.py's LD_PRELOAD hook (real
    `wlr_output_destroy`, not a fake/simulated event) while a real capture
    session is live on the sole output. `Output.handleDestroy` calls the same
    `stopForOutput` bounded fallback as idle blanking and `stop_all_capture`
    (see run_idle_blank_case): the capturing client is disconnected outright,
    not just its one session, since wlroots 0.20 has no narrower stop. Checks
    that happens without the compositor itself wedging or crashing.
    """
    with tempfile.TemporaryDirectory(prefix="rediwm-capture-outdestroy-") as directory:
        tmp = Path(directory)
        flags = shlex.split(subprocess.check_output(
            ["pkg-config", "--cflags", "--libs", "wlroots-0.20", "wayland-server"],
            text=True))
        hook = tmp / "unplug.so"
        subprocess.run(["cc", "-shared", "-fPIC", "-Wall", "-Wextra", "-Werror",
                        str(ROOT / "tests/output_destroy_hook.c"), "-o", str(hook),
                        *flags, "-ldl"], check=True)
        trigger = tmp / "unplug"
        compositor, log = spawn_compositor(
            tmp, scale="1", outputs="1",
            config_content="[compositor]\nxwayland = false\n",
            env_extra={"XDG_CACHE_HOME": str(tmp / "cache"),
                       "LD_PRELOAD": str(hook), "REDIWM_TEST_UNPLUG": str(trigger)})
        client = None
        client_log = tmp / "client.log"
        try:
            socket_path = wait_for(lambda: next(tmp.glob("rediwm-*.sock"), None), "IPC unavailable")
            display = next(p.name for p in tmp.glob("wayland-*") if not p.name.endswith(".lock"))
            env = dict(os.environ, XDG_RUNTIME_DIR=str(tmp), WAYLAND_DISPLAY=display)
            with client_log.open("w") as output:
                client = subprocess.Popen([str(client_binary)], stdin=subprocess.PIPE,
                                          stdout=output, stderr=output, text=True, env=env)

            with IPCClient(socket_path) as ipc:
                wait_for(lambda: next((w for w in ipc.get_windows()
                                       if w["app_id"] == "rediwm.capture-fixture"), None),
                         "capture-fixture toplevel did not map")
                wait_for(lambda: "presented\n" in client_log.read_text(), "first frame not presented")

                client.stdin.write("capture\n")
                client.stdin.flush()
                wait_for(lambda: "ready" in client_log.read_text(), "capture session did not become ready")
                wait_for_capture_sessions(ipc, 1, "session missing from status before unplug")

                trigger.touch()
                wait_for(lambda: len(ipc.get_outputs()) == 0, "output did not unplug")

                # Same bounded fallback as stop_all_capture/idle blanking: the
                # whole client is disconnected, not just this one session.
                client.wait(timeout=10)
                assert client.returncode == 0, (client_log.read_text(), client.returncode)
                assert compositor.poll() is None, "compositor exited on output destroy"
                wait_for_capture_sessions(ipc, 0, "session still reported active after output destroy")

                print("capture: destroying the sole output stopped its session by disconnecting the capturing client")

                for keycode in (125, 42):
                    ipc.action("key", {"keycode": keycode, "pressed": True})
                try:
                    ipc.action("key", {"keycode": 18, "pressed": True})
                except EOFError:
                    pass
            compositor.wait(timeout=10)
            assert compositor.returncode == 0, (tmp / "compositor.log").read_text()
            print("capture: compositor shut down cleanly after a mid-session output destroy")
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


def run_screenshot_coexistence_case(client_binary):
    """Stage 1 exit gate: "Check normal rendering and screenshot
    coexistence." The compositor-internal screenshot path
    (screenshot/capture.zig) and the real ext-image-copy-capture-v1 protocol
    both end up reading the same scene output; prove a screenshot taken while
    a capture session is open doesn't corrupt either one, in either order.
    """
    with tempfile.TemporaryDirectory(prefix="rediwm-capture-screenshot-") as directory:
        tmp = Path(directory)
        compositor, log = spawn_compositor(
            tmp, scale="1", outputs="1",
            config_content="[compositor]\nxwayland = false\n",
            env_extra={"XDG_CACHE_HOME": str(tmp / "cache")})
        client = None
        client_log = tmp / "client.log"
        try:
            socket_path = wait_for(lambda: next(tmp.glob("rediwm-*.sock"), None), "IPC unavailable")
            display = next(p.name for p in tmp.glob("wayland-*") if not p.name.endswith(".lock"))
            env = dict(os.environ, XDG_RUNTIME_DIR=str(tmp), WAYLAND_DISPLAY=display)
            with client_log.open("w") as output:
                client = subprocess.Popen([str(client_binary)], stdin=subprocess.PIPE,
                                          stdout=output, stderr=output, text=True, env=env)

            with IPCClient(socket_path) as ipc:
                win = wait_for(lambda: next((w for w in ipc.get_windows()
                                             if w["app_id"] == "rediwm.capture-fixture"), None),
                               "capture-fixture toplevel did not map")
                wait_for(lambda: "presented\n" in client_log.read_text(), "first frame not presented")
                ipc.action("move_window_to", {"id": win["id"], "x": 0, "y": 0})
                ipc.action("reset_camera")

                before = client_log.read_text()

                def capture_pixel(x, y):
                    nonlocal before
                    client.stdin.write("capture\n")
                    client.stdin.flush()
                    wait_for(lambda: "ready" in client_log.read_text()[len(before):], "capture did not become ready")
                    client.stdin.write(f"sample {x} {y}\n")
                    client.stdin.flush()
                    line = wait_for(lambda: next((l for l in client_log.read_text()[len(before):].splitlines()
                                                  if l.startswith("pixel")), None),
                                    "no pixel sample reply")
                    before = client_log.read_text()
                    _, sx, sy, b0, b1, b2, b3 = line.split()
                    assert (int(sx), int(sy)) == (x, y)
                    return (int(b2), int(b1), int(b0))  # premultiplied BGRA -> RGB

                # Baseline: the real protocol sees the known red fixture pixel
                # before any screenshot is involved.
                assert capture_pixel(50, 50) == (255, 0, 0)

                png_path = tmp / "coexist.png"
                ipc.screenshot(path=str(png_path))
                with Image.open(png_path) as image:
                    rgb = image.convert("RGB").getpixel((50, 50))
                assert rgb == (255, 0, 0), rgb

                # A capture session opened after the screenshot must still see
                # correct pixels — the screenshot's own scene render/commit
                # must not leave the output desynchronized for later capture.
                assert capture_pixel(50, 50) == (255, 0, 0)

                print("capture: a compositor screenshot and a live ext-image-copy-capture-v1 session "
                      "both read correct pixels from the same output")

                client.stdin.write("quit\n")
                client.stdin.flush()
                client.wait(timeout=5)

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


def run():
    with tempfile.TemporaryDirectory(prefix="rediwm-capture-build-") as build_dir:
        build_tmp = Path(build_dir)
        build_client(build_tmp)
        client_binary = build_tmp / "client"

        run_case(client_binary, "pixman", "capture",
                 (SHM_FORMAT_ARGB8888, SHM_FORMAT_XRGB8888), SHM_FORMAT_ARGB8888, "ext-image-copy-capture-v1 shm")

        run_window_capture_case(client_binary)
        run_window_occlusion_case(client_binary)
        run_window_camera_case(client_binary)
        run_window_resize_case(client_binary)
        run_window_destroy_case(client_binary)
        run_window_minimize_case(client_binary)
        run_stop_all_case(client_binary)
        run_capture_state_case(client_binary)
        run_idle_blank_case(client_binary)
        run_output_destroy_case(client_binary)
        run_screenshot_coexistence_case(client_binary)

        if any(Path("/dev/dri").glob("renderD*")):
            run_case(client_binary, "gles2", "capture_dmabuf",
                     (DRM_FORMAT_ARGB8888, DRM_FORMAT_XRGB8888), DRM_FORMAT_ARGB8888, "ext-image-copy-capture-v1 dmabuf")
        else:
            print("capture: dmabuf path skipped, no /dev/dri render node on this machine (untested, not failing)")


if __name__ == "__main__":
    run()

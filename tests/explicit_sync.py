#!/usr/bin/env python3
"""wp_linux_drm_syncobj_v1 with a real Vulkan client on headless GLES2.

A client using explicit sync gets its buffers back only through release
points; if the compositor stops signalling them, vkcube runs out of images and
stalls. The window is also moved under the glass taskbar so backdrop captures
read its buffers (ReadFence). Skips without vkcube, wayland-info or a GPU.
"""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

from desktop_zoom import wait_for
from ipc_client import IPCClient, spawn_compositor, stop_process

FRAMES = 600


def globals_of(env):
    out = subprocess.run(["wayland-info"], env=env, capture_output=True, text=True, timeout=10).stdout
    return out


def run_case(disabled):
    with tempfile.TemporaryDirectory(prefix="rediwm-explicit-sync-") as directory:
        tmp = Path(directory)
        extra = {"XDG_CACHE_HOME": str(tmp / "cache")}
        if disabled:
            extra["REDIWM_NO_EXPLICIT_SYNC"] = "1"
        compositor, log = spawn_compositor(
            tmp, renderer=os.environ.get("REDIWM_TEST_RENDERER", "gles2"),
            config_content="[compositor]\nxwayland = false\n", env_extra=extra)
        try:
            socket_path = wait_for(lambda: next(tmp.glob("rediwm-*.sock"), None), "IPC unavailable")
            display = next(p.name for p in tmp.glob("wayland-*") if not p.name.endswith(".lock"))
            env = dict(os.environ, XDG_RUNTIME_DIR=str(tmp), WAYLAND_DISPLAY=display)
            env.pop("DISPLAY", None)
            advertised = "wp_linux_drm_syncobj_manager_v1" in globals_of(env)
            if disabled:
                assert not advertised, "REDIWM_NO_EXPLICIT_SYNC=1 still advertised syncobj"
                return
            if not advertised:
                print("SKIP: renderer/backend without timeline support")
                return
            client_log = tmp / "vkcube.log"
            with client_log.open("w") as output:
                client = subprocess.Popen(["vkcube", "--wsi", "wayland", "--c", str(FRAMES)],
                                          env=dict(env, WAYLAND_DEBUG="1"),
                                          stdout=subprocess.DEVNULL, stderr=output)
            try:
                with IPCClient(socket_path) as ipc:
                    # vkcube sets no app id; it is the only client.
                    win = wait_for(lambda: next(iter(ipc.get_windows()), None), "vkcube did not map")
                    output = next(iter(ipc.get_outputs()), None)
                    bottom = (output or {}).get("height") or 1080
                    ipc.action("move_window_to", {"id": win["id"], "x": 40, "y": bottom - win["height"] // 2})
                # Every image comes back only through a release point.
                client.wait(timeout=60)
            finally:
                if client.poll() is None:
                    client.kill()
                    client.wait()
                    raise AssertionError("vkcube stalled: release points not signalled")
            assert client.returncode == 0, client_log.read_text()[-2000:]
            acquires = client_log.read_text().count("set_acquire_point")
            assert acquires >= FRAMES, f"vkcube set only {acquires} acquire points"
            assert compositor.poll() is None, "compositor exited"
        finally:
            stop_process(compositor)
            log.close()


def main():
    missing = [tool for tool in ("vkcube", "wayland-info") if not shutil.which(tool)]
    if missing or not any(Path("/dev/dri").glob("renderD*")):
        print(f"SKIP: needs a render node and {', '.join(missing) or 'nothing else'}")
        return 0
    run_case(disabled=False)
    run_case(disabled=True)
    print("explicit sync checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())

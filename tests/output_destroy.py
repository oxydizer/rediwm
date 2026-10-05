#!/usr/bin/env python3
"""Hot-unplug a headless output while a real client remains connected."""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile

from desktop_zoom import ROOT, build_client, wait_for
from ipc_client import IPCClient, spawn_compositor, stop_process


def run():
    with tempfile.TemporaryDirectory(prefix="rediwm-output-destroy-") as directory:
        tmp = Path(directory)
        build_client(tmp)
        flags = shlex.split(subprocess.check_output(
            ["pkg-config", "--cflags", "--libs", "wlroots-0.20", "wayland-server"],
            text=True))
        hook = tmp / "unplug.so"
        subprocess.run(["cc", "-shared", "-fPIC", "-Wall", "-Wextra", "-Werror",
                        str(ROOT / "tests/output_destroy_hook.c"), "-o", str(hook),
                        *flags, "-ldl"], check=True)
        trigger = tmp / "unplug"
        compositor, log = spawn_compositor(
            tmp, outputs="2", config_content='[compositor]\nxwayland = false\n[keybinds]\n"F12" = "quit"\n',
            env_extra={"LD_PRELOAD": str(hook), "REDIWM_TEST_UNPLUG": str(trigger),
                       "XDG_CACHE_HOME": str(tmp / "cache")})
        client = None
        try:
            with IPCClient(tmp) as ipc:
                wait_for(lambda: len(ipc.get_outputs()) == 2, "two outputs missing")
                display = next(p.name for p in tmp.glob("wayland-*")
                               if not p.name.endswith(".lock"))
                client = subprocess.Popen([str(tmp / "client")], env=dict(
                    os.environ, XDG_RUNTIME_DIR=str(tmp), WAYLAND_DISPLAY=display),
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                wait_for(lambda: ipc.get_windows(), "client did not map")
                # The first-created scene output is the hook's unplug target.
                target = ipc.get_outputs()[0]
                ipc.move_cursor(20, 20, output=target["name"])
                ipc.action('set_camera', {"x": 0, "y": 0})
                px = target["logical_width"] - 40
                py = target["logical_height"] - target["bottom_exclusion"] - 40
                wait_for(lambda: ipc.hit_test(px, py, output=target["name"])["target_type"] == "mini_map", "mini map missing")
                ipc.move_cursor(px, py, output=target["name"])
                ipc.pointer_button(272, True)
                trigger.touch()
                wait_for(lambda: len(ipc.get_outputs()) == 1, "output did not unplug")
                ipc.pointer_button(272, False)
                assert ipc.get_input_state()["cursor_mode"] == "passthrough"
                assert compositor.poll() is None
                assert client.poll() is None
                assert ipc.get_windows(), "client disappeared on hot-unplug"
                ipc.wait_for_frame(output=ipc.get_outputs()[0]["name"])
                # Quit can close IPC before its buffered reply is flushed.
                ipc.sock.sendall(b'{"version":1,"command":"key","params":{"keycode":88,"pressed":true}}\n')
                assert compositor.wait(timeout=5) == 0, "orderly shutdown failed"
                print("output destruction: scene detached before node cleanup; client and IPC survive")
        except Exception:
            log.flush()
            print((tmp / "compositor.log").read_text())
            raise
        finally:
            if client is not None:
                stop_process(client)
            stop_process(compositor)
            log.close()


if __name__ == "__main__":
    run()

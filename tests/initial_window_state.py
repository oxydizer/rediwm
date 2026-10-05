#!/usr/bin/env python3
"""Client-requested startup states must agree with the displayed geometry."""
import os
from pathlib import Path
import subprocess
import tempfile

from desktop_zoom import build_client
from ipc_client import IPCClient, spawn_compositor, stop_process
from xwayland import wait_for, wayland_display_name


def run():
    with tempfile.TemporaryDirectory(prefix="rediwm-initial-state-") as directory:
        tmp = Path(directory)
        build_client(tmp)
        for decoration in ("client", "server"):
            for state, override, depth in (
                ("floating", False, 0),
                ("maximized", False, 0),
                ("fullscreen", False, 0),
                ("maximized", True, 0),
                ("fullscreen", True, 0),
                ("maximized", False, 1),
            ):
                case = f"{decoration}-{state}-{override}-{depth}"
                runtime = tmp / case
                runtime.mkdir(mode=0o700)
                config = '[compositor]\nxwayland = false\n[animations]\nenabled = false\n'
                config += f'[[window_rules]]\napp_id = "rediwm.zoom-fixture"\ndepth = {depth}\n'
                if override:
                    config += f'{state} = false\n'
                compositor, log = spawn_compositor(runtime, config_content=config,
                                                  env_extra={"XDG_CACHE_HOME": str(runtime / "cache")})
                client = None
                try:
                    with IPCClient(runtime) as ipc, (runtime / "client.log").open("w") as client_log:
                        ipc.wait_for("wallpaper_presented", timeout_ms=10000)
                        # A startup target is in layout coordinates; placement
                        # must also account for the camera's world offset.
                        ipc.action("set_camera", {"x": 200, "y": 100})
                        env = dict(os.environ, XDG_RUNTIME_DIR=str(runtime),
                                   WAYLAND_DISPLAY=wayland_display_name(runtime),
                                   REDIWM_TEST_DECORATION=decoration,
                                   REDIWM_TEST_INITIAL_STATE=state)
                        client = subprocess.Popen([str(tmp / "client")], env=env,
                                                  stdout=client_log, stderr=client_log)
                        win = wait_for(lambda: next(iter(ipc.get_windows()), None), "window did not map")
                        wid = win["id"]
                        output = ipc.get_outputs()[0]
                        taskbar = next(p for p in ipc.list_panels()["panels"] if p["name"] == "taskbar")
                        expected_state = "floating" if override else state

                        def correct_frame():
                            debug = ipc.get_window_debug(wid)
                            if debug["maximized"] != (expected_state == "maximized"):
                                return False
                            if debug["fullscreen"] != (expected_state == "fullscreen"):
                                return False
                            if expected_state == "floating":
                                return debug["client_box"]["width"] == 400 and debug["client_box"]["height"] == 260
                            box = debug["chrome_box"]
                            camera = ipc.get_state()["camera"]
                            zoom = debug["zoom_percent"] / 100
                            height = output["logical_height"]
                            if expected_state == "maximized":
                                height -= taskbar["box"]["height"]
                            return (
                                (box["x"], box["y"]) == (camera["x"], camera["y"])
                                and abs(box["width"] * zoom - output["logical_width"]) <= 1
                                and abs(box["height"] * zoom - height) <= 1
                            )

                        wait_for(correct_frame, lambda: f"{case}: startup state/geometry mismatch: {ipc.get_window_debug(wid)}", timeout=3)
                        if expected_state != "floating":
                            ipc.action("restore_window", {"id": wid})

                            def restored():
                                debug = ipc.get_window_debug(wid)
                                return (not debug["maximized"] and not debug["fullscreen"]
                                        and debug["client_box"]["width"] == 640
                                        and debug["client_box"]["height"] == 480)

                            wait_for(restored, f"{case}: restore did not return to floating geometry")
                        print(f"PASS: {case}", flush=True)
                except Exception:
                    print((runtime / "compositor.log").read_text(errors="replace")[-4000:])
                    raise
                finally:
                    if client is not None:
                        stop_process(client)
                    stop_process(compositor)
                    log.close()


if __name__ == "__main__":
    run()

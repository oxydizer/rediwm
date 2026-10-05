#!/usr/bin/env python3
"""Untrusted X11 size hints cannot overflow the compositor's geometry math."""
import os
from pathlib import Path
import subprocess
import tempfile

from ipc_client import IPCClient, spawn_compositor, stop_process
from xwayland import build_client, wait_for


def run():
    with tempfile.TemporaryDirectory(prefix="rediwm-xwayland-hardening-") as directory:
        tmp = Path(directory)
        build_client(tmp)
        compositor, log = spawn_compositor(
            tmp, config_content="[compositor]\nxwayland = true\nxwayland_scale = 1\n",
            renderer=os.environ.get("REDIWM_TEST_RENDERER", "pixman"),
            env_extra={"DBUS_SESSION_BUS_ADDRESS": "", "DISPLAY": "",
                       "XAUTHORITY": "", "XDG_CACHE_HOME": str(tmp / "cache")})
        client = None
        try:
            with IPCClient(tmp) as ipc, (tmp / "client.log").open("w") as client_log:
                display = ipc.get_runtime()["xwayland_display"]
                assert display
                env = dict(os.environ, DISPLAY=display, XDG_RUNTIME_DIR=str(tmp))
                env.pop("WAYLAND_DISPLAY", None)
                env.pop("XAUTHORITY", None)
                client = subprocess.Popen(
                    [str(tmp / "x11-client")], env=env, stdin=subprocess.PIPE,
                    stdout=client_log, stderr=client_log, text=True)

                def window():
                    assert compositor.poll() is None, "compositor exited"
                    assert client.poll() is None, (tmp / "client.log").read_text()
                    return next((w for w in ipc.get_windows()
                                 if w.get("backend") == "xwayland"), None)

                first = wait_for(window, "X11 window did not map")
                maximum = 2**31 - 1
                cases = [
                    # A perfectly valid 1:1 ratio with unreduced large terms.
                    ((maximum, maximum, maximum, maximum), (420, 310), (310, 310)),
                    # Exercise the minimum-ratio branch as well.
                    ((maximum, maximum, maximum, maximum), (320, 440), (320, 320)),
                    ((maximum, 1, maximum, 1), (430, 330), (1, 1)),
                    ((1, maximum, 1, maximum), (440, 340), (1, 340)),
                    # Invalid terms are ignored, then normal hints still work.
                    ((1, 0, 1, 0), (450, 350), (450, 350)),
                    ((-1, 1, -1, 1), (460, 360), (460, 360)),
                    ((4, 3, 4, 3), (480, 400), (480, 360)),
                ]
                for ratio, requested, expected in cases:
                    client.stdin.write("aspect " + " ".join(map(str, ratio)) + "\n")
                    client.stdin.write(f"resize {requested[0]} {requested[1]}\n")
                    client.stdin.flush()

                    def resized():
                        current = window()
                        if current:
                            box = ipc.get_window_debug(current["id"])["client_box"]
                            if (box["width"], box["height"]) == expected:
                                return current
                        return None

                    current = wait_for(resized, f"aspect {ratio} did not produce {expected}")
                    assert current["id"] == first["id"]

                # The same application remains usable after all bad hints.
                client.stdin.write("title Recovered X11 window\n")
                client.stdin.flush()
                wait_for(lambda: window()["title"] == "Recovered X11 window",
                         "X11 client stopped responding")
                print("PASS: extreme/invalid X11 aspect hints and subsequent updates stay connected")
        except Exception:
            print((tmp / "compositor.log").read_text(errors="replace")[-6000:])
            if (tmp / "client.log").exists():
                print((tmp / "client.log").read_text(errors="replace"))
            raise
        finally:
            for process in (client, compositor):
                if process is not None:
                    stop_process(process)
            log.close()


if __name__ == "__main__":
    run()

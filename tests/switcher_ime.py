#!/usr/bin/env python3
"""Alt+Tab dismissal while an input method owns the keyboard grab.

An input method (fcitx5) mirrors the modifier state the compositor forwards to
its keyboard grab onto its own virtual keyboard. While the switcher is open the
compositor used to stop forwarding to the grab, so the method never learned the
trigger was released, its virtual keyboard stayed stuck with Alt held, and the
switcher counted that echo as a held trigger: it was never dismissed. The
switcher must end on the physical release, and the grab must keep receiving
modifier updates and the release of keys it was sent.
"""
import os
import subprocess
import tempfile
import time
from pathlib import Path

from PIL import Image

from desktop_zoom import wait_for
from ipc_client import IPCClient, spawn_compositor, stop_process
from input_protocols import compile_client

RED = lambda c: c[0] > 220 and 15 < c[1] < 65 and 35 < c[2] < 95  # noqa: E731


def red_pixels(path):
    with Image.open(path) as shot:
        image = shot.convert("RGB")
    return sum(1 for y in range(image.height) for x in range(image.width) if RED(image.getpixel((x, y))))


def run(scale, style):
    with tempfile.TemporaryDirectory(prefix="rediwm-switcher-ime-") as directory:
        tmp = Path(directory)
        compile_client(tmp)
        wallpaper = tmp / "wallpaper.png"
        Image.new("RGB", (32, 32), (20, 24, 30)).save(wallpaper)
        config = f'[compositor]\nwallpaper = "{wallpaper}"\nswitcher_style = "{style}"\n[keybinds]\n"alt+tab" = "focus_next"\n'
        proc, log = spawn_compositor(tmp, scale=scale, config_content=config)
        processes = []
        logs = []
        try:
            with IPCClient(tmp) as ipc:
                ipc.wait_for("wallpaper_presented", timeout_ms=10000)
                display = next(p.name for p in tmp.glob("wayland-*") if not p.name.endswith(".lock"))
                env = dict(os.environ, XDG_RUNTIME_DIR=str(tmp), WAYLAND_DISPLAY=display)
                env.pop("WAYLAND_DEBUG", None)

                def spawn(name, mode):
                    path = tmp / f"{name}.log"
                    out = path.open("w")
                    logs.append(out)
                    peer = subprocess.Popen([str(tmp / "protocol-client"), mode], env=env,
                                            stdin=subprocess.PIPE, stdout=out, stderr=subprocess.STDOUT, text=True)
                    processes.append(peer)
                    wait_for(lambda: "ready\n" in path.read_text() or peer.poll() is not None,
                             f"{name} did not start: {path.read_text(errors='replace')[-1500:]}")
                    return peer, path

                def send(peer, path, command):
                    before = path.read_text().count(f"ack {command}\n")
                    peer.stdin.write(command + "\n")
                    peer.stdin.flush()
                    wait_for(lambda: path.read_text().count(f"ack {command}\n") > before or peer.poll() is not None,
                             f"no ack for {command}: {path.read_text(errors='replace')[-1500:]}")

                app_a, log_a = spawn("app-a", "org.test.a")
                app_b, log_b = spawn("app-b", "org.test.b")
                wait_for(lambda: len(ipc.get_windows()) == 2, "windows did not map")
                ids = {w["app_id"]: w["id"] for w in ipc.get_windows()}

                # Focus a text field first, then connect the input method: it
                # activates on the focused input, grabs the keyboard and mirrors
                # the state it receives through its own virtual keyboard.
                ipc.action("focus_window", {"id": ids["org.test.a"]})
                ime, log_ime = spawn("ime", "ime")
                send(ime, log_ime, "method")
                wait_for(lambda: "activate" in log_ime.read_text(), "IME did not activate")
                wait_for(lambda: "text-enter" in log_a.read_text(), "text input did not enter")
                send(ime, log_ime, "grab")
                wait_for(lambda: "grab-keymap" in log_ime.read_text(), "IME did not grab the keyboard")
                send(ime, log_ime, "forward")

                # Known MRU order: B previous, A current, so Tab selects B.
                for app in ("org.test.a", "org.test.b", "org.test.a"):
                    ipc.action("focus_window", {"id": ids[app]})
                time.sleep(0.15)

                def capture(name):
                    path = tmp / f"{name}-{style}-{scale}.png"
                    ipc.screenshot(path=str(path))
                    wait_for(path.exists, "capture")
                    return red_pixels(path)

                ipc.key(56, True)  # Alt press; the grab receives it (and mirrors it)
                wait_for(lambda: "grab-key 56 1" in log_ime.read_text(), "IME never saw the Alt press")
                ipc.key_down_up(15)  # Tab selects the previous window
                time.sleep(0.2)
                assert capture("open") > 200, "switcher did not open"
                ipc.key(56, False)  # Alt release must dismiss it
                wait_for(lambda: (ipc.get_focused_window() or {}).get("app_id") == "org.test.b",
                         "switcher did not accept on the Alt release")

                def closed_pixels():
                    path = tmp / f"closed-{style}-{scale}.png"
                    path.unlink(missing_ok=True)
                    ipc.screenshot(path=str(path))
                    wait_for(path.exists, "capture")
                    return red_pixels(path)

                # Circular plays a short close animation; the linear style
                # cancels synchronously. Either way the switcher must be gone.
                wait_for(lambda: closed_pixels() == 0, "switcher stayed on screen after the Alt release")
                # The grab owns the press, so it must also see the release and
                # the modifier reset; otherwise the method (and its virtual
                # keyboard) keeps Alt held and the compositor's own gestures do.
                wait_for(lambda: "grab-key 56 0" in log_ime.read_text(), "release did not reach the IME grab")
                wait_for(lambda: not ipc.get_input_state()["modifiers"]["alt"], "stuck Alt modifier after dismiss")
                assert ipc.get_focused_window()["app_id"] == "org.test.b"
                print(f"PASS switcher ime dismiss style={style} scale={scale}")
        except BaseException:
            print((tmp / "compositor.log").read_text(errors="replace")[-6000:])
            raise
        finally:
            for peer in processes:
                stop_process(peer)
            for out in logs:
                out.close()
            stop_process(proc)
            log.close()


if __name__ == "__main__":
    for style in ("linear", "circular"):
        run(os.environ.get("REDIWM_TEST_SCALE", "1"), style)

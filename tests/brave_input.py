#!/usr/bin/env python3
"""Native Wayland Brave input smoke test, with an isolated profile and desktop.

Run after zig build. Requires Brave; set REDIWM_TEST_BRAVE to its executable.
The default pixman run disables browser GPU rendering. Set
REDIWM_TEST_RENDERER=gles2 to test GPU rendering on an accessible render node.
Only local test pages are opened. No host input or browser profile is used.
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

from xwayland import ipc_connect, request, start_compositor, wait_for, wayland_display_name


def run():
    browser = os.environ.get("REDIWM_TEST_BRAVE") or shutil.which("brave")
    if not browser:
        raise SystemExit("Brave not found; set REDIWM_TEST_BRAVE to its executable")
    renderer = os.environ.get("REDIWM_TEST_RENDERER", "pixman")
    with tempfile.TemporaryDirectory(prefix="rediwm-brave-input-") as directory:
        tmp = Path(directory)
        # Report DOM changes through the ordinary window title: no devtools
        # injection that could bypass the keyboard/clipboard/pointer paths.
        for name in ("first", "second"):
            (tmp / f"{name}.html").write_text(
                f"<title>probe:{name}</title>"
                '<textarea style="width:80%;height:260px" '
                'oninput="document.title=\'text:\'+this.value">clipboard-probe</textarea>'
                '<div style="height:4000px;background:linear-gradient(red,blue)">scroll</div>'
                '<script>onscroll=()=>document.title="scroll:"+Math.round(scrollY)</script>'
            )
        compositor, compositor_log = start_compositor(
            tmp, "[compositor]\nxwayland = false\n[input]\ninvert_scroll = false\n",
            env_overrides={"WLR_RENDERER": renderer},
        )
        client = None
        sock = reader = None
        try:
            sock, reader = ipc_connect(tmp)

            def req(value):
                return request(sock, reader, value)

            def action(name, params):
                return req({"version": 1, "command": name, "params": params})

            def window():
                return next((w for w in req({'version': 1, 'command': 'windows'})["Windows"]
                             if w["app_id"] and "brave" in w["app_id"].lower()), None)

            def title_is(expected):
                wait_for(lambda: window() and window()["title"] == expected + " - Brave",
                         lambda: f"expected title {expected!r}, got {window()}")

            def key(name, ctrl=False):
                if ctrl:
                    action('key', {"keycode": 29, "pressed": True})
                action('key_press', {"key": name})
                if ctrl:
                    action('key', {"keycode": 29, "pressed": False})
                # IPC completion means events were sent, not that the browser
                # has processed them. Allow clipboard ownership to settle.
                time.sleep(.15)

            def click(x, y):
                action('move_cursor', {"x": x, "y": y})
                action('pointer_button', {"button": 272, "pressed": True})
                action('pointer_button', {"button": 272, "pressed": False})
                time.sleep(.15)

            env = dict(os.environ, XDG_RUNTIME_DIR=str(tmp),
                       WAYLAND_DISPLAY=wayland_display_name(tmp),
                       XDG_CONFIG_HOME=str(tmp / "config"))
            for name in ("DISPLAY", "XAUTHORITY", "REDIWM_SOCKET", "WAYLAND_DEBUG"):
                env.pop(name, None)
            argv = [browser, "--ozone-platform=wayland", f"--user-data-dir={tmp / 'profile'}",
                    "--no-first-run", "--no-default-browser-check", "--disable-background-networking"]
            if renderer == "pixman":
                argv.append("--disable-gpu")
            with (tmp / "brave.log").open("w") as browser_log:
                client = subprocess.Popen(argv + [(tmp / "first.html").as_uri()],
                                          env=env, stdout=browser_log, stderr=browser_log,
                                          start_new_session=True)
                wait_for(window, "Brave did not map", timeout=30)
                title_is("probe:first")
                w = window()
                assert w["backend"] == "xdg", w
                # Within the large textarea, below browser UI and any banner.
                click(w["x"] + 100, w["y"] + 240)
                key("a", ctrl=True)
                key("c", ctrl=True)
                key("BackSpace")
                title_is("text:")
                key("v", ctrl=True)
                title_is("text:clipboard-probe")
                print("PASS: mouse-focused Brave textarea copy/delete/paste")

                # Open the address overlay, then click into it before editing.
                key("l", ctrl=True)
                click(w["x"] + 310, w["y"] + 59)
                key("a", ctrl=True)
                action('type_text', {"text": (tmp / "second.html").as_uri()})
                key("a", ctrl=True)
                key("c", ctrl=True)
                key("BackSpace")
                key("v", ctrl=True)
                key("Return")
                title_is("probe:second")
                print("PASS: mouse-focused address-bar copy/paste and Enter navigation")

                action('move_cursor', {"x": w["x"] + 400, "y": w["y"] + 550})
                action('scroll', {"dx": 0, "dy": 120})
                wait_for(lambda: window()["title"].startswith("scroll:") and
                         int(window()["title"].split(":")[1].split()[0]) > 0,
                         "Brave page did not scroll")
                action('scroll', {"dx": 0, "dy": -1200})
                title_is("scroll:0")
                print(f"PASS: Brave page scrolls down and back to top ({renderer})")
        except BaseException:
            for name in ("compositor.log", "brave.log"):
                path = tmp / name
                if path.exists():
                    print(f"{name}:\n{path.read_text(errors='replace')[-5000:]}")
            raise
        finally:
            if client is not None:
                client.terminate()
                try:
                    client.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    client.kill()
                    client.wait(timeout=5)
            if reader is not None:
                reader.close()
            if sock is not None:
                sock.close()
            compositor.terminate()
            compositor.wait(timeout=5)
            compositor_log.close()


if __name__ == "__main__":
    run()

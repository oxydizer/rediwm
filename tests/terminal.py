#!/usr/bin/env python3
"""RediTerm in a private compositor: shell I/O, title, clipboard and color.

Commands and the PTY probe write files. Color swatches are checked by pixel
value, so no OCR or font-specific goldens are needed.
"""
import os
import shutil
from pathlib import Path
import subprocess
import sys
import tempfile
import time

from PIL import Image

from ipc_client import IPCClient, ROOT, spawn_compositor, stop_process
from xwayland_support import wait_for

CTRL, SHIFT, ENTER, KEY_C, KEY_V, SPACE = 29, 42, 28, 46, 47, 57
CURSOR_RGB = (252, 203, 150)

COLOR_PROBE = r"""
import os
from pathlib import Path
import select
import tty

tty.setraw(0)
os.write(1, b"\x1b]10;?\x07\x1b]11;?\x1b\\\x1b]12;?\x07\x1b]4;1;?;17;?\x07")
reply = b""
while reply.count(b"\x1b\\") < 5:
    if not select.select([0], [], [], 2)[0]:
        raise SystemExit(f"Incomplete color reply: {reply!r}")
    reply += os.read(0, 4096)
Path("colors.txt").write_bytes(reply)
os.write(1, b"\x1b[?1049h\x1b[?25l\x1b[H"
            b"\x1b[41m            \x1b[48;5;17m            "
            b"\x1b[48;2;42;124;176m            \x1b[0m"
            b"\x1b]2;color swatches\x07")
for title, sequence in (
    (b"caret right", b"\x1b[3;8H\x1b[2 q\x1b[?25h"),
    (b"caret left", b"\x1b[3;2H"),
    (b"caret next row", b"\x1b[4;8H"),
    (b"caret hidden", b"\x1b[?25l"),
    (b"before newline", b"\x1b[?1049l\x1b[2J\x1b[3;12H\x1b[2 q\x1b[?25h"),
    (b"after newline", b"\r\n"),
):
    key = os.read(0, 1)
    if title == b"after newline":
        assert key == b"\r", key
    os.write(1, sequence + b"\x1b]2;" + title + b"\x07")
os.read(0, 1)
"""


def caret_bounds(ipc, window_id, path):
    path.unlink(missing_ok=True)
    ipc.screenshot(path=str(path), window_id=window_id)
    with Image.open(path) as image:
        # The probe uses only the first few rows and columns.
        strip = image.convert("RGB").crop((0, 0, 200, 240))
        pixels = strip.load()
        points = [(x, y) for y in range(strip.height) for x in range(strip.width) if pixels[x, y] == CURSOR_RGB]
    if not points:
        return None
    x, y = zip(*points)
    return min(x), min(y), max(x) + 1, max(y) + 1


def check_caret(ipc, window_id, caret_shot, windows):
    def step(title, key=SPACE):
        ipc.key_down_up(key)
        wait_for(lambda: windows()[0]["title"] == title, f"cursor probe did not reach {title}")

    def capture():
        return caret_bounds(ipc, window_id, caret_shot)

    ipc.focus_window(window_id)
    step("caret right")
    ipc.wait_for_frame()
    right = capture()
    step("caret left")
    time.sleep(0.07)
    middle = capture()
    time.sleep(0.5)
    left = capture()
    assert right and middle and left, (right, middle, left)
    assert left[0] < middle[0] < right[0] and right[1] == middle[1] == left[1], (right, middle, left)
    assert abs((middle[2] - middle[0]) - (right[2] - right[0])) <= 1, (right, middle)
    step("caret next row")
    ipc.wait_for_frame()
    next_row = capture()
    assert next_row and next_row[0] == right[0] and next_row[1] > right[1], (right, next_row)
    step("caret hidden")
    ipc.wait_for_frame()
    assert capture() is None

    step("before newline")
    ipc.wait_for_frame()
    start = capture()
    step("after newline", ENTER)
    time.sleep(0.1)
    middle = capture()
    time.sleep(0.75)
    end = capture()
    assert start and middle and end, (start, middle, end)
    assert end[0] < middle[0] < start[0] and start[1] < middle[1] < end[1], (start, middle, end)


def main():
    with tempfile.TemporaryDirectory(prefix="rediwm-terminal-") as directory:
        tmp = Path(directory)
        work = tmp / "work"
        work.mkdir()
        env = dict(HOME=directory, XDG_CONFIG_HOME=str(tmp / "config"),
                   XDG_DATA_HOME=str(tmp / "data"), XDG_CACHE_HOME=str(tmp / "cache"),
                   XDG_STATE_HOME=str(tmp / "state"), DBUS_SESSION_BUS_ADDRESS="",
                   DBUS_SYSTEM_BUS_ADDRESS="unix:path=/nonexistent-rediwm-test-system-bus",
                   WLR_RENDERER_ALLOW_SOFTWARE="1", LANG="C", LC_ALL="C")
        compositor, log = spawn_compositor(
            tmp, scale=os.environ.get("REDIWM_TEST_SCALE", "1"), env_extra=env,
            config_content='[compositor]\nxwayland = false\nfocus_zoom = "keep"\n[animations]\nenabled = false\n'
                           '[theme]\nterminal_fg = "#eeddbc"\nterminal_bg = "#28192a"\n'
                           'terminal_cursor = "#fccb96"\nterminal_red = "#d57d6f"\n',
            binary=os.environ.get("REDIWM_TEST_BINARY"))
        app_config = tmp / "terminal.toml"
        # Grow the client glide so a screenshot can sample it while the compositor stays at rest.
        app_config.write_text((tmp / "rediwm-config.toml").read_text().replace("enabled = false", "enabled = true") +
                              '[input]\ncaret_motion_ms = 500\n')
        apps = []
        try:
            with IPCClient(tmp, timeout=20) as ipc:
                display = next(p.name for p in tmp.glob("wayland-*") if not p.name.endswith(".lock"))
                app_env = dict(os.environ, **env, XDG_RUNTIME_DIR=directory, WAYLAND_DISPLAY=display,
                               REDIWM_CONFIG=str(app_config), SHELL="/bin/sh",
                               PS1="$ ", ENV="")
                app_env.pop("REDIWM_THEME", None)
                binary = os.environ.get("REDIWM_TEST_TERMINAL", str(ROOT / "zig-out/bin/rediwm-terminal"))

                def launch(*args):
                    app_log = (tmp / f"terminal-{len(apps)}.log").open("w")
                    app = subprocess.Popen([binary, *args], env=app_env, cwd=work,
                                           stdout=app_log, stderr=app_log)
                    apps.append(app)
                    return app

                def windows():
                    return [w for w in ipc.get_windows() if w["app_id"] == "rediwm-terminal"]

                def run(command):
                    ipc.type_text(command)
                    ipc.key_down_up(ENTER)

                def chord(*keys):
                    for key in keys:
                        ipc.key(key, True)
                    for key in reversed(keys):
                        ipc.key(key, False)

                def read(name):
                    path = work / name
                    return path.read_text() if path.exists() else None

                app = launch()
                ipc.wait_for("window_mapped", app_id="rediwm-terminal")
                win = windows()[0]
                assert win["title"] == "RediTerm", win
                ipc.focus_window(win["id"])
                ipc.wait_for("window_geometry_settled", window_id=win["id"])

                # The shell starts in the launch directory and reaches the PTY.
                run("pwd > cwd.txt; printf '%s %s\\n' \"$TERM\" \"$COLORTERM\" > term.txt")
                wait_for(lambda: read("term.txt") == "xterm-256color truecolor\n", "the shell did not run a command")
                assert read("cwd.txt") == f"{work}\n", read("cwd.txt")

                # OSC 2 becomes the window title.
                run("printf '\\033]2;build: done\\007'")
                wait_for(lambda: windows()[0]["title"] == "build: done", "the title was not applied")

                # Select a whole row of output, copy it, paste it into a command.
                run("clear; for i in 1 2 3 4 5 6 7 8 9 10 11 12; do echo COPYME; done")
                ipc.wait_for_frame()
                box = ipc.get_window_debug(win["id"])["client_box"]
                y = box["y"] + 90  # A row of output at any plausible cell height.
                ipc.drag(box["x"] + 2, y, box["x"] + box["width"] - 4, y)
                chord(CTRL, SHIFT, KEY_C)
                ipc.type_text("printf %s \"")
                chord(CTRL, SHIFT, KEY_V)
                run("\" > pasted.txt")
                wait_for(lambda: read("pasted.txt") == "COPYME", f"paste wrote {read('pasted.txt')!r}")
                if shutil.which("wl-copy") and shutil.which("wl-paste"):
                    # Other clients read the selection and paste into the shell.
                    copied = subprocess.run(["wl-paste", "--no-newline"], env=app_env, stdout=subprocess.PIPE,
                                            timeout=5, check=True).stdout
                    assert copied == b"COPYME", copied
                    source = subprocess.Popen(["wl-copy", "--foreground", "--paste-once"],
                                              stdin=subprocess.PIPE, env=app_env)
                    apps.append(source)
                    source.stdin.write(b"printf external > external.txt")
                    source.stdin.close()
                    # RediTerm offers only text/plain types; wl-copy adds X11 names.
                    wait_for(lambda: b"STRING" in subprocess.run(["wl-paste", "--list-types"], env=app_env,
                                                                 capture_output=True, timeout=3).stdout,
                             "wl-copy did not take the selection")
                    chord(CTRL, SHIFT, KEY_V)
                    source.wait(timeout=5)  # Served; RediTerm reads it on its next wakeup.
                    time.sleep(0.2)
                    ipc.key_down_up(ENTER)
                    wait_for(lambda: read("external.txt") == "external", "an external paste did not arrive")

                # The shell's exit closes the window.
                run("exit")
                ipc.wait_for("window_closed", window_id=win["id"])
                assert app.wait(timeout=5) == 0

                # -e runs a command on the PTY instead of the shell.
                app = launch("-e", "sh", "-c", "tty > tty.txt; printf ok > e.txt")
                wait_for(lambda: read("e.txt") == "ok", "-e did not run the command")
                assert read("tty.txt").startswith("/dev/pts/"), read("tty.txt")
                assert app.wait(timeout=5) == 0

                # Full-screen programs probe the theme and paint with both indexed and RGB colors.
                app = launch("-e", sys.executable, "-c", COLOR_PROBE)
                ipc.wait_for("window_mapped", app_id="rediwm-terminal")
                win = windows()[0]
                wait_for(lambda: read("colors.txt"), "no color replies came back through the PTY")
                assert (work / "colors.txt").read_bytes() == (
                    b"\x1b]10;rgb:eeee/dddd/bcbc\x1b\\\x1b]11;rgb:2828/1919/2a2a\x1b\\"
                    b"\x1b]12;rgb:fcfc/cbcb/9696\x1b\\\x1b]4;1;rgb:d5d5/7d7d/6f6f\x1b\\"
                    b"\x1b]4;17;rgb:0000/0000/5f5f\x1b\\"
                )
                wait_for(lambda: windows()[0]["title"] == "color swatches", "swatches were not drawn")
                ipc.wait_for_frame()
                shot = tmp / "colors.png"
                ipc.screenshot(path=str(shot), window_id=win["id"])
                with Image.open(shot) as image:
                    colors = {rgb: count for count, rgb in image.convert("RGB").getcolors(image.width * image.height)}
                for rgb in [(213, 125, 111), (0, 0, 95), (42, 124, 176), (40, 25, 42)]:
                    assert colors.get(rgb, 0) > 100, (rgb, colors.get(rgb, 0))

                check_caret(ipc, win["id"], tmp / "caret.png", windows)
                ipc.close_window(win["id"])
                ipc.wait_for("window_closed", window_id=win["id"])
                assert app.wait(timeout=5) == 0

                # Closing the window hangs up a running shell.
                app = launch()
                ipc.wait_for("window_mapped", app_id="rediwm-terminal")
                win = windows()[0]
                ipc.focus_window(win["id"])
                # An interactive shell at its prompt exits on SIGHUP without
                # running a HUP trap, so the trapping script takes its place.
                run("exec sh -c 'trap \"echo hup > hup.txt; exit 0\" HUP; echo ready > ready.txt; "
                    "while :; do sleep 1; done'")
                wait_for(lambda: read("ready.txt") == "ready\n", "the shell did not start")
                ipc.close_window(win["id"])
                ipc.wait_for("window_closed", window_id=win["id"])
                assert app.wait(timeout=5) == 0
                assert read("hup.txt") == "hup\n", "the shell was not hung up"
                print("RediTerm: shell, title, clipboard, -e, colors, caret glide and close passed")
        finally:
            for app in apps:
                if app.poll() is None:
                    stop_process(app)
            stop_process(compositor)
            log.close()
            for path in [tmp / "compositor.log", *tmp.glob("terminal-*.log")]:
                if path.exists():
                    errors = path.read_text()
                    assert "panic" not in errors and "error(gpa)" not in errors, errors[-6000:]


if __name__ == "__main__":
    os.umask(0o077)
    main()

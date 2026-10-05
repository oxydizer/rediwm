#!/usr/bin/env python3
"""Real Files peers: text editing, external clipboard, partial moves and retained buffers."""
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import time
from urllib.parse import unquote, urlparse

from files_browser import wait_for
from ipc_client import IPCClient, ROOT, spawn_compositor, stop_process


def run(scale="1"):
    with tempfile.TemporaryDirectory(prefix="rediwm-files-fixes-") as directory:
        tmp = Path(directory)
        home = tmp / "Home"
        source, dest = home / "source", home / "destination"
        source.mkdir(parents=True)
        dest.mkdir()
        for name, size in (("a.txt", 1), ("b.log", 99), ("c.txt", 10)):
            (source / name).write_text("x" * size)
            os.utime(source / name, (size, size))
        long_name = "A long filename " + "readable " * 15 + ".txt"
        (home / long_name).write_text("long")
        for name in ("Desktop", "Documents", "Downloads", "Pictures", "Music", "Videos", "Projects"):
            (home / name).mkdir()
        env_extra = {"HOME": str(home), "XDG_STATE_HOME": str(tmp / "state"),
                     "XDG_CACHE_HOME": str(tmp / "cache"), "REDIWM_FILES_DEVICES": "0"}
        comp, log = spawn_compositor(tmp, scale=scale, config_content="[compositor]\nxwayland = false\n[input]\ninvert_scroll = false\n", env_extra=env_extra)
        processes = []
        logs = []
        try:
            sock = wait_for(lambda: next(tmp.glob("rediwm-*.sock"), None), "IPC unavailable")
            display = next(p.name for p in tmp.glob("wayland-*") if not p.name.endswith(".lock"))
            env = dict(os.environ, **env_extra, XDG_RUNTIME_DIR=directory, WAYLAND_DISPLAY=display)
            with IPCClient(sock) as ipc:
                def key(code, ctrl=False, shift=False, alt=False):
                    mods = ([29] if ctrl else []) + ([42] if shift else []) + ([56] if alt else [])
                    for mod in mods:
                        ipc.action('key', {"keycode": mod, "pressed": True})
                    for pressed in (True, False):
                        ipc.action('key', {"keycode": code, "pressed": pressed})
                    for mod in reversed(mods):
                        ipc.action('key', {"keycode": mod, "pressed": False})
                    time.sleep(.08)

                def start(path, csd=False):
                    before = {w["id"] for w in ipc.get_windows()}
                    logpath = tmp / f"files-{len(logs)}.log"
                    logs.append(logpath)
                    with logpath.open("w") as out:
                        proc = subprocess.Popen([str(ROOT / "zig-out/bin/rediwm-files"), str(path)],
                                                env=dict(env, WAYLAND_DEBUG="client", **({"REDIWM_FILES_FORCE_CSD": "1"} if csd else {})),
                                                stdout=out, stderr=out)
                    processes.append(proc)
                    win = wait_for(lambda: next((w for w in ipc.get_windows() if w["id"] not in before), None), "Files did not map")
                    ipc.focus_window(win["id"])
                    time.sleep(.3)
                    return win, proc, logpath

                def box(win):
                    return ipc.get_window_debug(win["id"])["client_box"]

                def move(win, x, y):
                    b = box(win)
                    ipc.move_cursor(b["x"] + x, b["y"] + y)
                    time.sleep(.06)

                def click(win, x, y):
                    move(win, x, y)
                    for pressed in (True, False):
                        ipc.action('pointer_button', {"button": 272, "pressed": pressed})
                    time.sleep(.12)

                def clipboard():
                    return subprocess.check_output(["wl-paste", "--no-newline"], env=env, timeout=5).decode()

                def offer(data, mime="text/plain;charset=utf-8"):
                    proc = subprocess.Popen(["wl-copy", "--foreground", "--type", mime], env=env, stdin=subprocess.PIPE)
                    proc.stdin.write(data.encode())
                    proc.stdin.close()
                    processes.append(proc)
                    time.sleep(.15)
                    return proc

                def paths():
                    return [Path(unquote(urlparse(line).path)) for line in clipboard().splitlines() if line.startswith("file:")]

                def navigate(path):
                    key(38, ctrl=True)
                    ipc.action('type_text', {"text": str(path)})
                    key(28)
                    time.sleep(.25)

                first, proc, first_log = start(source)
                key(38, ctrl=True)  # Ctrl+L, Ctrl+A must stay in the path field.
                key(30, ctrl=True)
                key(46, ctrl=True)
                assert clipboard() == str(source)
                key(45, ctrl=True)
                offer(str(dest))
                key(47, ctrl=True)
                key(30, ctrl=True)
                key(46, ctrl=True)
                assert clipboard() == str(dest), "external text paste failed"
                key(1)  # Escape restores source, without navigating.
                key(38, ctrl=True)
                key(46, ctrl=True)
                assert clipboard() == str(source)
                key(1)

                # UTF-8 rename editing and Shift selection use the same editor.
                key(102)
                key(60)
                offer("é雪.txt")
                key(47, ctrl=True)
                key(102)
                key(106, shift=True)
                key(46, ctrl=True)
                assert clipboard() == "é"
                key(1)

                # Click places the caret; dragging selects part of the path.
                key(38, ctrl=True)
                click(first, 166, 27)
                key(102)
                ipc.action('type_text', {"text": "PREFIX"})
                key(30, ctrl=True)
                key(46, ctrl=True)
                assert clipboard().startswith("PREFIX"), "click editing failed"
                key(1)

                # Unfocused, the path bar is clickable folders; the empty space
                # after them edits the path like Ctrl+L.
                def title_is(value):
                    return any(w["id"] == first["id"] and w["title"] == value + " — Files" for w in ipc.get_windows())
                click(first, 144, 27)  # "Home" crumb
                wait_for(lambda: title_is("Home"), "path bar folder click did not navigate")
                navigate(source)
                wait_for(lambda: title_is("source"), "typed path did not navigate")
                click(first, box(first)["width"] - 120, 27)
                key(30, ctrl=True)
                key(46, ctrl=True)
                assert clipboard() == str(source), "empty path bar space did not start editing"
                key(1)

                # Keyboard multi-selection then copy from one real Files peer to another.
                key(102)
                key(106, shift=True)
                key(46, ctrl=True)
                assert paths() == [source / "a.txt", source / "b.log"]
                key(106, ctrl=True)
                key(46, ctrl=True)
                assert paths() == [source / "a.txt", source / "b.log"], "Ctrl+Right cleared selection"
                second, _, _ = start(dest)
                key(47, ctrl=True)
                wait_for(lambda: (dest / "a.txt").exists() and (dest / "b.log").exists(), "cross-window clipboard copy stalled")

                # Another application, both URI-list and GNOME cut formats.
                offer((source / "c.txt").as_uri() + "\r\n", "text/uri-list")
                key(47, ctrl=True)
                wait_for(lambda: (dest / "c.txt").exists(), "external URI copy stalled")
                (source / "move.txt").write_text("move")
                offer("cut\n" + (source / "move.txt").as_uri() + "\n", "x-special/gnome-copied-files")
                key(47, ctrl=True)
                wait_for(lambda: (dest / "move.txt").exists() and not (source / "move.txt").exists(), "external cut failed")

                # First item moves, second conflicts. Cancelling preserves the remainder.
                (source / "partial.txt").write_text("partial")
                offer("cut\n" + (source / "partial.txt").as_uri() + "\n" + (source / "a.txt").as_uri(), "x-special/gnome-copied-files")
                key(47, ctrl=True)
                wait_for(lambda: (dest / "partial.txt").exists(), "partial move did not start")
                time.sleep(.2)
                key(1)
                time.sleep(.2)
                assert paths() == [source / "a.txt"], "cancelled move lost cut remainder"
                assert (source / "a.txt").exists()
                key(47, ctrl=True)
                time.sleep(.2)
                key(31)  # Skip conflict; still keep source on clipboard.
                time.sleep(.2)
                assert paths() == [source / "a.txt"]

                # A stalled sender must not block keyboard delivery. Changing
                # the selection interrupts its receive without leaking the pipe.
                stalled = offer((source / "a.txt").as_uri(), "text/uri-list")
                stalled.send_signal(signal.SIGSTOP)
                key(47, ctrl=True)
                key(38, ctrl=True)
                key(46, ctrl=True)
                assert clipboard() == str(dest), "pending receive blocked the UI"
                stalled.send_signal(signal.SIGCONT)
                key(1)

                # Oversized data must not be parsed/truncated or hang subsequent input.
                offer("x" * (1024 * 1024 + 1), "text/uri-list")
                key(47, ctrl=True)
                time.sleep(.4)
                key(38, ctrl=True)
                key(46, ctrl=True)
                assert clipboard() == str(dest)
                key(1)

                ipc.action('close_window', {"id": second["id"]})
                ipc.focus_window(first["id"])
                time.sleep(.2)
                # Header sorting stays folders-first, preserves focus and is reversible.
                click(first, 727, 80)
                click(first, 640, 125)  # Size ascending
                key(102)
                key(46, ctrl=True)
                assert paths() == [source / "a.txt"]
                click(first, 640, 125)  # Size descending
                key(102)
                key(46, ctrl=True)
                assert paths() == [source / "b.log"]
                click(first, 750, 125)  # Type ascending
                key(102)
                key(46, ctrl=True)
                assert paths() == [source / "b.log"]
                click(first, 860, 125)  # Modified ascending
                key(102)
                key(46, ctrl=True)
                assert paths() == [source / "a.txt"]

                # History restores selection after leaving and returning.
                click(first, 640, 125)
                key(102)
                key(106, shift=True)
                key(46, ctrl=True)
                selected = paths()
                navigate(home)
                key(105, alt=True)
                time.sleep(.25)
                key(46, ctrl=True)
                assert paths() == selected, "Back lost selection"

                # Repeated motion within one item must not repaint or allocate buffers.
                move(first, 270, 175)
                time.sleep(.3)
                before = first_log.read_text()
                for x in (275, 280, 285, 290):
                    move(first, x, 178)
                time.sleep(.2)
                after = first_log.read_text()
                assert after.count(".attach(") == before.count(".attach("), "same-item motion repainted"
                creates = after.count(".create_buffer(")
                for x in (270, 940, 270, 940, 270):
                    move(first, x, 180)
                time.sleep(.2)
                after = first_log.read_text()
                assert after.count(".create_buffer(") <= creates + 1, "hover allocates fresh buffers"
                assert after.count(".set_buffer_scale(") <= 3, "unchanged scale repeatedly sent"
                # Any small hover damage must be narrower than the full client.
                damage = re.findall(r"\.damage_buffer\((\d+), (\d+), (\d+), (\d+)\)", after)
                assert any(int(w) < box(first)["width"] and int(h) < 100 for _, _, w, h in damage), "no partial damage observed"

                # Persist list mode/sort, then exercise short sidebar and minimum dialogs.
                ipc.action('close_window', {"id": first["id"]})
                proc.wait(timeout=5)
                first, proc, first_log = start(home)
                assert (tmp / "state/rediwm/files-view").read_bytes()[1] == 1
                layout_preview = Path(f"/tmp/rediwm-files-layout-{scale}.png")
                layout_preview.unlink(missing_ok=True)
                ipc.screenshot(path=str(layout_preview))
                ipc.action('set_window_size', {"id": first["id"], "width": 500, "height": 240})
                time.sleep(.4)
                move(first, 70, 190)
                # IPC Scroll supplies continuous pixels, not wheel detents.
                ipc.action('scroll', {"dx": 0, "dy": 800})
                time.sleep(.2)
                preview = Path(f"/tmp/rediwm-files-fixes-{scale}.png")
                preview.unlink(missing_ok=True)
                ipc.screenshot(path=str(preview))
                # The last destination is now visible and reachable in a short sidebar.
                click(first, 70, 190)
                wait_for(lambda: any(w["id"] == first["id"] and w["title"] == "Projects — Files" for w in ipc.get_windows()), "short sidebar could not reach Projects")
                navigate(home)
                ipc.action('set_window_size', {"id": first["id"], "width": 360, "height": 240})
                time.sleep(.4)
                key(49, ctrl=True)
                ipc.action('type_text', {"text": "small-window.txt"})
                key(28)
                wait_for(lambda: (home / "small-window.txt").exists(), "minimum dialog failed")
                # Large folder navigation and a >64 KiB outgoing file offer.
                large = home / "large-folder"
                large.mkdir()
                for i in range(2000):
                    (large / f"entry-{i:04d}.txt").touch()
                navigate(large)
                time.sleep(.3)
                key(30, ctrl=True)
                key(46, ctrl=True)
                assert len(paths()) == 2000, "large-folder selection/clipboard was incomplete"
                key(107)
                key(104)
                key(102)
                navigate(home)

                # CSD cursor serials and restoration, also after menu dismissal.
                ipc.action('close_window', {"id": first["id"]})
                proc.wait(timeout=5)
                first, proc, first_log = start(home, csd=True)
                from client_cursor import exercise_csd
                exercise_csd(ipc, first, first_log)
                key(139)  # Menu
                key(1)
                exercise_csd(ipc, first, first_log)
                print(f"Files fixes passed at {scale}x; preview: {preview}")
        except Exception:
            print((tmp / "compositor.log").read_text()[-2500:])
            for path in logs:
                print(path.name, path.read_text()[-3000:])
            raise
        finally:
            for process in reversed(processes):
                if process.poll() is None:
                    process.send_signal(signal.SIGCONT)
                    stop_process(process)
            stop_process(comp)
            log.close()


if __name__ == "__main__":
    run(sys.argv[1] if len(sys.argv) > 1 else "1")

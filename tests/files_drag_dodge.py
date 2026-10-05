#!/usr/bin/env python3
"""Files slides aside while a file is dragged out of it onto a window it covers,
and slides back when the drag is dropped or cancelled with Escape.

Scenarios (each gets its own compositor, since a second drag in one session is
unreliable):

  drop    slides aside, the drop still reaches the covered window, slides back
  escape  Escape cancels the drag: no drop, and the window slides back
  off     `dodge_file_drags = false` leaves the window where it is
  apart   nothing under Files, so there is nothing to uncover and it stays
  zoomed  the same as drop with the camera zoomed out to 70%
  browser drop onto the part of a real Brave upload page that Files covered
          (not run by default: needs Brave, or REDIWM_TEST_BRAVE=/path)
"""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

from files_browser import wait_for
from ipc_client import IPCClient, spawn_compositor, stop_process

ROOT = Path(__file__).resolve().parents[1]
ESC = 1


def run(scenario):
    with tempfile.TemporaryDirectory(prefix="rediwm-files-dodge-") as directory:
        tmp = Path(directory)
        home = tmp / "home"
        home.mkdir()
        for name in ("a space #.txt", "b-雪.txt"):
            (home / name).write_text("drag payload")
        config = "[compositor]\nxwayland = false\n"
        if scenario == "off":
            config += "dodge_file_drags = false\n"
        comp, log = spawn_compositor(tmp, config_content=config,
                                     renderer=os.environ.get("REDIWM_TEST_RENDERER", "pixman"),
                                     env_extra={"HOME": str(home)})
        peers = []
        try:
            with IPCClient(tmp).connect() as ipc:
                display = next(p.name for p in tmp.glob("wayland-*") if not p.name.endswith(".lock"))
                env = dict(os.environ, HOME=str(home), XDG_RUNTIME_DIR=str(tmp),
                           XDG_STATE_HOME=str(tmp / "state"), XDG_CONFIG_HOME=str(tmp / "config"),
                           REDIWM_CONFIG=str(tmp / "rediwm-config.toml"), WAYLAND_DISPLAY=display,
                           GDK_BACKEND="wayland", DBUS_SESSION_BUS_ADDRESS="unix:path=/nonexistent",
                           REDIWM_FILES_DEVICES="0")
                for key in ("DISPLAY", "REDIWM_SOCKET", "WAYLAND_DEBUG"):
                    env.pop(key, None)

                def launch(argv, name):
                    with (tmp / name).open("w") as out:
                        peer = subprocess.Popen(argv, env=env, stdin=subprocess.PIPE, stdout=out, stderr=out)
                    peers.append(peer)
                    return peer

                launch([str(ROOT / "zig-out/bin/rediwm-files"), str(home)], "files.log")
                src = wait_for(lambda: next((w for w in ipc.get_windows() if w["app_id"] == "rediwm-files"), None), "Files did not map")
                if scenario == "browser":
                    page = tmp / "upload.html"
                    page.write_text('<title>drop-ready</title><body style="margin:0;background:white">'
                                    '<div id="target" style="position:absolute;left:100px;top:100px;'
                                    'width:400px;height:300px;outline:2px solid gray">Drop files here</div>'
                                    '<script>const t=document.getElementById("target");'
                                    't.ondragover=e=>{e.preventDefault();e.dataTransfer.dropEffect="copy";'
                                    'document.title="drop-hover";};'
                                    't.ondrop=async e=>{e.preventDefault();'
                                    'const fs=[...e.dataTransfer.files];const texts=await Promise.all(fs.map(f=>f.text()));'
                                    'document.title="received:"+fs.length+":"+texts.join("|");};</script>')
                    executable = os.environ.get("REDIWM_TEST_BRAVE") or shutil.which("brave")
                    assert executable, "Brave required for the browser scenario"
                    launch([executable, "--ozone-platform=wayland", f"--user-data-dir={tmp / 'profile'}",
                            "--no-first-run", "--no-default-browser-check", "--disable-background-networking",
                            "--disable-gpu", page.as_uri()], "dest.log")
                    dst = wait_for(lambda: next((w for w in ipc.get_windows() if "drop-ready" in w["title"]), None), "browser did not map", 30)
                else:
                    launch([sys.executable, str(ROOT / "tests/dnd_gtk_client.py"), "dest"], "dest.log")
                    dst = wait_for(lambda: next((w for w in ipc.get_windows() if "GTK DnD Fixture" in w["title"]), None), "destination did not map", 30)

                ipc.action('set_window_size', {"id": src["id"], "width": 600, "height": 500})
                ipc.action('move_window_to', {"id": src["id"], "x": 10, "y": 30})
                # The destination lies partly under Files, or clear of it.
                ipc.action('set_window_size', {"id": dst["id"], "width": 900, "height": 600})
                ipc.action('move_window_to', {"id": dst["id"], "x": 700 if scenario == "apart" else 200, "y": 30})
                ipc.action('focus_window', {"id": src["id"]})
                time.sleep(.5)

                def window_at(x, y):
                    return ipc.hit_test(round(x), round(y)).get("window_id")

                def files_position():
                    win = next(w for w in ipc.get_windows() if w["id"] == src["id"])
                    return win["x"], win["y"]

                def move(x, y):
                    ipc.action('move_cursor', {"x": round(x), "y": round(y)})

                def button(pressed):
                    ipc.action('pointer_button', {"button": 272, "pressed": pressed})

                if scenario == "zoomed":
                    move(0, 0)
                    ipc.action('set_zoom', {"percent": 70})
                    wait_for(lambda: ipc.action("get_camera")["zoom_percent"] == 70, "camera did not zoom")
                    time.sleep(.6)
                cam = ipc.action("get_camera")
                zoom = cam["zoom_percent"] / 100

                def screen(wx, wy):
                    return (wx - cam["x"]) * zoom, (wy - cam["y"]) * zoom

                box = ipc.get_window_debug(src["id"])["client_box"]
                centre = screen(310, 280)  # inside Files, and inside the destination when uncovered
                assert window_at(*centre) == src["id"], "Files should start on top"
                start = files_position()

                for key, pressed in ((29, True), (30, True), (30, False), (29, False)):
                    ipc.action('key', {"keycode": key, "pressed": pressed})
                x, y = screen(box["x"] + 250, box["y"] + 158)
                tx, ty = screen(900, 300)  # over the destination, well clear of Files
                move(x, y)
                button(True)
                time.sleep(.08)
                for step in range(1, 17):
                    move(x + (tx - x) * step / 16, y + (ty - y) * step / 16)
                    time.sleep(.05)
                sx, sy = tx, ty
                if scenario == "browser":
                    wait_for(lambda: window_at(*centre) == dst["id"], "Files did not slide out of the way")
                    # The page's drop area lies under where Files was: go there.
                    tx, ty = screen(400, 300)
                    for step in range(1, 9):
                        move(sx + (tx - sx) * step / 8, sy + (ty - sy) * step / 8)
                        time.sleep(.05)
                    wait_for(lambda: any("drop-hover" in w["title"] for w in ipc.get_windows()), "the upload area under Files did not highlight")
                else:
                    wait_for(lambda: "drag-motion" in (tmp / "dest.log").read_text(), "destination never saw the drag")

                if scenario in ("off", "apart"):
                    time.sleep(.6)
                    assert window_at(*centre) == src["id"], "Files moved although it should not have"
                    button(False)
                else:
                    wait_for(lambda: window_at(*centre) == dst["id"], "Files did not slide out of the way")
                    # Only presentation moved: the window itself is where it was.
                    assert files_position() == start, (files_position(), start)
                    # A strip of it stays on screen at the left edge.
                    assert window_at(20, centre[1]) == src["id"], "no strip of Files left at the edge"
                    assert window_at(60, centre[1]) != src["id"], "more than the strip of Files is left"
                    preview = os.environ.get("REDIWM_FILES_DODGE_PREVIEW")
                    if preview:
                        ipc.screenshot(path=preview)

                    if scenario == "browser":
                        button(False)
                        expected = "received:2:drag payload|drag payload"
                        wait_for(lambda: any(expected in w["title"] for w in ipc.get_windows()), "the browser did not read both dropped files")
                    elif scenario in ("drop", "zoomed"):
                        button(False)
                        wait_for(lambda: "drag-data-received" in (tmp / "dest.log").read_text(), "GTK did not receive the drop")
                    else:
                        ipc.action('key', {"keycode": ESC, "pressed": True})
                        ipc.action('key', {"keycode": ESC, "pressed": False})
                        time.sleep(.3)
                        button(False)
                        time.sleep(.3)
                        text = (tmp / "dest.log").read_text()
                        assert "drag-drop" not in text and "drag-data-received" not in text, text
                    wait_for(lambda: window_at(*centre) == src["id"], "Files did not slide back")
                    assert files_position() == start, (files_position(), start)
                assert not any(p.poll() is not None for p in peers), "a client died"
                print(f"PASS Files dodge: {scenario}")
        except Exception:
            for name in ("files.log", "dest.log", "compositor.log"):
                if (tmp / name).exists():
                    print(name, (tmp / name).read_text()[-5000:])
            raise
        finally:
            for peer in reversed(peers):
                stop_process(peer)
            stop_process(comp)
            log.close()


if __name__ == "__main__":
    for name in (sys.argv[1:] or ["drop", "escape", "off", "apart", "zoomed"]):
        run(name)

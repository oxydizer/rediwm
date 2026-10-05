#!/usr/bin/env python3
"""Drag selected files to a native GTK peer or a real browser upload target."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

from PIL import Image, ImageChops

from files_browser import wait_for
from ipc_client import IPCClient, spawn_compositor, stop_process

ROOT = Path(__file__).resolve().parents[1]


def run(browser=False, select=False, list_view=False):
    with tempfile.TemporaryDirectory(prefix="rediwm-files-drag-") as directory:
        tmp = Path(directory)
        home = tmp / "home"
        home.mkdir()
        names = ["a space #.txt", "b-雪.txt"]
        for name in names:
            (home / name).write_text("drag upload payload")
        comp, log = spawn_compositor(tmp, config_content="[compositor]\nxwayland = false\n",
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

                files = launch([str(ROOT / "zig-out/bin/rediwm-files"), str(home)], "files.log")
                src = wait_for(lambda: next((w for w in ipc.get_windows() if w["app_id"] == "rediwm-files"), None), "Files did not map")
                ipc.action('set_window_size', {"id": src["id"], "width": 600, "height": 500})
                ipc.action('move_window_to', {"id": src["id"], "x": 10, "y": 30})
                if browser:
                    page = tmp / "upload.html"
                    page.write_text('<title>drop-ready</title><body style="margin:0;background:white">'
                                    '<div id="target" style="position:absolute;left:100px;top:100px;'
                                    'width:400px;height:300px;outline:2px solid gray">Drop files here</div>'
                                    '<script>const t=document.getElementById("target");'
                                    't.ondragover=e=>{e.preventDefault();e.dataTransfer.dropEffect="copy";'
                                    't.style.outlineColor="green";document.title="drop-hover";};'
                                    't.ondragleave=()=>{t.style.outlineColor="gray";document.title="drop-left";};'
                                    't.ondrop=async e=>{e.preventDefault();'
                                    'const fs=[...e.dataTransfer.files];const texts=await Promise.all(fs.map(f=>f.text()));'
                                    'document.title="received:"+fs.length+":"+texts.join("|");};</script>')
                    executable = os.environ.get("REDIWM_TEST_BRAVE") or shutil.which("brave")
                    assert executable, "Brave required for --browser"
                    launch([executable, "--ozone-platform=wayland", f"--user-data-dir={tmp / 'profile'}",
                            "--no-first-run", "--no-default-browser-check", "--disable-background-networking",
                            "--disable-gpu", page.as_uri()], "dest.log")
                else:
                    launch([sys.executable, str(ROOT / "tests/dnd_gtk_client.py"), "dest"], "dest.log")
                dst = wait_for(lambda: next((w for w in ipc.get_windows() if "drop-ready" in w["title"] or "GTK DnD Fixture" in w["title"]), None), "destination did not map", 30)
                ipc.action('set_window_size', {"id": dst["id"], "width": 600, "height": 500})
                ipc.action('move_window_to', {"id": dst["id"], "x": 680, "y": 30})
                ipc.action('focus_window', {"id": src["id"]})
                time.sleep(.5)
                box = ipc.get_window_debug(src["id"])["client_box"]
                dest = ipc.get_window_debug(dst["id"])["client_box"]
                def move(x, y):
                    ipc.action('move_cursor', {"x": round(x), "y": round(y)})
                def button(pressed):
                    ipc.action('pointer_button', {"button": 272, "pressed": pressed})
                if list_view:
                    move(box["x"] + 367, box["y"] + 80)
                    button(True)
                    button(False)
                    time.sleep(.2)
                if select:
                    # Start in the gutter, cover both items and release. The
                    # external drop below proves exactly which paths selected.
                    top = 157 if list_view else 127
                    move(box["x"] + 165, box["y"] + top)
                    time.sleep(.08)
                    button(True)
                    time.sleep(.08)
                    for step in range(1, 11):
                        move(box["x"] + 165 + 395 * step / 10,
                             box["y"] + top + (70 if list_view else 210) * step / 10)
                        if step == 3:
                            # A watcher refresh during a gesture must not
                            # cancel the band or reorder the selected items.
                            (home / ".refresh-probe").write_text("refresh")
                        time.sleep(.03)
                    preview = os.environ.get("REDIWM_FILES_SELECTION_PREVIEW")
                    if preview:
                        ipc.screenshot(path=preview)
                    button(False)
                    time.sleep(.1)
                else:
                    for key, pressed in ((29, True), (30, True), (30, False), (29, False)):
                        ipc.action('key', {"keycode": key, "pressed": pressed})
                x, y = box["x"] + 250, box["y"] + (178 if list_view else 158)
                tx, ty = dest["x"] + 250, dest["y"] + 300
                def icon_pixels():
                    path = tmp / "drag.png"
                    path.unlink(missing_ok=True)
                    ipc.screenshot(path=str(path))
                    with Image.open(path) as image:
                        return image.convert("RGB").crop((round(tx + 8), round(ty + 16),
                                                          round(tx + 40), round(ty + 48)))
                before_icon = icon_pixels() if browser else None
                move(x, y)
                ipc.action('pointer_button', {"button": 272, "pressed": True})
                time.sleep(.08)
                for step in range(1, 17):
                    move(x + (tx-x)*step/16, y + (ty-y)*step/16)
                    time.sleep(.05)
                time.sleep(.3)
                if browser:
                    def title_is(title):
                        return any(title in w["title"] for w in ipc.get_windows())
                    wait_for(lambda: title_is("drop-hover"), "upload target did not highlight")
                    # Cross out of the page target, then out of the browser,
                    # and re-enter. The icon must not intercept target motion.
                    move(dest["x"] + 40, ty)
                    wait_for(lambda: title_is("drop-left"), "upload target did not receive leave")
                    move(x, y)
                    time.sleep(.1)
                    for step in range(1, 9):
                        move(x + (tx-x)*step/8, y + (ty-y)*step/8)
                        time.sleep(.05)
                    wait_for(lambda: title_is("drop-hover"), "upload target did not highlight on re-entry")
                    wait_for(lambda: ImageChops.difference(before_icon, icon_pixels()).getbbox(),
                             "file drag icon was not rendered below the cursor")
                ipc.action('pointer_button', {"button": 272, "pressed": False})
                if browser:
                    expected = "received:2:drag upload payload|drag upload payload"
                    wait_for(lambda: any(expected in w["title"] for w in ipc.get_windows()), "browser did not read both dropped files")
                    wait_for(lambda: ImageChops.difference(before_icon, icon_pixels()).getbbox() is None,
                             "file drag icon remained after drop")
                else:
                    wait_for(lambda: "drag-data-received" in (tmp / "dest.log").read_text(), "GTK did not receive drag")
                    received = (tmp / "dest.log").read_text()
                    for name in names:
                        assert (home / name).as_uri() in received, received
                assert files.poll() is None
                assert all((home / name).exists() for name in names)
                print("PASS Files " + ("list " if list_view else "grid ") + ("drag-selection and " if select else "") + "multi-file drag to " + ("browser upload" if browser else "GTK"))
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


def run_pin():
    """Drag folders and a file onto PLACES: a line marks the gap, a release pins there."""
    with tempfile.TemporaryDirectory(prefix="rediwm-files-pin-") as directory:
        tmp = Path(directory)
        home = tmp / "home"
        home.mkdir()
        for name in ("pinned folder", "second folder"):
            (home / name).mkdir()
        (home / "note.txt").write_text("pin me")
        state = tmp / "state/rediwm/files-places"
        comp, log = spawn_compositor(tmp, config_content="[compositor]\nxwayland = false\n",
                                     renderer=os.environ.get("REDIWM_TEST_RENDERER", "pixman"),
                                     env_extra={"HOME": str(home)})
        files = None
        try:
            with IPCClient(tmp).connect() as ipc:
                display = next(p.name for p in tmp.glob("wayland-*") if not p.name.endswith(".lock"))
                env = dict(os.environ, HOME=str(home), XDG_RUNTIME_DIR=str(tmp),
                           XDG_STATE_HOME=str(tmp / "state"), XDG_CONFIG_HOME=str(tmp / "config"),
                           REDIWM_CONFIG=str(tmp / "rediwm-config.toml"), WAYLAND_DISPLAY=display,
                           DBUS_SESSION_BUS_ADDRESS="unix:path=/nonexistent", REDIWM_FILES_DEVICES="0")
                for key in ("DISPLAY", "REDIWM_SOCKET", "WAYLAND_DEBUG"):
                    env.pop(key, None)
                with (tmp / "files.log").open("w") as out:
                    files = subprocess.Popen([str(ROOT / "zig-out/bin/rediwm-files"), str(home)], env=env, stdout=out, stderr=out)
                win = wait_for(lambda: next((w for w in ipc.get_windows() if w["app_id"] == "rediwm-files"), None), "Files did not map")
                ipc.action('set_window_size', {"id": win["id"], "width": 1000, "height": 560})
                ipc.action('move_window_to', {"id": win["id"], "x": 10, "y": 30})
                ipc.action('focus_window', {"id": win["id"]})
                time.sleep(.6)
                box = ipc.get_window_debug(win["id"])["client_box"]

                # Window coordinates: three grid cards 252 px apart, the sidebar 208 px
                # wide with rows 32 px apart. Row n of the pins is centred at
                # 462 + 32n, and the gap above it is at 446 + 32n.
                def move(x, y):
                    ipc.action('move_cursor', {"x": round(box["x"] + x), "y": round(box["y"] + y)})
                def button(pressed, code=272):
                    ipc.action('pointer_button', {"button": code, "pressed": pressed})
                def click(x, y, code=272):
                    move(x, y)
                    button(True, code)
                    button(False, code)
                    time.sleep(.15)
                def pins():
                    return state.read_text().splitlines() if state.exists() else []
                def accent_at(y):
                    # The insertion line is accent red; the sidebar there is grey.
                    path = tmp / "hover.png"
                    path.unlink(missing_ok=True)
                    ipc.screenshot(path=str(path))
                    with Image.open(path) as image:
                        pixels = [image.convert("RGB").getpixel((round(box["x"] + 100), round(box["y"] + y + d))) for d in range(-3, 4)]
                    return any(r > 180 and g < 90 and b < 110 for r, g, b in pixels)
                def drag(card, x, y, line_at=None):
                    sx = 250 + 252 * card
                    click(sx, 158)
                    # The press that starts the drag must not read as a double click.
                    time.sleep(.7)
                    move(sx, 158)
                    button(True)
                    time.sleep(.1)
                    for step in range(1, 11):
                        move(sx + (x - sx) * step / 10, 158 + (y - 158) * step / 10)
                        time.sleep(.04)
                    time.sleep(.25)
                    if line_at is not None:
                        wait_for(lambda: accent_at(line_at), f"no insertion line at {line_at} while hovering PLACES")
                    button(False)
                    time.sleep(.5)

                names = [home / "pinned folder", home / "second folder", home / "note.txt"]
                # A file onto the section pins it, even aimed far from the gap.
                drag(2, 80, 240, line_at=446)
                wait_for(lambda: pins() == [str(names[2])], "the dropped file was not pinned")
                # Above the first pin, then between the two.
                drag(0, 80, 240, line_at=446)
                wait_for(lambda: pins() == [str(names[0]), str(names[2])], "folder did not land above the first pin")
                drag(1, 80, 480, line_at=478)
                wait_for(lambda: pins() == [str(n) for n in names], "folder did not land between the pins")
                # Off PLACES nothing is accepted, and a listed folder is not added twice.
                drag(0, 600, 400)
                drag(0, 80, 240)
                time.sleep(.3)
                assert pins() == [str(n) for n in names], pins()
                # A click opens a folder pin.
                click(80, 494)
                wait_for(lambda: any(w["title"].startswith("second folder") for w in ipc.get_windows()), "pin did not open its folder")
                # Removing one keeps the others in order.
                click(80, 526, 273)
                time.sleep(.2)
                for key in (108, 28):
                    ipc.action('key', {"keycode": key, "pressed": True})
                    ipc.action('key', {"keycode": key, "pressed": False})
                wait_for(lambda: pins() == [str(names[0]), str(names[1])], "Remove from Places did not remove the pin")
                assert files.poll() is None
                assert all(n.exists() for n in names)
                print("PASS Files drag onto PLACES pins in order, ignores other drops, opens and removes pins")
        except Exception:
            for name in ("files.log", "compositor.log"):
                if (tmp / name).exists():
                    print(name, (tmp / name).read_text()[-5000:])
            raise
        finally:
            if files:
                stop_process(files)
            stop_process(comp)
            log.close()


if __name__ == "__main__":
    if "--pin" in sys.argv:
        run_pin()
        sys.exit(0)
    run("--browser" in sys.argv, "--select" in sys.argv, "--list" in sys.argv)

#!/usr/bin/env python3
"""Files Trash view: restore, permanent delete, Restore All, Empty Trash and read-only rules.

The trash is a fixture under a scratch XDG_DATA_HOME and `gio` is a fake, so
nothing touches the host's trash. Ground truth is the filesystem.
"""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
from urllib.parse import quote

from files_browser import wait_for
from ipc_client import IPCClient, spawn_compositor, stop_process

ROOT = Path(__file__).resolve().parents[1]

ESC, ENTER, TAB = 1, 28, 15
CTRL, SHIFT = 29, 42
KEY_A, KEY_N, KEY_X, KEY_L, F2 = 30, 49, 45, 38, 60
HOME, UP, LEFT, RIGHT, DOWN, DELETE, MENU = 102, 103, 105, 106, 108, 111, 127


def run():
    with tempfile.TemporaryDirectory(prefix="rediwm-files-trash-") as directory:
        tmp = Path(directory)
        home = tmp / "home"
        data = tmp / "data"
        trash = data / "Trash"
        files, info = trash / "files", trash / "info"
        for d in (home, files, info, tmp / "bin", tmp / "state"):
            d.mkdir(parents=True)
        log = tmp / "gio.log"

        def put(name, origin, content="", folder=False, meta=True):
            """A trashed entry, with the .trashinfo gio would have written."""
            item = files / name
            if folder:
                item.mkdir()
                (item / "inner.txt").write_text(content)
            else:
                item.write_text(content)
            if meta:
                (info / (name + ".trashinfo")).write_text(
                    "[Trash Info]\nPath=" + quote(str(origin), safe="/") + "\nDeletionDate=2026-11-03T12:00:00\n")

        put("a.txt", home / "a.txt", "alpha")
        put("b.txt", home / "gone" / "dir" / "b.txt", "bravo")
        put("c.txt", home / "c.txt", "charlie")
        (home / "c.txt").write_text("current")
        put("d dir", home / "d dir", "delta", folder=True)
        put("e.txt", home / "e.txt", "echo")
        put(".hidden", home / ".hidden", "shy")
        put("nometa.txt", home / "nometa.txt", "no metadata", meta=False)
        (info / "ghost.txt.trashinfo").write_text("[Trash Info]\nPath=" + str(home / "ghost.txt") + "\n")
        (trash / "directorysizes").write_text("5 50 d%20dir\n7 70 other\n")

        # A fake gio: Move to Trash is logged; Empty Trash removes the items but,
        # like an interrupted run, leaves their metadata behind for us to sweep.
        gio = tmp / "bin" / "gio"
        gio.write_text(
            "#!/bin/sh\n"
            'if [ "$1" = trash ] && [ "$2" = --empty ]; then\n'
            f'  find "{files}" -mindepth 1 -delete\n'
            f'  echo emptied >> "{log}"; exit 0\n'
            "fi\n"
            'if [ "$1" = trash ] && [ "$2" = -- ]; then shift 2; '
            f'for p in "$@"; do echo "trash $p" >> "{log}"; done; exit 0; fi\n'
            "exit 1\n")
        gio.chmod(0o755)

        comp, comp_log = spawn_compositor(
            tmp, config_content="[compositor]\nxwayland = false\n",
            renderer=os.environ.get("REDIWM_TEST_RENDERER", "gles2"),
            env_extra={"HOME": str(home), "XDG_DATA_HOME": str(data)})
        peers = []
        try:
            with IPCClient(tmp).connect() as ipc:
                display = next(p.name for p in tmp.glob("wayland-*") if not p.name.endswith(".lock"))
                env = dict(os.environ, HOME=str(home), XDG_RUNTIME_DIR=str(tmp), XDG_DATA_HOME=str(data),
                           XDG_STATE_HOME=str(tmp / "state"), XDG_CONFIG_HOME=str(tmp / "config"),
                           REDIWM_CONFIG=str(tmp / "rediwm-config.toml"), WAYLAND_DISPLAY=display,
                           DBUS_SESSION_BUS_ADDRESS="unix:path=/nonexistent", REDIWM_FILES_DEVICES="0",
                           PATH=str(tmp / "bin") + ":" + os.environ["PATH"])
                for name in ("DISPLAY", "REDIWM_SOCKET", "WAYLAND_DEBUG"):
                    env.pop(name, None)
                with (tmp / "files.log").open("w") as out:
                    peers.append(subprocess.Popen([str(ROOT / "zig-out/bin/rediwm-files"), str(files)],
                                                  env=env, stdout=out, stderr=out))

                def windows():
                    return [w for w in ipc.get_windows() if w["app_id"] == "rediwm-files"]

                win = wait_for(lambda: next(iter(windows()), None), "Files did not map")
                ipc.focus_window(win["id"])

                def key(code, *mods):
                    for mod in mods:
                        ipc.key(mod, True)
                    ipc.key_down_up(code)
                    for mod in reversed(mods):
                        ipc.key(mod, False)
                    time.sleep(.15)

                def title(value):
                    wait_for(lambda: windows() and windows()[0]["title"] == value + " — RediWM Files",
                             "Files did not reach " + value)

                def settle():
                    time.sleep(.4)

                def shot(name):
                    """Optional review pictures: REDIWM_TRASH_SHOTS=<directory>."""
                    if os.environ.get("REDIWM_TRASH_SHOTS"):
                        time.sleep(.3)
                        ipc.screenshot(str(Path(os.environ["REDIWM_TRASH_SHOTS"]) / (name + ".png")), window_id=win["id"])

                def delete_key():
                    """Delete opens a confirmation; Enter before it is up would open the item instead."""
                    key(DELETE)
                    time.sleep(.4)

                def select(index):
                    """Select the index-th item of the (name-sorted) listing."""
                    key(HOME)
                    for _ in range(index):
                        key(RIGHT)

                def menu(*downs):
                    key(MENU)
                    for _ in range(downs[0] if downs else 0):
                        key(DOWN)

                def gone(path):
                    return wait_for(lambda: not path.exists(), f"{path.name} was not removed")

                title("Trash")
                settle()

                # Folders sort first: d dir, a.txt, b.txt, c.txt, e.txt, nometa.txt (.hidden is hidden).
                # An entry without a .trashinfo cannot say where it belongs: Restore is faded and explains itself.
                select(5)
                menu(2)
                shot("menu-no-metadata")
                key(ENTER)
                shot("notice-no-metadata")
                key(ESC)
                settle()
                assert (files / "nometa.txt").exists() and not (home / "nometa.txt").exists()

                # Restore one item from its context menu: Open, Copy, Restore, Delete Permanently, Properties.
                select(1)
                menu(2)
                shot("menu-item")
                key(ENTER)
                wait_for(lambda: (home / "a.txt").exists(), "Restore did not put a.txt back")
                assert (home / "a.txt").read_text() == "alpha"
                gone(files / "a.txt")
                gone(info / "a.txt.trashinfo")
                assert (files / "b.txt").exists() and (info / "b.txt.trashinfo").exists(), "Restore touched other entries"
                settle()

                # Move to Trash is not offered: Delete deletes permanently, after confirmation.
                select(3)  # d dir, b.txt, c.txt, e.txt
                delete_key()
                shot("dialog-delete")
                key(ESC)
                settle()
                assert (files / "e.txt").exists(), "Cancel deleted e.txt"
                delete_key()
                key(ENTER)
                gone(files / "e.txt")
                gone(info / "e.txt.trashinfo")
                assert not log.exists() or "trash" not in log.read_text(), "Delete in Trash called gio trash"
                assert (files / "c.txt").exists()
                settle()

                # The Trash is read-only apart from Restore and Delete.
                key(ESC)
                key(KEY_N, CTRL, SHIFT)  # New Folder
                key(ENTER)
                key(KEY_N, CTRL)  # New File
                key(ENTER)
                select(1)  # b.txt
                key(F2)
                ipc.type_text("renamed")  # would go to a rename dialog; there is none
                time.sleep(.5)
                assert sorted(p.name for p in files.iterdir()) == sorted(
                    [".hidden", "b.txt", "c.txt", "d dir", "nometa.txt"]), "Trash was edited: " + str(sorted(files.iterdir()))

                # Restore All from the empty-space menu: Empty Trash…, Restore All, Refresh.
                # Typing may have opened the search box; Escape closes it, then clears the selection.
                key(ESC)
                key(ESC)
                menu(1)
                shot("menu-background")
                key(ENTER)
                wait_for(lambda: (home / "gone/dir/b.txt").exists(), "Restore All did not recreate the parent folder")
                assert (home / "gone/dir/b.txt").read_text() == "bravo"
                # A taken name is never overwritten.
                assert (home / "c.txt").read_text() == "current"
                assert (home / "c (1).txt").read_text() == "charlie"
                assert (home / "d dir/inner.txt").read_text() == "delta"
                assert (home / ".hidden").read_text() == "shy", "Restore All skipped a hidden entry"
                assert (trash / "directorysizes").read_text() == "7 70 other\n"
                # An entry with no .trashinfo has nowhere to go and stays.
                assert (files / "nometa.txt").read_text() == "no metadata"
                assert sorted(p.name for p in files.iterdir()) == ["nometa.txt"], list(files.iterdir())
                assert sorted(p.name for p in info.iterdir()) == ["ghost.txt.trashinfo"], list(info.iterdir())
                settle()

                # Several selected entries restore together; the one without metadata is skipped, not fatal.
                for n in ("m1", "m2", "m3"):
                    put(n + ".txt", home / (n + ".txt"), n)
                key(63)  # F5
                settle()
                key(KEY_A, CTRL)
                menu(2)
                key(ENTER)
                for n in ("m1", "m2", "m3"):
                    wait_for(lambda n=n: (home / (n + ".txt")).exists() and (home / (n + ".txt")).read_text() == n,
                             f"multi-select Restore skipped {n}.txt")
                    gone(info / (n + ".txt.trashinfo"))
                assert sorted(p.name for p in files.iterdir()) == ["nometa.txt"], list(files.iterdir())
                settle()

                # Several selected entries are deleted together, metadata included (nometa.txt too).
                for n in ("p1", "p2", "p3"):
                    put(n + ".txt", home / (n + ".txt"), n)
                key(63)
                settle()
                key(KEY_A, CTRL)
                delete_key()
                key(ENTER)
                wait_for(lambda: not list(files.iterdir()), "multi-select Delete left entries behind: " + str(list(files.iterdir())))
                assert sorted(p.name for p in info.iterdir()) == ["ghost.txt.trashinfo"], list(info.iterdir())
                assert not any((home / (n + ".txt")).exists() for n in ("p1", "p2", "p3")), "Delete restored instead of deleting"
                put("left.txt", home / "left.txt", "l")
                key(63)
                settle()

                # Empty Trash from the same menu; leftover metadata is swept.
                key(ESC)
                key(ESC)
                menu(0)
                key(ENTER)  # opens the confirmation
                time.sleep(.3)
                shot("dialog-empty")
                assert (files / "left.txt").exists(), "Empty Trash ran before confirmation"
                key(ENTER)
                wait_for(lambda: log.exists() and "emptied" in log.read_text(), "Empty Trash did not run gio trash --empty")
                wait_for(lambda: not list(info.iterdir()), "orphaned metadata survived Empty Trash")
                assert not list(files.iterdir())

                # Elsewhere nothing changed: Move to Trash still goes through gio, and New works.
                plain = tmp / "plain"
                plain.mkdir()
                (plain / "move-me.txt").write_text("m")
                key(KEY_L, CTRL)
                ipc.type_text(str(plain))
                key(ENTER)
                title("plain")
                settle()
                key(HOME)
                delete_key()
                key(ENTER)
                wait_for(lambda: f"trash {plain / 'move-me.txt'}" in log.read_text(), "Move to Trash did not call gio trash")
                key(KEY_N, CTRL, SHIFT)
                ipc.type_text("made")
                key(ENTER)
                wait_for(lambda: (plain / "made").is_dir(), "New Folder no longer works outside the Trash")

                # The sidebar's Trash row has its own Properties window (items, size, Open, Close),
                # not the permissions sheet of its folder: Tab never reaches a permission cell, so
                # Enter after two Tabs closes the window instead of changing the folder's mode.
                put("late.txt", home / "late.txt", "twelve chars")
                mode = files.stat().st_mode
                geometry = next(iter(windows()))
                row = (geometry["x"] + 75, geometry["y"] + 221)  # sidebar: Home, Trash, Recent

                def trash_properties():
                    ipc.click_at(*row, 0x111)
                    time.sleep(.3)
                    for _ in range(3):  # Open, Open in New Window, Empty Trash…, Properties
                        key(DOWN)
                    key(ENTER)
                    time.sleep(.6)

                trash_properties()
                key(TAB)
                key(TAB)
                key(ENTER)
                time.sleep(.4)
                assert files.stat().st_mode == mode, "Trash Properties offered permissions to change"
                trash_properties()
                key(ESC)
                time.sleep(.3)
                assert windows()[0]["title"] == "plain — RediWM Files", "Escape in Trash Properties navigated away"
                trash_properties()
                key(TAB)
                key(ENTER)  # Open
                title("Trash")
        finally:
            for peer in peers:
                stop_process(peer)
            stop_process(comp)
    print("files trash: ok")


if __name__ == "__main__":
    run()

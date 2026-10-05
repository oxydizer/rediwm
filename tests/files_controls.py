#!/usr/bin/env python3
"""Headless file-manager toolbar, search, sort, view and context-menu checks."""
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import zipfile

from files_browser import wait_for

ROOT = Path(__file__).resolve().parents[1]


def run():
    with tempfile.TemporaryDirectory(prefix="rediwm-files-controls-") as directory:
        tmp = Path(directory)
        home = tmp / "Home"
        home.mkdir()
        for name in ("Archive", "Documents", "Downloads", "Music", "Pictures",
                     "Projects", "Research", "Work", "Desktop"):
            (home / name).mkdir()
        (home / "alpha-file.txt").write_text("small")
        (home / "zeta-file.txt").write_text("large" * 100)
        (home / ".hidden-file").write_text("hidden")
        helpers = tmp / "bin"
        helpers.mkdir()
        marker = tmp / "opened"
        opener = helpers / "gio"
        opener.write_text('#!/bin/sh\n[ "$1" = "open" ] || exit 1\nprintf "%s" "$2" > "' + str(marker) + '"\n')
        opener.chmod(0o755)
        config = tmp / "config.toml"
        config.write_text("")
        env = dict(os.environ, HOME=str(home), XDG_RUNTIME_DIR=directory,
                   XDG_DATA_HOME=str(tmp / "data"),
                   REDIWM_CONFIG=str(config), WLR_BACKENDS="headless", REDIWM_FILES_DEVICES="0",
                   WLR_HEADLESS_OUTPUTS="1", WLR_RENDERER=os.environ.get("REDIWM_TEST_RENDERER", "pixman"),
                   REDIWM_SCALE="1", XDG_STATE_HOME=str(tmp / "state"), PATH=str(helpers) + ":" + os.environ["PATH"],
                   REDIWM_IPC_AUTOMATION="1")
        env.pop("WAYLAND_DISPLAY", None)
        env.pop("REDIWM_SOCKET", None)
        processes = []

        def start(binary, *args, **extra):
            with (tmp / (binary + ".log")).open("w") as log:
                p = subprocess.Popen([str(ROOT / "zig-out/bin" / binary), *args],
                                     env=dict(env, **extra), stdout=log, stderr=log)
            processes.append(p)
            return p

        try:
            start("rediwm")
            paths = wait_for(lambda: list(tmp.glob("rediwm-*.sock")), "IPC unavailable")
            with socket.socket(socket.AF_UNIX) as sock:
                sock.settimeout(10)
                sock.connect(str(paths[0]))
                reader = sock.makefile("r")

                def request(value):
                    sock.sendall((json.dumps(value) + "\n").encode())
                    result = json.loads(reader.readline())
                    assert "Ok" in result, result
                    return result["Ok"]

                def action(name, params):
                    return request({"version": 1, "command": name, "params": params})

                def key(code, ctrl=False, alt=False):
                    modifiers = ([29] if ctrl else []) + ([56] if alt else [])
                    for mod in modifiers:
                        action('key', {"keycode": mod, "pressed": True})
                    for pressed in (True, False):
                        action('key', {"keycode": code, "pressed": pressed})
                    for mod in reversed(modifiers):
                        action('key', {"keycode": mod, "pressed": False})
                    time.sleep(.1)

                def windows():
                    return [w for w in request({'version': 1, 'command': 'windows'}).get("Windows", [])
                            if w["app_id"] == "rediwm-files"]

                display = next(p.name for p in tmp.glob("wayland-*") if not p.name.endswith(".lock"))
                start("rediwm-files", str(home), WAYLAND_DISPLAY=display)
                win = wait_for(lambda: next(iter(windows()), None), "file manager did not map")
                action('focus_window', {"id": win["id"]})
                time.sleep(.3)

                def click(x, y, button=272):
                    debug = request({"version": 1, "command": 'get_window_debug', "params": {"id": win["id"]}})["WindowDebug"]
                    box = debug["client_box"]
                    action('move_cursor', {"x": box["x"] + x, "y": box["y"] + y})
                    for pressed in (True, False):
                        action('pointer_button', {"button": button, "pressed": pressed})
                    time.sleep(.15)

                def text(value):
                    action('type_text', {"text": value})
                    time.sleep(.2)

                def search(value):
                    key(33, ctrl=True)  # Ctrl+F selects the local query.
                    text(value)

                def title(value):
                    wait_for(lambda: windows() and windows()[0]["title"] == value + " — RediWM Files",
                             "navigation did not reach " + value)

                def opened(name):
                    wait_for(lambda: marker.exists() and marker.read_text() == str(home / name),
                             "did not open " + name)
                    marker.unlink()

                # Both common evdev side-button pairs navigate on press only.
                for folder in ("Archive", "Documents"):
                    key(38, ctrl=True)  # Ctrl+L
                    text(str(home / folder))
                    key(28)
                    title(folder)
                action('move_cursor', {"x": win["x"] + 300, "y": win["y"] + 300})
                for button, folder in ((0x113, "Archive"), (0x114, "Documents"),
                                       (0x116, "Archive"), (0x115, "Documents")):
                    action('pointer_button', {"button": button, "pressed": True})
                    title(folder)
                    action('pointer_button', {"button": button, "pressed": False})
                    time.sleep(.1)
                    assert windows()[0]["title"] == folder + " — RediWM Files"
                # A modal editor must keep its current directory.
                key(49, ctrl=True)  # Ctrl+N: new folder
                for pressed in (True, False):
                    action('pointer_button', {"button": 0x113, "pressed": pressed})
                title("Documents")
                key(1)
                key(105, alt=True)
                key(105, alt=True)
                title("Home")

                # Trash below Home opens the local trash, even before its first use.
                click(70, 175)
                title("Trash")
                trash = tmp / "data" / "Trash" / "files"
                assert trash.is_dir(), "Trash shortcut did not create an empty location"
                click(70, 140)
                title("Home")

                # Toolbar New popup is actionable with the keyboard.
                click(50, 80)
                key(28)
                text("Toolbar Folder")
                key(28)
                wait_for(lambda: (home / "Toolbar Folder").is_dir(), "New menu failed")

                # The client repeats held keys itself, at the compositor's
                # repeat_info (default 25/s after 400 ms): 1.2 s is ~21 "a"s.
                click(50, 80)
                key(28)
                action('key', {"keycode": 30, "pressed": True})
                time.sleep(1.2)
                action('key', {"keycode": 30, "pressed": False})
                time.sleep(.2)
                key(28)
                repeated = wait_for(lambda: next((p.name for p in home.iterdir() if p.name.startswith("a") and set(p.name) == {"a"}), None),
                                    "held key did not make a folder")
                assert 8 <= len(repeated) <= 30, repeated
                (home / repeated).rmdir()

                # A right-click targets the clicked item, including rename.
                click(250, 160, 273)
                click(320, 317)  # Rename, after Open's separator and three edit rows.
                text("Archive renamed")
                key(28)
                wait_for(lambda: (home / "Archive renamed").is_dir(), "context rename failed")

                # Empty-space menu near the edge must remain clickable after clamping.
                click(935, 500, 273)
                key(108)  # New File
                key(28)
                text("Context File.txt")
                key(28)
                wait_for(lambda: (home / "Context File.txt").is_file(), "background context menu failed")

                # Search is case-insensitive and Enter transfers focus to results.
                search("ARCHIVE")
                key(28)
                key(28)
                title("Archive renamed")
                key(105, alt=True)
                title("Home")

                # Sort by size, retaining the current query.
                search("-file.txt")
                key(28)
                click(790, 80)  # Sort
                key(108)
                key(108)
                key(28)  # Largest first
                key(102)
                key(28)
                opened("zeta-file.txt")

                # Switching to list changes hit testing as well as painting.
                click(727, 80)
                click(300, 220)  # Second 44px row below the pinned header
                key(28)
                opened("alpha-file.txt")

                # Folders-only filter yields no matches for this file query.
                click(900, 80)
                key(28)
                key(102)
                key(28)
                assert not marker.exists(), "filtered file was still activatable"
                click(900, 80)
                key(28)
                key(102)
                key(28)
                opened("zeta-file.txt")

                # Restore a useful preview and show the file context menu.
                key(38, ctrl=True)  # Ctrl+L clears query and restores location mode.
                key(1)
                click(690, 80)  # Grid
                click(790, 80)
                key(28)  # Name ascending
                key(102)
                time.sleep(.2)
                # Sidebar context menus target the clicked place without navigating first.
                click(70, 270, 273)  # Documents
                title("Home")
                key(28)  # Open
                title("Documents")
                click(70, 270, 273)
                key(108)
                key(28)  # Unpin
                title("Documents")  # Unpin does not navigate or delete the folder.
                assert (home / "Documents").is_dir()
                saved = (tmp / "state/rediwm/files-view").read_bytes()
                assert saved[0] == ord("3") and saved[3] & 2 and saved[4] == 1, saved
                click(70, 270)  # Downloads now occupies Documents' old row.
                title("Downloads")
                click(70, 140, 273)  # Home has Open and Properties, without Unpin.
                key(108)
                key(28)  # Properties opens a modal without navigating.
                title("Downloads")
                key(1)  # Close Properties before opening another menu.
                click(70, 140, 273)
                key(28)
                title("Home")

                # Repository discovery switches a grid preference to Name/Git.
                # Changes remain live across index updates and branch switches.
                repo = home / "git-project"
                repo.mkdir()
                def git(*args):
                    return subprocess.check_output(
                        ["git", "-c", "user.name=Files Test", "-c", "user.email=files@example.invalid",
                         "-c", "commit.gpgsign=false", "-C", str(repo), *args],
                        env=dict(env, GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL="/dev/null"),
                        stderr=subprocess.STDOUT)
                git("init", "-b", "main")
                (repo / "alpha.txt").write_text("original\nsecond\nthird\n")
                (repo / "beta.txt").write_text("deleted")
                git("add", ".")
                git("commit", "-m", "initial")
                git("checkout", "-b", "upstream")
                git("commit", "--allow-empty", "-m", "upstream change")
                git("checkout", "main")
                git("branch", "--set-upstream-to=upstream")
                git("commit", "--allow-empty", "-m", "local change")
                (repo / "alpha.txt").write_text("modified\n" * 10)
                git("add", "alpha.txt")
                (repo / "alpha.txt").write_text("modified\n" * 28)
                (repo / "beta.txt").unlink()
                (repo / "gamma.txt").write_text("added")
                git("add", "gamma.txt")
                diff_ran = tmp / "repository-diff-helper-ran"
                git("config", "diff.test.command", f"sh -c 'touch {diff_ran}'")
                git("config", "diff.test.textconv", f"sh -c 'touch {diff_ran}'")
                (repo / ".git/info/attributes").write_text("alpha.txt diff=test\n")
                # Git view lists changed files flat, from any depth, below the others.
                (repo / "zdir" / "inner").mkdir(parents=True)
                (repo / "zdir" / "inner" / "omega.txt").write_text("nested")
                key(38, ctrl=True)
                text(str(repo))
                key(28)
                title("git-project")
                time.sleep(.5)

                from PIL import Image
                def git_shot():
                    shot = tmp / "git.png"
                    shot.unlink(missing_ok=True)
                    action('screenshot', {"path": str(shot)})
                    box = request({"version": 1, "command": 'get_window_debug', "params": {"id": win["id"]}})["WindowDebug"]["client_box"]
                    with Image.open(shot) as full:
                        return full.convert("RGB").crop((box["x"], box["y"], box["x"] + box["width"], box["y"] + box["height"]))

                def reveal_git_card():
                    # The Git card is the last sidebar section; scroll it into view.
                    box = request({"version": 1, "command": 'get_window_debug', "params": {"id": win["id"]}})["WindowDebug"]["client_box"]
                    action('move_cursor', {"x": box["x"] + 100, "y": box["y"] + 300})
                    action('scroll', {"dx": 0, "dy": -1200})
                    time.sleep(.8)

                def badges(offset=190):
                    image = git_shot()
                    # List cell ends at width-34; Git defaults to 164px.
                    x = image.width - offset
                    return [image.getpixel((x, 170 + row * 38)) for row in range(3)]

                def changed_badges():
                    modified, deleted, added = badges()
                    return modified[1] > modified[0] + 12 and deleted[0] > deleted[1] + 12 and added[1] > added[0] + 12
                wait_for(changed_badges, "Git M/D/A badges did not appear")
                # Both line-count colours appear beside M: staged and working
                # changes combine into +28 -3, rather than double counting.
                def count_pixels(image, row=0):
                    return image.crop((image.width - 160, 158 + row * 38,
                                       image.width - 40, 182 + row * 38)).tobytes()
                raw = count_pixels(git_shot())
                pixels = zip(raw[0::3], raw[1::3], raw[2::3])
                assert any(g > r + 40 and g > b + 25 for r, g, b in pixels), "added-line count missing"
                pixels = zip(raw[0::3], raw[1::3], raw[2::3])
                assert any(r > g + 40 and r > b + 25 for r, g, b in pixels), "removed-line count missing"
                assert not diff_ran.exists(), "line counts ran a repository's diff helper"
                # Header divider moves the Git badge with it and never sorts.
                image = git_shot()
                box = request({"version": 1, "command": 'get_window_debug', "params": {"id": win["id"]}})["WindowDebug"]["client_box"]
                divider = image.width - 198
                action('move_cursor', {"x": box["x"] + divider, "y": box["y"] + 140})
                action('pointer_button', {"button": 272, "pressed": True})
                action('move_cursor', {"x": box["x"] + divider - 48, "y": box["y"] + 190})
                action('pointer_button', {"button": 272, "pressed": False})
                wait_for(lambda: (lambda p: p[1] > p[0] + 12)(git_shot().getpixel((image.width - 238, 170))),
                         "Name/Git divider did not resize the columns")
                action('move_cursor', {"x": box["x"] + divider - 48, "y": box["y"] + 140})
                action('pointer_button', {"button": 272, "pressed": True})
                action('move_cursor', {"x": box["x"] + divider, "y": box["y"] + 140})
                action('pointer_button', {"button": 272, "pressed": False})
                wait_for(changed_badges, "Git columns did not resize back")
                # Content edits refresh just the counts as well as the status.
                counts_before = count_pixels(git_shot())
                (repo / "alpha.txt").write_text("modified\n" * 29)
                wait_for(lambda: count_pixels(git_shot()) != counts_before, "line counts did not refresh after editing")
                (repo / "alpha.txt").write_text("modified\n" * 28)
                wait_for(lambda: count_pixels(git_shot()) == counts_before, "line counts did not return after editing")
                # No folder row precedes the files (they would push the badges down), and the
                # nested file is the fourth row, labelled with its path from the folder.
                def nested_row():
                    image = git_shot()
                    badge = image.getpixel((image.width - 190, 170 + 3 * 38))
                    return badge[1] > badge[0] + 12, image.crop((250, 170 + 3 * 38 - 12, 700, 170 + 3 * 38 + 12)).tobytes()
                assert nested_row()[0], "nested changed file was not listed flat"
                with_path = nested_row()[1]
                def toggle_full_paths():
                    click(900, 82)  # Filter: folders only, hidden, changed files, full paths
                    for _ in range(3):
                        key(108)
                    key(28)
                toggle_full_paths()
                wait_for(lambda: nested_row()[1] != with_path, "Show full paths did not change the Name column")
                toggle_full_paths()
                wait_for(lambda: nested_row()[1] == with_path, "Show full paths did not return")
                reveal_git_card()
                image = git_shot()
                # Empty points in the Git section use the plain sidebar surface.
                assert image.getpixel((12, 345)) == image.getpixel((5, 345)), "Git sidebar still has its red bar"
                assert image.getpixel((170, 345)) == image.getpixel((5, 345)), "Git sidebar still has its red highlight"
                if preview := os.environ.get("REDIWM_FILES_GIT_PREVIEW"):
                    git_shot().save(preview)
                # The Git View checkbox, left of the view buttons, shows the
                # repository as an ordinary folder when off and remembers that.
                prefs = tmp / "state/rediwm/files-view"
                checkbox_x = git_shot().width - 380
                click(checkbox_x, 82)
                wait_for(lambda: prefs.read_bytes()[4] == 0, "Git View checkbox did not turn off")
                wait_for(lambda: all(max(pixel) - min(pixel) < 30 for pixel in badges(offset=90)),
                         "Git badges stayed with Git View off")
                click(checkbox_x, 82)
                wait_for(lambda: prefs.read_bytes()[4] == 1, "Git View checkbox did not turn back on")
                wait_for(changed_badges, "Git badges did not return with Git View on")
                click(300, 215)  # Deleted beta.txt is retained but cannot open.
                key(28)
                assert not marker.exists(), "deleted tracked file was opened"
                key(46, ctrl=True)
                key(111)
                key(1)
                # Commit only changes metadata; alpha remains on disk unchanged.
                git("add", "-A")
                git("commit", "-m", "changes")
                def clean_badges():
                    return all(max(pixel) - min(pixel) < 30 for pixel in badges()[:2])
                wait_for(clean_badges, "Git index/commit did not refresh badges")
                reveal_git_card()
                before_branch = git_shot().crop((30, 300, 175, 510)).tobytes()
                git("checkout", "-b", "feature")
                wait_for(lambda: git_shot().crop((30, 300, 175, 510)).tobytes() != before_branch,
                         "branch switch did not refresh Git sidebar")
                # Worktrees use a .git file, and subfolders inherit repository state.
                worktree = home / "git-worktree"
                git("worktree", "add", "-b", "linked", str(worktree))
                (worktree / "nested").mkdir()
                (worktree / "nested" / "untracked.txt").write_text("new")
                key(38, ctrl=True)
                text(str(worktree / "nested"))
                key(28)
                title("nested")
                wait_for(lambda: (lambda pixel: pixel[1] > pixel[0] + 12)(badges()[0]),
                         "worktree subfolder did not show untracked status")
                reveal_git_card()
                click(75, 345)  # Repository card navigates to the worktree root.
                title("git-worktree")
                # The expanded card lists every branch; the last row creates one
                # and a branch row switches to it.
                def worktree_branch():
                    return subprocess.check_output(
                        ["git", "-C", str(worktree), "branch", "--show-current"],
                        env=dict(env, GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL="/dev/null")).decode().strip()
                assert worktree_branch() == "linked"
                reveal_git_card()
                click(75, 488)  # "New branch"
                text("topic")
                key(28)
                wait_for(lambda: worktree_branch() == "topic", "New branch row did not create and switch")
                reveal_git_card()
                # Alphabetical: feature, linked, main, topic, upstream, then "New branch".
                click(75, 376)
                wait_for(lambda: worktree_branch() == "linked", "branch row did not switch branches")
                # A folder from an archive or a USB stick brings its .git/config
                # along: opening it must not run the filter that config names.
                foreign = home / "foreign-repo"
                foreign.mkdir()
                ran = tmp / "foreign-filter-ran"
                def foreign_git(*args):
                    subprocess.check_output(
                        ["git", "-c", "user.name=Files Test", "-c", "user.email=files@example.invalid",
                         "-c", "commit.gpgsign=false", "-C", str(foreign), *args],
                        env=dict(env, GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL="/dev/null"),
                        stderr=subprocess.STDOUT)
                foreign_git("init", "-b", "main")
                (foreign / "notes.txt").write_text("tracked")
                foreign_git("add", ".")
                foreign_git("commit", "-m", "initial")
                (foreign / ".gitattributes").write_text("* filter=x\n")
                foreign_git("config", "filter.x.clean", f"sh -c 'touch {ran}; cat'")
                time.sleep(1.1)
                (foreign / "notes.txt").touch()  # Stat-dirty: status would compare contents.
                key(38, ctrl=True)
                text(str(foreign))
                key(28)
                title("foreign-repo")
                wait_for(lambda: "not showing Git status for" in (tmp / "rediwm-files.log").read_text(),
                         "Files did not refuse the repository's own filter")
                time.sleep(.5)
                assert not ran.exists(), "opening a folder ran its repository's filter command"
                key(38, ctrl=True)
                text(str(home))
                key(28)
                title("Home")
                time.sleep(.3)
                # Leaving Git restores the user's grid preference.
                assert (tmp / "state/rediwm/files-view").read_bytes()[1] == 0
                click(250, 160)
                key(28)
                title("Archive renamed")
                key(105, alt=True)
                title("Home")
                print("Git badges, deleted rows, live commits/branches, worktrees and view restoration passed.")

                # Archive browsing shares Files navigation, without unpacking on entry.
                archive_dir = tmp / "archive-check"
                archive_dir.mkdir()
                destination = tmp / "extracted"
                destination.mkdir()
                archive = archive_dir / "sample.zip"
                with zipfile.ZipFile(archive, "w") as z:
                    z.writestr("nested/item.txt", "archive member")
                    z.writestr("top.txt", "top level")
                key(38, ctrl=True)
                text(str(archive_dir))
                key(28)
                title("archive-check")
                time.sleep(.3)
                click(250, 160)
                key(57)  # Space browses the archive.
                title("sample.zip")
                time.sleep(.3)
                assert list(archive_dir.iterdir()) == [archive], "browsing extracted the archive"
                key(102)  # Home, then Enter opens the implicit nested folder.
                key(28)
                title("nested")
                time.sleep(.3)
                key(102)
                key(28)  # Open just one member through the existing opener.
                wait_for(marker.exists, "archive member did not open")
                member_path = Path(marker.read_text())
                assert member_path.read_text() == "archive member"
                assert not (member_path.parent.parent / "top.txt").exists()
                marker.unlink()
                key(49, ctrl=True)  # Read-only: New, Rename and Delete do nothing.
                key(60)
                key(111)
                key(103, alt=True)
                title("sample.zip")
                key(103, alt=True)
                title("archive-check")
                key(105, alt=True)
                title("sample.zip")
                key(106, alt=True)
                title("archive-check")
                time.sleep(.3)
                click(250, 160)
                click(250, 160)
                title("sample.zip")
                key(103, alt=True)
                title("archive-check")
                time.sleep(.3)

                # Extract to uses the real folder chooser, and its result starts the job.
                click(250, 160, 273)
                for _ in range(3):
                    key(108)
                key(28)
                def picker():
                    return next((w for w in request({'version': 1, 'command': 'windows'}).get("Windows", [])
                                 if w["app_id"] == "rediwm-file-chooser"), None)
                choice = wait_for(picker, "extraction folder picker did not open")
                action('focus_window', {"id": choice["id"]})
                key(1)
                wait_for(lambda: picker() is None, "folder picker did not cancel")
                assert list(destination.iterdir()) == []
                action('focus_window', {"id": win["id"]})
                click(250, 160, 273)
                for _ in range(3):
                    key(108)
                key(28)
                choice = wait_for(picker, "folder picker did not reopen")
                action('focus_window', {"id": choice["id"]})
                key(38, ctrl=True)
                text(str(destination))
                key(28)
                time.sleep(.3)
                key(15)  # File view -> filename; Enter accepts the current folder.
                key(28)
                wait_for(lambda: (destination / "nested/item.txt").exists(), "Extract to failed")
                assert (destination / "top.txt").read_text() == "top level"
                action('focus_window', {"id": win["id"]})
                click(250, 160, 273)
                key(108)
                key(108)
                key(28)
                wait_for(lambda: (archive_dir / "nested/item.txt").exists(), "Extract in place failed")
                assert archive.exists()
                print("Archive browsing, member opening, read-only navigation and both extraction actions passed.")

                if preview := os.environ.get("REDIWM_FILES_PREVIEW"):
                    click(250, 160, 273)
                    preview = Path(preview)
                    preview.unlink(missing_ok=True)
                    action('screenshot', {"path": str(preview)})
                    from PIL import Image
                    with Image.open(preview) as image:
                        image.crop((win["x"], win["y"], win["x"] + win["width"],
                                    win["y"] + win["height"])).save(preview)
                print("Toolbar creation, context menus, search, sorting, filtering and list hit testing passed.")
        except Exception:
            for log in tmp.glob("*.log"):
                print(log.read_text()[-5000:])
            raise
        finally:
            for p in reversed(processes):
                if p.poll() is None:
                    p.terminate()
                    p.wait(timeout=5)


if __name__ == "__main__":
    run()

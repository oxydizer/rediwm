#!/usr/bin/env python3
"""Text editor workflows in a private headless compositor; never uses the host session."""
import os
from pathlib import Path
import subprocess
import tempfile
import time
from ipc_client import IPCClient, ROOT
from files_browser import wait_for


def run():
    os.umask(0o077)
    with tempfile.TemporaryDirectory(prefix="rediwm-editor-test-") as directory:
        tmp = Path(directory)
        docs = tmp / "Documents"
        docs.mkdir()
        first = docs / "alpha.txt"
        first.write_bytes(b"\xef\xbb\xbfhello\r\nworld\r\n")
        second = docs / "beta.txt"
        second.write_text("second document\n")
        (docs / "binary.txt").write_bytes(b"binary\x00data")
        from PIL import Image
        Image.new("RGB", (40, 40), "red").save(docs / "z image.png")
        config = tmp / "config.toml"
        config.write_text('[compositor]\nxwayland = false\n')
        env = dict(os.environ, HOME=directory, XDG_RUNTIME_DIR=directory,
                   XDG_CONFIG_HOME=str(tmp / "config"), XDG_DATA_HOME=str(tmp / "data"),
                   XDG_CACHE_HOME=str(tmp / "cache"), XDG_STATE_HOME=str(tmp / "state"),
                   REDIWM_CONFIG=str(config), WLR_BACKENDS="headless", REDIWM_FILES_DEVICES="0", WLR_HEADLESS_OUTPUTS="1",
                   WLR_RENDERER=os.environ.get("REDIWM_TEST_RENDERER", "gles2"),
                   REDIWM_SCALE=os.environ.get("REDIWM_TEST_SCALE", "1"), DBUS_SESSION_BUS_ADDRESS="")
        env.pop("WAYLAND_DISPLAY", None)
        env.pop("REDIWM_SOCKET", None)
        processes = []

        def start(binary, *args):
            log = (tmp / f"{binary}-{len(processes)}.log").open("w")
            proc = subprocess.Popen([str(ROOT / "zig-out/bin" / binary), *map(str, args)], env=env, stdout=log, stderr=log)
            log.close()
            processes.append(proc)
            return proc

        try:
            from input_protocols import compile_client
            compile_client(tmp)
            start("rediwm")
            sock = wait_for(lambda: next(tmp.glob("rediwm-*.sock"), None), "IPC unavailable")
            env["WAYLAND_DISPLAY"] = next(p.name for p in tmp.glob("wayland-*") if not p.name.endswith(".lock"))
            with IPCClient(sock) as ipc:
                def windows(app):
                    return [w for w in ipc.get_windows() if w["app_id"] == app]

                def editor():
                    return next(iter(windows("rediwm-editor")), None)

                def title(prefix):
                    return wait_for(lambda: (w := editor()) and w["title"].startswith(prefix) and w, "editor title: " + prefix)

                def key(code, ctrl=False, shift=False):
                    for modifier, active in ((29, ctrl), (42, shift)):
                        if active:
                            ipc.action('key', {"keycode": modifier, "pressed": True})
                    for pressed in (True, False):
                        ipc.action('key', {"keycode": code, "pressed": pressed})
                    for modifier, active in ((42, shift), (29, ctrl)):
                        if active:
                            ipc.action('key', {"keycode": modifier, "pressed": False})
                    time.sleep(.12)

                def click(window, x, y):
                    box = ipc.get_window_debug(window["id"])["client_box"]
                    ipc.move_cursor(round(box["x"] + x), round(box["y"] + y))
                    for pressed in (True, False):
                        ipc.action('pointer_button', {"button": 272, "pressed": pressed})
                    time.sleep(.15)

                def menu_action(row):
                    win = editor()
                    box = ipc.get_window_debug(win["id"])["client_box"]
                    # CSD hosts the menu in its header; SSD uses the tab bar.
                    click(win, box["width"] - (132 if csd else 18), 23)
                    separators = int(row >= 2) + int(row >= 4)
                    click(win, box["width"] - 200, (52 if csd else 44) + 6 + row * 32 + separators * 7 + 16)

                def window_control(offset):
                    win = editor()
                    debug = ipc.get_window_debug(win["id"])
                    box = debug["client_box" if csd else "chrome_box"]
                    client = debug["client_box"]
                    click(win, box["x"] + box["width"] - offset - client["x"],
                          box["y"] + (23 if csd else debug["titlebar_height"] / 2) - client["y"])

                start("rediwm-files", docs)
                files = wait_for(lambda: next(iter(windows("rediwm-files")), None), "Files maps")
                ipc.focus_window(files["id"])
                time.sleep(.3)
                key(107)  # Text opening must also work while an image preview is open.
                key(57)
                wait_for(lambda: windows("rediwm-images"), "image preview maps")
                ipc.focus_window(files["id"])
                key(102)
                key(57)
                win = title("alpha.txt")
                csd = "REDIWM_EDITOR_FORCE_CSD" in env
                debug = ipc.get_window_debug(win["id"])
                assert debug["decoration_mode"] == ("client" if csd else "server"), debug
                if not csd:
                    files_debug = ipc.get_window_debug(files["id"])
                    for field in ("titlebar_height", "frame_border", "frame_radius", "footer_height"):
                        assert debug[field] == files_debug[field], (field, debug, files_debug)
                assert "(1/1)" in win["title"]
                ipc.focus_window(win["id"])
                key(107, ctrl=True)  # end of document
                key(45)  # x
                title("* alpha.txt")
                key(57)  # a space is text, not close
                key(44, ctrl=True)  # undo space
                key(44, ctrl=True)  # undo x -> saved point
                title("alpha.txt")
                key(21, ctrl=True)  # redo x
                title("* alpha.txt")
                menu_action(2)  # Save through the application menu.
                wait_for(lambda: first.read_bytes() == b"\xef\xbb\xbfhello\r\nworld\r\nx", "save bytes and BOM/CRLF")
                title("alpha.txt")
                print("Space opens text; typing, undo/redo and lossless save", flush=True)

                ipc.focus_window(files["id"])
                key(106)  # next file in grid
                key(57)
                win = title("beta.txt")
                assert len(windows("rediwm-editor")) == 1 and "(2/2)" in win["title"], win
                key(57)  # focus must have moved from Files to editor
                title("* beta.txt")
                key(44, ctrl=True)
                title("beta.txt")
                helper = start("rediwm-editor", first)
                helper.wait(timeout=5)
                win = title("alpha.txt")
                assert "(1/2)" in win["title"], win
                ipc.focus_window(win["id"])
                key(109, ctrl=True)
                title("beta.txt")
                key(30, ctrl=True)
                key(46, ctrl=True)
                menu_action(0)  # New through the application menu
                key(47, ctrl=True)
                title("* Untitled")
                print("one window, tabs, focus handoff, duplicate open and clipboard", flush=True)

                key(31, ctrl=True)
                chooser = wait_for(lambda: next(iter(windows("rediwm-file-chooser")), None), "Save As chooser")
                ipc.focus_window(chooser["id"])
                key(30, ctrl=True)
                ipc.type_text("saved.txt")
                key(28)
                wait_for(lambda: not windows("rediwm-file-chooser"), "chooser closes")
                saved = tmp / "saved.txt"
                wait_for(lambda: saved.exists(), "new file saved")
                assert saved.read_text() == "second document\n"
                win = title("saved.txt")
                ipc.focus_window(win["id"])
                key(107, ctrl=True)
                key(45)
                key(17, ctrl=True)  # unsaved close
                assert editor(), "dirty tab closed without confirmation"
                key(1)  # cancel
                title("* saved.txt")
                saved.write_text("external change")
                key(31, ctrl=True)
                time.sleep(.25)
                assert saved.read_text() == "external change"
                title("* saved.txt")
                key(17, ctrl=True)
                box = ipc.get_window_debug(editor()["id"])["client_box"]
                header = 46 if csd else 0
                click(editor(), (box["width"]-420)/2+200, (box["height"]-header-170)/2+130+header)
                title("beta.txt")
                print("existing Save As dialog, close cancellation, discard and external-change protection", flush=True)

                # Real external clipboard transfers, including delayed delivery.
                if subprocess.run(["sh", "-c", "command -v wl-copy >/dev/null"], env=env).returncode == 0:
                    owner = subprocess.Popen(["wl-copy", "--foreground", "clipboard snow 雪"], env=env, stderr=subprocess.DEVNULL)
                    processes.append(owner)
                    time.sleep(.15)
                    ipc.focus_window(editor()["id"])
                    key(30, ctrl=True)
                    key(47, ctrl=True)
                    title("* beta.txt")
                    key(31, ctrl=True)
                    wait_for(lambda: second.read_text() == "clipboard snow 雪", "external UTF-8 clipboard")
                    print("external Wayland clipboard", flush=True)

                key(33, ctrl=True)  # Find the selected word and replace it.
                ipc.type_text("snow" if "snow" in second.read_text() else "document")
                key(28)
                key(1)
                key(45)
                title("* beta.txt")
                key(44, ctrl=True)
                title("beta.txt")
                print("find, selection replacement and undo", flush=True)

                # Replace one and all through the real fields and buttons. A
                # replacement containing its query must not be searched again.
                key(30, ctrl=True)
                ipc.type_text("cat cat cafe cat")
                key(31, ctrl=True)
                wait_for(lambda: second.read_text() == "cat cat cafe cat", "replacement fixture saved")
                key(35, ctrl=True)  # Ctrl+H
                ipc.type_text("cat")
                key(15)  # Tab focuses replacement
                ipc.type_text("catfish")
                if output := os.environ.get("REDIWM_EDITOR_REPLACE_PREVIEW"):
                    ipc.screenshot(path=output)
                key(28)  # Replace current/next match
                key(31, ctrl=True)
                wait_for(lambda: second.read_text() == "catfish cat cafe cat", "replace one")
                key(44, ctrl=True)  # Undo while the replacement field has focus
                key(31, ctrl=True)
                wait_for(lambda: second.read_text() == "cat cat cafe cat", "replace-one undo")
                box = ipc.get_window_debug(editor()["id"])["client_box"]
                click(editor(), box["width"] - 76, header + 99)  # Replace All
                key(31, ctrl=True)
                wait_for(lambda: second.read_text() == "catfish catfish cafe catfish", "replace all without rescanning replacements")
                key(44, ctrl=True)
                key(31, ctrl=True)
                wait_for(lambda: second.read_text() == "cat cat cafe cat", "replace-all single undo")
                key(21, ctrl=True)
                key(31, ctrl=True)
                wait_for(lambda: second.read_text() == "catfish catfish cafe catfish", "replace-all redo")
                key(1)
                menu_action(5)  # Replace is also discoverable in the menu
                ipc.type_text("catfish")
                key(15)
                key(14)  # Empty replacement deletes every match
                key(28, ctrl=True)
                key(31, ctrl=True)
                wait_for(lambda: second.read_text() == "  cafe ", "replace all with empty text")
                key(35, ctrl=True)
                ipc.type_text("missing")
                key(15)
                ipc.type_text("unused")
                key(28, ctrl=True)
                key(31, ctrl=True)
                title("beta.txt")
                assert second.read_text() == "  cafe ", "no-match replace changed text"
                key(1)
                print("replace one/all, empty replacement, no match and atomic undo/redo", flush=True)

                # Drive the actual text-input-v3 client with the existing IM peer.
                im_log = tmp / "ime.log"
                with im_log.open("w") as log:
                    im = subprocess.Popen([str(tmp / "protocol-client"), "ime"], env=env,
                                          stdin=subprocess.PIPE, stdout=log, stderr=log, text=True)
                processes.append(im)
                wait_for(lambda: "ready" in im_log.read_text(), "IME ready")
                def im_send(command):
                    previous = im_log.read_text().count("ack " + command)
                    im.stdin.write(command + "\n")
                    im.stdin.flush()
                    wait_for(lambda: im_log.read_text().count("ack " + command) > previous, "IME " + command)
                im_send("method")
                wait_for(lambda: "activate\n" in im_log.read_text(), "editor enables IME")
                ipc.focus_window(editor()["id"])
                key(107, ctrl=True)
                ime_original = second.read_text()
                im_send("commit-only")
                title("* beta.txt")
                key(31, ctrl=True)
                wait_for(lambda: second.read_text() == ime_original + "final", "IME commit saved")
                # Preedit, surrounding deletion, commit, and undo are one edit.
                key(30, ctrl=True)
                ipc.type_text("hello")
                key(102)
                for _ in range(3): key(106)
                im_send("compose")
                key(31, ctrl=True)
                wait_for(lambda: second.read_text() == "hcomposedo", "IME delete and commit")
                im_send("commit-only")
                key(31, ctrl=True)
                wait_for(lambda: second.read_text() == "hcomposedfinalo", "IME replaces preedit")
                im.terminate()
                im.wait(timeout=5)
                print("text-input-v3 composition", flush=True)

                start("rediwm-editor", docs / "binary.txt")
                time.sleep(.4)
                assert "(2/2)" in editor()["title"], editor()
                if output := os.environ.get("REDIWM_EDITOR_PREVIEW"):
                    ipc.screenshot(path=output)
                # Exercise the shared chrome and the fallback client controls.
                window_control(56)
                wait_for(lambda: editor()["is_maximized"], "header maximizes")
                time.sleep(.3)
                window_control(56)
                wait_for(lambda: not editor()["is_maximized"], "header restores")
                time.sleep(.3)
                window_control(88)
                wait_for(lambda: editor()["is_minimized"], "header minimizes")
                ipc.restore(editor()["id"])
                ipc.focus_window(editor()["id"])
                time.sleep(.3)
                window_control(24)  # close all clean tabs
                wait_for(lambda: not windows("rediwm-editor"), "editor closes")
                print("binary rejection and clean window close", flush=True)

                # Unsaved text outlives a kill, a signal and closing the window.
                import json, signal
                drafts = tmp / "state/rediwm/editor-drafts"

                def kept():
                    try:
                        return json.loads((drafts / "session.json").read_text())["tabs"]
                    except (OSError, ValueError):
                        return None

                def gone(proc):
                    wait_for(lambda: proc.poll() is not None and not windows("rediwm-editor"), "editor exits")

                notes = docs / "draft-notes.txt"
                notes.write_text("on disk\n")
                proc = start("rediwm-editor", notes)
                win = title("draft-notes.txt")
                ipc.focus_window(win["id"])
                key(107, ctrl=True)
                ipc.type_text("typed in file")
                key(49, ctrl=True)  # new tab
                ipc.type_text("never saved note")
                title("* Untitled")
                wait_for(lambda: len(kept() or []) == 2, "drafts written after a pause in typing")
                assert oct((drafts / "session.json").stat().st_mode & 0o777) == "0o600"
                assert oct(drafts.stat().st_mode & 0o777) == "0o700"
                proc.send_signal(signal.SIGKILL)
                proc.wait()
                wait_for(lambda: not windows("rediwm-editor"), "killed editor unmaps")
                assert notes.read_text() == "on disk\n"

                proc = start("rediwm-editor")
                win = title("* Untitled")
                assert "(2/2)" in win["title"], win["title"]
                ipc.focus_window(win["id"])
                key(104, ctrl=True)  # previous tab: the file, edited, still unsaved
                title("* draft-notes.txt")
                key(31, ctrl=True)
                wait_for(lambda: notes.read_bytes() == b"on disk\ntyped in file", "restored file draft saves over its file")
                title("draft-notes.txt")
                wait_for(lambda: len(kept() or []) == 1, "a saved tab leaves the drafts")
                assert len(list(drafts.glob("*.txt"))) == 1

                # Closing the window asks about what is unsaved, like closing a
                # tab; the drafts are for a session that ends some other way.
                ipc.action("close_window", {"id": editor()["id"]})
                time.sleep(.3)
                assert editor(), "window closed on unsaved work without asking"
                key(1)  # cancel
                win = title("* Untitled")
                assert "(1/1)" in win["title"], win["title"]
                ipc.focus_window(win["id"])
                ipc.type_text(" and more")
                time.sleep(.3)
                proc.terminate()  # SIGTERM before the pause: written on the way out
                gone(proc)
                assert any(b"never saved note and more" in p.read_bytes() for p in drafts.glob("*.txt")), "SIGTERM flushed the last typing"
                proc = start("rediwm-editor")
                win = title("* Untitled")
                ipc.focus_window(win["id"])

                # Discarding on purpose is the only way to lose it.
                key(17, ctrl=True)
                box = ipc.get_window_debug(editor()["id"])["client_box"]
                header = 46 if csd else 0
                click(editor(), (box["width"]-420)/2+200, (box["height"]-header-170)/2+130+header)
                gone(proc)
                assert kept() == [] and not list(drafts.glob("*.txt")), "discarded draft is removed"
                proc = start("rediwm-editor")
                title("Untitled")
                assert "(1/1)" in editor()["title"] and not editor()["title"].startswith("*")
                key(17, ctrl=True)
                gone(proc)
                print("unsaved text survives kill and signal, and closing asks, until discarded", flush=True)

                # Many tabs share the strip down to a minimum width, then it scrolls.
                proc = start("rediwm-editor")
                win = title("Untitled")
                ipc.focus_window(win["id"])
                for _ in range(11):
                    key(49, ctrl=True)
                assert "(12/12)" in title("Untitled")["title"]
                box = ipc.get_window_debug(editor()["id"])["client_box"]
                header = 46 if csd else 0
                strip = box["width"] - (40 if csd else 80)
                assert strip / 12 < 112 < 12 * 112 - strip + 1, strip
                # Away from the close buttons, which sit at the right of each tab.
                click(editor(), strip - 60, header + 18)
                assert "(12/12)" in title("Untitled")["title"], "the newest tab is scrolled into view"
                reached = []
                for dy in (2000, -2000):
                    ipc.move_cursor(round(box["x"] + 300), round(box["y"] + header + 18))
                    ipc.scroll(0, dy)
                    time.sleep(.2)
                    click(editor(), 60, header + 18)
                    reached.append(int(editor()["title"].rsplit("(", 1)[1].split("/")[0]))
                far = int((60 + 12 * 112 - strip) // 112) + 1
                assert sorted(reached) == [1, far], ("the wheel scrolls the strip to both ends", reached, far)
                for _ in range(12):
                    key(17, ctrl=True)
                gone(proc)
                print("tabs share the strip, shrink to a minimum and scroll", flush=True)

                # Beyond the old 16 MiB limit, and past the size where a save is
                # copied: opening must not lay the whole text out, End must reach
                # the real end, and the file written must be exact.
                large = docs / "large.log"
                chunk = b"".join(b"line %d: the quick brown fox jumps over the lazy dog\n" % n for n in range(20000))
                with large.open("wb") as handle:
                    handle.write(b"\xef\xbb\xbf")
                    for _ in range(40):
                        handle.write(chunk)
                original = large.read_bytes()
                assert len(original) > 40 * 1024 * 1024
                start("rediwm-editor", large)
                win = title("large.log")
                ipc.focus_window(win["id"])
                key(107, ctrl=True)
                ipc.type_text("END")
                title("* large.log")
                key(31, ctrl=True)
                wait_for(lambda: large.read_bytes() == original + b"END", "large file saved exactly with its BOM")
                title("large.log")
                key(17, ctrl=True)
                wait_for(lambda: not windows("rediwm-editor"), "large file tab closes")
                print("files beyond 16 MiB open, jump to the end and save exactly", flush=True)
                # Real held-key delivery, Unicode word selection and drag extension.
                inputs = docs / "input.txt"
                inputs.write_text("alpha café omega")
                start("rediwm-editor", inputs)
                win = title("input.txt")
                ipc.focus_window(win["id"])
                ipc.wait_for("window_geometry_settled", window_id=win["id"])
                ipc.wait_for_frame()
                time.sleep(.15)
                header = 46 if csd else 0

                def save_input():
                    key(31, ctrl=True)
                    title("input.txt")
                    return inputs.read_text()

                def hold(code, duration=.85, ctrl=False):
                    if ctrl: ipc.key(29, True)
                    ipc.key(code, True)
                    time.sleep(duration)
                    ipc.key(code, False)
                    if ctrl: ipc.key(29, False)
                    time.sleep(.1)

                # A click near the centre of café must select only that word.
                # Use the rendered glyphs to find its extent across fonts/scales.
                from PIL import Image
                preview = tmp / "word-selection.png"
                ipc.screenshot(path=str(preview))
                image = Image.open(preview).convert("RGB")
                factor = image.width / ipc.get_outputs()[0]["logical_width"]
                box = ipc.get_window_debug(win["id"])["client_box"]
                y0 = round((box["y"] + header + 40) * factor)
                y1 = round((box["y"] + header + 64) * factor)
                columns = []
                for x in range(round((box["x"]+16)*factor), round((box["x"]+220)*factor)):
                    if any(min(image.getpixel((x, y))) > 155 for y in range(y0, y1)):
                        if not columns or x > columns[-1][-1] + 1: columns.append([x])
                        else: columns[-1].append(x)
                # Derive the monospace cell width from the first five glyphs.
                assert len(columns) >= 9, (columns, box)
                cell = (columns[4][0] - columns[0][0]) / 4 / factor
                x = 16 + cell * 8
                y = header + 50
                click(win, x, y)
                click(win, x+1, y)
                key(45)  # replace selected café with x
                assert save_input() == "alpha x omega", inputs.read_text()
                key(44, ctrl=True)
                assert save_input() == "alpha café omega"
                for end_cell, expected in ((13, "alpha x"), (2, "x omega")):
                    click(win, x, y)
                    box = ipc.get_window_debug(win["id"])["client_box"]
                    ipc.move_cursor(round(box["x"]+x+1), round(box["y"]+y))
                    ipc.action('pointer_button', {"button": 272, "pressed": True})
                    ipc.move_cursor(round(box["x"]+16+cell*end_cell), round(box["y"]+y))
                    ipc.action('pointer_button', {"button": 272, "pressed": False})
                    key(45)
                    assert save_input() == expected
                    key(44, ctrl=True)
                    assert save_input() == "alpha café omega"
                print("double-click selects a Unicode word and drags by whole words", flush=True)

                key(107, ctrl=True)
                hold(28)  # Return
                value = save_input()
                assert value.startswith("alpha café omega") and value.count("\n") >= 3, repr(value)
                time.sleep(.5)
                assert save_input() == value, "key repeat continued after release"
                hold(15)  # Tab
                value = save_input()
                assert value.count("\t") >= 3, repr(value)
                hold(30)  # a
                value = save_input()
                assert value.endswith("aaa"), repr(value)
                hold(14)  # Backspace
                assert len(save_input()) < len(value)-2
                key(30, ctrl=True)
                ipc.type_text("one two three four five")
                key(107, ctrl=True)
                hold(105, ctrl=True)  # Ctrl+Left reaches the first word
                key(45)
                assert save_input() == "xone two three four five"
                key(107, ctrl=True)
                hold(14, ctrl=True)  # Ctrl+Backspace removes words repeatedly
                assert len(save_input()) < 10
                # Changing focus cancels a held key even when its release is
                # delivered to the newly focused client.
                key(30, ctrl=True)
                key(14)
                ipc.key(30, True)
                time.sleep(.5)
                start("rediwm-files", docs)
                other = wait_for(lambda: next(iter(windows("rediwm-files")), None), "repeat focus target")
                ipc.focus_window(other["id"])
                time.sleep(.2)
                ipc.key(30, False)
                ipc.focus_window(win["id"])
                stopped = save_input()
                time.sleep(.5)
                assert save_input() == stopped, "held key survived focus loss"
                print("held Enter, Tab, text, deletion and word navigation; release and focus cancellation", flush=True)
                if env["WLR_RENDERER"] == "gles2":
                    lines = (tmp / "rediwm-0.log").read_text().splitlines()
                    for line in lines:
                        if "GL renderer" in line or "GLES2 renderer" in line:
                            print(line, flush=True)
        except Exception:
            for path in tmp.glob("*.log"):
                print(f"--- {path.name} ---\n{path.read_text()[-5000:]}")
            raise
        finally:
            for proc in reversed(processes):
                if proc.poll() is None:
                    proc.terminate()
            for proc in reversed(processes):
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait()

if __name__ == "__main__":
    run()

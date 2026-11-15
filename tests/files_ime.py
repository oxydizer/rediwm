#!/usr/bin/env python3
"""text-input-v3 (what fcitx5 speaks) in Files' own single-line fields.

The terminal drawer had an input method; search, the location bar, dialog
fields and the chooser name must compose too. Drives a real protocol peer
against a private headless compositor and checks the filesystem after each
commit.
"""
import os
from pathlib import Path
import subprocess
import tempfile
import time

from ipc_client import IPCClient, ROOT, spawn_compositor, stop_process
from files_browser import wait_for


def run():
    os.umask(0o077)
    with tempfile.TemporaryDirectory(prefix="rediwm-files-ime-") as directory:
        tmp = Path(directory)
        home = tmp / "Home"
        docs = home / "Documents" / "文档"
        docs.mkdir(parents=True)
        (docs / "中文.txt").write_text("中文内容")
        (home / "另一个").mkdir()
        (home / "alpha.txt").write_text("alpha")

        from input_protocols import compile_client
        compile_client(tmp)

        compositor, _ = spawn_compositor(
            tmp, scale=os.environ.get("REDIWM_TEST_SCALE", "1"),
            config_content="[compositor]\nxwayland = false\n")
        clients = []
        try:
            sock = wait_for(lambda: next(tmp.glob("rediwm-*.sock"), None), "IPC unavailable")
            display = next(p.name for p in tmp.glob("wayland-*") if not p.name.endswith(".lock"))
            env = dict(os.environ, HOME=str(home), XDG_RUNTIME_DIR=str(tmp),
                       XDG_CONFIG_HOME=str(tmp / "config"), XDG_DATA_HOME=str(tmp / "data"),
                       XDG_CACHE_HOME=str(tmp / "cache"), XDG_STATE_HOME=str(tmp / "state"),
                       REDIWM_FILES_DEVICES="0", DBUS_SESSION_BUS_ADDRESS="",
                       WAYLAND_DISPLAY=display)
            env.pop("REDIWM_SOCKET", None)

            ime_log = tmp / "ime.log"
            with ime_log.open("w") as log:
                ime = subprocess.Popen([str(tmp / "protocol-client"), "ime"], env=env,
                                       stdin=subprocess.PIPE, stdout=log, stderr=log, text=True)
            clients.append(ime)
            wait_for(lambda: "ready" in ime_log.read_text(), "IME peer did not start")

            def ime_text():
                return ime_log.read_text()

            def ime_send(command):
                previous = ime_text().count("ack " + command)
                ime.stdin.write(command + "\n")
                ime.stdin.flush()
                wait_for(lambda: ime_text().count("ack " + command) > previous,
                         "IME " + command.split(" ", 1)[0])

            def ime_surrounds():
                return ime_text().count("surround ")

            def wait_surround(text):
                wait_for(lambda: ("surround " + text) in ime_text(),
                         "IME was not told about " + text)

            ime_send("method")

            files_log = (tmp / "rediwm-files.log").open("w")
            files = subprocess.Popen([str(ROOT / "zig-out/bin/rediwm-files"), str(home)],
                                     env=env, stdout=files_log, stderr=files_log)
            files_log.close()
            clients.append(files)

            with IPCClient(sock) as ipc:
                def window():
                    return next((w for w in ipc.get_windows() if w["app_id"] == "rediwm-files"), None)

                def title(value):
                    wait_for(lambda: (w := window()) and w["title"] == value + " — RediWM Files",
                             "window did not show " + value)

                def key(code, ctrl=False):
                    if ctrl:
                        ipc.key(29, True)
                    ipc.key_down_up(code)
                    if ctrl:
                        ipc.key(29, False)
                    time.sleep(.15)

                win = wait_for(window, "Files did not map")
                ipc.focus_window(win["id"])
                time.sleep(.3)
                assert window()["is_focused"]

                # Location bar: composition replaces the selected path, the
                # committed UTF-8 path navigates, and the IM gets the new
                # surrounding text back.
                before = ime_surrounds()
                key(38, ctrl=True)  # Ctrl+L
                wait_for(lambda: ime_surrounds() > before, "location bar was not advertised to the IME")
                assert "activate\n" in ime_text(), "Files did not enable text input"
                ime_send("preedit-text 拼")  # Local composition, not field text.
                time.sleep(.2)
                ime_send("commit-text " + str(docs))
                wait_surround(str(docs))
                key(28)
                title("文档")

                # Search box: the committed query must filter, so F2 below
                # renames the only match, 中文.txt.
                before = ime_surrounds()
                key(33, ctrl=True)  # Ctrl+F
                wait_for(lambda: ime_surrounds() > before, "search box was not advertised to the IME")
                ime_send("preedit-text 中")
                time.sleep(.2)
                ime_send("commit-text 中文")
                wait_surround("中文")
                key(28)  # Leave the search field; the match is selected.
                time.sleep(.3)

                # Rename dialog: the selected stem is replaced by composed text.
                before = ime_surrounds()
                key(60)  # F2
                wait_for(lambda: ime_surrounds() > before, "rename field was not advertised to the IME")
                wait_surround("中文.txt")
                ime_send("preedit-text 新")  # Replacing the selected stem drops it first.
                time.sleep(.2)
                ime_send("commit-text 中文文件")
                wait_surround("中文文件.txt")
                key(28)
                wait_for(lambda: (docs / "中文文件.txt").exists(), "IME rename did not apply")
                assert not (docs / "中文.txt").exists()
                print("PASS: text-input-v3 composition in the location bar, search box and rename dialog")

                # Losing keyboard focus must disable the text input. Left
                # enabled, the compositor sees no state change when the surface
                # is entered again and never re-activates the input method:
                # composition silently stops for every window switch.
                def ime_events(name):
                    return sum(1 for line in ime_text().splitlines() if line == name or line.startswith(name + " "))

                advertised = ime_text().count("surround " + str(docs))
                key(38, ctrl=True)  # Ctrl+L: the location bar takes composition again
                wait_for(lambda: ime_text().count("surround " + str(docs)) > advertised,
                         "location bar was not advertised to the IME again")
                activations = ime_events("activate")
                deactivations = ime_events("deactivate")
                dones = ime_events("im-done")
                calculator_log = (tmp / "rediwm-calculator.log").open("w")
                calculator = subprocess.Popen([str(ROOT / "zig-out/bin/rediwm-calculator")], env=env,
                                              stdout=calculator_log, stderr=calculator_log)
                calculator_log.close()
                clients.append(calculator)
                calculator_window = wait_for(
                    lambda: next((w for w in ipc.get_windows() if w["app_id"] == "rediwm-calculator"), None),
                    "calculator did not map")
                ipc.focus_window(calculator_window["id"])
                wait_for(lambda: ime_events("deactivate") > deactivations,
                         "IME was not deactivated when Files lost focus")
                # The deactivation's done must not be mistaken for the state
                # the re-activated input receives.
                wait_for(lambda: ime_events("im-done") > dones, "IME deactivation did not complete")
                dones = ime_events("im-done")
                ipc.focus_window(win["id"])
                wait_for(lambda: ime_events("activate") > activations,
                         "Files did not re-activate the IME after focus returned")
                wait_for(lambda: ime_events("im-done") > dones, "IME state did not arrive after focus returned")
                ime_send("commit-text " + str(home / "另一个"))
                key(28)
                title("另一个")
                print("PASS: the input method is re-activated after focus returns")

                # The terminal drawer keeps its own composition path: the
                # commit is typed into the PTY, not pasted or shell syntax.
                before = ime_surrounds()
                key(62)  # F4 opens the drawer.
                wait_for(lambda: ime_surrounds() > before,
                         "terminal drawer was not advertised to the IME")
                time.sleep(1)  # Let the shell reach its prompt.
                scratch = home / "terminal-中文"
                ime_send("commit-text touch " + str(scratch))
                time.sleep(.2)
                key(28)  # Enter runs the committed command.
                wait_for(scratch.exists, "terminal IME commit did not reach the shell")
                print("PASS: the Files terminal still types IME commits into the PTY")

                if output := os.environ.get("REDIWM_FILES_IME_SCREENSHOT"):
                    ipc.action("screenshot", {"path": output})
                assert files.poll() is None, "Files exited"
        except Exception:
            for path in (tmp / "ime.log", tmp / "rediwm-files.log", tmp / "compositor.log"):
                if path.exists():
                    print(path.name + ":\n" + path.read_text()[-4000:])
            raise
        finally:
            for process in reversed(clients):
                stop_process(process)
            stop_process(compositor)


if __name__ == "__main__":
    run()

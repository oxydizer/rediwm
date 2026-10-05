#!/usr/bin/env python3
"""Launch feedback: the bundled phinger theme loads, and a starting app turns
the default arrow into the animated progress cursor until its window maps or
its process fails."""
from pathlib import Path
import shlex
import tempfile
import time

from desktop_zoom import build_client, wait_for
from ipc_client import IPCClient, spawn_compositor, stop_process


def run():
    with tempfile.TemporaryDirectory(prefix="rediwm-launch-feedback-") as directory:
        tmp = Path(directory)
        build_client(tmp)
        apps = tmp / "data/applications"
        apps.mkdir(parents=True)
        client = shlex.quote(str(tmp / "client"))
        # The window's app id differs from the entry: only the pid chain
        # (sh execs the client) can match it.
        (apps / "slow-window.desktop").write_text(
            "[Desktop Entry]\nType=Application\nName=Slow Window\n"
            f"Exec=sh -c \"sleep 1.5; exec {client} --app-id unrelated.app\"\n")
        (apps / "broken.desktop").write_text(
            "[Desktop Entry]\nType=Application\nName=Broken\nExec=sh -c \"sleep 0.5; exit 3\"\n")
        (apps / "windowless.desktop").write_text(
            "[Desktop Entry]\nType=Application\nName=Windowless\nExec=sleep 30\n")
        proc, log = spawn_compositor(
            tmp,
            config_content='[input]\ncursor_theme = "phinger-cursors-dark"\n[compositor]\nxwayland = false\n',
            env_extra={"XDG_DATA_HOME": str(tmp / "data"), "XDG_DATA_DIRS": str(tmp / "empty"),
                       "XDG_CACHE_HOME": str(tmp / "cache"), "XCURSOR_THEME": "",
                       "XCURSOR_PATH": str(tmp / "no-icons")})
        try:
            with IPCClient(tmp) as ipc:
                ipc.wait_for("catalog_published", timeout_ms=10000)

                def state():
                    s = ipc.get_input_state()
                    return s["cursor_source"], s["cursor_name"]

                def launch(name):
                    ipc.action('launch_app', {"desktop_id": name + ".desktop"})

                # Over empty desktop with the pointer still at its start.
                assert state() == ("default", "default"), ipc.get_input_state()

                launch("slow-window")
                assert state() == ("default", "progress"), ipc.get_input_state()
                wait_for(lambda: any(w["app_id"] == "unrelated.app" for w in ipc.get_windows()), "window did not map")
                wait_for(lambda: state()[1] == "default", "progress cursor outlived the window")
                # Park the pointer away from the new window before the next checks.
                ipc.move_cursor(2, 2)

                launch("broken")
                assert state()[1] == "progress", ipc.get_input_state()
                wait_for(lambda: state()[1] == "default", "failed launch kept the progress cursor", timeout=5)

                launch("windowless")
                time.sleep(1.5)
                assert state()[1] == "progress", ipc.get_input_state()

                # A reload swaps the theme without losing the busy cursor.
                (tmp / "rediwm-config.toml").write_text(
                    '[input]\ncursor_theme = "phinger-cursors-light"\n[compositor]\nxwayland = false\n')
                ipc.reload_config()
                wait_for(lambda: "Loaded cursor theme 'phinger-cursors-light'" in (tmp / "compositor.log").read_text(),
                         "reload did not load the light theme")
                assert state()[1] == "progress", ipc.get_input_state()
            stop_process(proc)
            assert proc.returncode == 0, (tmp / "compositor.log").read_text()
            text = (tmp / "compositor.log").read_text()
            # Found through the XCURSOR_PATH entry the compositor adds.
            assert "Loaded cursor theme 'phinger-cursors-dark'" in text, text
        finally:
            if proc.poll() is None:
                stop_process(proc)
            log.close()
    print("PASS: bundled cursor theme, progress cursor until window, failure and pending launches, theme reload")


if __name__ == "__main__":
    run()

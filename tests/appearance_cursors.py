#!/usr/bin/env python3
"""Appearance > Cursor theme: lists installed Xcursor themes (the bundled
phinger variants plus any on XCURSOR_PATH), switches live and persists."""
from pathlib import Path
import tempfile
import time
import tomllib

from desktop_zoom import wait_for
from ipc_client import IPCClient, spawn_compositor, stop_process
from ui_driver import UIDriver


def run():
    with tempfile.TemporaryDirectory(prefix="rediwm-cursor-themes-") as directory:
        tmp = Path(directory)
        # A user theme whose index.theme name sorts before the bundled ones;
        # a directory without cursors/ is not a cursor theme.
        (tmp / "icons/aardvark/cursors").mkdir(parents=True)
        (tmp / "icons/aardvark/index.theme").write_text("[Icon Theme]\nName=Aardvark\n")
        (tmp / "icons/not-cursors").mkdir()
        config_path = tmp / "rediwm-config.toml"
        proc, log = spawn_compositor(
            tmp, config_content='[input]\npointer_speed = 0.4\ncursor_theme = "default"\n[compositor]\nxwayland = false\n',
            env_extra={"XCURSOR_PATH": str(tmp / "icons"), "XCURSOR_THEME": "", "DBUS_SESSION_BUS_ADDRESS": ""})
        try:
            with IPCClient(tmp, timeout=15) as ipc:
                ipc.action('open_control_center')
                time.sleep(.3)

                def widgets():
                    return ipc.get_widget_tree("control_center")["widgets"]

                def click(widget):
                    panel = ipc.get_shell_state()["control_center"]["box"]
                    box = widget["box"]
                    ipc.click_at(round(panel["x"] + box["x"] + box["width"] / 2),
                                 round(panel["y"] + box["y"] + box["height"] / 2))
                    time.sleep(.2)

                def cursor_select():
                    return UIDriver(ipc).scroll_into_view("cursor_theme")

                def saved():
                    return tomllib.loads(config_path.read_text())["input"]["cursor_theme"]

                def pick(downs):
                    click(cursor_select())
                    ipc.key_press("Home")
                    for _ in range(downs):
                        ipc.key_press("Down")
                    ipc.key_press("Return")
                    time.sleep(.4)

                def loaded(name):
                    return f"Loaded cursor theme '{name}'" in (tmp / "compositor.log").read_text()

                click(next(w for w in widgets() if w["label"] == "Appearance"))
                assert not cursor_select()["is_disabled"]
                # System default, then the bundled Dark and Light, then Aardvark.
                pick(1)
                assert saved() == "phinger-cursors-dark", config_path.read_text()
                wait_for(lambda: loaded("phinger-cursors-dark"), "dark theme did not load live")
                pick(2)
                assert saved() == "phinger-cursors-light"
                wait_for(lambda: loaded("phinger-cursors-light"), "light theme did not load live")
                pick(3)
                assert saved() == "aardvark"
                pick(0)
                assert saved() == "default"
                assert tomllib.loads(config_path.read_text())["input"]["pointer_speed"] == .4
                assert ipc.get_input_state()["cursor_name"] == "default"
            stop_process(proc)
            assert proc.returncode == 0, (tmp / "compositor.log").read_text()
        finally:
            if proc.poll() is None:
                stop_process(proc)
            log.close()
    print("PASS: cursor theme discovery, live switch and persistence")


if __name__ == "__main__":
    run()

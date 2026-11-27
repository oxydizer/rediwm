#!/usr/bin/env python3
"""Shortcut recording, conflict/cancel handling and persistence in an isolated session."""
import os
from pathlib import Path
import tempfile
import time

from ipc_client import IPCClient, spawn_compositor, stop_process


def run():
    with tempfile.TemporaryDirectory(prefix="rediwm-shortcuts-") as directory:
        tmp = Path(directory)
        original = '# preserved\n[input]\npointer_speed = 0.4\n[keybinds]\n"Super+q" = "close_window"\n"Super+f" = "toggle_fullscreen"\n'
        workspace_mode = os.getenv("REDIWM_TEST_WORKSPACES") == "1"
        if workspace_mode:
            original = '[compositor]\ndesktop_mode = "workspaces"\n' + original.replace('[keybinds]', '[keybinds.workspace]')
            original += '"Super+c" = "noop"\n'
        process, log = spawn_compositor(tmp, config_content=original, env_extra={"DBUS_SESSION_BUS_ADDRESS": ""})
        try:
            with IPCClient(tmp, timeout=15) as ipc:
                ipc.action('open_control_center')
                time.sleep(.3)

                def widgets():
                    return ipc.get_widget_tree("control_center")["widgets"]

                def click(label, beside=None):
                    tree = widgets()
                    candidates = [w for w in tree if w["label"] == label]
                    if beside is None:
                        widget = candidates[0]
                    else:
                        y = next(w["box"]["y"] for w in tree if w["label"] == beside)
                        widget = min(candidates, key=lambda w: abs(w["box"]["y"] - y))
                    box = widget["box"]
                    panel = ipc.get_shell_state()["control_center"]["box"]
                    ipc.click_at(round(panel["x"] + box["x"] + box["width"] / 2),
                                 round(panel["y"] + box["y"] + box["height"] / 2))
                    time.sleep(.15)

                def has(label):
                    return any(w["label"] == label for w in widgets())

                def chord(key):
                    ipc.key(125, True)
                    ipc.key_press(key)
                    ipc.key(125, False)

                click("Keyboard Shortcuts")
                assert has("Window Management") and has("Launcher")
                assert has("Open System Monitor"), "existing shortcuts omitted System Monitor"
                assert has("Ctrl+Alt+Delete")
                click("Super+q")
                chord("f")
                time.sleep(.15)
                assert has("Shortcut already in use. Try another.")
                assert next(w for w in widgets() if w["label"] == "Save shortcut")["is_disabled"]
                chord("F12")
                time.sleep(.15)
                assert has("Super+F12")
                click("Cancel")
                assert has("Super+q")
                assert (tmp / "rediwm-config.toml").read_text() == original
                click("Super+q")
                chord("F12")
                time.sleep(.15)
                click("Save shortcut")
                time.sleep(.3)
                assert has("Super+F12") and not has("Cancel")
                saved = (tmp / "rediwm-config.toml").read_text()
                assert '"Super+F12" = "close_window"' in saved
                assert ('"Super+q" = "noop"' in saved) if workspace_mode else ('"Super+q"' not in saved)
                assert '# preserved' in saved and 'pointer_speed = 0.4' in saved
                # Previously disabled bindings can be reclaimed.
                click("Super+F12")
                chord("q")
                time.sleep(.15)
                click("Save shortcut")
                time.sleep(.3)
                assert has("Super+q") and not has("Cancel")
                click("Super+q")
                ipc.key_down_up(1)  # Escape cancels capture without closing Settings.
                time.sleep(.15)
                assert has("Keyboard Shortcuts") and not has("Cancel")
                # Record a multi-modifier chord even when the main key lands first.
                click("Super+q")
                ipc.key(18, True)  # E
                ipc.key(125, True)  # Super
                ipc.key(29, True)  # Ctrl
                ipc.key(42, True)  # Shift
                ipc.key(42, False)
                ipc.key(29, False)
                ipc.key(125, False)
                ipc.key(18, False)
                time.sleep(.15)
                assert has("Super+Ctrl+Shift+e")
                click("Cancel")
                # Modifiers pressed first must also survive either release order.
                click("Super+q")
                ipc.key(125, True)
                ipc.key(29, True)
                ipc.key(42, True)
                ipc.key(18, True)
                ipc.key(18, False)
                ipc.key(42, False)
                ipc.key(29, False)
                ipc.key(125, False)
                time.sleep(.15)
                assert has("Super+Ctrl+Shift+e")
                click("Cancel")
                # Hardware keys are recorded before normal hardware dispatch.
                click("Super+q")
                ipc.key_press("XF86AudioRaiseVolume")
                time.sleep(.15)
                assert has("Shortcut already in use. Try another.")
                click("Cancel")
                # A failed atomic write keeps both the old config and the editor.
                before_failure = (tmp / "rediwm-config.toml").read_text()
                blocked = tmp / "rediwm-config.toml.shortcuts.tmp"
                blocked.write_text("occupied")
                click("Super+q")
                chord("F12")
                time.sleep(.15)
                click("Save shortcut")
                assert has("Could not save. Check the configuration file and try again.")
                assert (tmp / "rediwm-config.toml").read_text() == before_failure
                blocked.unlink()
                click("Cancel")
                # Reloading while recording cancels stale edits.
                click("Super+q")
                (tmp / "rediwm-config.toml").write_text(before_failure + "\n# external edit\n")
                time.sleep(.6)
                assert not has("Cancel")
                # Collapse/expand uses the existing scrollable widget tree.
                click("Window Management")
                assert not has("Close Window")
                click("Window Management")
                assert has("Close Window")
                close_y = next(w["box"]["y"] for w in widgets() if w["label"] == "Close Window")
                click("Add shortcut", beside="Super+q")
                chord("F12")
                click("Save shortcut")
                assert has("Super+q") and has("Super+F12")
                click("Disable shortcut", beside="Super+q")
                assert has("Super+F12")
                assert next(w["box"]["y"] for w in widgets() if w["label"] == "Close Window") == close_y
                click("Disable shortcut", beside="Super+F12")
                assert has("Close Window") and has("Not assigned")
                saved = (tmp / "rediwm-config.toml").read_text()
                assert ('"Super+q" = "noop"' in saved) if workspace_mode else ('"Super+q"' not in saved)
                assert '"Super+F12"' not in saved
                chord("q")
                assert ipc.get_shell_state()["control_center"] is not None
            stop_process(process)
            log.close()
            process, log = spawn_compositor(tmp, config_content=saved, env_extra={"DBUS_SESSION_BUS_ADDRESS": ""})
            with IPCClient(tmp, timeout=15) as ipc:
                ipc.action("open_control_center")
                time.sleep(.3)
                click("Keyboard Shortcuts")
                assert has("Close Window")
                click("Not assigned", beside="Close Window")
                chord("F12")
                click("Save shortcut")
                assert has("Super+F12")
                chord("F12")
                time.sleep(.3)
                assert ipc.get_shell_state()["control_center"] is None
            print("PASS: shortcut recording, multiple bindings, unassignment and restart")
        finally:
            stop_process(process)
            log.close()


if __name__ == "__main__":
    run()

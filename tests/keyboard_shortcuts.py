#!/usr/bin/env python3
"""Shortcut recording, conflict/cancel handling and persistence in an isolated session."""
from pathlib import Path
import tempfile
import time

from ipc_client import IPCClient, spawn_compositor, stop_process


def run():
    with tempfile.TemporaryDirectory(prefix="rediwm-shortcuts-") as directory:
        tmp = Path(directory)
        original = '# preserved\n[input]\npointer_speed = 0.4\n[keybinds]\n"Super+q" = "close_window"\n"Super+f" = "toggle_fullscreen"\n'
        process, log = spawn_compositor(tmp, config_content=original, env_extra={"DBUS_SESSION_BUS_ADDRESS": ""})
        try:
            with IPCClient(tmp, timeout=15) as ipc:
                ipc.action('open_control_center')
                time.sleep(.3)

                def widgets():
                    return ipc.get_widget_tree("control_center")["widgets"]

                def click(label):
                    widget = next(w for w in widgets() if w["label"] == label)
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
                assert '"Super+q"' not in saved
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
            print("PASS: shortcut conflicts, capture, cancel, save, reuse and groups")
        finally:
            stop_process(process)
            log.close()


if __name__ == "__main__":
    run()

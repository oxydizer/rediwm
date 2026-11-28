#!/usr/bin/env python3
"""Shortcut recording, conflict/cancel handling and persistence in an isolated session."""
import os
from pathlib import Path
import tempfile
import time
import tomllib

from ipc_client import IPCClient, spawn_compositor, stop_process


def run():
    with tempfile.TemporaryDirectory(prefix="rediwm-shortcuts-") as directory:
        tmp = Path(directory)
        original = '# preserved\n[input]\npointer_speed = 0.4\n[keybinds]\n"Super+q" = "close_window"\n"Super+f" = "toggle_fullscreen"\n'
        workspace_mode = os.getenv("REDIWM_TEST_WORKSPACES") == "1"
        if workspace_mode:
            original = '[compositor]\ndesktop_mode = "workspaces"\n' + original.replace('[keybinds]', '[keybinds.workspace]')
            original += '"Super+c" = "noop"\n'
        else:
            original += '"Super+F1" = "save_layout home"\n"Super+Ctrl+F1" = "restore_layout home"\n'
        custom = '"Alt+F11" = "spawn printf hello" # keep custom command'
        original += custom + "\n"
        env = {"DBUS_SESSION_BUS_ADDRESS": "", "HOME": str(tmp), "REDIWM_SHORTCUT_TEST": "two words"}
        config_path = tmp / "rediwm-config.toml"
        output_path = tmp / "shortcut-result"
        managed = (
            """python3 -c 'import pathlib,sys; pathlib.Path(sys.argv[1]).write_text("|".join(sys.argv[2:]))' """
            """~/shortcut-result "quoted value" "$REDIWM_SHORTCUT_TEST" ;"""
        )
        shell_command = """sh -c 'printf "%s" "$1" > "$2"' sh "shell result" ~/shortcut-result"""
        process, log = spawn_compositor(tmp, config_content=original, env_extra=env)
        try:
            with IPCClient(tmp, timeout=15) as ipc:
                ipc.action('open_control_center')
                time.sleep(.3)

                def widgets():
                    return ipc.get_widget_tree("control_center")["widgets"]

                def click(label, beside=None):
                    tree = widgets()
                    candidates = [w for w in tree if w["label"] == label or w["name"] == label]
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

                def find_shortcut(query):
                    if has("Clear shortcut search"):
                        click("Clear shortcut search")
                    click("shortcut_search")
                    ipc.type_text(query)
                    time.sleep(.15)

                def commands():
                    return tomllib.loads(config_path.read_text()).get("shortcut_commands", {})

                def mode_bindings():
                    bindings = tomllib.loads(config_path.read_text())["keybinds"]
                    return bindings["workspace"] if workspace_mode else bindings

                def expect_command_output(expected):
                    deadline = time.monotonic() + 5
                    while time.monotonic() < deadline:
                        if output_path.exists() and output_path.read_text() == expected:
                            return
                        time.sleep(.05)
                    raise AssertionError(f"custom shortcut did not write {expected!r}")

                click("Keyboard Shortcuts")
                assert has("Window Management") and has("Launcher")
                assert has("Open System Monitor"), "existing shortcuts omitted System Monitor"
                assert has("Ctrl+Alt+Delete")
                click("Window Management")
                assert not has("Close Window")
                for query in ("close", "WINDOW", "Super + Q"):
                    click("shortcut_search")
                    ipc.type_text(query)
                    time.sleep(.15)
                    assert has("Close Window")
                    if query == "Super + Q":
                        assert not has("Media")
                    click("Clear shortcut search")
                    assert not has("Close Window")
                click("shortcut_search")
                ipc.type_text("printf hello")
                time.sleep(.15)
                assert has("Custom Commands") and has("Alt+F11")
                assert not has("Window Management")
                click("Clear shortcut search")
                click("shortcut_search")
                ipc.type_text("missing-action")
                time.sleep(.15)
                assert has("No matching shortcuts. Try an action name, command, or key combination.")
                click("Clear shortcut search")
                assert (tmp / "rediwm-config.toml").read_text() == original
                click("Window Management")
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
                click("Unassign shortcut", beside="Super+q")
                assert has("Super+F12")
                assert next(w["box"]["y"] for w in widgets() if w["label"] == "Close Window") == close_y
                click("Unassign shortcut", beside="Super+F12")
                assert has("Close Window") and has("Not assigned")
                click("shortcut_search")
                ipc.type_text("close")
                time.sleep(.15)
                assert has("Close Window") and has("Not assigned")
                click("Clear shortcut search")
                saved = (tmp / "rediwm-config.toml").read_text()
                assert ('"Super+q" = "noop"' in saved) if workspace_mode else ('"Super+q"' not in saved)
                assert '"Super+F12"' not in saved
                if not workspace_mode:
                    find_shortcut("layout: home")
                    click("Unassign shortcut", beside="Super+F1")
                    click("Unassign shortcut", beside="Super+Ctrl+F1")
                    assert has("Save layout: home") and has("Restore layout: home")
                    assert sum(w["label"] == "Not assigned" for w in widgets()) == 2
                    assert "save_layout home" not in mode_bindings().values()
                    assert "restore_layout home" not in mode_bindings().values()
                    click("Clear shortcut search")
                    saved = config_path.read_text()
                chord("q")
                assert ipc.get_shell_state()["control_center"] is not None
            stop_process(process)
            log.close()
            process, log = spawn_compositor(tmp, config_content=saved, env_extra=env)
            with IPCClient(tmp, timeout=15) as ipc:
                ipc.action("open_control_center")
                time.sleep(.3)
                click("Keyboard Shortcuts")
                if not workspace_mode:
                    find_shortcut("layout: home")
                    assert has("Save layout: home") and has("Restore layout: home")
                    assert sum(w["label"] == "Not assigned" for w in widgets()) == 2
                    for label, key, action in (
                        ("Save layout: home", "F1", "save_layout home"),
                        ("Restore layout: home", "F4", "restore_layout home"),
                    ):
                        click("Not assigned", beside=label)
                        chord(key)
                        time.sleep(.15)
                        assert has(f"Super+{key}"), label
                        click("Save shortcut")
                        assert mode_bindings()[f"Super+{key}"] == action
                    chord("F1")
                    assert (tmp / "layouts/home.toml").is_file()
                    click("Clear shortcut search")
                assert has("Close Window")
                click("Not assigned", beside="Close Window")
                chord("F12")
                click("Save shortcut")
                assert has("Super+F12")
                chord("F12")
                time.sleep(.3)
                assert ipc.get_shell_state()["control_center"] is None
                ipc.action("open_control_center")
                time.sleep(.3)
                click("Keyboard Shortcuts")
                before_reset = (tmp / "rediwm-config.toml").read_text()
                click("Reset All Shortcuts")
                assert has("Reset built-in shortcuts")
                click("Cancel")
                assert (tmp / "rediwm-config.toml").read_text() == before_reset
                click("Restore factory bindings", beside="Close Window")
                close_key = "c" if workspace_mode else "q"
                close_chord = f"Super+{close_key}"
                assert has(close_chord)
                assert not has("Super+F12")
                assert custom in (tmp / "rediwm-config.toml").read_text()
                click("Add shortcut", beside="Super+f")
                chord("F12")
                time.sleep(.15)
                click("Save shortcut")
                click("Unassign shortcut", beside=close_chord)
                click("Super+f")
                chord(close_key)
                time.sleep(.15)
                click("Save shortcut")
                assert mode_bindings()[close_chord] == "toggle_fullscreen"
                before_conflict = config_path.read_text()
                click("Restore factory bindings", beside="Close Window")
                assert has("A factory shortcut is in use. Unassign it before resetting.")
                assert config_path.read_text() == before_conflict
                click("Reset All Shortcuts")
                click("Reset built-in shortcuts")
                assert mode_bindings()[close_chord] == "close_window"
                assert mode_bindings()["Super+f"] == "toggle_fullscreen"
                assert "Super+F12" not in mode_bindings()
                assert custom in (tmp / "rediwm-config.toml").read_text()

                find_shortcut("printf hello")
                click("Add Custom Command")
                before_command = config_path.read_text()
                click("Save command")
                assert has("Enter an executable and check the command’s quoting and expansions.")
                assert config_path.read_text() == before_command
                click("shortcut_command")
                ipc.type_text(managed)
                blocked = tmp / "rediwm-config.toml.shortcuts.tmp"
                blocked.write_text("occupied")
                click("Save command")
                assert has("Could not save. Check the configuration file and try again.")
                assert config_path.read_text() == before_command
                blocked.unlink()
                click("Save command")
                assert list(commands().values()) == [managed]
                command_id = next(iter(commands()))
                action = f"custom_command {command_id}"

                find_shortcut("python3")
                assert has(managed)
                click("Not assigned", beside=managed)
                chord("f")
                time.sleep(.15)
                assert has("Shortcut already in use. Try another.")
                chord("F12")
                time.sleep(.15)
                click("Save shortcut")
                assert mode_bindings()["Super+F12"] == action
                chord("F12")
                expect_command_output("quoted value|two words|;")

                find_shortcut("Close Window")
                click("Unassign shortcut", beside=close_chord)
                find_shortcut("python3")
                click("Super+F12")
                chord(close_key)
                time.sleep(.15)
                click("Save shortcut")
                assert mode_bindings()[close_chord] == action
                before_conflict = config_path.read_text()
                click("Reset All Shortcuts")
                click("Reset built-in shortcuts")
                assert has("A factory shortcut is in use. Unassign it before resetting.")
                assert config_path.read_text() == before_conflict
                click(close_chord)
                chord("F12")
                time.sleep(.15)
                click("Save shortcut")
                click("Reset All Shortcuts")
                click("Reset built-in shortcuts")
                assert mode_bindings()[close_chord] == "close_window"
                assert mode_bindings()["Super+F12"] == action

                click("Edit command", beside=managed)
                click("shortcut_command")
                ipc.key(29, True)
                ipc.key_press("a")
                ipc.key(29, False)
                ipc.type_text(shell_command)
                click("Save command")
                assert commands() == {command_id: shell_command}
                assert mode_bindings()["Super+F12"] == action
                chord("F12")
                expect_command_output("shell result")

                find_shortcut("shell result")
                click("Unassign shortcut", beside="Super+F12")
                assert has(shell_command) and has("Not assigned")
                assert action not in mode_bindings().values()
                saved = config_path.read_text()
            stop_process(process)
            log.close()
            process, log = spawn_compositor(tmp, config_content=saved, env_extra=env)
            with IPCClient(tmp, timeout=15) as ipc:
                ipc.action("open_control_center")
                time.sleep(.3)
                click("Keyboard Shortcuts")
                find_shortcut("shell result")
                assert commands() == {command_id: shell_command}
                assert has(shell_command) and has("Not assigned")
                click("Not assigned", beside=shell_command)
                chord("F12")
                time.sleep(.15)
                click("Save shortcut")
                assert mode_bindings()["Super+F12"] == action
                click("Edit command", beside=shell_command)
                click("Delete command…")
                click("Delete command and its shortcuts")
                assert not commands()
                assert action not in mode_bindings().values()
                assert not has(shell_command)
                assert custom in config_path.read_text()
            print("PASS: shortcut recording, reset, and custom command lifecycle")
        finally:
            stop_process(process)
            log.close()


def run_reload_callbacks():
    workspace_mode = os.getenv("REDIWM_TEST_WORKSPACES") == "1"
    mode = "workspaces" if workspace_mode else "canvas"
    table = "keybinds.workspace" if workspace_mode else "keybinds"
    close = '"Super+q" = "close_window"\n'
    full = '"Super+f" = "toggle_fullscreen"\n'
    extra = '"Alt+F10" = "focus_next"\n'
    managed = '"Alt+F12" = "custom_command managed"\n'
    command = '\n[shortcut_commands]\nmanaged = "printf old"\n'
    changed = command.replace("printf old", "printf new")

    def config(bindings):
        return f'[compositor]\ndesktop_mode = "{mode}"\n[{table}]\n' + bindings

    with tempfile.TemporaryDirectory(prefix="rediwm-shortcuts-reload-") as directory:
        tmp = Path(directory)
        path = tmp / "rediwm-config.toml"
        process, log = spawn_compositor(tmp, config_content=config(close + full),
                                        env_extra={"DBUS_SESSION_BUS_ADDRESS": ""})
        try:
            with IPCClient(tmp, timeout=15) as ipc:
                def widgets():
                    return ipc.get_widget_tree("control_center")["widgets"]

                def point(label, beside=None):
                    rows = widgets()
                    matches = [w for w in rows if label in (w["label"], w["name"])]
                    if beside is not None:
                        y = next(w["box"]["y"] for w in rows if w["label"] == beside)
                        matches.sort(key=lambda w: abs(w["box"]["y"] - y))
                    box = matches[0]["box"]
                    panel = ipc.get_shell_state()["control_center"]["box"]
                    return (round(panel["x"] + box["x"] + box["width"] / 2),
                            round(panel["y"] + box["y"] + box["height"] / 2))

                def click(label, beside=None):
                    ipc.click_at(*point(label, beside))
                    time.sleep(.15)

                def reload(text):
                    path.write_text(text)
                    ipc.reload_config()
                    time.sleep(.15)

                def reload_while_held(label, text, beside=None):
                    ipc.move_cursor(*point(label, beside))
                    ipc.pointer_button(0x110, True)
                    reload(text)
                    ipc.pointer_button(0x110, False)
                    time.sleep(.15)

                ipc.open_control_center()
                time.sleep(.3)
                click("Keyboard Shortcuts")
                for case, before, after, should_unassign in (
                    ("reordered", close + full, full + close, True),
                    ("inserted", close + full, extra + close + full, True),
                    ("removed", extra + close + full, close + full, True),
                    ("disappeared", close + full, full, False),
                    ("reassigned", close + full, close.replace("close_window", "toggle_maximize") + full, False),
                ):
                    reload(config(before))
                    updated = config(after)
                    reload_while_held("Unassign shortcut", updated, "Super+q")
                    if not should_unassign:
                        assert path.read_text() == updated, case
                        continue
                    expected = tomllib.loads(updated)["keybinds"]
                    actual = tomllib.loads(path.read_text())["keybinds"]
                    if workspace_mode:
                        expected, actual = expected["workspace"], actual["workspace"]
                        # Workspaces inherits Super+q for the terminal.
                        expected["Super+q"] = "noop"
                    else:
                        expected.pop("Super+q")
                    assert actual == expected, (case, actual, expected)

                reload(config(close + full))
                click("Super+q")
                ipc.key(125, True)
                ipc.key_press("F12")
                ipc.key(125, False)
                time.sleep(.15)
                updated = config(full + close)
                reload_while_held("Save shortcut", updated)
                assert path.read_text() == updated

                reload(config(close + full + managed) + command)
                click("shortcut_search")
                ipc.type_text("Alt+F12")
                time.sleep(.15)
                for new_command in (changed, ""):
                    reload(config(close + full + managed) + command)
                    updated = config(close + full + managed) + new_command
                    reload_while_held("Unassign shortcut", updated, "Alt+F12")
                    assert path.read_text() == updated

                reload(config(close + full + managed) + command)
                updated = config(close + full + managed) + changed
                reload_while_held("Edit command", updated)
                assert not any(w["name"] == "shortcut_command" for w in widgets())
                assert path.read_text() == updated

                reload(config(close + full + managed) + command)
                click("Edit command")
                reload_while_held("Save command", updated)
                assert path.read_text() == updated
                click("Cancel")
                click("Edit command")
                click("Delete command…")
                updated = config(close + full + managed)
                reload_while_held("Delete command and its shortcuts", updated)
                assert path.read_text() == updated
        finally:
            stop_process(process)
            log.close()
    print(f"PASS: {mode} shortcut callbacks preserve their targets across reload")


def run_text_shortcut_priority():
    workspace = os.getenv("REDIWM_TEST_WORKSPACES") == "1"
    mode = "workspaces" if workspace else "canvas"
    table = "keybinds.workspace" if workspace else "keybinds"
    with tempfile.TemporaryDirectory(prefix="rediwm-shortcut-text-") as directory:
        tmp = Path(directory)
        path = tmp / "rediwm-config.toml"
        marker = tmp / "intercepted"
        modified = tmp / "modified"
        conflicts = ("z", "Left", "BackSpace", "Delete", "Ctrl+a", "Ctrl+c", "Ctrl+x", "Ctrl+v", "Escape")
        config = f'[compositor]\ndesktop_mode = "{mode}"\n[{table}]\n'
        config += "".join(f'"{chord}" = "spawn printf hit > {marker}"\n' for chord in conflicts)
        config += f'"Super+F11" = "spawn printf hit > {modified}"\n'
        config += '"Super+q" = "close_window"\n"Alt+F12" = "custom_command demo"\n'
        config += '[shortcut_commands]\ndemo = "printf original-marker"\n'
        process, log = spawn_compositor(tmp, config_content=config, env_extra={"DBUS_SESSION_BUS_ADDRESS": ""})
        try:
            with IPCClient(tmp, timeout=15) as ipc:
                def widgets():
                    return ipc.get_widget_tree("control_center")["widgets"]

                def click(label):
                    widget = next(w for w in widgets() if label in (w["label"], w["name"]))
                    box = widget["box"]
                    panel = ipc.get_shell_state()["control_center"]["box"]
                    ipc.click_at(round(panel["x"] + box["x"] + box["width"] / 2),
                                 round(panel["y"] + box["y"] + box["height"] / 2))
                    time.sleep(.15)

                def modified_key(modifier, key):
                    ipc.key(modifier, True)
                    ipc.key_press(key)
                    ipc.key(modifier, False)
                    time.sleep(.15)

                def length(name, expected):
                    widget = next(w for w in widgets() if w["name"] == name)
                    assert widget["is_focused"] and widget["text_length"] == expected, (name, expected, widget)

                ipc.open_control_center()
                time.sleep(.3)
                click("Keyboard Shortcuts")
                click("shortcut_search")
                ipc.key_press("z")
                time.sleep(.15)
                length("shortcut_search", 1)
                ipc.key_press("z")
                ipc.key_press("Left")
                ipc.key_press("Delete")
                time.sleep(.15)
                length("shortcut_search", 1)
                modified_key(29, "a")
                modified_key(29, "c")
                ipc.key_press("BackSpace")
                time.sleep(.15)
                length("shortcut_search", 0)
                modified_key(29, "v")
                length("shortcut_search", 1)
                modified_key(29, "a")
                modified_key(29, "x")
                length("shortcut_search", 0)
                modified_key(29, "v")
                length("shortcut_search", 1)
                modified_key(125, "F11")
                assert modified.read_text() == "hit"
                assert not marker.exists()

                click("Clear shortcut search")
                ipc.type_text("original-marker")
                time.sleep(.15)
                click("Edit command")
                modified_key(29, "a")
                ipc.key_press("z")
                time.sleep(.15)
                length("shortcut_command", 1)
                modified_key(29, "a")
                modified_key(29, "x")
                length("shortcut_command", 0)
                modified_key(29, "v")
                length("shortcut_command", 1)
                click("Save command")
                assert tomllib.loads(path.read_text())["shortcut_commands"]["demo"] == "z"

                click("Clear shortcut search")
                ipc.type_text("Alt+F12")
                time.sleep(.15)
                click("Edit command")
                ipc.key_down_up(1)
                time.sleep(.15)
                assert not any(w["name"] == "shortcut_command" for w in widgets())
                click("Clear shortcut search")
                click("Super+q")
                modified_key(125, "z")
                assert any(w["label"] == "Super+z" for w in widgets())
                ipc.key_down_up(1)
                time.sleep(.15)
                assert not any(w["label"] == "Save shortcut" for w in widgets())
                assert not marker.exists()
                click("General")
                ipc.key_press("z")
                time.sleep(.2)
                assert marker.read_text() == "hit"
        finally:
            stop_process(process)
            log.close()
    print(f"PASS: {mode} Settings text editing takes priority over conflicting shortcuts")


def run_temporary_mode():
    workspace = os.getenv("REDIWM_TEST_WORKSPACES") == "1"
    persisted = "workspaces" if workspace else "canvas"
    temporary = "canvas" if workspace else "workspaces"
    original = (
        f'[compositor]\ndesktop_mode = "{persisted}"\n'
        '[keybinds]\n"Super+q" = "close_window"\n'
        '[keybinds.workspace]\n"Super+q" = "close_window"\n'
    )
    with tempfile.TemporaryDirectory(prefix="rediwm-shortcut-mode-") as directory:
        tmp = Path(directory)
        path = tmp / "rediwm-config.toml"
        process, log = spawn_compositor(
            tmp, config_content=original,
            env_extra={"DBUS_SESSION_BUS_ADDRESS": ""},
        )
        try:
            with IPCClient(tmp, timeout=15) as ipc:
                def disk():
                    return tomllib.loads(path.read_text())

                def expect_mode(active, saved):
                    rows = ipc.get_workspaces()
                    if active == "canvas":
                        assert rows[0]["name"] == "Canvas", rows
                    else:
                        assert rows[0]["layout"] == "split", rows
                    assert disk()["compositor"]["desktop_mode"] == saved

                def click(label):
                    tree = ipc.get_widget_tree("control_center")["widgets"]
                    widget = next(w for w in tree if label in (w["label"], w["name"]))
                    box = widget["box"]
                    panel = ipc.get_shell_state()["control_center"]["box"]
                    ipc.click_at(round(panel["x"] + box["x"] + box["width"] / 2),
                                 round(panel["y"] + box["y"] + box["height"] / 2))
                    time.sleep(.15)

                expect_mode(persisted, persisted)
                ipc.action("set_desktop_mode", {"mode": temporary, "persist": False})
                time.sleep(.3)
                expect_mode(temporary, persisted)

                ipc.open_control_center()
                time.sleep(.3)
                click("Keyboard Shortcuts")
                click("shortcut_search")
                ipc.type_text("Close Window")
                time.sleep(.15)
                click("Super+q")
                ipc.key(125, True)
                ipc.key_press("F12")
                ipc.key(125, False)
                time.sleep(.15)
                click("Save shortcut")
                time.sleep(.6)
                expect_mode(temporary, persisted)

                bindings = disk()["keybinds"]
                if temporary == "workspaces":
                    assert bindings["workspace"]["Super+F12"] == "close_window"
                    assert bindings["Super+q"] == "close_window"
                else:
                    assert bindings["Super+F12"] == "close_window"
                    assert bindings["workspace"]["Super+q"] == "close_window"

                # Explicit reload must also preserve the temporary mode.
                ipc.reload_config()
                time.sleep(.3)
                expect_mode(temporary, persisted)

                # An unrelated external write must not end the temporary mode.
                path.write_text(path.read_text() + "\n# external edit\n")
                time.sleep(.6)
                expect_mode(temporary, persisted)

                # A changed persisted preference must become the new baseline.
                path.write_text(path.read_text().replace(
                    f'desktop_mode = "{persisted}"',
                    f'desktop_mode = "{temporary}"',
                ))
                ipc.reload_config()
                time.sleep(.3)
                expect_mode(temporary, temporary)

                ipc.action("set_desktop_mode", {"mode": persisted, "persist": False})
                ipc.reload_config()
                time.sleep(.3)
                expect_mode(persisted, temporary)

                # Permanent selection updates both runtime and disk.
                ipc.action("set_desktop_mode", {"mode": persisted, "persist": True})
                time.sleep(.6)
                expect_mode(persisted, persisted)

                # A subsequent external mode change must take effect.
                path.write_text(path.read_text().replace(
                    f'desktop_mode = "{persisted}"',
                    f'desktop_mode = "{temporary}"',
                ))
                ipc.reload_config()
                time.sleep(.3)
                expect_mode(temporary, temporary)
        finally:
            stop_process(process)
            log.close()
    print(f"PASS: temporary {temporary} mode survives shortcut saves and reloads")


if __name__ == "__main__":
    run()
    run_reload_callbacks()
    run_text_shortcut_priority()
    run_temporary_mode()

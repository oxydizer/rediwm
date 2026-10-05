#!/usr/bin/env python3
"""Integration tests for [[window_rules]] configuration and IPC."""
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def wait_for(check, message, timeout=15):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = check()
        if result:
            return result
        time.sleep(0.05)
    raise AssertionError(message)


def build_wayland_client(tmp):
    protocol_dir = subprocess.check_output(
        ["pkg-config", "--variable=pkgdatadir", "wayland-protocols"], text=True
    ).strip()
    protocol = Path(protocol_dir) / "stable/xdg-shell/xdg-shell.xml"
    for mode, target in [
        ("client-header", "xdg-shell-client-protocol.h"),
        ("private-code", "xdg-shell-protocol.c"),
    ]:
        subprocess.run(
            ["wayland-scanner", mode, str(protocol), str(tmp / target)], check=True
        )
    decoration_protocol = (
        Path(protocol_dir) / "unstable/xdg-decoration/xdg-decoration-unstable-v1.xml"
    )
    for mode, target in [
        ("client-header", "xdg-decoration-client-protocol.h"),
        ("private-code", "xdg-decoration-protocol.c"),
    ]:
        subprocess.run(
            ["wayland-scanner", mode, str(decoration_protocol), str(tmp / target)],
            check=True,
        )
    subprocess.run(
        [
            "cc",
            "-Wall",
            "-Wextra",
            f"-I{tmp}",
            str(ROOT / "tests/zoom_client.c"),
            str(tmp / "xdg-shell-protocol.c"),
            str(tmp / "xdg-decoration-protocol.c"),
            "-lwayland-client",
            "-o",
            str(tmp / "wayland-client"),
        ],
        check=True,
    )


def build_x11_client(tmp):
    subprocess.run(
        [
            "cc",
            "-Wall",
            "-Wextra",
            str(ROOT / "tests/xwayland_client.c"),
            "-lxcb",
            "-o",
            str(tmp / "x11-client"),
        ],
        check=True,
    )


CONFIG_TOML = """
[compositor]
xwayland = true
inactive_opacity = 0.8

# Rule 1: output + x/y
[[window_rules]]
app_id = "test.output-xy"
output = "HEADLESS-2"
x = 100
y = 150

# Rule 2: output + center
[[window_rules]]
app_id = "test.center"
output = "HEADLESS-2"
center = true

# Rule 3: first configure carries rule size
[[window_rules]]
app_id = "test.size"
width = 500
height = 350

# Rule 4: open maximized
[[window_rules]]
app_id = "test.maximized"
width = 520
height = 340
maximized = true

# Rule 5: open fullscreen
[[window_rules]]
app_id = "test.fullscreen"
fullscreen = true

# Rule 6: focus = false
[[window_rules]]
app_id = "test.no-focus"
focus = false

# Rule 7: depth
[[window_rules]]
app_id = "test.depth"
depth = 1

# Rule 8: opacity
[[window_rules]]
app_id = "test.opacity"
opacity = 0.5

# Rule 9: decorations server
[[window_rules]]
app_id = "test.decor-server"
decorations = "server"

# Rule 10: decorations client
[[window_rules]]
app_id = "test.decor-client"
decorations = "client"

# Rule 11: skip_taskbar
[[window_rules]]
app_id = "test.skip-taskbar"
skip_taskbar = true

# Rule 12: late app_id
[[window_rules]]
app_id = "test.late-app-id"
width = 450
height = 320

# Rule 13: X11 class matching without dialog
[[window_rules]]
backend = "xwayland"
x11_class = "MatchedX11"
dialog = false
width = 480
height = 310
opacity = 0.7

# Rule 14: X11 class matching with dialog
[[window_rules]]
backend = "xwayland"
x11_class = "MatchedX11"
dialog = true
width = 250
height = 180

# Rule 15: reload live properties
[[window_rules]]
app_id = "test.reload"
opacity = 0.6
skip_taskbar = false
"""


def run():
    with tempfile.TemporaryDirectory(prefix="rediwm-window-rules-") as directory:
        tmp = Path(directory)
        build_wayland_client(tmp)
        build_x11_client(tmp)

        config_file = tmp / "config.toml"
        config_file.write_text(CONFIG_TOML)

        env = dict(
            os.environ,
            XDG_RUNTIME_DIR=str(tmp),
            WLR_BACKENDS="headless",
            WLR_HEADLESS_OUTPUTS="2",
            WLR_RENDERER="pixman",
            REDIWM_SCALE="1",
            REDIWM_CONFIG=str(config_file),
        )
        env.pop("WAYLAND_DISPLAY", None)
        env.pop("REDIWM_SOCKET", None)
        env.pop("DISPLAY", None)

        clients = []
        with (tmp / "compositor.log").open("w") as log:
            compositor = subprocess.Popen(
                [str(ROOT / "zig-out/bin/rediwm")],
                env=env,
                stdout=log,
                stderr=log,
            )

        try:
            ipc = wait_for(lambda: next(tmp.glob("rediwm-*.sock"), None), "IPC unavailable")
            display = wait_for(
                lambda: next(
                    (p.name for p in tmp.glob("wayland-*") if not p.name.endswith(".lock")),
                    None,
                ),
                "Wayland display unavailable",
            )

            with socket.socket(socket.AF_UNIX) as sock:
                sock.settimeout(10)
                sock.connect(str(ipc))
                reader = sock.makefile("r")

                def request(value):
                    sock.sendall((json.dumps(value) + "\n").encode())
                    line = reader.readline()
                    assert line, "EOF from compositor socket"
                    result = json.loads(line)
                    assert "Ok" in result, result
                    return result["Ok"]

                def action(name, params=None):
                    return request({"version": 1, "command": name, "params": params or {}})

                def windows():
                    return request({'version': 1, 'command': 'windows'})["Windows"]

                def spawn_wayland(app_id, extra_args=None, env_extra=None):
                    client_env = dict(env, WAYLAND_DISPLAY=display)
                    if env_extra:
                        client_env.update(env_extra)
                    args = [str(tmp / "wayland-client"), "--app-id", app_id]
                    if extra_args:
                        args.extend(extra_args)
                    clog = tmp / f"{app_id}.log"
                    f = clog.open("w")
                    p = subprocess.Popen(args, env=client_env, stdout=f, stderr=f)
                    clients.append((p, f))
                    return p, clog

                def spawn_x11(args, xdisplay):
                    client_env = dict(env, DISPLAY=xdisplay)
                    clog = tmp / f"x11_{len(clients)}.log"
                    f = clog.open("w")
                    p = subprocess.Popen(
                        [str(tmp / "x11-client")] + args,
                        env=client_env,
                        stdin=subprocess.PIPE,
                        stdout=f,
                        stderr=f,
                        text=True,
                    )
                    clients.append((p, f))
                    return p, clog

                def close_win(wid, proc):
                    action('close_window', {"id": wid})
                    wait_for(lambda: not any(w["id"] == wid for w in windows()), "window did not close")
                    proc.wait(timeout=3)

                def get_two_outputs():
                    o = request({'version': 1, 'command': 'outputs'}).get("Outputs", [])
                    return o if len(o) == 2 else None
                outs = wait_for(get_two_outputs, "outputs not ready")
                out1 = next(o for o in outs if o["name"] == "HEADLESS-1")
                out2 = next(o for o in outs if o["name"] == "HEADLESS-2")

                print("Testing Case 1: output + x/y and center...")
                # 1a: output + x/y
                proc, _ = spawn_wayland("test.output-xy")
                win = wait_for(
                    lambda: next((w for w in windows() if w.get("app_id") == "test.output-xy"), None),
                    "test.output-xy did not map",
                )
                rules = request({"version": 1, "command": 'get_window_rules', "params": {"id": win["id"]}})["WindowRules"]
                assert 1 in rules["matched_rules"], rules
                assert rules["open"]["output"] == "HEADLESS-2", rules
                assert rules["open"]["x"] == 100, rules
                assert rules["open"]["y"] == 150, rules
                assert win["x"] == out2["x"] + 100, (win["x"], out2["x"] + 100)
                assert win["y"] == out2["y"] + 150, (win["y"], out2["y"] + 150)
                close_win(win["id"], proc)

                # 1b: output + center
                proc, _ = spawn_wayland("test.center")
                win = wait_for(
                    lambda: next((w for w in windows() if w.get("app_id") == "test.center"), None),
                    "test.center did not map",
                )
                rules = request({"version": 1, "command": 'get_window_rules', "params": {"id": win["id"]}})["WindowRules"]
                assert 2 in rules["matched_rules"], rules
                assert rules["open"]["center"] is True, rules
                usable_h = out2["logical_height"] - out2.get("bottom_exclusion", 0)
                expected_x = out2["x"] + (out2["logical_width"] - win["width"]) // 2
                expected_y = out2["y"] + (usable_h - win["height"]) // 2
                assert abs(win["x"] - expected_x) <= 1, (win["x"], expected_x)
                assert abs(win["y"] - expected_y) <= 1, (win["y"], expected_y)
                close_win(win["id"], proc)
                print("PASS: Case 1")

                print("Testing Case 2: first configure carries rule size...")
                proc, clog = spawn_wayland("test.size")
                win = wait_for(
                    lambda: next((w for w in windows() if w.get("app_id") == "test.size"), None),
                    "test.size did not map",
                )
                debug = request({"version": 1, "command": 'get_window_debug', "params": {"id": win["id"]}})["WindowDebug"]
                assert debug["client_box"]["width"] == 500, debug
                assert debug["client_box"]["height"] == 350, debug
                # Verify first configure in client log
                def get_configure_log():
                    t = clog.read_text()
                    return t if "configure" in t else None
                client_text = wait_for(get_configure_log, "no configure in client log")
                first_cfg = [l for l in client_text.splitlines() if l.startswith("configure ")][0]
                assert first_cfg == "configure 500 350", first_cfg
                close_win(win["id"], proc)
                print("PASS: Case 2")

                print("Testing Case 3: open maximized and un-maximize...")
                proc, _ = spawn_wayland("test.maximized")
                win = wait_for(
                    lambda: next((w for w in windows() if w.get("app_id") == "test.maximized"), None),
                    "test.maximized did not map",
                )
                assert win["is_maximized"] is True, win
                rules = request({"version": 1, "command": 'get_window_rules', "params": {"id": win["id"]}})["WindowRules"]
                assert rules["open"]["maximized"] is True, rules
                assert rules["open"]["width"] == 520, rules
                assert rules["open"]["height"] == 340, rules
                # Unmaximize
                action('restore_window', {"id": win["id"]})
                unmax = wait_for(
                    lambda: (w := next((w for w in windows() if w["id"] == win["id"]), None))
                    and not w["is_maximized"]
                    and w,
                    "unmaximize failed",
                )
                debug = request({"version": 1, "command": 'get_window_debug', "params": {"id": unmax["id"]}})["WindowDebug"]
                assert debug["client_box"]["width"] == 520, debug
                assert debug["client_box"]["height"] == 340, debug
                close_win(win["id"], proc)
                print("PASS: Case 3")

                print("Testing Case 4: open fullscreen...")
                proc, _ = spawn_wayland("test.fullscreen")
                win = wait_for(
                    lambda: next((w for w in windows() if w.get("app_id") == "test.fullscreen"), None),
                    "test.fullscreen did not map",
                )
                debug = request({"version": 1, "command": 'get_window_debug', "params": {"id": win["id"]}})["WindowDebug"]
                assert debug["fullscreen"] is True, debug
                rules = request({"version": 1, "command": 'get_window_rules', "params": {"id": win["id"]}})["WindowRules"]
                assert rules["open"]["fullscreen"] is True, rules
                close_win(win["id"], proc)
                print("PASS: Case 4")

                print("Testing Case 5: focus = false...")
                proc_base, _ = spawn_wayland("test.base")
                base_win = wait_for(
                    lambda: next((w for w in windows() if w.get("app_id") == "test.base"), None),
                    "test.base did not map",
                )
                action('focus_window', {"id": base_win["id"]})
                focused = wait_for(
                    lambda: (f := request({'version': 1, 'command': 'focused_window'})["FocusedWindow"])
                    and f["id"] == base_win["id"]
                    and f,
                    "base window not focused",
                )
                proc_nofocus, _ = spawn_wayland("test.no-focus")
                nofocus_win = wait_for(
                    lambda: next((w for w in windows() if w.get("app_id") == "test.no-focus"), None),
                    "test.no-focus did not map",
                )
                focused_after = request({'version': 1, 'command': 'focused_window'})["FocusedWindow"]
                assert focused_after["id"] == base_win["id"], (focused_after, base_win["id"])
                close_win(nofocus_win["id"], proc_nofocus)
                close_win(base_win["id"], proc_base)
                print("PASS: Case 5")

                print("Testing Case 6: depth...")
                proc, _ = spawn_wayland("test.depth")
                win = wait_for(
                    lambda: next((w for w in windows() if w.get("app_id") == "test.depth"), None),
                    "test.depth did not map",
                )
                rules = request({"version": 1, "command": 'get_window_rules', "params": {"id": win["id"]}})["WindowRules"]
                assert rules["open"]["depth"] == 1, rules
                assert win["zoom_percent"] == 85, win
                close_win(win["id"], proc)
                print("PASS: Case 6")

                print("Testing Case 7: effective opacity with inactive_opacity...")
                proc_base, _ = spawn_wayland("test.base")
                base_win = wait_for(
                    lambda: next((w for w in windows() if w.get("app_id") == "test.base"), None),
                    "base window did not map",
                )
                proc_op, _ = spawn_wayland("test.opacity")
                op_win = wait_for(
                    lambda: next((w for w in windows() if w.get("app_id") == "test.opacity"), None),
                    "test.opacity did not map",
                )
                # op_win is focused
                action('focus_window', {"id": op_win["id"]})
                wait_for(
                    lambda: (f := request({'version': 1, 'command': 'focused_window'})["FocusedWindow"])
                    and f["id"] == op_win["id"]
                    and f,
                    "op_win not focused",
                )
                rules = request({"version": 1, "command": 'get_window_rules', "params": {"id": op_win["id"]}})["WindowRules"]
                assert rules["live"]["opacity"] == 0.5, rules
                assert abs(rules["live"]["effective_opacity"] - 0.5) < 0.01, rules

                # Unfocus op_win by focusing base_win
                action('focus_window', {"id": base_win["id"]})
                wait_for(
                    lambda: (f := request({'version': 1, 'command': 'focused_window'})["FocusedWindow"])
                    and f["id"] == base_win["id"]
                    and f,
                    "base_win not focused",
                )
                rules = request({"version": 1, "command": 'get_window_rules', "params": {"id": op_win["id"]}})["WindowRules"]
                assert rules["live"]["opacity"] == 0.5, rules
                # 0.5 * 0.8 == 0.4
                assert abs(rules["live"]["effective_opacity"] - 0.4) < 0.01, rules
                close_win(op_win["id"], proc_op)
                close_win(base_win["id"], proc_base)
                print("PASS: Case 7")

                print("Testing Case 8: decorations server/client...")
                # 8a: rule says server, client asks client
                proc, _ = spawn_wayland("test.decor-server", env_extra={"REDIWM_TEST_DECORATION": "client"})
                win = wait_for(
                    lambda: next((w for w in windows() if w.get("app_id") == "test.decor-server"), None),
                    "decor-server did not map",
                )
                debug = request({"version": 1, "command": 'get_window_debug', "params": {"id": win["id"]}})["WindowDebug"]
                assert debug["decoration_mode"] == "server", debug
                assert win["width"] > 400, win
                rules = request({"version": 1, "command": 'get_window_rules', "params": {"id": win["id"]}})["WindowRules"]
                assert rules["live"]["decorations"] == "server", rules
                close_win(win["id"], proc)

                # 8b: rule says client, client asks server
                proc, _ = spawn_wayland("test.decor-client", env_extra={"REDIWM_TEST_DECORATION": "server"})
                win = wait_for(
                    lambda: next((w for w in windows() if w.get("app_id") == "test.decor-client"), None),
                    "decor-client did not map",
                )
                debug = request({"version": 1, "command": 'get_window_debug', "params": {"id": win["id"]}})["WindowDebug"]
                assert debug["decoration_mode"] == "client", debug
                assert (win["width"], win["height"]) == (400, 260), win
                rules = request({"version": 1, "command": 'get_window_rules', "params": {"id": win["id"]}})["WindowRules"]
                assert rules["live"]["decorations"] == "client", rules
                close_win(win["id"], proc)
                print("PASS: Case 8")

                print("Testing Case 9: skip_taskbar...")
                proc, _ = spawn_wayland("test.skip-taskbar")
                win = wait_for(
                    lambda: next((w for w in windows() if w.get("app_id") == "test.skip-taskbar"), None),
                    "skip-taskbar did not map",
                )
                shell = request({'version': 1, 'command': 'get_shell_state', 'params': {}})["ShellState"]
                chips = shell["taskbars"][0]["chips"]
                chip_wids = [c["window_id"] for c in chips]
                assert win["id"] not in chip_wids, (win["id"], chip_wids)
                rules = request({"version": 1, "command": 'get_window_rules', "params": {"id": win["id"]}})["WindowRules"]
                assert rules["live"]["skip_taskbar"] is True, rules
                close_win(win["id"], proc)
                print("PASS: Case 9")

                print("Testing Case 10: late app_id reports resolved_before_app_id...")
                proc, _ = spawn_wayland("test.late-app-id", extra_args=["--late-app-id"])
                win = wait_for(
                    lambda: next((w for w in windows() if w.get("app_id") == "test.late-app-id"), None),
                    "late app_id window did not map",
                )
                rules = request({"version": 1, "command": 'get_window_rules', "params": {"id": win["id"]}})["WindowRules"]
                assert rules["resolved_before_app_id"] is True, rules
                assert 12 in rules["matched_rules"], rules
                close_win(win["id"], proc)
                print("PASS: Case 10")

                print("Testing Case 11: X11 class matching and dialog exclusion...")
                xdisplay = wait_for(
                    lambda: request({'version': 1, 'command': 'get_runtime_info'})["RuntimeInfo"].get("xwayland_display"),
                    "Xwayland display not ready",
                )

                # 11a: non-dialog X11 window
                proc_x11, _ = spawn_x11(["--class", "MatchedX11", "MatchedX11", "--title", "Main Window"], xdisplay)
                win_main = wait_for(
                    lambda: next((w for w in windows() if w.get("title") == "Main Window"), None),
                    "X11 window did not map",
                )
                rules = request({"version": 1, "command": 'get_window_rules', "params": {"id": win_main["id"]}})["WindowRules"]
                assert 13 in rules["matched_rules"], rules
                assert 14 not in rules["matched_rules"], rules
                assert rules["open"]["width"] == 480, rules
                assert rules["open"]["height"] == 310, rules
                assert rules["live"]["opacity"] == 0.7, rules

                # 11b: dialog X11 window transient for main window
                proc_x11.stdin.write("dialog MatchedX11 MatchedX11 Dialog Window\n")
                proc_x11.stdin.flush()
                win_dlg = wait_for(
                    lambda: next((w for w in windows() if w.get("title") == "Dialog Window"), None),
                    "X11 dialog window did not map",
                )
                rules_dlg = request({"version": 1, "command": 'get_window_rules', "params": {"id": win_dlg["id"]}})["WindowRules"]
                assert 14 in rules_dlg["matched_rules"], rules_dlg
                assert 13 not in rules_dlg["matched_rules"], rules_dlg
                assert rules_dlg["open"]["width"] == 250, rules_dlg
                assert rules_dlg["open"]["height"] == 180, rules_dlg

                action('close_window', {"id": win_dlg["id"]})
                wait_for(lambda: not any(w["id"] == win_dlg["id"] for w in windows()), "dialog did not close")
                close_win(win_main["id"], proc_x11)
                print("PASS: Case 11")

                print("Testing Case 12: ReloadConfig changes live properties without moving window...")
                proc, _ = spawn_wayland("test.reload")
                win = wait_for(
                    lambda: next((w for w in windows() if w.get("app_id") == "test.reload"), None),
                    "test.reload did not map",
                )
                init_x, init_y = win["x"], win["y"]
                init_w, init_h = win["width"], win["height"]
                rules = request({"version": 1, "command": 'get_window_rules', "params": {"id": win["id"]}})["WindowRules"]
                assert rules["live"]["opacity"] == 0.6, rules
                assert rules["live"]["skip_taskbar"] is False, rules
                shell = request({'version': 1, 'command': 'get_shell_state', 'params': {}})["ShellState"]
                chip_wids = [c["window_id"] for c in shell["taskbars"][0]["chips"]]
                assert win["id"] in chip_wids, chip_wids

                # Reload config with new live properties
                new_config = CONFIG_TOML.replace("opacity = 0.6\nskip_taskbar = false", "opacity = 0.9\nskip_taskbar = true")
                config_file.write_text(new_config)
                action('reload_config')

                wait_for(
                    lambda: (r := request({"version": 1, "command": 'get_window_rules', "params": {"id": win["id"]}})["WindowRules"])
                    and r["live"]["opacity"] == 0.9
                    and r["live"]["skip_taskbar"] is True
                    and r,
                    "ReloadConfig did not update live rules",
                )
                # Check chip removed
                shell = request({'version': 1, 'command': 'get_shell_state', 'params': {}})["ShellState"]
                chip_wids = [c["window_id"] for c in shell["taskbars"][0]["chips"]]
                assert win["id"] not in chip_wids, chip_wids

                # Verify geometry did not change
                win_after = next(w for w in windows() if w["id"] == win["id"])
                assert win_after["x"] == init_x, (win_after["x"], init_x)
                assert win_after["y"] == init_y, (win_after["y"], init_y)
                assert win_after["width"] == init_w, (win_after["width"], init_w)
                assert win_after["height"] == init_h, (win_after["height"], init_h)
                close_win(win["id"], proc)
                print("PASS: Case 12")

                print("Testing Case 13: MatchWindowRules dry-run...")
                res = request({'version': 1, 'command': 'match_window_rules', 'params': {"app_id": "test.size"}})["MatchWindowRules"]
                assert 3 in res["matched_rules"], res
                assert res["open"]["width"] == 500, res

                res_none = request({'version': 1, 'command': 'match_window_rules', 'params': {"app_id": "nonexistent.app"}})["MatchWindowRules"]
                assert res_none["matched_rules"] == [], res_none
                print("PASS: Case 13")

                print("ALL 13 WINDOW RULES TEST CASES PASSED!")

        except Exception:
            for p in tmp.glob("*.log"):
                print(f"=== {p.name} ===")
                print(p.read_text())
            raise
        finally:
            for p, f in clients:
                if p.poll() is None:
                    p.terminate()
                    try:
                        p.wait(timeout=2)
                    except subprocess.TimeoutExpired:
                        p.kill()
                f.close()
            if compositor.poll() is None:
                compositor.terminate()
                try:
                    compositor.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    compositor.kill()


if __name__ == "__main__":
    run()

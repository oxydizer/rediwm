#!/usr/bin/env python3
"""Taskbar preview and window context menu in isolated headless sessions."""
import os
import signal
from pathlib import Path
import subprocess
import tempfile

from PIL import Image, ImageChops
from desktop_zoom import build_client, wait_for
from ipc_client import IPCClient, spawn_compositor, stop_process


def run():
    with tempfile.TemporaryDirectory(prefix="rediwm-peek-") as directory:
        tmp = Path(directory)
        build_client(tmp)
        process, log = spawn_compositor(tmp, config_content='''[compositor]
xwayland = false
inactive_opacity = 0.8
[[window_rules]]
app_id = "peek.a"
opacity = 0.7
''', env_extra={"DBUS_SESSION_BUS_ADDRESS": "", "XDG_CACHE_HOME": str(tmp / "cache"), "XDG_CONFIG_HOME": str(tmp / "config"), "XDG_DATA_HOME": str(tmp / "data")})
        clients = []
        client_logs = {}
        try:
            with IPCClient(tmp) as ipc:
                ipc.wait_for("wallpaper_presented", timeout_ms=10000)
                display = wait_for(lambda: next((p.name for p in tmp.glob("wayland-*") if not p.name.endswith(".lock")), None), "display")
                for name in ("peek.a", "peek.b"):
                    client_logs[name] = (tmp / f"{name}.log").open("w")
                    clients.append(subprocess.Popen([str(tmp / "client"), "--app-id", name],
                        env=dict(os.environ, XDG_RUNTIME_DIR=str(tmp), WAYLAND_DISPLAY=display),
                        stdout=client_logs[name], stderr=subprocess.DEVNULL))
                    wait_for(lambda: any(w["app_id"] == name for w in ipc.get_windows()), name)
                wins = {w["app_id"]: w["id"] for w in ipc.get_windows()}
                a, b = wins["peek.a"], wins["peek.b"]
                ipc.action('move_window_to', {"id": a, "x": 50, "y": 50})
                ipc.action('move_window_to', {"id": b, "x": 600, "y": 50})
                ipc.action('focus_window', {"id": b})
                now = 1000

                def advance(ms=200):
                    nonlocal now
                    now += ms
                    ipc.action('set_anim_time', {"ms": now})
                    ipc.wait_for_frame()

                def hover(wid):
                    bar = ipc.get_shell_state()["taskbars"][0]
                    box = next(c["box"] for c in bar["chips"] if c["window_id"] == wid)
                    ipc.move_cursor(box["x"] + box["width"] // 2, box["y"] + box["height"] // 2)
                    ipc.wait_for_frame()

                def opacity(wid):
                    return ipc.request(raw_cmd={"version": 1, "command": 'get_window_rules', "params": {"id": wid}})["live"]["effective_opacity"]

                def check(x, y, focused=None):
                    assert abs(opacity(a) - x) < .001, (opacity(a), x)
                    assert abs(opacity(b) - y) < .001, (opacity(b), y)
                    assert ipc.get_focused_window()["id"] == (b if focused is None else focused)

                def shot(name):
                    path = tmp / f"{name}.png"
                    ipc.screenshot(str(path))
                    with Image.open(path) as image:
                        return image.convert("RGB").crop((610, 150, 700, 220))

                advance()
                hover(a)
                advance()
                check(.56, 1)
                baseline = shot("baseline")
                ipc.key(125, True)  # Left Super; pointer already on the chip.
                ipc.wait_for_frame()
                advance(50)
                assert .2 < opacity(b) < 1
                advance()
                check(.9, .2)
                assert ImageChops.difference(baseline, shot("dimmed")).getbbox()
                hover(b)
                assert abs(opacity(b) - .9) < .001
                advance()
                check(.2, .9)
                hover(a)
                advance()
                ipc.key(125, False)
                ipc.wait_for_frame()
                advance(50)
                assert .2 < opacity(b) < 1
                advance()
                check(.56, 1)
                assert ImageChops.difference(baseline, shot("restored")).getbbox() is None
                # Super before hover, leaving the bar, and mid-fade reversal.
                ipc.move_cursor(10, 10)
                ipc.key(125, True)
                hover(a)
                advance(30)
                ipc.key(125, False)
                ipc.wait_for_frame()
                before = opacity(b)
                advance(30)
                assert before < opacity(b) < 1
                advance()
                check(.56, 1)
                ipc.key(125, True)
                ipc.wait_for_frame()
                advance()
                check(.9, .2)
                ipc.move_cursor(10, 10)
                ipc.wait_for_frame()
                advance()
                check(.9, .2)
                # An overlapping dimmed window must not intercept preview input.
                ipc.action('move_window_to', {"id": b, "x": 100, "y": 100})
                # The selected client receives clicks and scroll with Super held.
                ipc.move_cursor(150, 200)
                ipc.action('pointer_button', {"button": 272, "pressed": True})
                ipc.action('pointer_button', {"button": 272, "pressed": False})
                ipc.scroll(0, 10)
                advance()
                check(.9, .2, focused=a)
                def received_input():
                    text = (tmp / "peek.a.log").read_text()
                    return "button 272 1" in text and "button 272 0" in text and "axis " in text
                wait_for(received_input, "previewed client did not receive input")
                ipc.key(125, False)
                ipc.wait_for_frame()
                advance()
                check(.7, .8, focused=a)
                # Pressing Super away from a chip must not resurrect the latch.
                ipc.key(125, True)
                ipc.wait_for_frame()
                advance()
                check(.7, .8, focused=a)
                hover(a)
                advance()
                check(.9, .2, focused=a)
                ipc.action('close_window', {"id": a})
                wait_for(lambda: len(ipc.get_windows()) == 1, "previewed client did not close")
                ipc.wait_for_frame()
                advance()
                assert abs(opacity(b) - 1) < .001
                ipc.key(125, False)
            print("PASS: taskbar peek, switching, fades, configured opacity, pixels, overlapping-window input, focus and close")
        except Exception:
            log.flush()
            print((tmp / "compositor.log").read_text()[-3000:])
            raise
        finally:
            for client in clients:
                stop_process(client)
            for handle in client_logs.values():
                handle.close()
            stop_process(process)
            log.close()


def context_menu():
    """Window actions work independently of preview animation/rendering."""
    with tempfile.TemporaryDirectory(prefix="rediwm-window-menu-") as directory:
        tmp = Path(directory)
        build_client(tmp)
        process, log = spawn_compositor(tmp, scale=float(os.environ.get("REDIWM_TEST_SCALE", "1")),
            renderer=os.environ.get("REDIWM_TEST_RENDERER", "pixman"),
            config_content='[compositor]\nxwayland = false\n[animations]\nenabled = false\n', env_extra={
                "DBUS_SESSION_BUS_ADDRESS": "", "XDG_CACHE_HOME": str(tmp / "cache"),
                "XDG_CONFIG_HOME": str(tmp / "config"), "XDG_DATA_HOME": str(tmp / "data")})
        clients = []
        try:
            with IPCClient(tmp) as ipc:
                ipc.wait_for("wallpaper_presented", timeout_ms=10000)
                display = wait_for(lambda: next((p.name for p in tmp.glob("wayland-*") if not p.name.endswith(".lock")), None), "display")

                def launch(name):
                    client = subprocess.Popen([str(tmp / "client"), "--app-id", name],
                        env=dict(os.environ, XDG_RUNTIME_DIR=str(tmp), WAYLAND_DISPLAY=display),
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    clients.append(client)
                    window = wait_for(lambda: next((w for w in ipc.get_windows() if w["app_id"] == name), None), name)
                    ipc.wait_for_frame()
                    return client, window["id"]

                def menu(wid):
                    bar = ipc.get_shell_state()["taskbars"][0]
                    box = next(c["box"] for c in bar["chips"] if c["window_id"] == wid)
                    x = box["x"] + box["width"] // 2
                    ipc.move_cursor(x, box["y"] + box["height"] // 2)
                    ipc.action('pointer_button', {"button": 273, "pressed": True})
                    ipc.action('pointer_button', {"button": 273, "pressed": False})
                    ipc.wait_for_frame()
                    return x, bar["box"]["y"] - 83 - 4

                def key(code):
                    ipc.key(code, True)
                    ipc.key(code, False)

                client, wid = launch("menu.close")
                other, other_id = launch("menu.other")
                x, y = menu(wid)
                assert ipc.get_focused_window()["id"] == other_id
                preview = os.environ.get("REDIWM_MENU_PREVIEW")
                if preview:
                    Path(preview).unlink(missing_ok=True)
                    ipc.screenshot(preview)
                ipc.click_at(x + 20, y + 41)  # Separator is inert.
                assert len(ipc.get_windows()) == 2
                key(1)  # Escape dismisses without closing the window.
                assert len(ipc.get_windows()) == 2
                menu(wid)
                ipc.click_at(10, 10)  # Outside press and release are swallowed.
                assert len(ipc.get_windows()) == 2
                x, y = menu(wid)
                ipc.click_at(x + 20, y + 22)
                wait_for(lambda: len(ipc.get_windows()) == 1, "menu Close did not close the client")
                assert client.wait(timeout=5) == 0
                menu(other_id)
                other.terminate()
                wait_for(lambda: not ipc.get_windows(), "menu target did not disappear")
                client, wid = launch("menu.hung")
                ipc.action('minimize_window', {"id": wid})
                ipc.wait_for_frame()
                client.send_signal(signal.SIGSTOP)
                menu(wid)
                assert next(w for w in ipc.get_windows() if w["id"] == wid)["is_minimized"]
                key(108)  # Down selects Close.
                key(108)  # Down skips the separator to Force Close.
                key(28)
                wait_for(lambda: not ipc.get_windows(), "Force Close did not remove hung client")
                assert client.wait(timeout=5) == -signal.SIGKILL
                ipc.open_control_center()
                shell = wait_for(lambda: next((w for w in ipc.get_windows() if w["backend"] == "shell"), None), "Settings window")
                menu(shell["id"])
                key(103)  # Up selects Force Close directly.
                key(28)
                wait_for(lambda: not ipc.get_windows(), "Force Close did not close Settings")
                assert process.poll() is None
            print("PASS: taskbar menu: Close, Force Close, separator, dismissal, minimized and disappearing targets")
        except Exception:
            log.flush()
            print((tmp / "compositor.log").read_text()[-3000:])
            raise
        finally:
            for client in clients:
                stop_process(client)
            stop_process(process)
            log.close()


if __name__ == "__main__":
    context_menu()
    run()

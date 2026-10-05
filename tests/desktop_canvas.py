#!/usr/bin/env python3
"""Canvas UI persistence, bounds, screen-sized keys and drag settlement."""
from pathlib import Path
import os
import shutil
import tempfile
import time
from ipc_client import IPCClient, spawn_compositor, stop_process


def run():
    with tempfile.TemporaryDirectory(prefix="rediwm-canvas-") as directory:
        tmp = Path(directory)
        # A 100 ms desktop slide settles well inside the 0.25 s waits below.
        original = '# keep me\n[input]\ninvert_scroll = false\npan_speed = 1.0\n[compositor]\nxwayland = false\ndesktop_switch_ms = 100\n'
        process, log = spawn_compositor(
            tmp, config_content=original, renderer=os.getenv("REDIWM_TEST_RENDERER", "pixman"),
            env_extra={"DBUS_SESSION_BUS_ADDRESS": ""})
        try:
            with IPCClient(tmp, timeout=20) as ipc:
                def camera():
                    return ipc.request(raw_cmd={'version': 1, 'command': 'get_camera'})

                def chord(key):
                    ipc.key(125, True)
                    ipc.key_press(key)
                    ipc.key(125, False)

                def widgets():
                    return ipc.get_widget_tree("control_center")["widgets"]

                def check_grid(columns, rows):
                    cells = [w["box"] for w in widgets() if w.get("name") == "desktop_preview_cell"]
                    assert len(cells) == columns * rows, cells
                    size = cells[0]["width"]
                    assert size > 0
                    assert all(c["width"] == size and c["height"] == size for c in cells), cells
                    xs = sorted({c["x"] for c in cells})
                    ys = sorted({c["y"] for c in cells})
                    assert len(xs) == columns and len(ys) == rows, cells
                    for positions in (xs, ys):
                        assert all(abs(b - a - size - 3) < .01 for a, b in zip(positions, positions[1:])), cells

                def click(label, index=0):
                    widget = [w for w in widgets() if w["label"] == label][index]
                    box = widget["box"]
                    panel = ipc.get_shell_state()["control_center"]["box"]
                    ipc.click_at(round(panel["x"] + box["x"] + box["width"] / 2),
                                 round(panel["y"] + box["y"] + box["height"] / 2))
                    time.sleep(.2)

                base = camera()
                width, height = base["max_x"], base["max_y"]
                assert width > 0 and height > 0, base
                chord("Right")
                time.sleep(.25)
                assert camera()["x"] == width, camera()
                chord("Right")
                time.sleep(.25)
                assert camera()["x"] == width
                chord("Left")
                chord("Left")
                time.sleep(.25)
                assert camera()["x"] == -width, camera()
                chord("Down")
                time.sleep(.25)
                assert camera()["y"] == height
                chord("Up")
                time.sleep(.25)
                assert camera()["y"] == 0

                # Back home: the settings window opens on the visible screen,
                # and a window keeps whatever canvas it sits on reachable.
                chord("Right")
                time.sleep(.25)
                assert camera()["x"] == 0 and camera()["y"] == 0, camera()
                ipc.action('open_control_center')
                time.sleep(.3)
                click("Desktop")
                assert any(w["label"] == "3 × 3  ·  9 screens total" for w in widgets())
                check_grid(3, 3)
                def fixed_toggle():
                    return next(w for w in widgets() if w.get("name") == "desktop_icons_fixed")
                assert fixed_toggle()["checked"] is True
                panel = ipc.get_shell_state()["control_center"]["box"]
                ipc.move_cursor(panel["x"] + panel["width"] - 100, panel["y"] + panel["height"] - 100)
                ipc.scroll(0, 400)
                time.sleep(.2)
                for enabled in (False, True):
                    toggle = fixed_toggle()
                    box = toggle["box"]
                    panel = ipc.get_shell_state()["control_center"]["box"]
                    ipc.click_at(round(panel["x"] + box["x"] + box["width"] / 2),
                                 round(panel["y"] + box["y"] + box["height"] / 2))
                    time.sleep(.2)
                    assert fixed_toggle()["checked"] is enabled, (toggle, panel, fixed_toggle())
                    assert "desktop_icons_fixed = " + str(enabled).lower() in (tmp / "rediwm-config.toml").read_text()
                ipc.scroll(0, -400)
                time.sleep(.2)
                click("→", 0)
                click("←", 1)
                check_grid(4, 2)
                state = camera()
                assert state["max_x"] == width * 1.5 and state["max_y"] == height / 2, state
                saved = (tmp / "rediwm-config.toml").read_text()
                assert "canvas_columns = 4" in saved and "canvas_rows = 2" in saved
                assert "# keep me" in saved and "pan_speed = 1.0" in saved
                ipc.screenshot(path=str(tmp / "canvas.png"))
                shutil.copyfile(tmp / "canvas.png", "/tmp/rediwm-desktop-canvas.png")
                for _ in range(6):
                    click("→", 0)
                assert camera()["max_x"] == width * 4.5
                assert [w for w in widgets() if w["label"] == "→"][0]["is_disabled"]
                for _ in range(8):
                    click("→", 1)
                assert camera()["max_y"] == height * 4.5
                assert any(w["label"] == "10 × 10  ·  100 screens total" for w in widgets())
                check_grid(10, 10)
                click("Reset to Default")
                assert camera()["max_x"] == width and camera()["max_y"] == height
                for _ in range(2):
                    click("←", 0)
                    click("←", 1)
                assert camera()["max_x"] == 0 and camera()["max_y"] == 0
                assert camera()["x"] == 0 and camera()["y"] == 0
                click("Reset to Default")
                ipc.close_panel("control_center")
                ipc.wait_for("control_center_closed", timeout_ms=5000)

                # A drag must stop immediately inside the bounds.
                ipc.action('move_cursor', {"x": 600, "y": 350})
                ipc.key(125, True)
                ipc.key(56, True)
                ipc.action('move_cursor', {"x": 580, "y": 350})
                ipc.action('move_cursor', {"x": 540, "y": 350})
                ipc.key(56, False)
                ipc.key(125, False)
                released = camera()
                time.sleep(.35)
                assert camera()["x"] == released["x"], (released, camera())

                # External config reload updates bounds without reopening Settings.
                path = tmp / "rediwm-config.toml"
                path.write_text(path.read_text().replace("canvas_columns = 3", "canvas_columns = 5"))
                time.sleep(.7)
                assert camera()["max_x"] == width * 2, camera()
                chord("Right")
                chord("Right")
                time.sleep(.25)
                assert camera()["x"] == width * 2, camera()
                # At 70% zoom the key snaps to the nearest desktop, steps, and
                # centres it: from desktop +1, Left centres the home desktop.
                chord("Left")
                time.sleep(.25)
                ipc.action('set_zoom', {"percent": 70})
                time.sleep(.8)
                chord("Left")
                time.sleep(.25)
                assert abs(camera()["x"] + width * (1 / .7 - 1) / 2) <= 2, camera()
                print("PASS: canvas settings, persistence, limits, hot reload, desktop keys and drag stop")
        except Exception:
            print((tmp / "compositor.log").read_text()[-4000:])
            raise
        finally:
            stop_process(process)
            log.close()


if __name__ == "__main__":
    run()

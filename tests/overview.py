#!/usr/bin/env python3
"""Live spread overview: overlapping/minimized windows, balanced rows and restoration."""
import os
from pathlib import Path
import subprocess
import tempfile
import time

from PIL import Image
from desktop_zoom import build_client, wait_for
from ipc_client import IPCClient, spawn_compositor, stop_process


def runs(values):
    result = []
    for value in values:
        if result and value == result[-1][-1] + 1:
            result[-1].append(value)
        else:
            result.append([value])
    return result


def blue_windows(image):
    """Locate the fixture's blue client bodies, independently of grid geometry."""
    pixels = image.load()
    rows = []
    for y in range(image.height):
        xs = [x for x in range(image.width)
              if pixels[x, y][2] > 245 and pixels[x, y][0] < 10 and pixels[x, y][1] < 10]
        rows.append(xs)
    boxes = []
    for band in runs(y for y, xs in enumerate(rows) if len(xs) >= 25):
        if len(band) < 12:
            continue
        occupied = sorted({x for y in band for x in rows[y]})
        row = []
        for columns in runs(occupied):
            if len(columns) >= 25:
                row.append((columns[0], band[0], columns[-1], band[-1]))
        if row:
            boxes.append(row)
    return boxes


def run():
    with tempfile.TemporaryDirectory(prefix="rediwm-spread-") as directory:
        tmp = Path(directory)
        build_client(tmp)
        base = ('[input]\ninvert_scroll = false\n'
                '[theme]\nswitcher_selected_border = "#ff00ff"\n'
                '[keybinds]\n"super+t" = "noop"\n')
        isolated = {"DBUS_SESSION_BUS_ADDRESS": ""}
        for variable, name in (("HOME", "home"), ("XDG_CONFIG_HOME", "config"),
                               ("XDG_DATA_HOME", "data"), ("XDG_CACHE_HOME", "cache")):
            (tmp / name).mkdir(mode=0o700)
            isolated[variable] = str(tmp / name)
        process, log = spawn_compositor(
            tmp, scale=os.environ.get("REDIWM_TEST_SCALE", "1"),
            outputs=os.environ.get("REDIWM_TEST_OUTPUTS", "1"),
            config_content=base, env_extra=isolated,
            binary=os.environ.get("REDIWM_TEST_BINARY"))
        clients, handles, ids = [], [], []
        try:
            with IPCClient(tmp) as ipc:
                ipc.wait_for("wallpaper_presented", timeout_ms=10000)
                clock = int(time.monotonic() * 1000) + 2000
                display = next(p.name for p in tmp.glob("wayland-*") if not p.name.endswith(".lock"))
                outputs = ipc.get_outputs()
                output = outputs[0]

                def tick(dt=1500):
                    nonlocal clock
                    clock += dt
                    ipc.action("set_anim_time", {"ms": clock})
                    ipc.wait_for_frame(output=output["name"])

                def camera():
                    return ipc.action("get_camera")

                def toggle():
                    ipc.key(125, True)
                    ipc.key_down_up(30)
                    ipc.key(125, False)

                def geometry():
                    return sorted((w["id"], w["x"], w["y"], w["width"], w["height"], w["zoom_percent"])
                                  for w in ipc.get_windows())

                def minimized(wid):
                    return ipc.get_window_debug(wid)["minimized"]

                def reload(extra=""):
                    (tmp / "rediwm-config.toml").write_text(base + extra)
                    ipc.action("reload_config")
                    tick()

                def spawn():
                    i = len(clients)
                    handle = (tmp / f"client-{i}.log").open("w")
                    handles.append(handle)
                    clients.append(subprocess.Popen(
                        [str(tmp / "client"), "--app-id", f"overview-{i}"],
                        env=dict(os.environ, XDG_RUNTIME_DIR=str(tmp), WAYLAND_DISPLAY=display,
                                 **({"REDIWM_TEST_PERF": "1", "REDIWM_TEST_PERF_HZ": "30"} if i == 4 else {})),
                        stdout=handle, stderr=handle))
                    ipc.wait_for("window_mapped", app_id=f"overview-{i}")
                    ids.append(next(w["id"] for w in ipc.get_windows() if w["app_id"] == f"overview-{i}"))
                    tick()
                    # Identical positions deliberately hide all but one normally.
                    ipc.action("move_window_to", {"id": ids[-1], "x": 500, "y": 100})
                    tick()

                def picture(name="spread"):
                    path = tmp / (name + ".png")
                    path.unlink(missing_ok=True)
                    ipc.screenshot(str(path), output=output["name"])
                    with Image.open(path) as image:
                        return image.convert("RGB").resize((output["logical_width"], output["logical_height"]))

                def grid(counts):
                    image = picture()
                    if keep := os.environ.get("REDIWM_TEST_LOG_DIR"):
                        image.save(Path(keep) / ("overview-" + "-".join(map(str, counts)) + ".png"))
                    boxes = blue_windows(image)
                    assert [len(row) for row in boxes] == counts, boxes
                    for row in boxes:
                        for left, right in zip(row, row[1:]):
                            assert right[0] - left[2] >= 20, row
                    for upper, lower in zip(boxes, boxes[1:]):
                        assert lower[0][1] - upper[0][3] >= 20, boxes
                    rgb = image.tobytes()
                    assert any(r > 240 and g < 15 and b > 240 for r, g, b in zip(rgb[::3], rgb[1::3], rgb[2::3])), "no selection outline"
                    return [box for row in boxes for box in row]

                tick()
                empty = camera()
                toggle()
                tick()
                assert camera() == empty
                for _ in range(4):
                    spawn()
                ipc.focus_window(ids[0])
                ipc.action("set_zoom", {"percent": 70})
                tick()
                ipc.action("set_camera", {"x": 150, "y": 70})
                tick()
                original, positions = camera(), geometry()
                before = [(tmp / f"client-{i}.log").read_text() for i in range(4)]
                ipc.open_start_menu()
                tick()
                toggle()
                tick()
                grid([2, 2])
                assert camera() == original and geometry() == positions
                assert ipc.get_focused_window()["id"] == ids[0]
                ipc.key_down_up(45)
                ipc.key_down_up(1)
                tick()
                assert camera() == original and geometry() == positions
                assert sum(map(len, blue_windows(picture("restored")))) == 1, "windows stayed spread after cancelling"
                for i, old in enumerate(before):
                    now = (tmp / f"client-{i}.log").read_text()
                    assert "key 45 1" not in now[len(old):]
                    assert now.count("configure ") == old.count("configure "), "spread resized a client"

                # A click before the frames separate must choose the visible
                # front window, rather than the grid's last rectangle.
                toggle()
                tick(0)
                frame = ipc.get_window_debug(ids[0])["chrome_box"]
                z = original["zoom_percent"] / 100
                ipc.move_cursor(round((frame["x"] + frame["width"] / 2 - original["x"]) * z),
                                round((frame["y"] + frame["height"] / 2 - original["y"]) * z),
                                output=output["name"])
                ipc.action("pointer_button", {"button": 272, "pressed": True})
                ipc.action("pointer_button", {"button": 272, "pressed": False})
                tick()
                assert ipc.get_focused_window()["id"] == ids[0]

                spawn()
                ipc.minimize(ids[4])
                tick()
                ipc.focus_window(ids[0])
                tick()
                original, positions = camera(), geometry()
                toggle()
                tick()
                boxes = grid([2, 3])
                assert minimized(ids[4]), "overview restored the minimized window"
                assert geometry() == positions
                # Previously occluded and minimized clients continue receiving frame callbacks.
                frames = (tmp / "client-4.log").read_text().count("frame ")
                wait_for(lambda: (tmp / "client-4.log").read_text().count("frame ") > frames,
                         "minimized preview stopped producing frames")
                ipc.key_down_up(1)
                tick()
                assert minimized(ids[4]) and camera() == original

                # Arrow keys follow the preview grid, even for identical source positions.
                toggle()
                tick()
                ipc.key_down_up(106)
                ipc.key_down_up(28)
                tick()
                assert ipc.get_focused_window()["id"] == ids[1]
                assert geometry() == positions
                assert camera()["zoom_percent"] == original["zoom_percent"]

                # Clicking the last card restores only that minimized window.
                toggle()
                tick()
                boxes = grid([2, 3])
                x0, y0, x1, y1 = boxes[-1]
                ipc.move_cursor((x0 + x1) // 2, (y0 + y1) // 2, output=output["name"])
                old = (tmp / "client-4.log").read_text()
                ipc.action("pointer_button", {"button": 272, "pressed": True})
                tick()
                ipc.action("pointer_button", {"button": 272, "pressed": False})
                assert ipc.get_focused_window()["id"] == ids[4] and not minimized(ids[4])
                assert "button 272" not in (tmp / "client-4.log").read_text()[len(old):]
                assert geometry() == positions

                # All minimized is still a useful overview; cancel leaves all minimized.
                for wid in ids:
                    ipc.minimize(wid)
                tick()
                toggle()
                tick()
                grid([2, 3])
                ipc.key_down_up(1)
                tick()
                assert all(minimized(wid) for wid in ids)
                assert not blue_windows(picture("minimized")), "minimized previews remained on the desktop"
                for wid in ids:
                    ipc.restore(wid)
                tick()

                if len(outputs) > 1:
                    output = outputs[1]
                    ipc.move_cursor(100, 100, output=output["name"])
                    saved = camera()
                    toggle()
                    tick()
                    grid([2, 3])
                    ipc.key_down_up(1)
                    tick()
                    assert camera() == saved
                    output = outputs[0]
                    ipc.move_cursor(0, 0, output=output["name"])

                # Camera distance must not dictate thumbnail size.
                ipc.action("move_window_to", {"id": ids[4], "x": 12000, "y": 100})
                tick()
                for extra in ('[animations]\nenabled = false\n', '[animations]\nreduced_motion = "on"\n',
                              '[compositor]\nfocus_zoom = "boost"\n', '[compositor]\nfocus_zoom = "camera"\n'):
                    reload(extra)
                    ipc.set_zoom(ids[0], 55)
                    ipc.focus_window(ids[0])
                    tick()
                    saved, positions = camera(), geometry()
                    toggle()
                    tick()
                    grid([2, 3])
                    ipc.key_down_up(1)
                    tick()
                    tick()
                    assert camera() == saved and geometry() == positions
                    toggle()
                    tick()
                    reload(extra)
                    assert camera() == saved

                reload()
                saved = camera()
                toggle()
                tick(40)
                toggle()
                tick()
                assert camera() == saved
                # Entering during a minimize effect drops its old scene snapshot.
                reload('[effects.window_minimize]\nenabled = true\n')
                ipc.minimize(ids[1])
                toggle()
                tick()
                grid([2, 3])
                ipc.key_down_up(1)
                tick()
                assert minimized(ids[1])
                reload()
                toggle()
                tick()
                stop_process(clients[0])
                wait_for(lambda: all(w["id"] != ids[0] for w in ipc.get_windows()), "client stayed mapped")
                tick()
                ipc.key_down_up(1)
                tick()

                # A compositor-owned Settings body also participates in the spread.
                ipc.action("open_control_center")
                tick()
                toggle()
                tick()
                ipc.key_down_up(1)
                tick()
                ipc.close_panel("control_center")
                tick()
                toggle()
                tick()
                stop_process(process)
                compositor_log = Path(log.name).read_text()
                assert "error(gpa)" not in compositor_log and "panic:" not in compositor_log
                print("overview: 2x2 and 2+3 live grids, minimized previews, restoration and input isolation passed")
        finally:
            for client in clients:
                stop_process(client)
            stop_process(process)
            for handle in handles:
                handle.close()
            log.close()


if __name__ == "__main__":
    run()

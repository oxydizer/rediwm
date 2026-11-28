#!/usr/bin/env python3
"""Exercise Files chrome in a headless session, optionally saving window crops."""

import argparse
import os
from pathlib import Path
import subprocess
import tempfile

from PIL import Image

from ipc_client import IPCClient, ROOT, spawn_compositor, stop_process
from desktop_zoom import wait_for


def run(binaries, screenshots, baseline, toolbar_relief):
    with tempfile.TemporaryDirectory(prefix="rediwm-files-chrome-") as directory:
        tmp = Path(directory)
        home = tmp / "Home"
        home.mkdir()
        ordinary = home / "Documents"
        ordinary.mkdir()
        (ordinary / "Notes.txt").write_text("Example notes\n")
        (ordinary / "Pictures").mkdir()
        repo = home / "Project"
        repo.mkdir()
        isolated = dict(HOME=str(home), XDG_CONFIG_HOME=str(tmp / "config"),
                        XDG_STATE_HOME=str(tmp / "state"), XDG_DATA_HOME=str(tmp / "data"),
                        XDG_CACHE_HOME=str(tmp / "cache"), DBUS_SESSION_BUS_ADDRESS="",
                        DBUS_SYSTEM_BUS_ADDRESS="unix:path=/nonexistent-rediwm-test-system-bus")
        env = dict(os.environ, **isolated, REDIWM_FILES_DEVICES="0", REDIWM_FILES_THUMBNAILS="0")
        def git(*args):
            subprocess.run(["git", "-C", str(repo), "-c", "user.name=Files Test",
                            "-c", "user.email=files@example.invalid", *args], env=env, check=True)

        readme = repo / "README.md"
        readme.write_text("Example project\n")
        git("init", "-q")
        git("add", "README.md")
        git("commit", "-qm", "Initial files")
        readme.write_text("Example project\nA local edit\n")
        config = ('[compositor]\nxwayland = false\nfocus_zoom = "keep"\n'
                  '[desktop]\nenabled = false\n[animations]\nenabled = false\n'
                  '[theme]\nchrome_height = 46\n')
        if toolbar_relief:
            pressed = "flat" if toolbar_relief == "flat" else "inset"
            config += (f'button_relief = "{toolbar_relief}"\nbutton_pressed_relief = "{pressed}"\n'
                       'app_toolbar = "#808080"\nrelief_depth = 3\nrelief_softness = 3\n'
                       'relief_light_angle = 90\nrelief_light = "#ffffff"\nrelief_dark = "#000000"\n')
        comp, log = spawn_compositor(tmp, config_content=config, binary=binaries / "rediwm",
                                     env_extra=isolated)
        env["REDIWM_CONFIG"] = str(tmp / "rediwm-config.toml")
        client = None
        try:
            with IPCClient(tmp, timeout=12) as ipc:
                display = next(p.name for p in tmp.glob("wayland-*") if not p.name.endswith(".lock"))
                client = subprocess.Popen([str(binaries / "rediwm-files"), str(ordinary)],
                                          env=dict(env, XDG_RUNTIME_DIR=str(tmp), WAYLAND_DISPLAY=display))

                def find_window():
                    return next((w for w in ipc.get_windows() if w["app_id"] == "rediwm-files"), None)

                wid = wait_for(find_window, "Files did not map")["id"]
                ipc.focus_window(wid)
                ipc.set_zoom(wid, 100)

                def widgets():
                    return {w["name"]: w for w in ipc.get_widget_tree(f"window/{wid}")["widgets"]}

                def tabs():
                    return [w for name, w in widgets().items() if name.startswith("tab/") and
                            not name.endswith("/close")]

                def click_widget(name, dx=None):
                    box = widgets()[name]["global_box"]
                    ipc.click_at(box["x"] + (dx if dx is not None else box["width"] // 2),
                                 box["y"] + box["height"] // 2)

                def key(code, ctrl=False):
                    if ctrl:
                        ipc.key(29, True)
                    ipc.key_down_up(code)
                    if ctrl:
                        ipc.key(29, False)

                def title(name):
                    wait_for(lambda: (find_window() or {}).get("title") == name + " — RediWM Files", name)

                def resize(width, height):
                    frame = find_window()
                    client_box = ipc.get_window_debug(wid)["client_box"]
                    client_width = width - (frame["width"] - client_box["width"])
                    client_height = height - (frame["height"] - client_box["height"])
                    ipc.action("set_window_size", {"id": wid, "width": client_width, "height": client_height})
                    wait_for(lambda: (find_window()["width"], find_window()["height"]) == (width, height),
                             f"frame did not resize to {width}x{height}")
                    ipc.action("move_window_to", {"id": wid, "x": 32, "y": 32})
                    ipc.wait_for_frame()

                def local(x, y):
                    box = ipc.get_window_debug(wid)["client_box"]
                    return box["x"] + x, box["y"] + y

                def capture(x, y, w, h):
                    ipc.wait_for_frame()
                    full = tmp / "shot.png"
                    full.unlink(missing_ok=True)
                    ipc.screenshot(path=str(full))
                    with Image.open(full) as image:
                        return image.crop((x, y, x + w, y + h))

                def shot(name):
                    if screenshots is None:
                        return
                    win = find_window()
                    capture(*(win[k] for k in ("x", "y", "width", "height"))).save(screenshots / (name + ".png"))

                def check_toolbar_relief():
                    width = ipc.get_window_debug(wid)["client_box"]["width"]
                    grid, listing, sort, filter_button = (width - offset for offset in (254, 224, 150, 51))
                    new = 58
                    # Coordinates in the crop start just after the navigation divider.
                    def pixel(image, x, y):
                        return image.getpixel((x, y - 42))

                    def capture_when(predicate, message):
                        def matching():
                            image = capture(*local(0, 42), width, 39)
                            return image if predicate(image) else None
                        return wait_for(matching, message)

                    def raised(image, raised_buttons, inset_buttons):
                        blank = pixel(image, 400, 47)
                        return (all(pixel(image, x, 47)[0] > blank[0] + 12 for x in raised_buttons)
                                and all(pixel(image, x, 47) == blank for x in inset_buttons))

                    def move_away():
                        ipc.move_cursor(*local(500, 250))

                    move_away()
                    controls = (new, grid, listing, sort, filter_button)
                    rest = capture_when(
                        lambda image: raised(image, (new, listing, sort, filter_button), (grid,))
                        if toolbar_relief == "raised" else raised(image, (), controls),
                        "resting toolbar relief did not match the theme and selected view",
                    )
                    if screenshots:
                        rest.save(screenshots / "toolbar-rest.png")
                    if toolbar_relief == "raised":
                        ipc.click_at(*local(listing, 62))
                        move_away()
                        capture_when(lambda image: raised(image, (grid,), (listing,)), "List did not take selected relief")
                        ipc.click_at(*local(grid, 62))
                        move_away()
                        capture_when(lambda image: image.tobytes() == rest.tobytes(), "Grid did not restore selected relief")
                    if toolbar_relief != "flat":
                        # Outside the hit target, so the moving chip cannot account for the changed pixel.
                        ipc.move_cursor(*local(new, 78))
                        near = capture_when(lambda image: pixel(image, new, 80) != pixel(rest, new, 80),
                                            "proximity elevation did not reach outside New")
                        if screenshots:
                            near.save(screenshots / "toolbar-proximity.png")
                        move_away()
                        capture_when(lambda image: image.tobytes() == rest.tobytes(), "toolbar kept stale hover pixels")

                resize(962, 590)
                wait_for(lambda: len(tabs()) == 1, "single tab did not publish")
                title("Documents")
                bar = widgets()["titlebar"]["box"]
                assert bar["height"] == (46 if baseline else 34), bar
                if not baseline:
                    tab = tabs()[0]["box"]
                    plus = widgets()["tab_new"]["box"]
                    assert (tab["y"], tab["width"], tab["height"]) == (4, 188, 30), tab
                    assert (plus["x"] - tab["x"] - tab["width"], plus["y"], plus["width"], plus["height"]) == (2, 6, 24, 24), plus
                    controls = [widgets()[name]["box"] for name in ("minimize", "maximize", "close")]
                    assert all(c["y"] + c["height"] == bar["height"] - 6 for c in controls), controls
                    assert all(b["x"] - a["x"] - a["width"] == 12 for a, b in zip(controls, controls[1:])), controls
                shot("wide-single-grid")
                if toolbar_relief and not baseline:
                    check_toolbar_relief()

                ipc.click_at(*local(141, 21))
                title("Home")
                ipc.click_at(*local(26, 21))
                title("Documents")
                # Ctrl+L focuses the same field used by the breadcrumb trail.
                key(38, ctrl=True)
                shot("wide-address")
                key(1)
                click_widget("tab_new")
                wait_for(lambda: len(tabs()) == 2, "new tab did not publish")
                key(38, ctrl=True)
                ipc.action("type_text", {"text": str(repo)})
                key(28)
                title("Project")
                ipc.click_at(*local(727 if baseline else 734, 82 if baseline else 62))
                shot("wide-repository-list")

                # Hover Filter and verify the existing menu opens from its new anchor.
                filter_y = 82 if baseline else 62
                ipc.move_cursor(*local(910, filter_y))
                shot("wide-filter-hover")
                ipc.click_at(*local(910, filter_y))
                shot("wide-filter-menu")
                key(1)

                resize(362, 500)
                w = widgets()
                assert "tab_previous" in w and "tab_next" in w, w.keys()
                if not baseline:
                    assert 108 <= tabs()[0]["box"]["width"] <= 188, tabs()
                shot("narrow-repository-overflow")
                click_widget("tab_previous")
                title("Documents")
                # Overflow arrows step through tabs and keep the selected tab visible.
                resize(962, 590)
                document = next(w for w in tabs() if w["label"] == "Documents")
                project = next(w for w in tabs() if w["label"] == "Project")
                click_widget(project["name"], dx=20)
                title("Project")
                a, b = (w["global_box"] for w in (document, project))
                ipc.action("drag", {"from_x": a["x"] + 20, "from_y": a["y"] + 15,
                                    "to_x": b["x"] + b["width"] - 15, "to_y": b["y"] + 15})
                wait_for(lambda: [w["label"] for w in tabs()] == ["Project", "Documents"], "tab did not reorder")
                click_widget(document["name"], dx=20)
                title("Documents")
                shot("wide-multiple-tabs")
                click_widget(document["name"] + "/close")
                wait_for(lambda: len(tabs()) == 1, "close tab did not remove it")
                title("Project")

                # Drag the gap between the plus button and window controls.
                w = widgets()
                plus = w["tab_new"]["global_box"]
                minimize = w["minimize"]["global_box"]
                x = (plus["x"] + plus["width"] + minimize["x"]) // 2
                y = plus["y"] + plus["height"] // 2
                before = find_window()
                ipc.action("drag", {"from_x": x, "from_y": y, "to_x": x + 50, "to_y": y + 30})
                wait_for(lambda: find_window()["x"] != before["x"], "titlebar drag did not move Files")
                click_widget("close")
                wait_for(lambda: find_window() is None, "window close button did not close Files")
        except Exception:
            print(Path(log.name).read_text()[-4000:])
            raise
        finally:
            if client is not None:
                stop_process(client)
            stop_process(comp)
            log.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binaries", type=Path, default=ROOT / "zig-out/bin")
    parser.add_argument("--screenshots", type=Path)
    parser.add_argument("--baseline", action="store_true", help="drive the upstream geometry")
    parser.add_argument("--toolbar-relief", choices=("flat", "raised", "inset"),
                        help="check toolbar pixels with the chosen relief style")
    args = parser.parse_args()
    if args.screenshots:
        args.screenshots.mkdir(parents=True, exist_ok=True)
    run(args.binaries, args.screenshots, args.baseline, args.toolbar_relief)
    print("Files chrome checks passed")

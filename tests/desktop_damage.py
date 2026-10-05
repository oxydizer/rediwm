#!/usr/bin/env python3
"""Desktop damage and texture reuse regression on an isolated headless output.

Compare identical settled states reached through different repaint histories.
The fixture exercises the compositor-drawn desktop and synthetic IPC input;
it never connects to the host display or session bus.
"""
import argparse
import math
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

from PIL import Image, ImageChops

from ipc_client import IPCClient, ROOT


def run(args):
    with tempfile.TemporaryDirectory(prefix="rediwm-desktop-damage-") as directory:
        tmp = Path(directory)
        desktop_dir = tmp / "Desktop"
        desktop_dir.mkdir()
        names = ("Alpha with two lines.txt", "Bravo.txt", "Charlie.txt")
        for name in names:
            (desktop_dir / name).write_text("desktop damage fixture")
        config = tmp / "config.toml"
        def configure_scale(scale, desktop=True):
            config.write_text(f'[compositor]\nxwayland = false\n[desktop]\nenabled = {str(desktop).lower()}\n'
                              f'[[outputs]]\nname = "HEADLESS-1"\nscale = {scale}\n')

        configure_scale(args.scale)
        env = dict(os.environ, XDG_RUNTIME_DIR=directory,
                   XDG_CONFIG_HOME=str(tmp / "config"), XDG_DATA_HOME=str(tmp / "data"),
                   XDG_CACHE_HOME=str(tmp / "cache"), REDIWM_CONFIG=str(config),
                   REDIWM_DESKTOP_BUILTINS="0", REDIWM_DESKTOP_DIR=str(desktop_dir), WLR_BACKENDS="headless",
                   WLR_HEADLESS_OUTPUTS="1", WLR_RENDERER=args.renderer, REDIWM_SCALE="auto",
                   DBUS_SESSION_BUS_ADDRESS="")
        env.pop("WAYLAND_DISPLAY", None)
        env.pop("REDIWM_SOCKET", None)
        processes = []

        def start(binary, log_name, **extra):
            with (tmp / log_name).open("w") as log:
                process = subprocess.Popen([str(args.bin_dir / binary)], env=dict(env, **extra),
                                           stdout=log, stderr=log)
            processes.append(process)
            return process

        def wait_for(predicate, message, timeout=10):
            deadline = time.monotonic() + timeout
            while True:
                assert all(p.poll() is None for p in processes), "fixture process exited"
                result = predicate()
                if result:
                    return result
                assert time.monotonic() < deadline, message
                time.sleep(.05)

        try:
            start("rediwm", "compositor.log")
            socket = wait_for(lambda: next(tmp.glob("rediwm-*.sock"), None), "IPC unavailable")
            display = wait_for(lambda: next((p.name for p in tmp.glob("wayland-*")
                                            if not p.name.endswith(".lock")), None), "display unavailable")
            with IPCClient(socket) as ipc:
                ipc.action('wait_for', {"condition": "wallpaper_presented", "timeout_ms": 10000})
                ipc.action('wait_for', {"condition": "catalog_published", "timeout_ms": 10000})
                output = ipc.get_outputs()[0]
                width, height = output["logical_width"], output["logical_height"]
                assert width >= 1000 and height >= 650, output
                layout = tmp / "config/rediwm-desktop/layout.toml"
                wait_for(layout.exists, "desktop never saved its layout")
                time.sleep(.8)

                def move(point):
                    ipc.move_cursor(*point)

                def button(pressed, code=272):
                    ipc.action('pointer_button', {"button": code, "pressed": pressed})

                def click(point, code=272):
                    move(point)
                    button(True, code)
                    button(False, code)

                def escape():
                    for pressed in (True, False):
                        ipc.action('key', {"keycode": 1, "pressed": pressed})

                captures = 0

                def capture(name):
                    nonlocal captures
                    # Hover/selection fades last 150ms. Keep the pointer in the
                    # same place for equal states and exclude the taskbar clock.
                    time.sleep(.3)
                    path = tmp / f"{captures:03d}-{name}.png"
                    captures += 1
                    ipc.action('screenshot', {"path": str(path)})
                    if args.capture_dir:
                        args.capture_dir.mkdir(parents=True, exist_ok=True)
                        shutil.copy2(path, args.capture_dir / path.name)
                    with Image.open(path) as image:
                        scale_y = image.height / height
                        return image.convert("RGB").crop((0, 0, image.width,
                                                          round((height - 80) * scale_y)))

                # GLES2 at a fractional scale composites the same scene one
                # level differently depending on render history, with or
                # without the desktop (opening and closing the control center
                # reproduces it). Stale desktop pixels differ by far more.
                tolerance = 1 if args.renderer == "gles2" and args.scale != int(args.scale) else 0

                def equal(expected, actual, message):
                    diff = ImageChops.difference(expected, actual)
                    worst = max(high for _, high in diff.getextrema())
                    assert worst <= tolerance, (message, diff.getbbox(), worst)

                def desktop_stats():
                    return ipc.get_perf()["desktop"]

                home = (400, 350)
                # Older clients can stop their birth fade before its final
                # fully opaque frame. An ordinary click gives both versions a
                # settled starting image for before/after comparison.
                click(home)
                baseline = capture("baseline")
                # Every tile after this point should update its texture in place
                # where the renderer can (GLES2); pixman always re-wraps.
                ipc.action("reset_performance_stats")
                # The rename field extends outside the icon cell. Recycled
                # buffers must preserve its text/selection when only a button
                # hover is damaged, then clear the entire overlay on cancel.
                click((width - 70, 60))
                time.sleep(.15)
                for pressed in (True, False):
                    ipc.action('key', {"keycode": 60, "pressed": pressed})
                move(home)
                rename_reference = capture("rename-reference")
                assert ImageChops.difference(baseline, rename_reference).getbbox(), "rename editor absent"
                for point in ((width - 52, 116), (width - 24, 116), home):
                    move(point)
                    rename_image = capture("rename-hover")
                equal(rename_reference, rename_image, "rename hover damaged retained editor pixels")
                ipc.action('type_text', {"text": "A very long filename that needs horizontal scrolling"})
                capture("rename-scrolled")
                for pressed in (True, False):
                    ipc.action('key', {"keycode": 102, "pressed": pressed})
                capture("rename-home")
                escape()
                move(home)
                equal(baseline, capture("rename-cancel"), "rename editor left stale pixels outside its icon")

                if args.rename_only:
                    print(f"Desktop rename damage pixels passed at scale {args.scale}")
                    return

                # Hover repeatedly enters/leaves icons. Each departed cell must
                # return exactly to its original pixels, including label shadows.
                for row in (0, 1, 2, 1, 0):
                    move((width - 70, 60 + row * 112))
                    hovered = capture(f"hover-{row}")
                    assert ImageChops.difference(baseline, hovered).getbbox(), "hover did not draw"
                    move(home)
                    equal(baseline, capture(f"unhover-{row}"), "hover animation left stale pixels")

                anchor = (width - 240, 355)
                endpoints = ((width - 10, 10), (width - 110, 130),
                             (width - 420, 550), (width - 10, 550),
                             (width - 240, 355), (width - 500, 15))
                references = []
                for index, endpoint in enumerate(endpoints):
                    # Each reference begins at the same clean desktop state.
                    move(anchor)
                    button(True)
                    move(endpoint)
                    references.append(capture(f"reference-{index}"))
                    if index != 4:
                        assert ImageChops.difference(baseline, references[-1]).getbbox(), "rubber band did not draw"
                    button(False)
                    click(home)
                    equal(baseline, capture(f"reference-clear-{index}"), "released selection left stale pixels")

                move(anchor)
                button(True)
                # A continuous gesture changes both axes and revisits every
                # state using buffers containing different older rectangles.
                for index in (0, 1, 3, 2, 5, 4, 0, 5, 1, 2, 3, 0):
                    move(endpoints[index])
                    equal(references[index], capture(f"history-{index}"),
                          f"selection changed with repaint history at endpoint {index}")
                button(False)
                click(home)
                equal(baseline, capture("release"), "selection release left stale pixels")

                # Menus force a large overlapping overlay onto the reusable
                # buffers; closing must clear its fill, border and text.
                click((width - 310, 70), 273)
                menu = capture("menu")
                assert ImageChops.difference(baseline, menu).getbbox(), "context menu absent"
                move((width - 280, 115))
                capture("menu-hover")
                escape()
                move(home)
                equal(baseline, capture("menu-close"), "menu close left stale pixels")

                # Drag across several cells, revisit an identical live ghost,
                # then compare the persisted result with a freshly drawn client.
                origin = (width - 70, 60)
                target = (width - 270, 395)
                move(origin)
                button(True)
                time.sleep(.18)
                move(target)
                dragged = capture("drag-reference")
                assert ImageChops.difference(baseline, dragged).getbbox(), "icon drag absent"
                for point in ((700, 210), (width - 70, 420), (520, 500), target):
                    move(point)
                    image = capture("drag-history")
                equal(dragged, image, "moving icon or drop outline left stale pixels")
                button(False)
                click(home)
                wait_for(lambda: layout.exists() and "cell_col = 2" in layout.read_text()
                         and "cell_row = 3" in layout.read_text(), "drag was not persisted")
                moved = capture("moved")

                # Adding/removing an icon animates its alpha and changes the
                # icon list. The empty cell must return to identical pixels.
                added = desktop_dir / "Delta.txt"
                added.write_text("temporary animated icon")
                time.sleep(.5)
                appeared = capture("appeared")
                assert ImageChops.difference(moved, appeared).getbbox(), "new icon absent"
                added.unlink()
                time.sleep(.5)
                equal(moved, capture("removed"), "icon removal left stale pixels")

                stats = desktop_stats()
                assert stats["paints"] > 0 and stats["tile_presents"] > 0, stats
                if args.renderer == "gles2":
                    assert stats["texture_uploads"] == 0, ("repaints created textures instead of updating them", stats)
                # A freshly started desktop must draw exactly the same image.
                configure_scale(args.scale, desktop=False)
                ipc.reload_config()
                time.sleep(.3)
                configure_scale(args.scale)
                ipc.reload_config()
                time.sleep(.8)
                equal(moved, capture("fresh-moved"), "partial repaint differs from freshly restored desktop")

                # Output density changes rebuild the canvas and repaint every
                # pixel. Return to the original density and compare again.
                for scale in (2 if math.ceil(args.scale) == 1 else 1, args.scale):
                    configure_scale(scale)
                    ipc.reload_config()
                    wait_for(lambda: ipc.get_outputs()[0]["scale"] == scale, "output scale reload failed")
                    capture(f"live-scale-{scale}")
                equal(moved, capture("scale-restored"), "scale round trip changed desktop pixels")
                print(f"Desktop damage pixels passed at scale {args.scale} ({args.renderer}); "
                      f"{stats['paints']} paints, {stats['tile_presents']} tile presents, "
                      f"{stats['texture_uploads']} texture uploads; live scale round trip passed")
        except Exception:
            if args.capture_dir:
                args.capture_dir.mkdir(parents=True, exist_ok=True)
                for path in tmp.glob("*.png"):
                    shutil.copy2(path, args.capture_dir / path.name)
            for path in tmp.glob("*.log"):
                print(path.name, path.read_text()[-4000:])
            raise
        finally:
            for process in reversed(processes):
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=3)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bin-dir", type=Path, default=ROOT / "zig-out/bin")
    parser.add_argument("--scale", type=float, choices=(1, 1.5, 2), default=1)
    parser.add_argument("--rename-only", action="store_true", help="Check the inline rename overlay and cancellation only")
    parser.add_argument("--renderer", choices=("pixman", "gles2"), default=os.environ.get("REDIWM_TEST_RENDERER", "pixman"),
                        help="gles2 also requires in-place texture updates (set WLR_RENDER_DRM_DEVICE)")
    parser.add_argument("--capture-dir", type=Path, help="Save screenshots for before/after comparison")
    run(parser.parse_args())

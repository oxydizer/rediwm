#!/usr/bin/env python3
"""Real Files → Space → image viewer input, pixels and lifecycle in a private session."""
import os
from pathlib import Path
import subprocess
import tempfile
import time
import sys
from PIL import Image, ImageChops
from ipc_client import IPCClient, ROOT
from files_browser import wait_for


def run(scale):
    with tempfile.TemporaryDirectory(prefix="rediwm-images-") as directory:
        tmp = Path(directory)
        pictures = tmp / "Pictures"
        pictures.mkdir()
        # Unequal coloured quadrants expose orientation, stretching and rotation.
        image = Image.new("RGB", (400, 200), (230, 40, 30))
        image.paste((30, 190, 70), (200, 0, 400, 100))
        image.paste((40, 70, 220), (0, 100, 200, 200))
        image.paste((240, 190, 20), (200, 100, 400, 200))
        image.save(pictures / "a landscape.png")
        Image.new("RGBA", (100, 200), (255, 0, 0, 128)).save(pictures / "b alpha.png")
        oriented = Image.new("RGB", (120, 60), (30, 180, 200))
        exif = Image.Exif()
        exif[274] = 6
        oriented.save(pictures / "c oriented.jpg", exif=exif)
        (pictures / "d broken.png").write_bytes(b"not an image")
        image.convert("P").save(pictures / "e palette.png")
        Image.new("RGB", (80, 40), (130, 20, 190)).save(pictures / "f quote'\nline.png")
        (pictures / "z text.txt").write_text("non-image")
        config = tmp / "config.toml"
        config.write_text('[compositor]\nxwayland = false\n')
        env = dict(os.environ, HOME=str(tmp), XDG_RUNTIME_DIR=directory,
                   XDG_CONFIG_HOME=str(tmp / "config"), XDG_DATA_HOME=str(tmp / "data"),
                   XDG_CACHE_HOME=str(tmp / "cache"), XDG_STATE_HOME=str(tmp / "state"), REDIWM_CONFIG=str(config),
                   WLR_BACKENDS="headless", REDIWM_FILES_DEVICES="0", WLR_HEADLESS_OUTPUTS="1",
                   WLR_RENDERER=os.environ.get("REDIWM_TEST_RENDERER", "pixman"),
                   REDIWM_SCALE=str(scale), DBUS_SESSION_BUS_ADDRESS="")
        env.pop("WAYLAND_DISPLAY", None)
        env.pop("REDIWM_SOCKET", None)
        processes = []

        def start(binary, *args, **extra):
            with (tmp / f"{binary}-{len(processes)}.log").open("w") as log:
                proc = subprocess.Popen([str(ROOT / "zig-out/bin" / binary), *args],
                                        env=dict(env, **extra), stdout=log, stderr=log)
            processes.append(proc)
            return proc

        try:
            start("rediwm")
            sock = wait_for(lambda: next(tmp.glob("rediwm-*.sock"), None), "IPC unavailable")
            display = next(p.name for p in tmp.glob("wayland-*") if not p.name.endswith(".lock"))
            with IPCClient(sock) as ipc:
                def windows(app):
                    return [w for w in ipc.get_windows() if w["app_id"] == app]

                def key(code, ctrl=False):
                    if ctrl:
                        ipc.action('key', {"keycode": 29, "pressed": True})
                    for pressed in (True, False):
                        ipc.action('key', {"keycode": code, "pressed": pressed})
                    if ctrl:
                        ipc.action('key', {"keycode": 29, "pressed": False})
                    time.sleep(.12)

                def viewer():
                    return next(iter(windows("rediwm-images")), None)

                def expect_title(prefix):
                    return wait_for(lambda: (w := viewer()) and w["title"].startswith(prefix) and w,
                                    "viewer did not reach " + prefix)

                def click_client(window, x, y):
                    box = ipc.get_window_debug(window["id"])["client_box"]
                    ipc.move_cursor(box["x"] + x, box["y"] + y)
                    for pressed in (True, False):
                        ipc.action('pointer_button', {"button": 272, "pressed": pressed})
                    time.sleep(.15)

                def capture(name):
                    time.sleep(.25)
                    path = tmp / (name + ".png")
                    ipc.screenshot(path=str(path))
                    with Image.open(path) as shot:
                        box = ipc.get_window_debug(viewer()["id"])["client_box"]
                        output = ipc.get_outputs()[0]
                        factor = shot.width / output["logical_width"]
                        region = (box["x"] + 16, box["y"] + 64,
                                  box["x"] + box["width"] - 16,
                                  box["y"] + box["height"] - 132)
                        return shot.convert("RGB").crop(tuple(round(v * factor) for v in region))

                files = start("rediwm-files", str(pictures), WAYLAND_DISPLAY=display)
                file_win = wait_for(lambda: next(iter(windows("rediwm-files")), None), "Files did not map")
                ipc.focus_window(file_win["id"])
                time.sleep(.4)
                key(102)  # Home selects first file.
                key(57)   # Space opens it.
                win = expect_title("a landscape.png")
                assert len(windows("rediwm-images")) == 1
                assert "(1/6)" in win["title"], win
                # Wait for the initial decode and filmstrip to settle.
                time.sleep(1)
                baseline = capture("baseline")
                assert sum(n for n, (r, g, b) in baseline.getcolors(baseline.width * baseline.height) if r > 200 and g < 70 and b < 70) > 1000, "image did not render"
                key(19)  # R rotates.
                rotated = capture("rotated")
                assert ImageChops.difference(baseline, rotated).getbbox(), "rotation did not change pixels"
                key(13)  # +
                key(2)   # 100%
                key(33)  # Fit
                key(44, ctrl=True)  # Rotation is now an edit; undo before browsing.
                key(106)
                expect_title("b alpha.png")
                time.sleep(.5)
                alpha = capture("alpha")
                assert sum(n for n, (r, g, b) in alpha.getcolors(alpha.width * alpha.height) if 135 < r < 165 and 10 < g < 40 and 10 < b < 40) > 100, "alpha was not premultiplied/composited correctly"
                key(106)
                expect_title("c oriented.jpg")
                time.sleep(.5)
                oriented_pixels = capture("oriented")
                r, g, b = oriented_pixels.split()
                mask = ImageChops.multiply(r.point(lambda v: 255 if v < 80 else 0),
                                          g.point(lambda v: 255 if v > 120 else 0))
                mask = ImageChops.multiply(mask, b.point(lambda v: 255 if v > 150 else 0))
                bounds = mask.getbbox()
                assert bounds and bounds[3] - bounds[1] > 1.8 * (bounds[2] - bounds[0]), "EXIF orientation was ignored"
                key(106)
                expect_title("d broken.png")
                time.sleep(.5)
                assert viewer(), "corrupt image closed the viewer"
                key(106)
                expect_title("e palette.png")
                time.sleep(.5)
                palette = capture("palette")
                assert sum(n for n, (r, g, b) in palette.getcolors(palette.width * palette.height) if r > 200 and g < 70 and b < 70) > 1000
                key(106)
                expect_title("f quote'\nline.png")
                key(102)  # Home and End while decodes may be pending.
                key(107)
                expect_title("f quote'\nline.png")
                key(57)
                wait_for(lambda: not viewer(), "Space did not close viewer")
                wait_for(lambda: (w := ipc.get_focused_window()) and w["id"] == file_win["id"], "focus did not return to Files")
                # Space in a text field must type, not launch a preview.
                key(33, ctrl=True)
                key(57)
                assert not viewer()
                key(1)
                key(102)
                key(57)
                expect_title("a landscape.png")
                key(1)
                wait_for(lambda: not viewer(), "Escape did not close viewer")
                # Preserve Files' filtered list and descending sort order.
                key(33, ctrl=True)
                ipc.action('type_text', {"text": ".png"})
                key(28)
                file_box = ipc.get_window_debug(file_win["id"])["client_box"]
                click_client(file_win, file_box["width"] - 152, 80)
                key(108)
                key(28)
                key(102)
                key(57)
                sorted_win = expect_title("f quote'\nline.png")
                assert "(1/5)" in sorted_win["title"], sorted_win
                key(106)
                expect_title("e palette.png")
                key(1)
                wait_for(lambda: not viewer(), "sorted preview did not close")
                # A standalone launch still gets normal chrome and sibling navigation.
                standalone = start("rediwm-images", str(pictures / "a landscape.png"), WAYLAND_DISPLAY=display,
                                   WAYLAND_DEBUG="client")
                win = expect_title("a landscape.png")
                time.sleep(1)
                renderer = env["WLR_RENDERER"]
                preview = Path(f"/tmp/rediwm-images-preview-{renderer}-{scale}.png")
                preview.unlink(missing_ok=True)
                ipc.screenshot(path=str(preview))
                # Maximizing expands the filmstrip to both canvas edges. Click
                # its far-right tile, which used to be empty centered padding.
                ipc.maximize(win["id"])
                time.sleep(.6)
                key(107)
                key(105)
                expect_title("e palette.png")
                box = ipc.get_window_debug(win["id"])["client_box"]
                click_client(win, box["width"] - 24, box["height"] - 74)
                expect_title("f quote'\nline.png")
                # Return through the recent-image cache and restore sizing.
                key(102)
                expect_title("a landscape.png")
                ipc.restore(win["id"])
                time.sleep(.6)
                # A quiet client must not keep publishing frames or repeating scale.
                log = tmp / f"rediwm-images-{len(processes)-1}.log"
                before = log.read_text().count(".attach(")
                time.sleep(.6)
                assert log.read_text().count(".attach(") == before, "viewer repaints while idle"
                assert log.read_text().count(".set_buffer_scale(") <= 2
                ipc.focus_window(win["id"])
                key(1)
                standalone.wait(timeout=5)
                assert standalone.returncode == 0
                # Decoration fallback remains movable and closable on other compositors.
                csd = start("rediwm-images", str(pictures / "b alpha.png"), WAYLAND_DISPLAY=display,
                            REDIWM_IMAGES_FORCE_CSD="1", WAYLAND_DEBUG="client")
                win = expect_title("b alpha.png")
                ipc.focus_window(win["id"])
                from client_cursor import exercise_csd
                exercise_csd(ipc, win, tmp / f"rediwm-images-{len(processes)-1}.log")
                key(1)
                csd.wait(timeout=5)
                assert csd.returncode == 0
                # Shared deletion dialog: cancel preserves the file; its checkbox
                # enables permanent deletion only after explicit confirmation.
                deletion_dir = tmp / "delete-fixture"
                deletion_dir.mkdir()
                target = deletion_dir / "delete-me.png"
                image.save(target)
                deleting = start("rediwm-images", str(target), WAYLAND_DISPLAY=display)
                win = expect_title("delete-me.png")
                ipc.focus_window(win["id"])
                key(111)  # Delete
                key(1)    # Cancel
                assert target.exists()
                key(111)
                key(15)   # Tab: permanent-delete checkbox
                key(57)   # Space: check
                key(15)   # Tab: confirm
                key(28)
                wait_for(lambda: not target.exists(), "permanent delete did not remove fixture")
                deleting.wait(timeout=5)
                assert deleting.returncode == 0
                assert files.poll() is None
                print(f"Image preview, navigation, alpha, palette PNG, corrupt file, input focus, standalone and idle checks passed at {scale}x. Preview: {preview}")
        except Exception:
            for log in tmp.glob("*.log"):
                print(log.name, log.read_text()[-5000:])
            raise
        finally:
            for proc in reversed(processes):
                if proc.poll() is None:
                    proc.terminate()
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait()


if __name__ == "__main__":
    run(float(sys.argv[1]) if len(sys.argv) > 1 else 1)

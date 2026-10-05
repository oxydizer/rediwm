#!/usr/bin/env python3
"""Headless checks for image thumbnails in rediwm-files.

Draws real pictures into a folder, starts a compositor and Files, and reads
pixels back from IPC screenshots: shapes and colours of the thumbnails, EXIF
rotation, the shared freedesktop cache (written and read), invalidation when a
file changes, the off switch, and that an idle Files makes no wakeups.
"""
import colorsys
import hashlib
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
from urllib.parse import quote

from PIL import Image, ImageChops, PngImagePlugin

from files_browser import wait_for

ROOT = Path(__file__).resolve().parents[1]

RED = (255, 0, 0)
GREEN = (0, 255, 0)
BLUE = (0, 0, 255)
YELLOW = (255, 255, 0)
MAGENTA = (255, 0, 255)
CYAN = (0, 255, 255)
LIME = (128, 255, 0)


def near(image, colour, tolerance=40):
    """Mask of pixels within `tolerance` per channel of `colour`."""
    mask = None
    for channel, want in zip(image.convert("RGB").split(), colour):
        band = channel.point(lambda v, want=want: 255 if abs(v - want) <= tolerance else 0)
        mask = band if mask is None else ImageChops.multiply(mask, band)
    return mask


def blob(image, colour):
    """(bounding box, pixel count) of `colour` in `image`, or (None, 0)."""
    mask = near(image, colour)
    return mask.getbbox(), mask.histogram()[255]


def size_of(box):
    return (box[2] - box[0], box[3] - box[1])


def close(actual, expected, slack=3):
    return all(abs(a - b) <= slack for a, b in zip(actual, expected))


def file_uri(path):
    return "file://" + quote(str(path), safe="-_.~!$&'()*+,;=:@/")


def make_pictures(pics):
    Image.new("RGB", (1600, 1200), RED).save(pics / "a_red.jpg", quality=90)
    Image.new("RGB", (800, 600), GREEN).save(pics / "b_green.png")
    Image.new("RGB", (300, 900), BLUE).save(pics / "c_blue_tall.png")
    (pics / "d_corrupt.jpg").write_bytes(b"\xff\xd8\xff\xe0 this is not a jpeg")
    (pics / "e_note.txt").write_text("not an image")
    # Landscape, top half yellow / bottom half magenta, tagged "rotate 90 CW":
    # shown upright it is portrait with yellow on the right.
    rotated = Image.new("RGB", (1200, 600), YELLOW)
    rotated.paste(Image.new("RGB", (1200, 300), MAGENTA), (0, 300))
    exif = Image.Exif()
    exif[0x0112] = 6
    rotated.save(pics / "f_rotated.jpg", quality=90, exif=exif.tobytes())
    # A picture whose shared-cache entry (cyan) is seeded below, so showing
    # cyan proves the entry was found by name and validated.
    Image.new("RGB", (900, 900), RED).save(pics / "g_seeded.png")


def seed_cache(cache, picture, colour):
    st = picture.stat()
    uri = file_uri(picture)
    info = PngImagePlugin.PngInfo()
    info.add_text("Thumb::URI", uri)
    info.add_text("Thumb::MTime", str(int(st.st_mtime)))
    info.add_text("Thumb::Size", str(st.st_size))
    directory = cache / "thumbnails" / "normal"
    directory.mkdir(parents=True, exist_ok=True)
    Image.new("RGBA", (128, 128), colour + (255,)).save(
        directory / (hashlib.md5(uri.encode()).hexdigest() + ".png"), pnginfo=info)


def saturated(image, region):
    """How many strongly coloured pixels `region` (a crop box) holds."""
    hsv = image.crop(region).convert("HSV")
    sat = hsv.getchannel(1).point(lambda v: 255 if v > 200 else 0)
    val = hsv.getchannel(2).point(lambda v: 255 if v > 200 else 0)
    return ImageChops.multiply(sat, val).histogram()[255]


def make_big_folder(big, count=240):
    big.mkdir()
    for i in range(count):
        r, g, b = (int(255 * c) for c in colorsys.hsv_to_rgb(i / count, 1, 1))
        Image.new("RGB", (640, 480), (r, g, b)).save(big / f"img_{i:04d}.jpg", quality=85)


def context_switches(pid):
    total = 0
    for status in Path(f"/proc/{pid}/task").glob("*/status"):
        for line in status.read_text().splitlines():
            if "ctxt_switches" in line:
                total += int(line.split()[1])
    return total


def run():
    with tempfile.TemporaryDirectory(prefix="rediwm-files-thumbs-") as directory:
        tmp = Path(directory)
        home = tmp / "Home"
        pics = home / "Pics"
        pics.mkdir(parents=True)
        cache = tmp / "cache"
        make_pictures(pics)
        seed_cache(cache, pics / "g_seeded.png", CYAN)
        config = tmp / "config.toml"
        config.write_text("")
        env = dict(os.environ, HOME=str(home), XDG_RUNTIME_DIR=directory,
                   XDG_DATA_HOME=str(tmp / "data"), XDG_CACHE_HOME=str(cache),
                   REDIWM_CONFIG=str(config), WLR_BACKENDS="headless", REDIWM_FILES_DEVICES="0",
                   WLR_HEADLESS_OUTPUTS="1", WLR_RENDERER=os.environ.get("REDIWM_TEST_RENDERER", "pixman"),
                   REDIWM_SCALE="1", XDG_STATE_HOME=str(tmp / "state"),
                   REDIWM_IPC_AUTOMATION="1")
        env.pop("WAYLAND_DISPLAY", None)
        env.pop("REDIWM_SOCKET", None)
        env.pop("REDIWM_FILES_THUMBNAILS", None)
        processes = []

        def start(binary, *args, **extra):
            with (tmp / (binary + ".log")).open("a") as log:
                p = subprocess.Popen([str(ROOT / "zig-out/bin" / binary), *args],
                                     env=dict(env, **extra), stdout=log, stderr=log)
            processes.append(p)
            return p

        try:
            start("rediwm")
            paths = wait_for(lambda: list(tmp.glob("rediwm-*.sock")), "IPC unavailable")
            with socket.socket(socket.AF_UNIX) as sock:
                sock.settimeout(10)
                sock.connect(str(paths[0]))
                reader = sock.makefile("r")

                def request(value):
                    sock.sendall((json.dumps(value) + "\n").encode())
                    result = json.loads(reader.readline())
                    assert "Ok" in result, result
                    return result["Ok"]

                def action(name, params):
                    return request({"version": 1, "command": name, "params": params})

                def windows():
                    return [w for w in request({'version': 1, 'command': 'windows'}).get("Windows", [])
                            if w["app_id"] == "rediwm-files"]

                display = next(p.name for p in tmp.glob("wayland-*") if not p.name.endswith(".lock"))
                shot = tmp / "shot.png"

                def screenshot():
                    win = windows()[0]
                    shot.unlink(missing_ok=True)
                    action('screenshot', {"path": str(shot)})
                    wait_for(shot.exists, "no screenshot")
                    time.sleep(0.05)
                    with Image.open(shot) as full:
                        return full.crop((win["x"], win["y"], win["x"] + win["width"],
                                          win["y"] + win["height"])).convert("RGB")

                def launch(folder=pics, **extra):
                    p = start("rediwm-files", str(folder), WAYLAND_DISPLAY=display, **extra)
                    win = wait_for(lambda: next(iter(windows()), None), "file manager did not map")
                    action('focus_window', {"id": win["id"]})
                    return p

                def stop(p):
                    p.terminate()
                    p.wait(timeout=5)
                    wait_for(lambda: not windows(), "window did not close")

                def wait_blob(colour, expected_size, what, slack=3):
                    last = {}

                    def check():
                        image = screenshot()
                        last["image"] = image
                        box, count = blob(image, colour)
                        last["box"] = box
                        return box and count > 100 and close(size_of(box), expected_size, slack)
                    try:
                        wait_for(check, what, timeout=15)
                    except TimeoutError:
                        if preview := os.environ.get("REDIWM_FILES_PREVIEW"):
                            last["image"].save(preview)
                        raise TimeoutError(f"{what}: last box {last.get('box')}")
                    return last["image"]

                # --- First visit: decode, draw, write to the shared cache. ---
                files = launch()
                wait_blob(GREEN, (48, 36), "800x600 PNG thumbnail (48x36)")
                wait_blob(BLUE, (16, 48), "300x900 PNG thumbnail keeps its shape (16x48)")
                wait_blob(RED, (48, 36), "1600x1200 JPEG thumbnail (48x36)")
                image = wait_blob(CYAN, (48, 48), "seeded shared-cache entry (48x48)")
                # The seeded entry replaced the real picture: no 900x900 red square
                # in that cell, only the JPEG's 48x36 red one counted above.
                yellow_box, _ = blob(image, YELLOW)
                magenta_box, _ = blob(image, MAGENTA)
                assert yellow_box and magenta_box, "EXIF-rotated thumbnail missing"
                # Orientation 6 turns the landscape picture upright: 24x48, with
                # yellow (the original top half) on the right of magenta.
                assert close(size_of(yellow_box), (12, 48), 3), yellow_box
                assert close(size_of(magenta_box), (12, 48), 3), magenta_box
                assert magenta_box[0] < yellow_box[0], (magenta_box, yellow_box)
                print("Thumbnails drawn with correct shape, colour and EXIF orientation.")
                # Nothing was drawn for the corrupt picture or the text file:
                # they keep their type icons, which hold no pure colours.
                if preview := os.environ.get("REDIWM_FILES_PREVIEW"):
                    image.save(preview)

                def written():
                    return sorted((cache / "thumbnails" / "normal").glob("*.png"))
                # The original pictures are bigger than a thumbnail, so each
                # got an entry (the seeded one was already there).
                wait_for(lambda: len(written()) == 5, "shared cache write-back")
                for name in ("a_red.jpg", "b_green.png", "c_blue_tall.png", "f_rotated.jpg"):
                    picture = pics / name
                    uri = file_uri(picture)
                    entry = cache / "thumbnails" / "normal" / (hashlib.md5(uri.encode()).hexdigest() + ".png")
                    assert entry.exists(), name
                    assert oct(entry.stat().st_mode & 0o777) == "0o600", oct(entry.stat().st_mode)
                    with Image.open(entry) as thumbnail:
                        assert thumbnail.info["Thumb::URI"] == uri
                        assert int(thumbnail.info["Thumb::MTime"]) == int(picture.stat().st_mtime)
                        assert int(thumbnail.info["Thumb::Size"]) == picture.stat().st_size
                        assert max(thumbnail.size) == 128, thumbnail.size
                print("Shared freedesktop cache entries written with Thumb::* metadata.")

                # --- Editing a file replaces its thumbnail. ---
                Image.new("RGB", (1000, 400), LIME).save(pics / "a_red.jpg", quality=90)
                wait_blob(LIME, (48, 19), "edited picture's new thumbnail (48x19)", slack=3)
                assert blob(screenshot(), RED)[1] < 100, "stale red thumbnail still drawn"
                print("Editing a picture refreshes its thumbnail.")

                # --- An idle window makes no wakeups. ---
                time.sleep(1.0)
                before = context_switches(files.pid)
                time.sleep(2.0)
                switches = context_switches(files.pid) - before
                assert switches <= 4, f"idle Files context-switched {switches} times in 2 s"
                print(f"Idle Files made {switches} context switches in 2 s.")
                stop(files)

                # --- A later visit shows the same pictures from the cache. ---
                files = launch()
                wait_blob(GREEN, (48, 36), "cached thumbnail on second visit")
                stop(files)

                # --- The environment switch turns the feature off. ---
                files = launch(REDIWM_FILES_THUMBNAILS="0")
                time.sleep(1.5)
                image = screenshot()
                for colour in (GREEN, BLUE, CYAN, MAGENTA):
                    assert blob(image, colour)[1] < 100, f"thumbnails drawn despite REDIWM_FILES_THUMBNAILS=0 ({colour})"
                stop(files)
                print("Thumbnails off when REDIWM_FILES_THUMBNAILS=0.")

                # --- A big folder: visible rows first, then wherever the view goes. ---
                big = home / "Big"
                make_big_folder(big)
                started = time.monotonic()
                files = launch(big)
                items = (215, 165, 940, 555)  # the file grid inside the window
                wait_for(lambda: saturated(screenshot(), items) > 7 * 1500,
                         "thumbnails for the first screenful of 240 pictures", timeout=15)
                first = time.monotonic() - started
                # Jump to the last picture, far beyond anything prefetched.
                for pressed in (True, False):
                    action('key', {"keycode": 107, "pressed": pressed})  # End
                scrolled = time.monotonic()
                wait_for(lambda: saturated(screenshot(), items) > 5 * 1500,
                         "thumbnails after jumping to the end of the folder", timeout=15)
                last = time.monotonic() - scrolled
                assert first < 10 and last < 10, (first, last)
                print(f"240 pictures: first screenful in {first:.2f} s, after End in {last:.2f} s.")
                time.sleep(1.0)
                before = context_switches(files.pid)
                time.sleep(2.0)
                switches = context_switches(files.pid) - before
                assert switches <= 4, f"idle Files context-switched {switches} times in 2 s"
                stop(files)
        except Exception:
            for log in tmp.glob("*.log"):
                print(log.read_text()[-4000:])
            raise
        finally:
            for p in reversed(processes):
                if p.poll() is None:
                    p.terminate()
                    p.wait(timeout=5)
    print("Files thumbnails passed.")


if __name__ == "__main__":
    run()

"""Controls and local file handoff on the private compositor from video.py."""
import os
from pathlib import Path
import re
import shutil
import subprocess
import time

from PIL import ImageChops

from video import BIN, ROOT, PLAYER, capture, playing, reference, wait


def controls(ipc, env, tmp, fixture):
    movies = tmp / "videos-to-open"
    movies.mkdir()
    clip = movies / "clock.mp4"
    shutil.copy(tmp / "clock.mp4", clip)
    chosen = movies / "a second video.mp4"
    if fixture:
        # Replace an A/V movie with a different A/V movie. This exercises
        # device handoff as well as switching between audio and silent files.
        subprocess.run(["ffmpeg", "-loglevel", "error", "-i", tmp / "sd601.mp4", "-i", clip,
                        "-map", "0:v", "-map", "1:a", "-c", "copy", "-shortest", chosen], check=True)
    else:
        shutil.copy(tmp / "sd601.mp4", chosen)
    # The regular suite generates this clip with a distinct luma every frame.
    def expected(at):
        return reference(clip, at, tmp / "controls-ref.png").getpixel((160, 90))[0]

    def inhibitor():
        state = ipc.request(query="get_idle_state")
        return [i for i in state["inhibitors"] if i["app_id"] == "rediwm-video" and i["is_active"]]

    def shortcut(code):
        ipc.key(29, True)
        ipc.key_down_up(code)
        ipc.key(29, False)

    env = dict(env, PATH=str(BIN) + os.pathsep + env["PATH"], REDIWM_FILES_DEVICES="0",
               WAYLAND_DEBUG="client", GIO_USE_VFS="local")
    with playing(ipc, env, tmp, fixture or PLAYER, ["--hwdec=no", "--paused", "--start", 3, clip]) as (win, _, log):
        ipc.focus_window(win)
        assert next(v for v in ipc.get_windows() if v["id"] == win)["content_type"] == "video"
        assert not inhibitor()

        def shot():
            return capture(ipc, win, tmp / "controls.png")

        def at(seconds):
            want = expected(seconds)
            def check():
                im = shot()
                return abs(im.getpixel((im.width // 2, im.height // 3))[0] - want) <= 1
            wait(check, f"picture at {seconds}s")

        at(3)
        ipc.key_down_up(51)  # previous picture across a keyframe boundary
        at(2.9)
        ipc.key_down_up(52)
        at(3)
        box = ipc.get_window_debug(win)["client_box"]
        x, y, w, h = [round(box[k]) for k in ("x", "y", "width", "height")]
        # A stopped video is flat. Painting the controls changes only the
        # bottom strip, and detaching the subsurface restores every pixel.
        ipc.move_cursor(x + 50, y + 36)
        def bar_visible():
            im = shot()
            strip = im.crop((im.width // 8, im.height * 3 // 4, im.width * 7 // 8, im.height - 15))
            return strip.getextrema()[0][1] - strip.getextrema()[0][0] > 60
        wait(bar_visible, "control bar on pointer motion")
        base = shot()
        if keep := os.environ.get("REDIWM_TEST_LOG_DIR"):
            base.save(os.path.join(keep, "video-controls.png"))
        ipc.key_down_up(108)
        wait(lambda: ImageChops.difference(base, shot()).getbbox(), "volume readout changed")
        wait(lambda: not bar_visible(), "OSD auto-hide", timeout=5)
        ipc.move_cursor(x + w // 2, y + h - 56)
        wait(bar_visible, "controls revealed")
        ipc.click()
        at(6)  # seek rail midpoint
        ipc.pointer_button(272, True)
        ipc.move_cursor(x + w // 2 + 24, y + h - 56)
        time.sleep(.15)
        ipc.move_cursor(x + w // 2, y + h - 56)
        ipc.pointer_button(272, False)
        at(6)
        before = shot().getpixel((base.width // 2, base.height // 3))
        ipc.scroll(0, -10)
        wait(lambda: abs(shot().getpixel((base.width // 2, base.height // 3))[0] - before[0]) > 12,
             "wheel over seek rail")
        ipc.click_at(x + 38, y + h - 27)  # play button
        wait(inhibitor, "playing video idle inhibitor")
        ipc.click_at(x + 50, y + 36)  # single click on picture
        wait(lambda: not inhibitor(), "pause releases inhibitor")
        ipc.click()
        ipc.click()
        wait(lambda: ipc.get_window_debug(win)["fullscreen"], "double click fullscreen")
        assert not inhibitor(), "double click also toggled playback"
        wait(lambda: re.search(r'wl_pointer#\d+\.set_cursor\(\d+, (?:nil|null),', log.read_text()), "hidden fullscreen cursor", timeout=5)
        ipc.move_cursor(150, 130)
        wait(lambda: 'set_shape' in log.read_text().rsplit('set_cursor', 1)[-1], "cursor restored on motion")
        ipc.key_down_up(1)
        wait(lambda: not ipc.get_window_debug(win)["fullscreen"], "Escape")
        # Real Files chooser cancellation and filtered selection in the same window.
        def chooser():
            return next((v["id"] for v in ipc.get_windows() if v["app_id"] == "rediwm-file-chooser"), None)
        shortcut(24)  # Ctrl+O
        dialog = wait(chooser, "Files open dialog")
        ipc.focus_window(dialog)
        ipc.key_down_up(1)
        wait(lambda: not chooser(), "cancelled chooser closes")
        assert next(v["title"] for v in ipc.get_windows() if v["id"] == win) == clip.name
        ipc.focus_window(win)
        box = ipc.get_window_debug(win)["client_box"]
        ipc.move_cursor(round(box["x"] + box["width"] - 64), round(box["y"] + box["height"] - 27))
        wait(bar_visible, "open button")
        ipc.click()
        dialog = wait(chooser, "Open button launches chooser")
        ipc.focus_window(dialog)
        ipc.wait_for("window_geometry_settled", window_id=dialog)
        ipc.key_down_up(108)  # first matching file in the movie's folder
        ipc.key_down_up(28)
        try:
            wait(lambda: next(v["title"] for v in ipc.get_windows() if v["id"] == win) == chosen.name, "chosen video in same window")
        except AssertionError:
            if chooser():
                capture(ipc, dialog, tmp / "chooser.png")
            raise
        assert len([v for v in ipc.get_windows() if v["app_id"] == "rediwm-video"]) == 1

        drop_video(ipc, env, tmp, win)

    if fixture:
        # Measure the actual callback samples, including the upper clamp
        # and mute ramp, independently of the displayed percentage.
        peaks = []
        for mode in ("default", "boost", "mute"):
            with playing(ipc, env, tmp, fixture, ["--hwdec=no", "--paused", clip]) as (win, _, log):
                ipc.focus_window(win)
                if mode == "boost":
                    box = ipc.get_window_debug(win)["client_box"]
                    # Use the volume slider, then wheel outside the seek bar
                    # and press Up enough times to pass its upper limit.
                    ipc.click_at(round(box["x"] + 165), round(box["y"] + box["height"] - 27))
                    ipc.scroll(0, 10)
                    for _ in range(32):
                        ipc.key_down_up(103)
                elif mode == "mute":
                    ipc.key_down_up(50)
                ipc.key_down_up(57)
                wait(inhibitor, "playing with selected volume")
                time.sleep(.5)
            m = re.search(r"null device played (\d+) nonzero frames, peak ([0-9.]+)", log.read_text())
            assert m, log.read_text()[-2000:]
            if mode == "mute":
                assert int(m[1]) <= 240, m.group()
            else:
                peaks.append(float(m[2]))
        assert peaks[0] > 0 and abs(peaks[1] / peaks[0] - 1.5) < .04, peaks

    # A launcher invocation with no filename opens the chooser immediately.
    with (tmp / "empty-launch.log").open("w") as out:
        proc = subprocess.Popen([fixture or PLAYER], env=env, stdout=out, stderr=out)
    try:
        dialog = wait(chooser, "chooser on empty launch")
        ipc.focus_window(dialog)
        ipc.key_down_up(1)
        assert proc.wait(5) == 0
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait()
    print("OSD, seeks and frame steps, fullscreen cursor, chooser, drop, mute and idle inhibitor OK")


def drop_video(ipc, env, tmp, win):
    protocols = Path(subprocess.check_output(
        ["pkg-config", "--variable=pkgdatadir", "wayland-protocols"], text=True).strip())
    sources = []
    for name, xml in (("xdg-shell", "stable/xdg-shell/xdg-shell.xml"),
                      ("xdg-decoration", "unstable/xdg-decoration/xdg-decoration-unstable-v1.xml")):
        source = tmp / f"{name}-protocol.c"
        subprocess.run(["wayland-scanner", "client-header", protocols / xml, tmp / f"{name}-client-protocol.h"], check=True)
        subprocess.run(["wayland-scanner", "private-code", protocols / xml, source], check=True)
        sources.append(source)
    sender = tmp / "transfer-client"
    subprocess.run(["cc", "-I", tmp, ROOT / "tests/desktop_transfer.c", *sources,
                    "-lwayland-client", "-o", sender], check=True)
    path = tmp / "two words #1.mp4"
    shutil.copy(tmp / "h264.mp4", path)
    for uri, accepted in (("file://remote/missing.mp4", False), (path.as_uri(), True)):
        sender_log = tmp / "sender.log"
        with sender_log.open("w") as out:
            proc = subprocess.Popen([sender], env=dict(env, REDIWM_TEST_TRANSFER=f"# media\r\n{uri}\r\n"),
                                    stdout=out, stderr=out)
        try:
            src = wait(lambda: next((v["id"] for v in ipc.get_windows() if v["app_id"] == "rediwm.desktop-transfer"), None), "drag source")
            for target, left, width in ((src, 10, 260), (win, 350, 320)):
                ipc.action("set_window_size", {"id": target, "width": width, "height": 180})
                ipc.action("move_window_to", {"id": target, "x": left, "y": 40})
                ipc.wait_for("window_geometry_settled", window_id=target)
            src_box = ipc.get_window_debug(src)["client_box"]
            dest = ipc.get_window_debug(win)["client_box"]
            ipc.move_cursor(round(src_box["x"] + 90), round(src_box["y"] + 80))
            ipc.pointer_button(272, True)
            try:
                wait(lambda: re.search(r"\.start_drag\([^\n]+\n.*?wl_pointer#\d+\.leave\(", sender_log.read_text(), re.S), "compositor starts drag grab")
                ipc.move_cursor(round(dest["x"] + 85), round(dest["y"] + 78))
                wait(lambda: '.target("text/uri-list")' in sender_log.read_text(), "player accepts URI lists")
            finally:
                ipc.pointer_button(272, False)
            wait(lambda: "transfer-sent" in sender_log.read_text(), "player receives the drop")
            if accepted:
                wait(lambda: "transfer-finished" in sender_log.read_text(), "copy completes")
                wait(lambda: next(v["title"] for v in ipc.get_windows() if v["id"] == win) == path.name, "drop opens decoded local URI")
                assert path.exists()
            else:
                wait(lambda: ".cancelled()" in sender_log.read_text(), "nonlocal URI refused")
                assert next(v["title"] for v in ipc.get_windows() if v["id"] == win) == "a second video.mp4"
        finally:
            proc.terminate()
            proc.wait(5)
            wait(lambda: not any(v["app_id"] == "rediwm.desktop-transfer" for v in ipc.get_windows()), "drag source closed")

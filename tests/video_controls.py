"""Controls and local file handoff on the private compositor from video.py."""
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import time

from PIL import ImageChops

from video import BIN, ROOT, PLAYER, capture, check_idle, playing, reference, wait


def inhibitor(ipc):
    state = ipc.request(query="get_idle_state")
    return [i for i in state["inhibitors"] if i["app_id"] == "rediwm-video" and i["is_active"]]


def chooser(ipc):
    return next((v["id"] for v in ipc.get_windows() if v["app_id"] == "rediwm-file-chooser"), None)


def open_shortcut(ipc):
    ipc.key(29, True)
    ipc.key_down_up(24)
    ipc.key(29, False)


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

    env = dict(env, PATH=str(BIN) + os.pathsep + env["PATH"], REDIWM_FILES_DEVICES="0",
               WAYLAND_DEBUG="client", GIO_USE_VFS="local")
    sender = make_drop_sender(tmp)
    with playing(ipc, env, tmp, fixture or PLAYER, ["--hwdec=no", "--paused", "--start", 3, clip]) as (win, _, log):
        ipc.focus_window(win)
        assert next(v for v in ipc.get_windows() if v["id"] == win)["content_type"] == "video"
        assert not inhibitor(ipc)

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
        wait(lambda: inhibitor(ipc), "playing video idle inhibitor")
        ipc.click_at(x + 50, y + 36)  # single click on picture
        wait(lambda: not inhibitor(ipc), "pause releases inhibitor")
        ipc.click()
        ipc.click()
        wait(lambda: ipc.get_window_debug(win)["fullscreen"], "double click fullscreen")
        assert not inhibitor(ipc), "double click also toggled playback"
        wait(lambda: re.search(r'wl_pointer#\d+\.set_cursor\(\d+, (?:nil|null),', log.read_text()), "hidden fullscreen cursor", timeout=5)
        ipc.move_cursor(150, 130)
        wait(lambda: 'set_shape' in log.read_text().rsplit('set_cursor', 1)[-1], "cursor restored on motion")
        ipc.key_down_up(1)
        wait(lambda: not ipc.get_window_debug(win)["fullscreen"], "Escape")
        ipc.wait_for("window_geometry_settled", window_id=win)
        ipc.click_at(x + w - 31, y + h - 30)
        wait(lambda: ipc.get_window_debug(win)["fullscreen"], "fullscreen icon")
        ipc.key_down_up(1)
        wait(lambda: not ipc.get_window_debug(win)["fullscreen"], "return to window")
        # Real Files chooser cancellation and filtered selection in the same window.
        open_shortcut(ipc)
        dialog = wait(lambda: chooser(ipc), "Files open dialog")
        ipc.focus_window(dialog)
        ipc.key_down_up(1)
        wait(lambda: not chooser(ipc), "cancelled chooser closes")
        assert next(v["title"] for v in ipc.get_windows() if v["id"] == win) == clip.name
        ipc.focus_window(win)
        box = ipc.get_window_debug(win)["client_box"]
        ipc.move_cursor(round(box["x"] + box["width"] - 142), round(box["y"] + box["height"] - 27))
        wait(bar_visible, "open button")
        ipc.click()
        dialog = wait(lambda: chooser(ipc), "Open button launches chooser")
        ipc.focus_window(dialog)
        ipc.wait_for("window_geometry_settled", window_id=dialog)
        ipc.key_down_up(108)  # first matching file in the movie's folder
        ipc.key_down_up(28)
        try:
            wait(lambda: next(v["title"] for v in ipc.get_windows() if v["id"] == win) == chosen.name, "chosen video in same window")
        except AssertionError:
            if chooser(ipc):
                capture(ipc, dialog, tmp / "chooser.png")
            raise
        assert len([v for v in ipc.get_windows() if v["app_id"] == "rediwm-video"]) == 1

        drop_video(ipc, env, tmp, win, sender, chosen.name)

    check_subtitles(ipc, env, tmp, fixture or PLAYER)

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
                    ipc.click_at(round(box["x"] + 125), round(box["y"] + box["height"] - 27))
                    ipc.scroll(0, 10)
                    for _ in range(32):
                        ipc.key_down_up(103)
                elif mode == "mute":
                    ipc.key_down_up(50)
                ipc.key_down_up(57)
                wait(lambda: inhibitor(ipc), "playing with selected volume")
                time.sleep(.5)
            m = re.search(r"null device played (\d+) nonzero frames, peak ([0-9.]+)", log.read_text())
            assert m, log.read_text()[-2000:]
            if mode == "mute":
                assert int(m[1]) <= 240, m.group()
            else:
                peaks.append(float(m[2]))
        assert peaks[0] > 0 and abs(peaks[1] / peaks[0] - 1.5) < .04, peaks

    if fixture:
        check_audio_tracks(ipc, env, tmp, fixture)
    check_empty_launch(ipc, env, tmp, fixture or PLAYER, sender)
    print("OSD, seeks and frame steps, fullscreen cursor, chooser, drop, mute and idle inhibitor OK")


def check_audio_tracks(ipc, env, tmp, binary):
    # Track 1 (the default) is silent and track 2 is a tone, so audible frames
    # at the null device prove the switch, live and while paused.
    clip = tmp / "two-tracks.mp4"
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=480x270:rate=25:duration=6",
                    "-f", "lavfi", "-i", "anullsrc=channel_layout=stereo:sample_rate=48000",
                    "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000", "-t", "6",
                    "-map", "0:v", "-map", "1:a", "-map", "2:a", "-ac", "2",
                    "-metadata:s:a:0", "language=eng", "-metadata:s:a:0", "title=Silence",
                    "-metadata:s:a:1", "language=spa", "-metadata:s:a:1", "title=Tone",
                    "-c:v", "libx264", "-g", "25", "-c:a", "aac", clip], check=True)
    ipc.move_cursor(1, 1)

    def nonzero(log):
        m = re.search(r"null device played (\d+) nonzero frames", log.read_text())
        assert m, log.read_text()[-2000:]
        return int(m[1])

    def choose(win, row):
        box = ipc.get_window_debug(win)["client_box"]
        right = round(box["x"] + box["width"])
        bottom = round(box["y"] + box["height"])
        ipc.click_at(right - 68, bottom - 30)  # audio track button
        time.sleep(.3)
        ipc.click_at(right - 130, bottom - (145 if row == 0 else 111))
        time.sleep(.2)

    for paused in (False, True):
        args = ["--hwdec=no", clip] if not paused else ["--hwdec=no", "--paused", clip]
        with playing(ipc, env, tmp, binary, args) as (win, _, log):
            ipc.focus_window(win)
            if not paused:
                wait(lambda: inhibitor(ipc), "playing the silent default track")
                time.sleep(.5)
            choose(win, 1)
            if paused:
                ipc.key_down_up(57)
                wait(lambda: inhibitor(ipc), "resume after choosing a track")
            time.sleep(1.2)
        assert nonzero(log) > 20000, ("the second track was not played", paused, nonzero(log))
    print("Audio track menu switches the decoded stream, playing and paused OK")


def check_empty_launch(ipc, env, tmp, binary, sender):
    home = tmp / "empty-launch-home"
    home.mkdir()
    movie = home / "first movie.mp4"
    shutil.copy(tmp / "clock.mp4", movie)
    # Launch from the app menu, cancel Open, then select the first movie.
    ipc.move_cursor(1, 1)
    with playing(ipc, dict(env, HOME=str(home)), tmp, binary, []) as (win, proc, log):
        assert not chooser(ipc) and not inhibitor(ipc)
        assert "decoding " not in log.read_text()
        check_idle(proc, .5)
        box = ipc.get_window_debug(win)["client_box"]
        # The empty window shows the usual bottom controls; Open File is the
        # button left of Subtitles.
        ipc.click_at(round(box["x"] + box["width"] / 2 + 120), round(box["y"] + box["height"] - 30))
        dialog = wait(lambda: chooser(ipc), "Open File button in the empty window's controls")
        ipc.focus_window(dialog)
        ipc.key_down_up(1)
        wait(lambda: not chooser(ipc), "cancel leaves player open")
        ipc.focus_window(win)
        for key in (57, 106, 52, 37):  # media shortcuts before the first movie
            ipc.key_down_up(key)
        open_shortcut(ipc)
        dialog = wait(lambda: chooser(ipc), "Ctrl+O in empty window")
        ipc.focus_window(dialog)
        ipc.wait_for("window_geometry_settled", window_id=dialog)
        ipc.key_down_up(108)
        ipc.key_down_up(28)
        wait(lambda: any(v["id"] == win and v["title"] == movie.name for v in ipc.get_windows()), "first movie in the launcher window")
        wait(lambda: inhibitor(ipc), "first movie plays")

    with playing(ipc, env, tmp, binary, ["--hwdec=no", "--paused", "--start", 3]) as (win, _, _):
        drop_video(ipc, env, tmp, win, sender, None)
        target = reference(movie, 3, tmp / "empty-start-ref.png").getpixel((160, 90))[0]
        def first_picture():
            im = capture(ipc, win, tmp / "empty-start.png")
            return abs(im.getpixel((im.width // 2, im.height // 3))[0] - target) <= 1
        wait(first_picture, "the first drop honors --start")
        assert not inhibitor(ipc), "the first drop should honor --paused"
        ipc.focus_window(win)
        ipc.key_down_up(57)
        wait(lambda: inhibitor(ipc), "resume first dropped video")
    print("Empty launch, idle threads, chooser cancellation and first playback from chooser or drop OK")


def check_subtitles(ipc, env, tmp, binary):
    folder = tmp / "subtitled"
    folder.mkdir()
    clip = folder / "film.mp4"
    # A cue starts and ends between two pictures of a one-frame-per-second
    # movie. The player must wake for both edges even with its controls hidden.
    subprocess.run(["ffmpeg", "-loglevel", "error", "-f", "lavfi", "-i",
                    "color=black:size=480x270:rate=1:duration=12", "-c:v", "libx264", clip], check=True)
    sidecar = clip.with_suffix(".srt")
    sidecar.write_text("1\n00:00:01,000 --> 00:00:03,000\nFIRST LINE\nSECOND LINE\n\n"
                       "2\n00:00:06,200 --> 00:00:06,800\nSHORT CUE\n")
    other = folder / "alternate.SRT"
    other.write_text("1\n00:00:00,000 --> 00:00:04,000\nALTERNATE\n")
    ipc.move_cursor(1, 1)
    with playing(ipc, env, tmp, binary, ["--paused", "--start", "1", clip]) as (win, proc, _):
        ipc.focus_window(win)
        scale = float(os.environ.get("REDIWM_TEST_SCALE", "1"))

        def lines():
            im = capture(ipc, win, tmp / "subtitles.png").convert("L")
            # A patch at the left of the control bar is black when hidden.
            # Measure only the video above the controls whenever they show.
            bar = im.getpixel((round(im.width * .13), im.height - round(42 * scale))) > 4
            end = im.height - round((86 if bar else 5) * scale)
            center = im.crop((im.width // 4, im.height // 3, im.width * 3 // 4, end))
            rows = center.point(lambda luma: 255 if luma > 185 else 0).getprojection()[1]
            return sum(bright and (y == 0 or not rows[y - 1]) for y, bright in enumerate(rows)), bar

        box = ipc.get_window_debug(win)["client_box"]
        right = round(box["x"] + box["width"])
        bottom = round(box["y"] + box["height"])

        def menu_visible():
            im = capture(ipc, win, tmp / "subtitle-menu.png")
            return max(im.getpixel((im.width - round(126 * scale), im.height - round(111 * scale)))[:3]) > 12

        def open_menu():
            ipc.click_at(right - 105, bottom - 30)
            wait(menu_visible, "subtitle menu above the controls")

        assert lines()[0] == 0, "sidecar should start off"
        open_menu()
        ipc.click_at(round(box["x"] + 40), round(box["y"] + 15))
        wait(lambda: not menu_visible(), "outside click dismisses subtitle menu")
        check_idle(proc, .4)  # dismissal must not play the movie
        open_menu()
        ipc.click_at(right - 130, bottom - 145)  # matching film.srt
        wait(lambda: lines() == (2, True), "two subtitle lines above the controls")
        wait(lambda: lines() == (2, False), "subtitle persists after controls hide")
        check_idle(proc, .4)
        ipc.key_down_up(106)  # seek to the gap at 6 s
        wait(lambda: lines()[0] == 0, "paused seek into a gap")
        ipc.key_down_up(57)
        wait(lambda: lines()[0] == 1, "cue starts between video frames")
        wait(lambda: lines()[0] == 0, "cue expires during playback")
        ipc.key_down_up(57)
        ipc.key_down_up(105)
        wait(lambda: lines()[0] == 2, "backward seek restores dialogue")
        open_menu()
        if keep := os.environ.get("REDIWM_TEST_LOG_DIR"):
            capture(ipc, win, Path(keep) / "video-subtitle-menu.png")
        ipc.click_at(right - 130, bottom - 178)  # Off
        wait(lambda: lines()[0] == 0, "disable subtitles")
        ipc.key_down_up(37)
        wait(lambda: lines()[0] == 2, "K restores selected subtitles")

        open_menu()
        ipc.click_at(right - 130, bottom - 111)
        dialog = wait(lambda: chooser(ipc), "Load subtitle file opens the subtitle chooser")
        ipc.focus_window(dialog)
        ipc.wait_for("window_geometry_settled", window_id=dialog)
        ipc.key_down_up(108)  # alternate.SRT sorts first
        ipc.key_down_up(28)
        wait(lambda: lines()[0] == 1, "selected SRT replaces the current track")
        assert next(v["title"] for v in ipc.get_windows() if v["id"] == win) == clip.name
    print("SRT sidecar, chooser, paused and playing cue timing, and idle threads OK")


def make_drop_sender(tmp):
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
    flags = shlex.split(subprocess.check_output(["pkg-config", "--cflags", "--libs", "wayland-client"], text=True))
    subprocess.run(["cc", "-I", tmp, ROOT / "tests/desktop_transfer.c", *sources, *flags, "-o", sender], check=True)
    return sender


def drop_video(ipc, env, tmp, win, sender, movie_title):
    initial = next(v["title"] for v in ipc.get_windows() if v["id"] == win)
    path = tmp / "two words #1.mp4"
    shutil.copy(tmp / ("h264.mp4" if movie_title else "clock.mp4"), path)
    subtitle = tmp / "a separate subtitle.srt"
    subtitle.write_text("1\n00:00:00,000 --> 00:01:00,000\nDROPPED\n")
    for uri, title in (("file://remote/missing.mp4", None), (subtitle.as_uri(), movie_title),
                       (path.as_uri(), path.name)):
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
            if title:
                wait(lambda: "transfer-finished" in sender_log.read_text(), "copy completes")
                wait(lambda: next(v["title"] for v in ipc.get_windows() if v["id"] == win) == title, "drop handled in the same window")
                assert path.exists()
            else:
                wait(lambda: ".cancelled()" in sender_log.read_text(), "unusable drop refused")
                assert next(v["title"] for v in ipc.get_windows() if v["id"] == win) == initial
        finally:
            proc.terminate()
            proc.wait(5)
            wait(lambda: not any(v["app_id"] == "rediwm.desktop-transfer" for v in ipc.get_windows()), "drag source closed")

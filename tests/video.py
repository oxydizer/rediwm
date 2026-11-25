#!/usr/bin/env python3
"""Check video pixels, seek generations, keyboard control, pause and EOF.
Pass the noninstalled null-device player (zig build test-video-integration)
to exercise audio. The installed player is used with silent clips only.
"""
from contextlib import contextmanager
import os
import re
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import time

from PIL import Image, ImageChops, ImageStat

from ipc_client import IPCClient, spawn_compositor, stop_process

ROOT = Path(__file__).resolve().parent.parent
BIN = Path(os.environ.get("REDIWM_TEST_BIN", ROOT / "zig-out/bin")).resolve()
PLAYER = BIN / "rediwm-video"
BT709 = ["-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709"]
BT601 = ["-colorspace", "smpte170m", "-color_primaries", "smpte170m", "-color_trc", "smpte170m"]

# name, size, rate, pixel format, matrix, range, tags, encoder, time to check
CLIPS = [
    ("h264.mp4", "960x540", 30, "yuv420p", "bt709", "tv", BT709, ["-c:v", "libx264"], 2.0),
    ("hevc10.mkv", "960x540", 24, "yuv420p10le", "bt709", "tv", BT709, ["-c:v", "libx265", "-x265-params", "log-level=error"], 3.0),
    ("vp9.webm", "960x540", 30, "yuv420p", "bt709", "tv", BT709, ["-c:v", "libvpx-vp9", "-b:v", "1M", "-deadline", "realtime"], 1.5),
    ("profile444.mp4", "640x360", 25, "yuv444p", "bt709", "tv", BT709, ["-c:v", "libx264"], 1.0),
    ("full.mp4", "960x540", 30, "yuv420p", "bt709", "pc", BT709, ["-c:v", "libx264"], 1.0),
    ("sd601.mp4", "640x360", 25, "yuv420p", "bt601", "tv", BT601, ["-c:v", "libx264"], 1.0),
]


def wait(fn, what, timeout=10.0):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        value = fn()
        if value:
            return value
        time.sleep(0.05)
    raise AssertionError(f"timed out waiting for {what}")


def make_clip(directory, name, size, rate, pix_fmt, matrix, rng, tags, encoder):
    # Tagged *and* converted with the same matrix: an untagged clip is
    # BT.601 from FFmpeg but BT.709 to a player at HD sizes.
    path = directory / name
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-f", "lavfi", "-i", f"testsrc2=size={size}:rate={rate}:duration=5",
                    "-vf", f"scale=out_color_matrix={matrix}:out_range={rng},format={pix_fmt}",
                    *tags, "-color_range", rng, "-g", str(rate), *encoder, str(path)], check=True)
    return path


def reference(clip, at, path):
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-ss", str(at), "-i", str(clip), "-frames:v", "1",
                    "-vf", "scale=in_color_matrix=auto:in_range=auto:out_range=pc,format=rgb24", str(path)], check=True)
    return Image.open(path).convert("RGB")


def compare(shot, ref):
    """Finds `ref` in the screenshot (below the titlebar); mean error per
    channel and the share of pixels off by more than 16 levels."""
    scale = float(os.environ.get("REDIWM_TEST_SCALE", "1"))
    if scale != 1:
        ref = ref.resize((round(ref.width * scale), round(ref.height * scale)), Image.Resampling.BILINEAR)
    small = lambda im: im.resize((im.width // 4, im.height // 4))
    target = small(ref)
    best = None
    for y in range(0, min(100, shot.height - ref.height + 1)):
        for x in range(0, min(8, shot.width - ref.width + 1)):
            if (x | y) % 2:
                continue
            crop = small(shot.crop((x, y, x + ref.width, y + ref.height)))
            score = sum(ImageStat.Stat(ImageChops.difference(crop, target)).mean)
            if best is None or score < best[0]:
                best = (score, x, y)
    candidates = [(x, y) for x in range(max(0, best[1] - 1), best[1] + 2) for y in range(max(0, best[2] - 1), best[2] + 2)]
    scored = []
    for x, y in candidates:
        crop = shot.crop((x, y, x + ref.width, y + ref.height))
        if crop.size == ref.size:
            scored.append((sum(ImageStat.Stat(ImageChops.difference(crop, ref)).mean), x, y))
    _, x, y = min(scored)
    diff = ImageChops.difference(shot.crop((x, y, x + ref.width, y + ref.height)), ref)
    mean = ImageStat.Stat(diff).mean
    gray = diff.convert("L")
    far = sum(gray.histogram()[17:]) / (ref.width * ref.height)
    return mean, far


@contextmanager
def playing(ipc, env, tmp, binary, args):
    log = tmp / "player.log"
    with log.open("w") as out:
        proc = subprocess.Popen([str(binary), *map(str, args)], env=env, stdout=out, stderr=out)
    try:
        def window():
            if proc.poll() is not None:
                raise AssertionError(f"player exited ({proc.returncode})\n{log.read_text()}")
            return next((w for w in ipc.get_windows() if w["app_id"] == "rediwm-video"), None)
        win = wait(window, "player window")["id"]
        ipc.wait_for("window_geometry_settled", window_id=win)
        yield win, proc, log
        ipc.close_window(win)
        assert proc.wait(timeout=5) == 0, log.read_text()
    except Exception:
        print(log.read_text()[-8000:], file=sys.stderr)
        raise
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait()
        wait(lambda: not any(w["app_id"] == "rediwm-video" for w in ipc.get_windows()), "player exit")


def capture(ipc, win, path):
    path.unlink(missing_ok=True)
    ipc.screenshot(path=str(path), window_id=win)
    with Image.open(path) as image:
        return image.convert("RGB")


def pixels(ipc, win, tmp, clip, at, label):
    shot_path = tmp / f"{label}.png"
    ref_path = tmp / f"{label}.ref.png"
    ref = reference(clip, at, ref_path)
    # Mapping the black letterbox root can precede the first decoded frame.
    def first_picture():
        shot = capture(ipc, win, shot_path)
        middle = shot.crop((shot.width // 4, shot.height // 4, shot.width * 3 // 4, shot.height * 3 // 4))
        return shot if max(middle.getextrema()[0]) > 32 else None
    mean, far = compare(wait(first_picture, "decoded frame"), ref)
    keep = os.environ.get("REDIWM_TEST_LOG_DIR")
    if keep:
        shutil.copy(shot_path, keep)
        shutil.copy(ref_path, keep)
    print(f"{label}: mean error {[round(m, 2) for m in mean]}, {far:.1%} of pixels off by >16")
    assert max(mean) < 4 and far < 0.10, (label, mean, far)


def switches(pid):
    if sys.platform.startswith("freebsd"):
        rows = subprocess.check_output(["ps", "-H", "-p", str(pid), "-o", "lwp=", "-o", "nvcsw=", "-o", "nivcsw="], text=True)
        return {tid: int(voluntary) + int(involuntary)
                for tid, voluntary, involuntary in (line.split() for line in rows.splitlines() if line.strip())}
    tasks = Path(f"/proc/{pid}/task")
    if not tasks.exists():
        return None
    return {p.parent.name: sum(int(line.split()[1]) for line in p.read_text().splitlines()
                               if "ctxt_switches:" in line) for p in tasks.glob("*/status")}


def check_idle(proc, duration):
    time.sleep(0.35)  # let the client dispatch the last releases
    before = switches(proc.pid)
    time.sleep(duration)
    after = switches(proc.pid)
    if before is not None:
        assert before and before == after, f"player threads woke while idle: {before} -> {after}"
    assert proc.poll() is None


def check_paused_vp9(ipc, env, tmp, clip):
    # Decoding ahead while the first surface was still resolving could hang
    # vaSyncSurface on NVIDIA. Vary the relative worker and display timing.
    for _ in range(8):
        with playing(ipc, env, tmp, PLAYER, ["--paused", "--start", 1.5, clip]) as (win, _, _):
            def decoded():
                im = capture(ipc, win, tmp / "vp9-start.png")
                return im.crop((80, 80, 400, 240)).getextrema()[0][1] > 128
            wait(decoded, "paused VP9 startup")


def check_modifier_fallback(ipc, env, tmp, clip):
    shim = tmp / "video-export.so"
    flags = shlex.split(subprocess.check_output(["pkg-config", "--cflags", "libva"], text=True))
    dl = ["-ldl"] if sys.platform.startswith("linux") else []
    subprocess.run(["cc", *flags, "-shared", "-fPIC", "-o", shim, ROOT / "tests/video_export.c", *dl], check=True)
    with playing(ipc, dict(env, LD_PRELOAD=str(shim)), tmp, PLAYER, [clip]) as (win, _, log):
        wait(lambda: "modifier 0xffffffffffffffff" in log.read_text(), "unadvertised layout")
        ipc.focus_window(win)
        ipc.key_down_up(57)
        ipc.key_down_up(105)
        ref = reference(clip, 0, tmp / "fallback.ref.png")
        def recovered():
            mean, far = compare(capture(ipc, win, tmp / "fallback.png"), ref)
            return max(mean) < 4 and far < 0.10
        wait(recovered, "software frame after import refusal and seek")
        assert log.read_text().count("switching to software") == 1
    print("mapped VAAPI surface switched to shm and stayed in software after seeking")


def control_clip(path, audio):
    # Each tenth of a second has its own flat luma. Eight-bit levels read
    # directly from the middle of the window identify the displayed frame.
    args = ["ffmpeg", "-loglevel", "error", "-y", "-f", "lavfi", "-i",
            "color=black:size=320x180:rate=10:duration=12,geq=lum='24+1.75*N':cb=128:cr=128"]
    if audio:
        args += ["-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100:duration=11.4"]
    subprocess.run([*args, "-c:v", "libx264", "-crf", "0", "-g", "30", "-color_range", "tv",
                    *BT601, "-c:a", "aac", str(path)], check=True)


def check_controls(ipc, env, tmp, fixture):
    clip = tmp / "clock.mp4"
    control_clip(clip, fixture is not None)
    with playing(ipc, env, tmp, fixture or PLAYER, ["--hwdec=no", "--paused", "--start", "1.3", clip]) as (win, proc, log):
        def sample():
            im = capture(ipc, win, tmp / "clock.png")
            return im.getpixel((im.width // 2, im.height // 2))[0]

        def level(seconds):
            return reference(clip, seconds, tmp / "clock.ref.png").getpixel((160, 90))[0]

        def at(seconds):
            value = level(seconds)
            wait(lambda: abs(sample() - value) <= 1, f"frame at {seconds} s (luma {value})")

        at(1.3)
        ipc.focus_window(win)
        ipc.key_down_up(106)  # right
        at(6.3)
        for code in (105, 106, 105, 106, 105):
            ipc.key_down_up(code)
        at(1.3)
        ipc.key_down_up(33)  # F
        wait(lambda: ipc.get_window_debug(win)["fullscreen"], "fullscreen")
        ipc.key_down_up(1)   # Escape
        wait(lambda: not ipc.get_window_debug(win)["fullscreen"], "leave fullscreen")
        ipc.wait_for("window_geometry_settled", window_id=win)
        at(1.3)
        ipc.key_down_up(57)  # space
        start = time.monotonic()
        target = level(3.3)
        wait(lambda: sample() >= target - 1, "two seconds of playback")
        elapsed = time.monotonic() - start
        assert 1.6 < elapsed < 2.5, f"media clock took {elapsed:.2f}s to advance two seconds"
        ipc.key_down_up(57)
        check_idle(proc, 5)
        paused = sample()
        assert abs(paused - target) <= 6, (paused, target)
        ipc.key(42, True)
        ipc.key_down_up(106)  # shift-right clamps to last frame
        ipc.key(42, False)
        at(11.9)
        ipc.key(42, True)
        ipc.key_down_up(105)
        ipc.key(42, False)
        at(0)
        ipc.key_down_up(106)
        ipc.key_down_up(106)
        at(10)
        ipc.key_down_up(57)
        at(11.9)  # audio ends before video
        check_idle(proc, 1)
        ipc.key_down_up(57)  # replay after EOF
        wait(lambda: sample() < 25, "replay from start")
    if fixture:
        match = re.search(r"null device played (\d+) nonzero frames", log.read_text())
        assert match and int(match[1]) > 2.5 * 48000, log.read_text()
    print(f"keyboard, exact seek, replay, {'audio' if fixture else 'monotonic'} clock ({elapsed:.2f}s), idle threads OK")


def check_opus_tail(ipc, env, tmp, fixture):
    clip = tmp / "short-audio.webm"
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-f", "lavfi", "-i",
                    "color=black:size=320x180:rate=10:duration=6,geq=lum='32+3*N':cb=128:cr=128",
                    "-f", "lavfi", "-i", "sine=sample_rate=48000:duration=0.8",
                    "-c:v", "libvpx-vp9", "-deadline", "realtime", "-c:a", "libopus", str(clip)], check=True)
    with playing(ipc, env, tmp, fixture, ["--hwdec=no", clip]) as (win, proc, log):
        def at_end():
            image = capture(ipc, win, tmp / "tail.png")
            return image.getpixel((image.width // 2, image.height // 2))[0] > 216
        wait(at_end, "video tail after short Opus stream")
        check_idle(proc, 1)
        assert not any(i["app_id"] == "rediwm-video" for i in ipc.request(query="get_idle_state")["inhibitors"])
    match = re.search(r"null device played (\d+) nonzero frames", log.read_text())
    assert match and 36000 < int(match[1]) < 40000, log.read_text()
    # Conversely, a paused preview must reach the first video packet even
    # when several seconds of audio precede it in an interleaved file.
    delayed = tmp / "late-video.webm"
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-itsoffset", "4", "-i", str(clip),
                    "-f", "lavfi", "-i", "sine=sample_rate=48000:duration=6",
                    "-map", "0:v", "-map", "1:a", "-c:v", "copy", "-c:a", "libopus", str(delayed)], check=True)
    with playing(ipc, env, tmp, fixture, ["--hwdec=no", "--paused", delayed]) as (win, _, log):
        def preview():
            im = capture(ipc, win, tmp / "late.png")
            return 14 < im.getpixel((im.width // 2, im.height // 2))[0] < 24
        wait(preview, "paused picture after four seconds of audio")
        ipc.focus_window(win)
        ipc.key_down_up(57)
        time.sleep(0.6)
    match = re.search(r"null device played (\d+) nonzero frames", log.read_text())
    assert match and int(match[1]) > 12000, log.read_text()
    print("VP9/Opus long video tail and idle EOF OK")


def main():
    if shutil.which("ffmpeg") is None:
        print("SKIP: ffmpeg not installed")
        return
    fixture = Path(sys.argv[1]).resolve() if len(sys.argv) == 2 else None
    with tempfile.TemporaryDirectory(prefix="rediwm-video-") as directory:
        tmp = Path(directory)
        env = dict(os.environ, HOME=str(tmp), XDG_RUNTIME_DIR=str(tmp), XDG_CONFIG_HOME=str(tmp / "config"),
                   XDG_DATA_HOME=str(tmp / "data"), XDG_STATE_HOME=str(tmp / "state"),
                   DBUS_SYSTEM_BUS_ADDRESS="unix:path=/nonexistent-rediwm-video-test-bus", XDG_CACHE_HOME=str(tmp / "cache"),
                   DBUS_SESSION_BUS_ADDRESS="unix:path=/nonexistent-rediwm-video-test-bus")
        env.pop("DISPLAY", None)
        settings = {k: env[k] for k in ("HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME", "DBUS_SESSION_BUS_ADDRESS")}
        compositor, compositor_log = spawn_compositor(tmp, scale=os.environ.get("REDIWM_TEST_SCALE", "1"), config_content='[compositor]\nxwayland = false\nfocus_zoom = "keep"\n[animations]\nenabled = false\n',
                                                      env_extra=settings, binary=BIN / "rediwm")
        try:
            socket_path = wait(lambda: next(tmp.glob("rediwm-*.sock"), None), "IPC socket")
            env["WAYLAND_DISPLAY"] = wait(lambda: next((p.name for p in tmp.glob("wayland-*") if not p.name.endswith(".lock")), None), "display")
            with IPCClient(socket_path) as ipc:
                hardware = False
                for name, size, rate, pix_fmt, matrix, rng, tags, encoder, at in CLIPS:
                    clip = make_clip(tmp, name, size, rate, pix_fmt, matrix, rng, tags, encoder)
                    for path, options in (("auto", []), ("shm", ["--hwdec=no"])):
                        with playing(ipc, env, tmp, PLAYER, [*options, "--paused", "--start", at, clip]) as (win, _, log):
                            pixels(ipc, win, tmp, clip, at, f"{name}-{path}")
                            if path == "auto":
                                print(log.read_text().strip())
                                if name == "h264.mp4":
                                    hardware = "(VAAPI)" in log.read_text() and "switching to software" not in log.read_text()
                clip = tmp / "h264.mp4"
                if hardware:
                    check_paused_vp9(ipc, env, tmp, tmp / "vp9.webm")
                    check_modifier_fallback(ipc, env, tmp, clip)
                # Exercise default selection with an unavailable VAAPI driver.
                with playing(ipc, dict(env, LIBVA_DRIVER_NAME="no-such-driver"), tmp, PLAYER,
                             ["--paused", "--start", 1, clip]) as (win, _, _):
                    pixels(ipc, win, tmp, clip, 1, "no-vaapi")
                with playing(ipc, env, tmp, PLAYER, [clip]) as (win, _, log):
                    time.sleep(1.0)
                    def imports():
                        return Path(compositor_log.name).read_text().count("Created GL FBO")
                    before = imports()
                    a = capture(ipc, win, tmp / "playing-a.png")
                    time.sleep(1.0)
                    b = capture(ipc, win, tmp / "playing-b.png")
                    assert sum(ImageStat.Stat(ImageChops.difference(a, b)).mean) > 3
                    if "(VAAPI)" in log.read_text() and "switching to software" not in log.read_text():
                        assert imports() == before, "new dmabuf imports after warmup"
                check_controls(ipc, env, tmp, fixture)
                from video_controls import controls
                controls(ipc, env, tmp, fixture)
                if fixture:
                    check_opus_tail(ipc, env, tmp, fixture)
        finally:
            stop_process(compositor)
            compositor_log.close()
    print("OK")


if __name__ == "__main__":
    sys.exit(main())

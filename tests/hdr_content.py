#!/usr/bin/env python3
"""Probe a tagged Wayland surface using raw IPC pixels. Default is a private headless session.
--live-output NAME uses a running RediWM session, fullscreen on that output, without changing settings.
Use a normal output transform and neutral night light when comparing raw signal values.
"""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile

from desktop_zoom import wait_for
from ipc_client import IPCClient, stop_process
from wlr_protocols import Session, compile_fixture, expect_line

BARS = [(0, 0, 0), (96, 96, 96), (148, 148, 148), (192, 192, 192), (136, 112, 96)]
TO_709 = ((1.660491, -.587641, -.072850), (-.124550, 1.132900, -.008349), (-.018151, -.100579, 1.118730))
TO_2020 = ((.627404, .329283, .043313), (.069097, .919540, .011362), (.016391, .088013, .895595))


def matrix(rows, v):
    return [sum(a * b for a, b in zip(row, v)) for row in rows]


def pq_decode(code):
    v = code ** (32 / 2523)
    return 10000 * (max(v - 3424 / 4096, 0) / (2413 / 128 - 2392 / 128 * v)) ** (16384 / 2610)


def pq_encode(nits):
    p = (max(0, nits) / 10000) ** (2610 / 16384)
    return ((3424 / 4096 + 2413 / 128 * p) / (1 + 2392 / 128 * p)) ** (2523 / 32)


def expected(bar, description, white, hdr):
    c = [v / 255 for v in bar]
    if description == "pq":
        if hdr:
            return bar
        c = matrix(TO_709, [pq_decode(v) / white for v in c])
    else:
        if description == "srgb":
            c = [v / 12.92 if v <= .04045 else ((v + .055) / 1.055) ** 2.4 for v in c]
        elif description != "linear":
            c = [v ** 2.2 for v in c]
        if hdr:
            return tuple(round(255 * pq_encode(v * white)) for v in matrix(TO_2020, c))
    if description in ("linear", "pq"):
        peak = max(c)
        if peak > .75:
            c = [v * (1 - .0625 / (peak - .5)) / peak for v in c]
    return tuple(round(255 * min(1, max(0, v)) ** (1/2.2)) for v in c)


def check_bars(ipc, output, description, white):
    for i, bar in enumerate(BARS):
        for raw in (True, False):
            want = expected(bar, description, white, output["hdr_active"] and raw)
            px = ipc.action("sample_pixels", {
                "output": output["name"], "raw": raw,
                "x": (2*i+1)*output["buffer_width"]//10, "y": output["buffer_height"]//3,
            })["pixels"][0]
            got = tuple((px >> bit) & 255 for bit in (16, 8, 0))
            assert max(abs(a-b) for a, b in zip(got, want)) <= 3, (
                output["name"], output["hdr"], white, description, raw, i, got, want)


def mpv_probe(tmp, session):
    # Lossless RGB video bars, repeated so mpv treats the input as video.
    line = b"".join(bytes(bar) * 64 for bar in BARS)
    clip = tmp / "pq-bars.mkv"
    subprocess.run(["ffmpeg", "-v", "error", "-f", "rawvideo", "-pixel_format", "rgb24",
                    "-video_size", "320x180", "-framerate", "1", "-i", "-", "-vf", "format=gbrp10le",
                    "-color_range", "pc", "-colorspace", "rgb", "-color_trc", "smpte2084",
                    "-color_primaries", "bt2020", "-c:v", "ffv1", str(clip)], input=line*180*3, check=True)
    session.ipc.request(query="set_output_config", params={"output": "HEADLESS-1", "hdr": "off", "sdr_white": 203})
    session.ipc.wait_for_frame(output="HEADLESS-1")
    player = session.spawn("mpv", "--no-config", "--no-audio", "--vo=gpu-next",
        "--gpu-api=vulkan", "--gpu-context=waylandvk", "--fullscreen", "--pause", "--keep-open=yes",
        "--no-osc", "--osd-level=0", "--target-colorspace-hint=yes", "--target-colorspace-hint-mode=source",
        "--target-trc=pq", "--target-prim=bt.2020", "--target-peak=1000",
        "--vf=format:primaries=bt.2020:gamma=pq:colormatrix=rgb:colorlevels=full:max-luma=1000", str(clip))
    try:
        window = wait_for(lambda: session.window("mpv"), "mpv did not map")
        session.ipc.wait_for("window_geometry_settled", window_id=window["id"])
        for mode in ("off", "on"):
            session.ipc.request(query="set_output_config", params={"output": "HEADLESS-1", "hdr": mode, "sdr_white": 203})
            session.ipc.wait_for_frame(output="HEADLESS-1")
            # mpv may map before it presents the first movie frame.
            wait_for(lambda: session.ipc.action("sample_pixels", {
                "output": "HEADLESS-1", "x": 896, "y": 240, "raw": True})["pixels"][0] & 255 >= 250,
                "mpv did not present the HDR highlight")
            check_bars(session.ipc, session.output("HEADLESS-1"), "pq", 203)
        print("PASS: mpv Vulkan HDR10 video matches the reference on both headless composition paths")
    finally:
        stop_process(player)


def probe(tmp, ipc, env, name, live, effective_white):
    output = next(o for o in ipc.get_outputs() if o["name"] == name)
    assert output["transform"] == "normal", output
    client = subprocess.Popen([str(tmp / "fixture"), "hdr-pattern", name], env=env,
                              stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
    try:
        expect_line(client, "pattern-ready")
        window = wait_for(lambda: next((w for w in ipc.get_windows() if w["app_id"] == "rediwm.hdr-pattern"), None),
                          "HDR pattern did not map")
        ipc.wait_for("window_geometry_settled", window_id=window["id"])
        def command(value, reply):
            client.stdin.write(value + "\n")
            client.stdin.flush()
            expect_line(client, reply)
        states = [(output["hdr"], effective_white or output["sdr_white"])] if live else [
            ("off", 203), ("on", 203), ("on", 400), ("off", 400)]
        for mode, white in states:
            if not live:
                ipc.request(query="set_output_config", params={"output": name, "hdr": mode, "sdr_white": white})
                ipc.wait_for_frame(output=name)
            out = next(o for o in ipc.get_outputs() if o["name"] == name)
            hdr = out["hdr_active"]
            if not live:
                assert out["hdr_linear"] == (mode == "on") and not hdr, out
            for request in ("preferred", "late-preferred"):
                command(request, "preferred 11 6" if hdr else "preferred 2 1")
            for desc in ("gamma", "srgb", "linear", "pq", "unset"):
                command(desc, desc)
                ipc.wait_for_frame(output=name)
                check_bars(ipc, out, desc, white)
            print(f"PASS: {name} hdr={mode}, PQ signal={hdr}, white={white}, preferred description and five raw/SDR bars")
    finally:
        if client.poll() is None:
            client.stdin.write("exit\n")
            client.stdin.flush()
        client.wait(timeout=5)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--live-output")
    group.add_argument("--mpv", action="store_true", help="also play HDR10 bars with mpv, Vulkan and FFmpeg in the private session")
    parser.add_argument("--effective-white", type=float, help="actual white in nits if the EDID caps the configured value")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="rediwm-hdr-content-") as directory:
        tmp = Path(directory)
        compile_fixture(tmp)
        if args.live_output:
            with IPCClient(os.environ.get("REDIWM_SOCKET")) as ipc:
                probe(tmp, ipc, os.environ, args.live_output, True, args.effective_white)
        else:
            s = Session(tmp, scale=os.environ.get("REDIWM_TEST_SCALE", "1"),
                        config='[compositor]\nxwayland = false\n[animations]\nenabled = false\n')
            try:
                probe(tmp, s.ipc, s.env, "HEADLESS-1", False, None)
                if args.mpv:
                    mpv_probe(tmp, s)
            finally:
                s.close()

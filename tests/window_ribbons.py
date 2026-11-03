#!/usr/bin/env python3
"""Optional window trails: pixels, fade, reload, input and idle. Private GLES session."""
import os
import signal
from pathlib import Path
import subprocess
import tempfile
import time

from PIL import Image, ImageChops, ImageDraw
from desktop_zoom import build_client, wait_for
from ipc_client import IPCClient, spawn_compositor, stop_process

BASE = '[compositor]\nxwayland = false\n[desktop]\nenabled = false\n'
ON = BASE + '[effects.window_move]\nenabled = true\n'


def assert_idle(ipc, reason):
    # The taskbar clock legitimately repaints on a wall-clock minute tick.
    # Keep the short no-animation-wakeups measurement away from that deadline.
    phase = time.time() % 60
    if phase >= 58:
        time.sleep(60.25 - phase)
    elif phase < .25:
        time.sleep(.25 - phase)
    ipc.wait_for_frame()
    ipc.reset_perf()
    time.sleep(.4)
    idle = ipc.get_perf()
    assert idle["output_commits"] == 0, (reason, idle)


def check_move_fade(ipc, shot, moving, box):
    # Pausing with the button held must freeze the folds as well as releasing
    # it. A fixed fading sheet can only lose contrast against the background.
    ipc.action("set_anim_time", {"ms": 1600})
    ipc.wait_for_frame()
    held = shot("move-held")
    ipc.action("set_anim_time", {"ms": 1700})
    ipc.wait_for_frame()
    held_later = shot("move-held-later")
    ipc.pointer_button(272, False)
    ipc.action("set_anim_time", {"ms": 1800})
    ipc.wait_for_frame()
    lingering = shot("lingering")
    ipc.action("set_anim_time", {"ms": 1850})
    ipc.wait_for_frame()
    lingering_later = shot("lingering-later")
    ipc.action("set_anim_time", {"ms": 2000})
    ipc.wait_for_frame()
    cleared = shot("move-cleared-quickly")
    ipc.action("set_anim_time", {"ms": 5000})
    ipc.wait_for_frame()
    faded_frame = shot("faded", None)
    faded = faded_frame.crop(box)
    assert ImageChops.difference(moving, faded).getbbox(), "enabled ribbon drew no pixels"
    assert ImageChops.difference(held, faded).getbbox(), "paused ribbon vanished instead of fading"
    assert ImageChops.difference(lingering, faded).getbbox(), "released ribbon vanished instead of fading"
    assert ImageChops.difference(cleared, faded).getbbox() is None, "stopped ribbon lingered beyond half a second"
    for earlier, later in ((held, held_later), (lingering, lingering_later)):
        before = ImageChops.difference(earlier, faded)
        after = ImageChops.difference(later, faded)
        gained = ImageChops.subtract(after, before)
        assert max(peak for _, peak in gained.getextrema()) <= 3, "stationary drag flame changed shape instead of just fading"
    return faded_frame, faded


def check_minimize(ipc, win, shot, tmp, mixed, scale):
    ipc.action("set_anim_time", {"ms": 11000})
    ipc.minimize(win["id"])
    assert ipc.get_windows()[0]["is_minimized"]
    first = shot("minimize-start", None)
    ipc.action("set_anim_time", {"ms": 11320})
    ipc.wait_for_frame()
    middle = shot("minimize-middle", None)
    ipc.action("set_anim_time", {"ms": 12000})
    ipc.wait_for_frame()
    finished = shot("minimize-finished", None)
    body = tuple(round(v * scale) for v in (win["x"], win["y"], win["x"] + win["width"], win["y"] + win["height"]))
    assert ImageChops.difference(first.crop(body), finished.crop(body)).getbbox(), "minimize lost its snapshot"
    assert ImageChops.difference(middle.crop(body), finished.crop(body)).getbbox(), "minimize ribbon vanished before completion"
    assert ImageChops.difference(first, middle).getbbox(), "window did not deform"
    # No stale pixels or live effect frames after the real-time clock resumes.
    ipc.action("set_anim_time", {"ms": None})
    time.sleep(1)
    assert_idle(ipc, "minimize did not return to idle")
    ipc.restore(win["id"])
    ipc.wait_for("window_geometry_settled", window_id=win["id"])
    time.sleep(.3)
    # Restore while the snapshot is alive: no second ghost of the window.
    ipc.action("set_anim_time", {"ms": 13000})
    ipc.minimize(win["id"])
    ipc.action("set_anim_time", {"ms": 13300})
    ipc.wait_for_frame()
    ipc.restore(win["id"])
    ipc.action("set_anim_time", {"ms": 15000})
    ipc.wait_for_frame()
    restored = shot("minimize-restored", None)
    (tmp / "rediwm-config.toml").write_text(BASE + mixed)
    ipc.reload_config()
    ipc.wait_for_frame()
    assert ImageChops.difference(restored, shot("minimize-restored-clean", None)).getbbox() is None
    # Independent opt-out and reduced motion both suppress the snapshot.
    for index, suffix in enumerate(('[effects.window_minimize]\nenabled = false\n',
                                   '[animations]\nreduced_motion = "on"\n')):
        (tmp / "rediwm-config.toml").write_text(ON + mixed + suffix)
        ipc.reload_config()
        ipc.action("set_anim_time", {"ms": 16000})
        ipc.minimize(win["id"])
        ipc.action("set_anim_time", {"ms": 16320})
        ipc.wait_for_frame()
        disabled = shot(f"minimize-suppressed-{index}", None)
        ipc.action("set_anim_time", {"ms": 18000})
        ipc.wait_for_frame()
        assert ImageChops.difference(disabled, shot(f"minimize-suppressed-later-{index}", None)).getbbox() is None
        ipc.restore(win["id"])
    # Minimizing can own the shader by itself, and reload erases a live sheet.
    (tmp / "rediwm-config.toml").write_text(BASE + mixed + '[effects.window_minimize]\nenabled = true\n')
    ipc.reload_config()
    ipc.action("set_anim_time", {"ms": 20000})
    ipc.minimize(win["id"])
    ipc.action("set_anim_time", {"ms": 20320})
    ipc.wait_for_frame()
    separate = shot("minimize-only", None)
    (tmp / "rediwm-config.toml").write_text(BASE + mixed)
    ipc.reload_config()
    ipc.wait_for_frame()
    erased = shot("minimize-cancelled", None)
    assert ImageChops.difference(separate.crop(body), erased.crop(body)).getbbox()
    ipc.action("set_anim_time", {"ms": 22000})
    ipc.wait_for_frame()
    assert ImageChops.difference(erased, shot("minimize-cancelled-later", None)).getbbox() is None
    ipc.restore(win["id"])
    (tmp / "rediwm-config.toml").write_text(ON + mixed)
    ipc.reload_config()
    ipc.action("set_anim_time", {"ms": None})


def check_resize(ipc, win, shot, move, tmp, mixed, scale, process):
    ipc.action("move_window_to", {"id": win["id"], "x": 120, "y": 80})
    ipc.wait_for("window_geometry_settled", window_id=win["id"])
    config = BASE + mixed + '[effects.window_resize]\nenabled = true\n'
    for index, (edge, dx, dy) in enumerate((("se", 50, 30), ("nw", -35, -25), ("e", 60, 0), ("se", -45, -35))):
        (tmp / "rediwm-config.toml").write_text(config)
        ipc.reload_config()
        win = ipc.get_windows()[0]
        target_w = win["width"] + (-dx if edge == "nw" else dx)
        target_h = win["height"] + (-dy if edge == "nw" else dy)
        x = win["x"] - 2 if edge == "nw" else win["x"] + win["width"] + 2
        y = win["y"] - 2 if edge == "nw" else win["y"] + (win["height"] + 2 if edge == "se" else win["height"] / 2)
        start = 30000 + index * 6000
        ipc.action("set_anim_time", {"ms": start})
        move(x, y)
        ipc.pointer_button(272, True)
        assert ipc.get_input_state()["cursor_mode"] == "resize", edge
        ipc.action("set_anim_time", {"ms": start + 100})
        move(x + dx, y + dy)
        ipc.wait_for_frame()
        assert ipc.get_windows()[0]["width"] == win["width"], "window jumped to the pointer"
        ipc.action("set_anim_time", {"ms": start + 140})
        resized = wait_for(lambda: current if abs((current := ipc.get_windows()[0])["width"] - win["width"]) > 2 else None,
                           "lagging resize did not advance")
        assert min(win["width"], target_w) + 2 < resized["width"] < max(win["width"], target_w) - 2, "resize has no visible lag"
        ipc.wait_for_frame()
        active = shot(f"resize-{edge}-{index}", None)
        # Release during the lag must keep easing, including fixed top/left edges.
        ipc.pointer_button(272, False)
        assert abs(ipc.get_windows()[0]["width"] - target_w) > 2
        ipc.action("set_anim_time", {"ms": start + 2000})
        ipc.wait_for("window_geometry_settled", window_id=win["id"])
        final = ipc.get_windows()[0]
        assert final["width"] == target_w
        assert final["height"] == target_h
        if edge == "nw":
            assert final["x"] + final["width"] == win["x"] + win["width"]
            assert final["y"] + final["height"] == win["y"] + win["height"]
        (tmp / "rediwm-config.toml").write_text(BASE + mixed)
        ipc.reload_config()
        ipc.wait_for_frame()
        clean = shot(f"resize-{edge}-{index}-clean", None)
        diff = ImageChops.difference(active, clean)
        assert diff.getbbox(), (edge, "no elastic resize membrane")

    # Fade while still held, resume on motion, then cancel through window detach.
    (tmp / "rediwm-config.toml").write_text(config)
    ipc.reload_config()
    win = ipc.get_windows()[0]
    x, y = win["x"] + win["width"] + 2, win["y"] + win["height"] + 2
    ipc.action("set_anim_time", {"ms": 50000})
    move(x, y)
    ipc.pointer_button(272, True)
    ipc.action("set_anim_time", {"ms": 50100})
    move(x + 20, y + 15)
    ipc.wait_for_frame()
    ipc.action("set_anim_time", {"ms": 54000})
    ipc.wait_for_frame()
    held = shot("resize-held-idle", None)
    ipc.action("set_anim_time", {"ms": None})
    time.sleep(.8)
    assert_idle(ipc, "stationary resize kept waking")
    ipc.action("set_anim_time", {"ms": 54100})
    move(x + 35, y + 20)
    ipc.wait_for_frame()
    ipc.minimize(win["id"])
    assert ipc.get_input_state()["cursor_mode"] == "passthrough"
    ipc.pointer_button(272, False)
    ipc.restore(win["id"])
    ipc.action("set_anim_time", {"ms": 56000})
    ipc.wait_for_frame()
    cancelled = shot("resize-cancelled", None)
    (tmp / "rediwm-config.toml").write_text(BASE + mixed)
    ipc.reload_config()
    ipc.wait_for_frame()
    assert ImageChops.difference(cancelled, shot("resize-cancelled-clean", None)).getbbox() is None
    assert held.size == cancelled.size
    # Releasing a fresh resize fades the sheet and stops output wakeups.
    (tmp / "rediwm-config.toml").write_text(ON + mixed)
    ipc.reload_config()
    win = ipc.get_windows()[0]
    x, y = win["x"] + win["width"] + 2, win["y"] + win["height"] / 2
    ipc.action("set_anim_time", {"ms": 57000})
    move(x, y)
    ipc.pointer_button(272, True)
    ipc.action("set_anim_time", {"ms": 57100})
    move(x + 20, y)
    ipc.wait_for_frame()
    ipc.pointer_button(272, False)
    ipc.action("set_anim_time", {"ms": 57200})
    ipc.wait_for_frame()
    release = shot("resize-release", None)
    ipc.action("set_anim_time", {"ms": 59000})
    ipc.wait_for("window_geometry_settled", window_id=win["id"])
    assert ImageChops.difference(release, shot("resize-release-faded", None)).getbbox()
    assert ipc.get_windows()[0]["width"] == win["width"] + 20

    check_resize_settlement(ipc, move, tmp, mixed, config, process)


def check_resize_settlement(ipc, move, tmp, mixed, config, process):
    # A late pre-release ack must not discard the pending final size/anchor.
    win = ipc.get_windows()[0]
    x, y = win["x"] - 2, win["y"] - 2
    ipc.action("set_anim_time", {"ms": 60000})
    move(x, y)
    ipc.pointer_button(272, True)
    process.send_signal(signal.SIGSTOP)
    try:
        ipc.action("set_anim_time", {"ms": 60100})
        move(x - 25, y - 20)
        ipc.action("set_anim_time", {"ms": 60150})
        ipc.wait_for_frame()
        ipc.pointer_button(272, False)
        ipc.action("set_anim_time", {"ms": 65000})
        ipc.wait_for_frame()
    finally:
        process.send_signal(signal.SIGCONT)
    ipc.wait_for("window_geometry_settled", window_id=win["id"])
    final = ipc.get_windows()[0]
    assert final["width"] == win["width"] + 25 and final["height"] == win["height"] + 20
    assert final["x"] + final["width"] == win["x"] + win["width"]
    assert final["y"] + final["height"] == win["y"] + win["height"]
    # Reloading during a lag immediately releases the final requested size;
    # reduced motion starts with ordinary, immediate resize behavior.
    for index, reduced in enumerate((False, True)):
        (tmp / "rediwm-config.toml").write_text(config + ('[animations]\nreduced_motion = "on"\n' if reduced else ''))
        ipc.reload_config()
        win = ipc.get_windows()[0]
        x, y = win["x"] + win["width"] + 2, win["y"] + win["height"] / 2
        stamp = 70000 + index * 4000
        ipc.action("set_anim_time", {"ms": stamp})
        move(x, y)
        ipc.pointer_button(272, True)
        move(x + 15, y)
        ipc.wait_for_frame()
        if not reduced:
            assert ipc.get_windows()[0]["width"] == win["width"]
            (tmp / "rediwm-config.toml").write_text(BASE + mixed)
            ipc.reload_config()
        wait_for(lambda: ipc.get_windows()[0]["width"] == win["width"] + 15, "resize opt-out retained lag")
        ipc.pointer_button(272, False)
        ipc.action("set_anim_time", {"ms": stamp + 1000})
        ipc.wait_for("window_geometry_settled", window_id=win["id"])
    (tmp / "rediwm-config.toml").write_text(ON + mixed)
    ipc.reload_config()
    ipc.action("set_anim_time", {"ms": None})
    time.sleep(1)
    assert_idle(ipc, "resize effect kept waking after release")


def check_shell_resize(ipc, move):
    # Settings applies its size synchronously and has no client ack to finish
    # settlement. It must use the same lag and preserve the fixed right edge.
    ipc.open_control_center()
    win = wait_for(lambda: next((w for w in ipc.get_windows() if w.get("app_id") == "rediwm-settings"), None), "Settings did not map")
    ipc.action("move_window_to", {"id": win["id"], "x": 40, "y": 20})
    ipc.wait_for("window_geometry_settled", window_id=win["id"])
    win = next(w for w in ipc.get_windows() if w["id"] == win["id"])
    ipc.action("set_anim_time", {"ms": 80000})
    move(win["x"] - 2, win["y"] + 80)
    ipc.pointer_button(272, True)
    assert ipc.get_input_state()["cursor_mode"] == "resize"
    ipc.action("set_anim_time", {"ms": 80100})
    move(win["x"] - 17, win["y"] + 80)
    ipc.wait_for_frame()
    current = next(w for w in ipc.get_windows() if w["id"] == win["id"])
    assert current["width"] == win["width"], "shell resize skipped lag"
    ipc.action("set_anim_time", {"ms": 80140})
    ipc.wait_for_frame()
    current = next(w for w in ipc.get_windows() if w["id"] == win["id"])
    assert win["width"] < current["width"] < win["width"] + 15
    ipc.pointer_button(272, False)
    ipc.action("set_anim_time", {"ms": 82000})
    ipc.wait_for("window_geometry_settled", window_id=win["id"])
    current = next(w for w in ipc.get_windows() if w["id"] == win["id"])
    assert current["width"] == win["width"] + 15
    assert current["x"] + current["width"] == win["x"] + win["width"]
    ipc.action("close_window", {"id": win["id"]})
    ipc.action("set_anim_time", {"ms": 84000})
    wait_for(lambda: all(w["id"] != win["id"] for w in ipc.get_windows()), "Settings did not close")
    ipc.action("set_anim_time", {"ms": None})


def run():
    scale = float(os.environ.get("REDIWM_TEST_SCALE", "1"))
    with tempfile.TemporaryDirectory(prefix="rediwm-ribbons-") as directory:
        tmp = Path(directory)
        build_client(tmp)
        outputs = os.environ.get("REDIWM_TEST_OUTPUTS", "1")
        mixed = ('[[outputs]]\nname = "HEADLESS-1"\nscale = 1\n' +
                 '[[outputs]]\nname = "HEADLESS-2"\nscale = 1.5\n') if outputs == "2" else ""
        process, log = spawn_compositor(tmp, scale="auto" if mixed else str(scale), outputs=outputs,
            config_content=ON + mixed, binary=os.environ.get("REDIWM_TEST_BINARY"), env_extra={
            "HOME": str(tmp), "XDG_CONFIG_HOME": str(tmp / "config"),
            "XDG_DATA_HOME": str(tmp / "data"), "XDG_CACHE_HOME": str(tmp / "cache"),
            "DBUS_SESSION_BUS_ADDRESS": "", "WLR_RENDERER_ALLOW_SOFTWARE": "1",
        })
        client = None
        try:
            with IPCClient(tmp, timeout=15) as ipc:
                ipc.wait_for("wallpaper_presented", timeout_ms=10000)
                # Headless output creation order can put HEADLESS-2 on the
                # left. Crop using the selected output's actual raster scale.
                capture_output = min(ipc.get_outputs(), key=lambda out: out["x"])
                scale = capture_output["scale"]

                def move(x, y):
                    for out in ipc.get_outputs():
                        if out["x"] <= x < out["x"] + out["logical_width"] and out["y"] <= y < out["y"] + out["logical_height"]:
                            return ipc.move_cursor(round(x - out["x"]), round(y - out["y"]), output=out["name"])
                    raise AssertionError(("pointer outside layout", x, y))
                display = wait_for(lambda: next((p.name for p in tmp.glob("wayland-*")
                                                 if not p.name.endswith(".lock")), None), "display unavailable")
                client = subprocess.Popen([str(tmp / "client")], env=dict(os.environ,
                    XDG_RUNTIME_DIR=str(tmp), WAYLAND_DISPLAY=display, REDIWM_TEST_DECORATION="server"),
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                win = wait_for(lambda: next(iter(ipc.get_windows()), None), "window unavailable")
                ipc.action("move_window_to", {"id": win["id"], "x": 100, "y": 140})
                ipc.wait_for("window_geometry_settled", window_id=win["id"])
                time.sleep(.4)
                ipc.action("set_anim_time", {"ms": 1000})
                move(180, 160)
                ipc.action("pointer_button", {"button": 272, "pressed": True})
                for step in range(1, 25):
                    ipc.action("set_anim_time", {"ms": 1000 + step * 20})
                    move(180 + step * 10, 160)
                    ipc.wait_for_frame()
                win = ipc.get_windows()[0]
                assert win["x"] > 300, ("ribbon intercepted the move", win)
                # Exclude the frame/shadow: only the trail to its left may differ.
                box = tuple(round(v * scale) for v in (max(0, win["x"] - 420),
                    max(0, win["y"] - 60), win["x"] - 35, win["y"] + win["height"] + 60))

                def shot(name, region=box):
                    path = tmp / f"{name}.png"
                    ipc.screenshot(path=str(path), output=capture_output["name"])
                    if os.environ.get("REDIWM_TEST_ARTIFACT_DIR"):
                        dest = Path(os.environ["REDIWM_TEST_ARTIFACT_DIR"])
                        dest.mkdir(parents=True, exist_ok=True)
                        (dest / f"ribbon-{name}-{scale}.png").write_bytes(path.read_bytes())
                    frame = Image.open(path).convert("RGB")
                    if region is None:
                        # The taskbar clock uses wall time, independently of the
                        # pinned animation clock. Keep minute ticks out of diffs.
                        ImageDraw.Draw(frame).rectangle((frame.width - round(120 * scale),
                            frame.height - round(44 * scale), frame.width, frame.height), fill=(0, 0, 0))
                    return frame.crop(region)

                moving_frame = shot("moving", None)
                moving = moving_frame.crop(box)
                faded_frame, faded = check_move_fade(ipc, shot, moving, box)
                # The middle of the trailing edge carries a faint wash too,
                # well away from both corner flames and the window's shadow.
                middle_box = tuple(round(v * scale) for v in (win["x"] - 100,
                    win["y"] + win["height"] * .36, win["x"] - 60,
                    win["y"] + win["height"] * .64))
                middle = ImageChops.difference(moving_frame.crop(middle_box), faded_frame.crop(middle_box))
                assert 2 < middle.getextrema()[0][1] < 25, "drag sheet is missing or too bright"
                # Opposite the trails, away from the titlebar and pointer: the
                # exterior frame halo must light up here too, then disappear.
                edge_box = tuple(round(v * scale) for v in (win["x"] + win["width"] + 2,
                    win["y"] + 80, win["x"] + win["width"] + 18, win["y"] + win["height"] - 30))
                edge = ImageChops.difference(moving_frame.crop(edge_box), faded_frame.crop(edge_box))
                assert edge.getextrema()[0][1] > 20, "dragged frame has no visible border glow"
                check_minimize(ipc, win, shot, tmp, mixed, scale)
                (tmp / "rediwm-config.toml").write_text(BASE + mixed)
                ipc.reload_config()
                ipc.wait_for_frame()
                disabled = shot("disabled")
                assert ImageChops.difference(faded, disabled).getbbox() is None, "trail left stale pixels"
                ipc.action("pointer_button", {"button": 272, "pressed": False})
                ipc.action("set_anim_time", {"ms": None})
                time.sleep(1)
                assert_idle(ipc, "disabled effect kept rendering")

                # Re-enable and destroy during a move: no retained window pointers.
                (tmp / "rediwm-config.toml").write_text(ON + mixed)
                ipc.reload_config()
                if mixed:
                    boundary = sorted(ipc.get_outputs(), key=lambda out: out["x"])[1]["x"]
                    ipc.action("move_window_to", {"id": win["id"], "x": boundary - 180, "y": 140})
                    ipc.wait_for("window_geometry_settled", window_id=win["id"])
                    win = ipc.get_windows()[0]
                ipc.action("set_anim_time", {"ms": 6000})
                move(win["x"] + 80, win["y"] + 20)
                ipc.action("pointer_button", {"button": 272, "pressed": True})
                move(win["x"] + 160, win["y"] + 20)
                ipc.wait_for_frame()
                ipc.action("set_anim_time", {"ms": 6300})
                ipc.wait_for_frame()
                # Disable while pixels are still live, then verify complete erasure.
                (tmp / "rediwm-config.toml").write_text(BASE + mixed)
                ipc.reload_config()
                ipc.wait_for_frame()
                live_disabled = shot("live-disabled")
                ipc.action("set_anim_time", {"ms": 10000})
                ipc.wait_for_frame()
                assert ImageChops.difference(live_disabled, shot("live-disabled-later")).getbbox() is None
                ipc.action("set_anim_time", {"ms": None})
                (tmp / "rediwm-config.toml").write_text(ON + mixed)
                ipc.reload_config()
                ipc.action("pointer_button", {"button": 272, "pressed": False})
                # The release only ends the grab; the next frame starts the drag
                # lift's fall on the real clock. Pinning the clock before that
                # frame leaves the animation "in the future", never settled.
                ipc.wait_for_frame()
                check_resize(ipc, ipc.get_windows()[0], shot, move, tmp, mixed, scale, client)
                check_shell_resize(ipc, move)
                win = ipc.get_windows()[0]
                move(win["x"] + 80, win["y"] + 20)
                ipc.action("pointer_button", {"button": 272, "pressed": True})
                move(win["x"] + 160, win["y"] + 20)
                ipc.wait_for_frame()
                stop_process(client)
                client = None
                wait_for(lambda: not ipc.get_windows(), "window did not disappear")
                ipc.action("pointer_button", {"button": 272, "pressed": False})
                ipc.wait_for_frame()
                assert process.poll() is None
                assert ipc.get_perf()["output_failed_commits"] == 0
                print(f"PASS: movement, minimize and resize ribbons draw, cancel, reload and return to idle at scale {scale}")
        except Exception:
            log.flush()
            print(Path(log.name).read_text()[-6000:])
            raise
        finally:
            if client and client.poll() is None:
                stop_process(client)
            stop_process(process)
            log.close()


if __name__ == "__main__":
    run()

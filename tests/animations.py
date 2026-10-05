#!/usr/bin/env python3
"""Animation observability: GetAnimations traces and GetPerformanceStats counters.

Stage 3 of plan-physics-animation.md. Assertions are on numbers from IPC,
not screenshots. Run after zig build.
"""
from pathlib import Path
import math
import tempfile

from desktop_zoom import build_client
from ipc_client import IPCClient, spawn_compositor, stop_process


def find_site(anims, site):
    for item in anims:
        if item.get("site") == site:
            return item
    return None


def run():
    with tempfile.TemporaryDirectory(prefix="rediwm-anim-") as directory:
        tmp = Path(directory)
        process, log = spawn_compositor(tmp)
        try:
            with IPCClient(socket_path=tmp, timeout=15) as client:
                client.wait_for("catalog_published", timeout_ms=10000)
                client.wait_for("wallpaper_presented", timeout_ms=10000)

                client.reset_perf()
                client.action('open_start_menu')
                client.wait_for("menu_opened", timeout_ms=5000)
                client.wait_for_frame()
                perf = client.get_perf()
                work = perf.get("frame_work") or {}
                assert "anim_cpu" in work, work
                anim_cpu = work["anim_cpu"]
                assert anim_cpu["samples"] >= 0, anim_cpu
                for field in ("avg_ms", "p50_ms", "p95_ms", "p99_ms", "max_ms"):
                    assert math.isfinite(anim_cpu[field]) and anim_cpu[field] >= 0, anim_cpu
                assert "anim_frames_scheduled" in perf, perf
                assert "anim_wasted_wakeups" in perf, perf
                assert "anim_longest_ms" in perf, perf
                assert perf["anim_wasted_wakeups"] <= perf["anim_frames_scheduled"], perf
                client.action("close_panel", {"panel": "start_menu"})
                client.wait_for("menu_closed", timeout_ms=5000)

                client.action('set_anim_time', {"ms": 1000})
                client.reset_perf()
                client.action('open_start_menu')
                client.wait_for_frame()
                client.wait_for_frame()
                assert client.get_perf()["anim_frames_scheduled"] == 0, "pinned animations scheduled another frame"
                anims = client.action('get_animations')
                assert isinstance(anims, list), anims
                slide = find_site(anims, "start_menu.slide")
                assert slide is not None, anims
                assert slide["curve"] == "spring", slide
                assert slide["target"] == 1, slide
                assert slide["settled"] is False, slide
                assert 0 <= slide["value"] < 0.2, slide

                values = []
                velocities = []
                t = 1000
                while t <= 1400:
                    client.action('set_anim_time', {"ms": t})
                    slide = find_site(client.action('get_animations'), "start_menu.slide")
                    assert slide is not None, t
                    values.append(slide["value"])
                    velocities.append(slide["velocity"])
                    if slide["value"] >= 0.4:
                        break
                    t += 8
                else:
                    raise AssertionError(f"open did not reach 40%: {values[-1]!r}")

                for prev, cur in zip(values, values[1:]):
                    assert cur + 1e-5 >= prev, (prev, cur, values)

                v_before = velocities[-1]
                client.action("close_panel", {"panel": "start_menu"})
                after = find_site(client.action('get_animations'), "start_menu.slide")
                assert after is not None
                assert after["target"] == 0, after
                assert after["settled"] is False, after
                assert after["curve"] == "spring", after
                assert abs(after["velocity"] - v_before) < 1e-3, (v_before, after)
                assert abs(after["value"] - values[-1]) < 1e-3, (values[-1], after)

                close_vel = [after["velocity"]]
                close_val = [after["value"]]
                t += 8
                end = t + 400
                while t <= end:
                    client.action('set_anim_time', {"ms": t})
                    slide = find_site(client.action('get_animations'), "start_menu.slide")
                    if slide is None:
                        # Close settled and the frame path destroyed the panel.
                        break
                    close_val.append(slide["value"])
                    close_vel.append(slide["velocity"])
                    if slide["settled"]:
                        break
                    t += 8

                for prev, cur in zip(close_vel, close_vel[1:]):
                    jump = cur - prev
                    # 8 ms of a panel spring cannot reverse by more than a
                    # small amount; a retarget restart would flip the sign
                    # and jump by the full initial speed.
                    assert abs(jump) < 8.0, (prev, cur, close_vel)

                client.action('set_anim_time', {"ms": t + 2000})
                done = find_site(client.action('get_animations'), "start_menu.slide")
                if done is not None:
                    assert done["settled"] is True, done
                    assert abs(done["value"] - done["target"]) < 1e-3, done
                    assert done["velocity"] == 0, done

                client.action('set_anim_time', {"ms": None})

                def reload(text):
                    (tmp / "rediwm-config.toml").write_text(text)
                    client.reload_config()

                client.action('set_anim_time', {"ms": 1000})
                client.action('open_start_menu')
                client.wait_for_frame()
                before = find_site(client.action('get_animations'), "start_menu.slide")
                assert before is not None and before["settled"] is False, before
                v0, x0 = before["velocity"], before["value"]
                reload("""
[animations]
speed = 1.0
[animations.panel_slide]
spring = { damping_ratio = 1.0, stiffness = 2000, epsilon = 0.0001 }
""")
                after = find_site(client.action('get_animations'), "start_menu.slide")
                assert after is not None, after
                assert abs(after["value"] - x0) < 1e-3, (x0, after)
                assert abs(after["velocity"] - v0) < 1e-3, (v0, after)
                assert after["settled"] is False, after
                client.action('set_anim_time', {"ms": 1080})
                stepped = find_site(client.action('get_animations'), "start_menu.slide")
                assert stepped is not None
                stiff_value = stepped["value"]
                client.action("close_panel", {"panel": "start_menu"})
                client.action('set_anim_time', {"ms": 3000})
                client.wait_for_frame()

                reload("""
[animations]
speed = 1.0
[animations.panel_slide]
spring = { damping_ratio = 1.0, stiffness = 400, epsilon = 0.0001 }
""")
                client.action('set_anim_time', {"ms": 4000})
                client.action('open_start_menu')
                client.action('set_anim_time', {"ms": 4080})
                soft = find_site(client.action('get_animations'), "start_menu.slide")
                assert soft is not None
                assert stiff_value > soft["value"] + 0.02, (stiff_value, soft["value"])
                client.action("close_panel", {"panel": "start_menu"})
                client.action('set_anim_time', {"ms": 6000})
                client.wait_for_frame()

                for extra, label in (
                    ("enabled = false\n", "enabled=false"),
                    ("speed = 0\n", "speed=0"),
                    ('reduced_motion = "on"\n', "reduced_motion=on"),
                ):
                    reload("[animations]\n" + extra)
                    client.action('set_anim_time', {"ms": 7000})
                    client.action('open_start_menu')
                    instant = find_site(client.action('get_animations'), "start_menu.slide")
                    if instant is not None:
                        assert instant["settled"] is True, (label, instant)
                        assert abs(instant["value"] - 1) < 1e-4, (label, instant)
                    perf = client.get_perf()
                    if label == "enabled=false":
                        assert perf["anim_enabled"] is False, perf
                    if label == "speed=0":
                        assert perf["anim_speed"] == 0, perf
                    if label == "reduced_motion=on":
                        assert perf["anim_reduced_motion"] is True, perf
                    client.action("close_panel", {"panel": "start_menu"})
                    client.wait_for_frame()

                client.action('set_anim_time', {"ms": None})

                reload("""
[animations]
enabled = true
speed = 1.0
reduced_motion = "off"
""")
                build_client(tmp)
                client.action('set_anim_time', {"ms": 10000})
                client.action("spawn", {"argv": [str(tmp / "client")]})
                client.wait_for("window_mapped", app_id="rediwm.zoom-fixture", timeout_ms=10000)
                wins = client.get_windows()
                assert wins, wins
                win = next(w for w in wins if w.get("app_id") == "rediwm.zoom-fixture")
                wid = win["id"]
                # Logical map is not gated on the open spring.
                assert any(w["id"] == wid for w in client.get_windows()), client.get_windows()
                opened = find_site(client.action('get_animations'), f"window.{wid}.open")
                faded = find_site(client.action('get_animations'), f"window.{wid}.fade")
                assert opened is not None, client.action('get_animations')
                assert faded is not None, client.action('get_animations')
                assert opened["settled"] is False, opened
                assert faded["settled"] is False, faded
                assert opened["target"] == 1, opened
                assert 0 <= opened["value"] < 0.5, opened
                open_vals = [opened["value"]]
                t = 10000
                while t <= 10400:
                    t += 8
                    client.action('set_anim_time', {"ms": t})
                    opened = find_site(client.action('get_animations'), f"window.{wid}.open")
                    if opened is None or opened["settled"]:
                        break
                    open_vals.append(opened["value"])
                assert open_vals[0] < 0.2, open_vals[0]
                assert max(open_vals) > 0.8, open_vals
                for prev, cur in zip(open_vals, open_vals[1:]):
                    assert abs(cur - prev) < 0.2, (prev, cur, open_vals)
                client.action('set_anim_time', {"ms": t + 2000})
                client.wait_for_frame()
                done_open = find_site(client.action('get_animations'), f"window.{wid}.open")
                if done_open is not None:
                    assert done_open["settled"] is True, done_open

                origin = next(w for w in client.get_windows() if w["id"] == wid)
                client.action('set_anim_time', {"ms": 20000})
                client.action("maximize_window", {"id": wid})
                maximized = next(w for w in client.get_windows() if w["id"] == wid)
                anims = client.action('get_animations')
                mx = find_site(anims, f"window.{wid}.move_x")
                my = find_site(anims, f"window.{wid}.move_y")
                sw = find_site(anims, f"window.{wid}.size_w")
                assert mx is not None or my is not None or sw is not None, anims
                if mx is not None:
                    assert mx["settled"] is False, mx
                    assert abs(mx["value"] - origin["x"]) < 8, (origin, mx)
                    assert mx["target"] == maximized["x"], (maximized, mx)
                if sw is not None:
                    assert sw["settled"] is False, sw
                    assert sw["target"] > origin["width"], (origin, sw)
                client.action('set_anim_time', {"ms": 22000})
                client.wait_for_frame()
                settled_move = find_site(client.action('get_animations'), f"window.{wid}.move_x")
                if settled_move is not None:
                    assert settled_move["settled"] is True, settled_move
                client.action("restore_window", {"id": wid})
                client.action('set_anim_time', {"ms": 24000})
                client.wait_for_frame()

                client.action('set_anim_time', {"ms": 30000})
                client.action("close_window", {"id": wid})
                client.wait_for("window_closed", window_id=wid, timeout_ms=5000)
                assert not any(w["id"] == wid for w in client.get_windows()), client.get_windows()
                closing = find_site(client.action('get_animations'), f"window.{wid}.open")
                fading = find_site(client.action('get_animations'), f"window.{wid}.fade")
                if closing is not None or fading is not None:
                    live = closing or fading
                    assert live["settled"] is False, live
                    assert live["target"] == 0, live
                    client.action('set_anim_time', {"ms": 32000})
                    client.wait_for_frame()
                    assert find_site(client.action('get_animations'), f"window.{wid}.open") is None
                    assert find_site(client.action('get_animations'), f"window.{wid}.fade") is None

                client.action('set_anim_time', {"ms": 40000})
                cam0 = client.action('get_camera')
                client.action('set_camera', {"x": 240, "y": 0})
                pan = find_site(client.action('get_animations'), "camera.pan_x")
                assert pan is not None, client.action('get_animations')
                assert pan["curve"] == "spring", pan
                assert pan["settled"] is False, pan
                assert pan["target"] == 240, pan
                assert abs(pan["value"] - cam0["x"]) < 8, (cam0, pan)
                pan_vals = [pan["value"]]
                t = 40000
                while t <= 40400:
                    t += 8
                    client.action('set_anim_time', {"ms": t})
                    pan = find_site(client.action('get_animations'), "camera.pan_x")
                    if pan is None or pan["settled"]:
                        break
                    pan_vals.append(pan["value"])
                assert max(pan_vals) > pan_vals[0] + 20, pan_vals
                for prev, cur in zip(pan_vals, pan_vals[1:]):
                    assert abs(cur - prev) < 40, (prev, cur, pan_vals)
                client.action('set_anim_time', {"ms": t + 2000})
                client.wait_for_frame()
                cam1 = client.action('get_camera')
                assert cam1["x"] == 240, cam1
                settled_pan = find_site(client.action('get_animations'), "camera.pan_x")
                if settled_pan is not None:
                    assert settled_pan["settled"] is True, settled_pan

                client.action('set_anim_time', {"ms": 50000})
                client.action('set_zoom', {"percent": 70})
                zoom = find_site(client.action('get_animations'), "camera.zoom")
                assert zoom is not None, client.action('get_animations')
                assert zoom["curve"] == "spring", zoom
                assert zoom["settled"] is False, zoom
                assert abs(zoom["target"] - 0.7) < 1e-3, zoom
                assert zoom["value"] > 0.9, zoom
                client.action('set_anim_time', {"ms": 52000})
                client.wait_for_frame()
                assert client.action('get_camera')["zoom_percent"] == 70
                done_zoom = find_site(client.action('get_animations'), "camera.zoom")
                if done_zoom is not None:
                    assert done_zoom["settled"] is True, done_zoom

                client.action('reset_camera')
                client.action('set_anim_time', {"ms": 54000})
                client.wait_for_frame()
                reset = client.action('get_camera')
                assert reset["zoom_percent"] == 100 and reset["x"] == 0 and reset["y"] == 0, reset

                # Rubber-band: a held pan past Bounds overshoots by less than the
                # unconstrained delta, then springs back on release.
                max_x = reset["max_x"]
                assert max_x > 0, reset
                client.action('set_anim_time', {"ms": 60000})
                client.action('set_camera', {"x": max_x, "y": 0})
                client.action('set_anim_time', {"ms": 62000})
                client.wait_for_frame()
                edge = client.action('get_camera')
                assert edge["x"] == max_x, edge
                client.action('move_cursor', {"x": 640, "y": 360})
                client.action('pointer_button', {"button": 0x112, "pressed": True})
                client.action('set_anim_time', {"ms": 62020})
                client.action('move_cursor', {"x": 200, "y": 360})
                over = client.action('get_camera')
                assert over["x"] > max_x, over
                assert over["x"] < max_x + 440, over
                client.action('pointer_button', {"button": 0x112, "pressed": False})
                release = find_site(client.action('get_animations'), "camera.pan_x")
                assert release is not None, client.action('get_animations')
                assert release["curve"] == "spring", release
                assert release["target"] == max_x, release
                client.action('set_anim_time', {"ms": 64000})
                client.wait_for_frame()
                back = client.action('get_camera')
                assert back["x"] == max_x, back

                client.action('move_cursor', {"x": 200, "y": 200})
                client.action('set_anim_time', {"ms": 70000})
                client.action('pinch', {"phase": "begin", "fingers": 2})
                live = find_site(client.action('get_animations'), "camera.zoom")
                assert live is not None and live["settled"] is False, client.action('get_animations')
                assert live["curve"] == "off", live
                client.action('pinch', {"phase": "update", "scale": 0.7})
                pinched = find_site(client.action('get_animations'), "camera.zoom")
                assert pinched is not None, client.action('get_animations')
                assert abs(pinched["value"] - 0.7) < 0.05, pinched
                assert client.action('get_camera')["zoom_percent"] == 100
                client.action('pinch', {"phase": "end"})
                settling = find_site(client.action('get_animations'), "camera.zoom")
                if settling is not None:
                    assert settling["curve"] == "spring", settling
                    assert abs(settling["target"] - 0.7) < 1e-3, settling
                assert client.action('get_camera')["zoom_percent"] == 70
                client.action('set_anim_time', {"ms": 72000})
                client.wait_for_frame()
                assert client.action('get_camera')["zoom_percent"] == 70

                client.action('reset_camera')
                client.action('set_anim_time', {"ms": 74000})
                client.wait_for_frame()
                client.action('move_cursor', {"x": 200, "y": 200})
                before_swipe = client.action('get_camera')
                client.action('set_anim_time', {"ms": 80000})
                client.action('swipe', {"phase": "begin", "fingers": 2})
                client.action('swipe', {"phase": "update", "dx": 40, "dy": 0})
                mid_swipe = client.action('get_camera')
                assert mid_swipe["x"] != before_swipe["x"], (before_swipe, mid_swipe)
                client.action('swipe', {"phase": "end"})
                client.action('set_anim_time', {"ms": 82000})
                client.wait_for_frame()
                after_swipe = client.action('get_camera')
                assert after_swipe["x"] != before_swipe["x"], after_swipe

                client.action('set_anim_time', {"ms": None})
            print("PASS: GetAnimations traces and animation performance counters")
        except Exception:
            print((tmp / "compositor.log").read_text())
            raise
        finally:
            log.close()
            stop_process(process)


if __name__ == "__main__":
    run()

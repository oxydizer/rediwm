#!/usr/bin/env python3
"""Damage-aware client-edge sampling. Run after zig build.

Uses the zoom_client fixture with REDIWM_TEST_EDGE=1. Never connects to the
host desktop. Set REDIWM_TEST_RENDERER=gles2 to exercise GPU readback.
"""
import os
from pathlib import Path
import subprocess
import tempfile

from desktop_zoom import ROOT, build_client, wait_for
from ipc_client import IPCClient


KEY_1, KEY_2, KEY_3, KEY_4 = 2, 3, 4, 5
KEY_7, KEY_8, KEY_9 = 7, 8, 9
KEY_F5, KEY_F6 = 63, 64
KEY_F8, KEY_F9 = 66, 67


def approx_rgba(value, expected, eps=0.02):
    assert value is not None, f"expected {expected}, got null skirt"
    assert len(value) == 4, value
    for got, want in zip(value, expected):
        assert abs(got - want) <= eps, f"{value} !~ {expected}"


def run():
    renderer = os.environ.get("REDIWM_TEST_RENDERER", "pixman")
    with tempfile.TemporaryDirectory(prefix="rediwm-edge-") as directory:
        tmp = Path(directory)
        build_client(tmp)
        (tmp / "config.toml").write_text("")
        env = dict(
            os.environ,
            XDG_RUNTIME_DIR=str(tmp),
            WLR_BACKENDS="headless",
            WLR_HEADLESS_OUTPUTS="1",
            WLR_RENDERER=renderer,
            WLR_RENDERER_ALLOW_SOFTWARE="1",
            REDIWM_SCALE="1",
            REDIWM_CONFIG=str(tmp / "config.toml"),
            REDIWM_TEST_EDGE="1",
            REDIWM_TEST_DECORATION="server",
        )
        env.pop("WAYLAND_DISPLAY", None)
        env.pop("REDIWM_SOCKET", None)
        client_log = tmp / "client.log"
        with (tmp / "compositor.log").open("w") as log:
            compositor = subprocess.Popen([str(ROOT / "zig-out/bin/rediwm")], env=env, stdout=log, stderr=log)
        client = None
        try:
            ipc_path = wait_for(lambda: next(tmp.glob("rediwm-*.sock"), None), "IPC unavailable")
            display = next(p.name for p in tmp.glob("wayland-*") if not p.name.endswith(".lock"))
            with client_log.open("w") as clog:
                client = subprocess.Popen(
                    [str(tmp / "client")],
                    env=dict(env, WAYLAND_DISPLAY=display),
                    stdout=clog,
                    stderr=clog,
                )
            with IPCClient(ipc_path, timeout=15) as ipc:
                win = wait_for(
                    lambda: next((w for w in ipc.get_windows() if w.get("app_id") == "rediwm.zoom-fixture"), None),
                    "fixture did not map",
                )
                wait_for(lambda: client_log.exists() and "frame 8" in client_log.read_text(), "frame callbacks not delivered")
                ipc.action("focus_window", {"id": win["id"]})
                ipc.wait_for_frame()

                debug = ipc.get_window_debug(win["id"])
                assert debug["decoration_mode"] == "server", debug
                approx_rgba(debug["skirt_fill"], (0.0, 0.0, 1.0, 1.0))
                assert debug["edge_sample"] == "color", debug

                def fire(code, token):
                    start = client_log.read_text().count(token)
                    ipc.key_down_up(code)
                    wait_for(lambda: client_log.read_text().count(token) > start, f"client did not log {token}")
                    ipc.wait_for_frame()

                ipc.reset_perf()
                before = ipc.get_perf()
                title_before = before["titlebar_paints"]
                footer_before = before["footer_paints"]
                attempted_before = before["edge_samples_attempted"]
                skipped_before = before["edge_samples_skipped"]

                fire(KEY_1, "edge above")
                after_above = ipc.get_perf()
                assert after_above["edge_samples_attempted"] == attempted_before, after_above
                assert after_above["edge_samples_skipped"] > skipped_before, after_above
                assert after_above["titlebar_paints"] == title_before, after_above
                assert after_above["footer_paints"] == footer_before, after_above
                debug = ipc.get_window_debug(win["id"])
                approx_rgba(debug["skirt_fill"], (0.0, 0.0, 1.0, 1.0))

                fire(KEY_3, "edge none")
                after_none = ipc.get_perf()
                assert after_none["edge_samples_attempted"] == attempted_before, after_none
                debug = ipc.get_window_debug(win["id"])
                approx_rgba(debug["skirt_fill"], (0.0, 0.0, 1.0, 1.0))

                fire(KEY_4, "edge rotate")
                after_rotate = ipc.get_perf()
                assert after_rotate["edge_samples_attempted"] == attempted_before, after_rotate
                debug = ipc.get_window_debug(win["id"])
                approx_rgba(debug["skirt_fill"], (0.0, 0.0, 1.0, 1.0))

                fire(KEY_2, "edge row")
                after_row = ipc.get_perf()
                assert after_row["edge_samples_attempted"] > attempted_before, after_row
                assert after_row["edge_samples_succeeded"] >= 1, after_row
                assert after_row["titlebar_paints"] == title_before, after_row
                assert after_row["footer_paints"] > footer_before, after_row
                debug = ipc.get_window_debug(win["id"])
                approx_rgba(debug["skirt_fill"], (0.0, 1.0, 0.0, 1.0))

                ipc.reset_perf()
                ipc.action("move_window_to", {"id": win["id"], "x": win["x"] + 40, "y": win["y"] + 20})
                ipc.wait_for_frame()
                moved = ipc.get_perf()
                assert moved["edge_samples_attempted"] == 0, moved
                debug = ipc.get_window_debug(win["id"])
                approx_rgba(debug["skirt_fill"], (0.0, 1.0, 0.0, 1.0))

                ipc.reset_perf()
                ipc.action("move_cursor", {"x": debug["chrome_box"]["x"] + 80, "y": debug["chrome_box"]["y"] + 10})
                ipc.wait_for_frame()
                hovered = ipc.get_perf()
                assert hovered["edge_samples_attempted"] == 0, hovered

                ipc.reset_perf()
                fire(KEY_8, "edge transform")
                rotated = ipc.get_window_debug(win["id"])
                assert rotated["edge_sample"] == "fallback", rotated
                assert rotated["skirt_fill"] is None, rotated
                assert rotated["buffer_transform"] != "normal", rotated
                fire(KEY_8, "edge transform")
                restored = ipc.get_window_debug(win["id"])
                assert restored["edge_sample"] == "color", restored
                approx_rgba(restored["skirt_fill"], (0.0, 1.0, 0.0, 1.0))

                ipc.reset_perf()
                fire(KEY_7, "edge scale")
                scaled = ipc.get_perf()
                assert scaled["edge_samples_attempted"] >= 1, scaled
                debug = ipc.get_window_debug(win["id"])
                assert debug["edge_sample"] == "color", debug
                fire(KEY_7, "edge scale")

                ipc.reset_perf()
                fire(KEY_9, "edge geometry")
                geo = ipc.get_perf()
                assert geo["edge_samples_attempted"] >= 1, geo
                fire(KEY_9, "edge geometry")

                ipc.key_down_up(KEY_F8)
                wait_for(
                    lambda: next((w for w in ipc.get_windows() if w["id"] == win["id"] and w.get("is_maximized") and w["width"] > 1000), None),
                    "maximize failed",
                )
                ipc.wait_for_frame()
                ipc.key_down_up(KEY_F9)
                wait_for(
                    lambda: next((w for w in ipc.get_windows() if w["id"] == win["id"] and not w.get("is_maximized")), None),
                    "restore failed",
                )
                ipc.wait_for_frame()
                debug = ipc.get_window_debug(win["id"])
                assert debug["edge_sample"] == "color", debug

                ipc.key_down_up(KEY_F5)
                wait_for(
                    lambda: ipc.get_window_debug(win["id"])["decoration_mode"] == "client",
                    "CSD switch failed",
                )
                csd = ipc.get_window_debug(win["id"])
                assert csd["decoration_mode"] == "client", csd
                ipc.key_down_up(KEY_F6)
                wait_for(
                    lambda: ipc.get_window_debug(win["id"])["decoration_mode"] == "server",
                    "SSD switch failed",
                )
                ssd = ipc.get_window_debug(win["id"])
                assert ssd["decoration_mode"] == "server", ssd
                assert ssd["edge_sample"] == "color", ssd

                ipc.action("close_window", {"id": win["id"]})
                wait_for(lambda: not ipc.get_windows(), "client did not close")
                ipc.reset_perf()
                with client_log.open("a") as clog:
                    client2 = subprocess.Popen(
                        [str(tmp / "client")],
                        env=dict(env, WAYLAND_DISPLAY=display),
                        stdout=clog,
                        stderr=clog,
                    )
                try:
                    remapped = wait_for(
                        lambda: next((w for w in ipc.get_windows() if w.get("app_id") == "rediwm.zoom-fixture"), None),
                        "second map failed",
                    )
                    ipc.wait_for_frame()
                    debug = ipc.get_window_debug(remapped["id"])
                    assert debug["edge_sample"] == "color", debug
                    approx_rgba(debug["skirt_fill"], (0.0, 0.0, 1.0, 1.0))
                    mapped = ipc.get_perf()
                    assert mapped["edge_samples_attempted"] >= 1, mapped
                finally:
                    if client2.poll() is None:
                        client2.terminate()
                        client2.wait(timeout=3)

                print(f"PASS: edge sampling ({renderer})")
        except Exception:
            for path in tmp.glob("*.log"):
                print(path.name, path.read_text()[-4000:])
            raise
        finally:
            for process in (client, compositor):
                if process is not None and process.poll() is None:
                    process.terminate()
                    process.wait(timeout=3)


if __name__ == "__main__":
    run()

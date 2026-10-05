#!/usr/bin/env python3
"""xdg-output wire metadata checked against an isolated compositor's IPC layout."""
import argparse
import json
import math
import os
from pathlib import Path
import re
import subprocess
import tempfile

from desktop_zoom import ROOT, wait_for
from ipc_client import IPCClient, spawn_compositor, stop_process


def build_client(tmp):
    protocols = Path(subprocess.check_output(
        ["pkg-config", "--variable=pkgdatadir", "wayland-protocols"], text=True).strip())
    xml = protocols / "unstable/xdg-output/xdg-output-unstable-v1.xml"
    for mode, name in (("client-header", "xdg-output-client-protocol.h"),
                       ("private-code", "xdg-output-protocol.c")):
        subprocess.run(["wayland-scanner", mode, str(xml), str(tmp / name)], check=True)
    subprocess.run(["cc", "-Wall", "-Wextra", "-Werror", f"-I{tmp}",
                    str(ROOT / "tests/xdg_output_client.c"), str(tmp / "xdg-output-protocol.c"),
                    "-lwayland-client", "-o", str(tmp / "client")], check=True)


def run_case(binary, scale, count, placements="", xwayland=False):
    with tempfile.TemporaryDirectory(prefix="rediwm-xdg-output-") as directory:
        tmp = Path(directory)
        config = f"[compositor]\nxwayland = {'true' if xwayland else 'false'}\n" + placements
        compositor, log = spawn_compositor(
            tmp, scale=str(scale), outputs=str(count), config_content=config,
            env_extra={"XDG_CACHE_HOME": str(tmp / "cache")})
        live = None
        try:
            socket_path = wait_for(lambda: next(tmp.glob("rediwm-*.sock"), None), "IPC unavailable")
            display = next(p.name for p in tmp.glob("wayland-*") if not p.name.endswith(".lock"))
            env = dict(os.environ, XDG_RUNTIME_DIR=str(tmp), WAYLAND_DISPLAY=display)
            with IPCClient(socket_path) as ipc:
                expected = wait_for(lambda: ipc.get_outputs() if len(ipc.get_outputs()) == count else None,
                                    "outputs did not appear")
                by_name = {o["name"]: o for o in expected}

                def read(version, core_version=4):
                    result = subprocess.run([str(binary), str(version), str(core_version)],
                                            env=env, capture_output=True, text=True, timeout=10)
                    assert result.returncode == 0, result.stdout + result.stderr
                    records = [json.loads(line) for line in result.stdout.splitlines()]
                    assert {o["name"] for o in records} == set(by_name), records
                    for o in records:
                        wanted = by_name[o["name"]]
                        assert (o["x"], o["y"], o["width"], o["height"]) == (
                            wanted["x"], wanted["y"], wanted["logical_width"], wanted["logical_height"]), (o, wanted)
                        assert (o["mode_width"], o["mode_height"]) == (
                            wanted["buffer_width"], wanted["buffer_height"]), (o, wanted)
                        assert o["scale"] == math.ceil(wanted["scale"]), (o, wanted)
                        # Headless mode is enlarged at startup, preserving 1280×720
                        # logical pixels. The taskbar's exclusion must not shrink it.
                        assert (o["width"], o["height"]) == (1280, 720), o
                        if scale == 1.5:
                            assert o["width"] != o["mode_width"] / o["scale"], o
                    return sorted(records, key=lambda o: o["name"])

                for version in (1, 2, 3):
                    read(version)
                read(3, 2)  # v3 completion on wl_output v2, before core name events.
                baseline = read(3)
                ipc.action("set_zoom", {"percent": 70})
                ipc.action("set_camera", {"x": 120, "y": 60})
                assert read(3) == baseline, "camera pan/zoom changed monitor metadata"
                ipc.action("reset_camera")

                if placements:
                    second = by_name["HEADLESS-2"]
                    assert (second["x"], second["y"]) == (-1280, -120), second
                elif count == 2:
                    assert sorted(o["x"] for o in expected) == [0, 1280], expected

                if xwayland:
                    owned_display = ipc.get_runtime()["xwayland_display"]
                    assert owned_display
                    # This display belongs to this test compositor. Never use host DISPLAY.
                    result = subprocess.run(["xrandr", "-display", owned_display, "--query"],
                                            env=dict(env, DISPLAY=owned_display),
                                            capture_output=True, text=True, timeout=15)
                    assert result.returncode == 0, result.stderr
                    rectangles = [tuple(map(int, m)) for m in re.findall(
                        r" connected[^\n]*? (\d+)x(\d+)\+(-?\d+)\+(-?\d+)", result.stdout)]
                    wanted = sorted((o["logical_width"], o["logical_height"], o["x"], o["y"]) for o in expected)
                    assert sorted(rectangles) == wanted, result.stdout
                    print("xdg-output: Xwayland RandR reports the real side-by-side monitor layout")

                with (tmp / "live-client.log").open("w") as client_log:
                    live = subprocess.Popen([str(binary), "3", "4", "live"], env=env,
                                            stdout=client_log, stderr=client_log)
                wait_for(lambda: "ready\n" in (tmp / "live-client.log").read_text(), "live client not ready")
                for keycode in (125, 42):
                    ipc.action("key", {"keycode": keycode, "pressed": True})
                try:
                    ipc.action("key", {"keycode": 18, "pressed": True})
                except EOFError:
                    pass
            compositor.wait(timeout=10)
            assert compositor.returncode == 0, (tmp / "compositor.log").read_text()
            live.wait(timeout=5)
            assert live.returncode == 0
            print(f"xdg-output: versions, geometry, completion and lifecycle passed ({count} outputs, {scale:g}x)")
        except Exception:
            print((tmp / "compositor.log").read_text()[-6000:])
            raise
        finally:
            if live and live.poll() is None:
                stop_process(live)
            if compositor.poll() is None:
                stop_process(compositor)
            log.close()


def run(xwayland=False):
    with tempfile.TemporaryDirectory(prefix="rediwm-xdg-output-build-") as directory:
        tmp = Path(directory)
        build_client(tmp)
        run_case(tmp / "client", 1, 1)
        run_case(tmp / "client", 1.5, 2)
        run_case(tmp / "client", 2, 2, placements=(
            '\n[[outputs]]\nname = "HEADLESS-1"\nx = 0\ny = 0\n'
            '\n[[outputs]]\nname = "HEADLESS-2"\nx = -1280\ny = -120\n'))
        if xwayland:
            run_case(tmp / "client", 1, 2, xwayland=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--xwayland", action="store_true", help="also check owned Xwayland RandR (needs Xwayland and xrandr)")
    run(parser.parse_args().xwayland)

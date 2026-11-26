#!/usr/bin/env python3
"""Layer clients survive screen blanking; disconnect leaves no stale entries."""
import os
from pathlib import Path
import subprocess
import tempfile

from desktop_zoom import ROOT, build_client, wait_for
from ipc_client import IPCClient, spawn_compositor, stop_process


def build_layer_client(tmp):
    """A minimal real wlr-layer-shell client (tests/layer_client.c)."""
    protocol = ROOT / "protocol/wlr-layer-shell-unstable-v1.xml"
    xdg_dir = subprocess.check_output(["pkg-config", "--variable=pkgdatadir", "wayland-protocols"], text=True).strip()
    xdg = Path(xdg_dir) / "stable/xdg-shell/xdg-shell.xml"
    # Layer-shell popups refer to xdg_popup, so its interface must link too.
    for xml, stem in ((protocol, "wlr-layer-shell-unstable-v1"), (xdg, "xdg-shell")):
        subprocess.run(["wayland-scanner", "client-header", str(xml), str(tmp / f"{stem}-client-protocol.h")], check=True)
        subprocess.run(["wayland-scanner", "private-code", str(xml), str(tmp / f"{stem}-protocol.c")], check=True)
    subprocess.run(["cc", "-Wall", "-Wextra", f"-I{tmp}", str(ROOT / "tests/layer_client.c"),
                    str(tmp / "wlr-layer-shell-unstable-v1-protocol.c"), str(tmp / "xdg-shell-protocol.c"),
                    "-lwayland-client", "-o", str(tmp / "layer-client")], check=True)
    return tmp / "layer-client"


def check_exclusive_zones(tmp, ipc, env, layer_client):
    build_client(tmp)
    windows = {}
    children = []

    def frame(window_id):
        box = ipc.get_window_debug(window_id)["chrome_box"]
        return box["x"], box["y"], box["width"], box["height"]

    def panel(version):
        proc = subprocess.Popen([str(layer_client), str(version)], env=env, stdin=subprocess.PIPE, text=True)
        children.append(proc)
        return proc

    try:
        for index, output in enumerate(ipc.get_outputs()):
            app_id = "layer.window." + output["name"]
            # A v6 and a v7 client share the compositor through the same layout changes.
            child_env = dict(env, REDIWM_TEST_XDG_VERSION=str(6 + index))
            log = tmp / f"window-{index}.log"
            with log.open("w") as out:
                children.append(subprocess.Popen([str(tmp / "client"), "--app-id", app_id], env=child_env, stdout=out))
            window = wait_for(lambda: next((w for w in ipc.get_windows() if w["app_id"] == app_id), None), "window map")
            window_id = window["id"]
            ipc.action("move_window_to", {"id": window_id, "x": output["x"] + 40, "y": output["y"] + 40})
            ipc.wait_for("window_geometry_settled", window_id=window_id)
            ipc.action("maximize_window", {"id": window_id})
            wait_for(lambda: frame(window_id)[0] == output["x"] and frame(window_id)[2] == output["logical_width"],
                     "maximize on selected output")
            ipc.wait_for("window_geometry_settled", window_id=window_id)
            windows[output["name"]] = (window_id, frame(window_id))
            if index == 0:
                hints = {line for line in log.read_text().splitlines() if line.startswith("constrained")}
                assert hints == {"constrained"}, ("v6 resize hints", hints)

        corner = panel(5)
        mapped = wait_for(lambda: next((s for s in ipc.get_layer_surfaces() if s["mapped"]), None), "corner panel map")
        affected = mapped["output"]
        window_id, (x, y, w, h) = windows[affected]

        def expect(left=0, top=0):
            target = (x + left, y + top, w - left, h - top)
            wait_for(lambda: frame(window_id) == target, f"panel reservation {target}")
            for name, (other_id, original) in windows.items():
                if name != affected:
                    assert frame(other_id) == original, "panel changed another output"

        def command(value):
            corner.stdin.write(value + "\n")
            corner.stdin.flush()

        expect(top=43)
        legacy = panel(4)
        expect(top=86)
        command("left")
        expect(left=45, top=43)
        command("unmap")
        expect(top=43)
        command("left")
        expect(left=45, top=43)
        stop_process(legacy)
        expect(left=45)
        stop_process(corner)
        expect()
        print("layer-shell: explicit and inferred edges, stacking, unmap, remap and output isolation")
    finally:
        for child in children:
            if child.poll() is None:
                stop_process(child)


def run():
    with tempfile.TemporaryDirectory(prefix="rediwm-layer-lifecycle-") as directory:
        tmp = Path(directory)
        layer_client = build_layer_client(tmp)
        compositor, log = spawn_compositor(
            tmp, outputs="2", scale=os.environ.get("REDIWM_TEST_SCALE", "1"),
            config_content="[compositor]\nxwayland = false\n[animations]\nenabled = false\n",
            env_extra={"XDG_CACHE_HOME": str(tmp / "cache"),
                       "XDG_DATA_HOME": str(tmp / "data"),
                       "DBUS_SESSION_BUS_ADDRESS": "unix:path=" + str(tmp / "missing-bus"),
                       "PULSE_SERVER": "unix:" + str(tmp / "missing-pulse"),
                       "PIPEWIRE_RUNTIME_DIR": str(tmp)})
        client = None
        try:
            with IPCClient(tmp) as ipc:
                display = next(p.name for p in tmp.glob("wayland-*")
                               if not p.name.endswith(".lock"))
                env = dict(os.environ, XDG_RUNTIME_DIR=str(tmp), WAYLAND_DISPLAY=display)
                for _ in range(3):
                    client = subprocess.Popen([str(layer_client)],
                                              env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    wait_for(lambda: ipc.query('get_layer_surfaces')["surfaces"], "layer client did not appear")
                    stop_process(client)
                    client = None
                    wait_for(lambda: not ipc.query('get_layer_surfaces')["surfaces"], "destroyed layer still listed")
                    assert compositor.poll() is None
                print("layer lifecycle: disconnect/recreate leaves no stale layer entries")
                check_exclusive_zones(tmp, ipc, env, layer_client)

                # A disabled monitor must not be chosen over an enabled but
                # sleeping one when the client leaves output selection to us.
                disabled, active = ipc.get_outputs()
                ipc.action('set_output_config', {"output": disabled["name"], "enabled": False})
                active = next(o for o in ipc.get_outputs() if o["name"] == active["name"])
                ipc.action('set_idle_config', {"enabled": True, "blank_after_seconds": 10,
                                               "suspend_after_seconds": 0})
                ipc.action('advance_idle_time', {"seconds": 15})
                wait_for(lambda: all(not o["enabled"] for o in ipc.get_outputs()), "outputs did not blank")

                client = subprocess.Popen([str(layer_client)], env=env,
                                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

                def mapped_layer():
                    assert client.poll() is None, "layer client was closed while the display was asleep"
                    return next((s for s in ipc.get_layer_surfaces() if s["mapped"]), None)

                layer = wait_for(mapped_layer, "layer did not map while display was asleep")
                expected_box = {"x": active["x"], "y": active["y"],
                                "width": active["logical_width"], "height": active["logical_height"]}
                assert layer["output"] == active["name"], layer
                assert layer["box"] == expected_box, (layer, expected_box)
                assert all(not o["enabled"] for o in ipc.get_outputs()), "layer woke a display"
                assert ipc.query('get_idle_state')["state"] == "blanked"

                ipc.action('key', {"keycode": 30, "pressed": True})
                ipc.action('key', {"keycode": 30, "pressed": False})
                wait_for(lambda: next(o for o in ipc.get_outputs() if o["name"] == active["name"])["enabled"],
                         "display did not wake")
                assert not next(o for o in ipc.get_outputs() if o["name"] == disabled["name"])["enabled"]
                assert mapped_layer()["box"] == expected_box
                stop_process(client)
                client = None
                wait_for(lambda: not ipc.get_layer_surfaces(), "woken layer left a stale entry")
                assert compositor.poll() is None
                print("layer lifecycle: maps while asleep at saved size, stays dark, survives wake")
        except Exception:
            log.flush()
            print((tmp / "compositor.log").read_text())
            raise
        finally:
            if client is not None:
                stop_process(client)
            stop_process(compositor)
            log.close()


if __name__ == "__main__":
    run()

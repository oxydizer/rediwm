#!/usr/bin/env python3
"""Monitors that drop out and come back, as on a wake from sleep, keep their
places in the layout and take their windows home: each window returns to the
output it was on before the first of them dropped, at the same place, even when
several outputs (or all of them) drop before any comes back.

`python3 tests/output_reconnect.py [case index ...]` runs the chosen cases."""
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile

from desktop_zoom import ROOT, build_client, wait_for
from ipc_client import IPCClient, spawn_compositor, stop_process


def outputs(ipc):
    return {o["name"]: o for o in ipc.get_outputs()}


def placement(ipc, window_id):
    """(output name, frame offset in it, maximized) of a window."""
    box = ipc.get_window_debug(window_id)["chrome_box"]
    maximized = next(w for w in ipc.get_windows() if w["id"] == window_id).get("maximized", False)
    for name, out in outputs(ipc).items():
        if out["x"] <= box["x"] < out["x"] + out["logical_width"] and out["y"] <= box["y"] < out["y"] + out["logical_height"]:
            return name, (box["x"] - out["x"], box["y"] - out["y"]), maximized
    return None, (box["x"], box["y"]), maximized


def hotplug(command_file, command):
    # Renamed into place: the hook must never read a half-written file.
    staged = command_file.with_suffix(".new")
    staged.write_text(command + "\n")
    os.replace(staged, command_file)
    wait_for(lambda: not command_file.exists(), "hook ran " + command)


def hotplug_environment(tmp):
    flags = shlex.split(subprocess.check_output(
        ["pkg-config", "--cflags", "--libs", "wlroots-0.20", "wayland-server"], text=True))
    hook = tmp / "hotplug.so"
    subprocess.run(["cc", "-shared", "-fPIC", "-Wall", "-Wextra", "-Werror",
                    str(ROOT / "tests/output_reconnect_hook.c"), "-o", str(hook), *flags, "-ldl"], check=True)
    return {"LD_PRELOAD": str(hook), "REDIWM_TEST_HOTPLUG": str(tmp / "hotplug")}


def run_case(name, output_count, homes, drops, returns, maximize=(), primary=None):
    with tempfile.TemporaryDirectory(prefix="rediwm-output-reconnect-") as directory:
        tmp = Path(directory)
        build_client(tmp)
        commands = tmp / "hotplug"
        config = "[compositor]\nxwayland = false\n"
        if primary:
            config += f'[[outputs]]\nname = "{primary}"\nprimary = true\n'
        compositor, log = spawn_compositor(
            tmp, outputs=str(output_count), config_content=config,
            env_extra={**hotplug_environment(tmp),
                       "XDG_CACHE_HOME": str(tmp / "cache")})
        clients = []
        try:
            with IPCClient(tmp) as ipc:
                wait_for(lambda: len(ipc.get_outputs()) == output_count, "outputs missing")
                display = next(p.name for p in tmp.glob("wayland-*") if not p.name.endswith(".lock"))
                ipc.action("set_camera", {"x": 0, "y": 0})
                windows = []
                for index, home in enumerate(homes):
                    ipc.move_cursor(200 + 40 * index, 150 + 30 * index, output=home)
                    app_id = f"reconnect-{index}"
                    clients.append(subprocess.Popen(
                        [str(tmp / "client"), "--app-id", app_id],
                        env=dict(os.environ, XDG_RUNTIME_DIR=str(tmp), WAYLAND_DISPLAY=display),
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
                    window = wait_for(lambda: next((w for w in ipc.get_windows() if w["app_id"] == app_id), None), app_id + " maps")
                    windows.append(window["id"])
                    if index in maximize:
                        ipc.maximize(window["id"])
                    ipc.wait_for("window_geometry_settled", window_id=window["id"])
                layout = {n: (o["x"], o["y"]) for n, o in outputs(ipc).items()}
                before = [placement(ipc, wid) for wid in windows]
                for index, home in enumerate(homes):
                    assert before[index][0] == home, (index, before[index], layout)

                for output in drops:
                    hotplug(commands, "unplug " + output)
                    wait_for(lambda: output not in outputs(ipc), output + " unplugged")
                assert compositor.poll() is None, "compositor died while outputs dropped"
                for output in returns:
                    hotplug(commands, "replug " + output)
                    wait_for(lambda: output in outputs(ipc), output + " replugged")
                assert compositor.poll() is None, "compositor died while outputs returned"
                for wid in windows:
                    ipc.wait_for("window_geometry_settled", window_id=wid)

                after_layout = {n: (o["x"], o["y"]) for n, o in outputs(ipc).items()}
                assert after_layout == layout, f"{name}: layout changed: {layout} -> {after_layout}"
                after = [placement(ipc, wid) for wid in windows]
                wrong = {i: (before[i], after[i]) for i in range(len(windows)) if after[i] != before[i]}
                boxes = [ipc.get_window_debug(wid)["chrome_box"] for wid in windows]
                assert not wrong, f"{name}: windows not back home (index: (before, after)): {wrong}; layout {after_layout}; frames {boxes}"
                assert all(c.poll() is None for c in clients), "a client exited"
                print("PASS: " + name)
        except Exception:
            log.flush()
            print((tmp / "compositor.log").read_text()[-6000:])
            raise
        finally:
            for client in clients:
                stop_process(client)
            stop_process(compositor)
            log.close()


CASES = [
    # The left of two monitors drops and comes back; the other must not take
    # its place, nor its windows end up on the returning one.
    ("first of two drops", 2, ["HEADLESS-1", "HEADLESS-2"], dict(drops=["HEADLESS-2"], returns=["HEADLESS-2"])),
    ("second of two drops", 2, ["HEADLESS-1", "HEADLESS-2"], dict(drops=["HEADLESS-1"], returns=["HEADLESS-1"])),
    # A laptop panel and two monitors. Windows of the first monitor to drop
    # go to the main display, the second, which then drops too; they come
    # back in the other order.
    ("two of three drop", 3, ["HEADLESS-1", "HEADLESS-2", "HEADLESS-3"],
     dict(drops=["HEADLESS-1", "HEADLESS-2"], returns=["HEADLESS-2", "HEADLESS-1"], maximize=(1,), primary="HEADLESS-2")),
    # A desktop whose every monitor drops before any comes back.
    ("every output drops", 2, ["HEADLESS-1", "HEADLESS-2"],
     dict(drops=["HEADLESS-1", "HEADLESS-2"], returns=["HEADLESS-1", "HEADLESS-2"], maximize=(0,))),
]


def run(selected=None):
    for index, (name, count, homes, options) in enumerate(CASES):
        if selected is None or index in selected:
            run_case(name, count, homes, **options)


if __name__ == "__main__":
    run({int(a) for a in sys.argv[1:]} or None)

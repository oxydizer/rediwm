#!/usr/bin/env python3
"""System Monitor input, disposable process actions and worker lifetime.

Every signal target is a child created here, selected by a unique comm value.
Compositors, themes, state and application databases stay in a private session.
"""
import os
from pathlib import Path
import signal
import shutil
import subprocess
import sys
import tempfile
import time

from PIL import Image, ImageChops
from files_browser import wait_for
from ipc_client import IPCClient, ROOT, spawn_compositor, stop_process


def switches(pid):
    total = 0
    for status in Path(f"/proc/{pid}/task").glob("*/status"):
        try:
            for line in status.read_text().splitlines():
                if line.startswith(("voluntary_ctxt_switches:", "nonvoluntary_ctxt_switches:")):
                    total += int(line.split()[1])
        except FileNotFoundError:
            pass
    return total


def check_signal_guard(tmp, guard, targets):
    """Prove the guard with two disposable children, before using the UI."""
    probe_dir = tmp / "guard-probe"
    probe_dir.mkdir()
    source = probe_dir / "probe.c"
    source.write_text('''#define _GNU_SOURCE
#include <errno.h>
#include <signal.h>
#include <stdlib.h>
#include <sys/syscall.h>
#include <unistd.h>
int main(int argc, char **argv) {
    if (argc != 3) return 1;
    int denied = syscall(SYS_pidfd_open, atoi(argv[2]), 0);
    int allowed = syscall(SYS_pidfd_open, atoi(argv[1]), 0);
    if (denied < 0 || allowed < 0) return 2;
    if (syscall(SYS_pidfd_send_signal, denied, SIGTERM, 0, 0) != -1 || errno != EPERM) return 3;
    if (syscall(SYS_pidfd_send_signal, allowed, SIGTERM, 0, 0) != 0) return 4;
    close(denied); close(allowed);
    return 0;
}
''')
    binary = probe_dir / "rediwm-monitor"
    subprocess.run(["cc", "-Wall", "-Wextra", "-Werror", str(source), "-o", str(binary)], check=True)
    allowed = subprocess.Popen(["/bin/sleep", "120"])
    denied = subprocess.Popen(["/bin/sleep", "120"])
    try:
        start = Path(f"/proc/{allowed.pid}/stat").read_text().rsplit(")", 1)[1].split()[19]
        targets.write_text(f"{os.getpid()}\n{allowed.pid} {start}\n")
        subprocess.run([str(binary), str(allowed.pid), str(denied.pid)], check=True, timeout=10,
                       env=dict(os.environ, LD_PRELOAD=str(guard), REDIWM_TEST_MONITOR_TARGETS=str(targets)))
        assert allowed.wait(timeout=5) == -signal.SIGTERM
        assert denied.poll() is None, "signal guard did not protect the unlisted fixture"
    finally:
        for child in (allowed, denied):
            if child.poll() is None:
                child.kill()
            child.wait(timeout=5)
        targets.write_text(f"{os.getpid()}\n")


def run(scale, workspace):
    with tempfile.TemporaryDirectory(prefix="rediwm-monitor-") as directory:
        tmp = Path(directory)
        config = ('[compositor]\nxwayland = false\n'
                  'taskbar_items = ["battery", "volume", "wifi", "clock"]\n' +
                  ('desktop_mode = "workspaces"\n' if workspace else '') +
                  '[theme]\napp_bg = "#203040"\napp_item_hover = "#4a6076"\n'
                  'app_item_selected = "#62768a"\n')
        env = {"HOME": directory, "XDG_CONFIG_HOME": str(tmp / "config"),
               "XDG_DATA_HOME": str(tmp / "data"), "XDG_CACHE_HOME": str(tmp / "cache"),
               "DBUS_SESSION_BUS_ADDRESS": "", "REDIWM_FILES_DEVICES": "0"}
        guard = tmp / "monitor-guard.so"
        subprocess.run(["cc", "-shared", "-fPIC", "-Wall", "-Wextra", "-Werror", "-pthread",
                        str(ROOT / "tests/system_monitor_guard.c"), "-o", str(guard)], check=True)
        targets = tmp / "signal-targets"
        targets.write_text(f"{os.getpid()}\n")
        check_signal_guard(tmp, guard, targets)
        env.update(LD_PRELOAD=str(guard), REDIWM_TEST_MONITOR_TARGETS=str(targets))
        subprocess.run(["cc", "-shared", "-fPIC", "-Wall", "-Wextra", "-Werror",
                        str(ROOT / "tests/system_monitor_gpu.c"), "-o", str(tmp / "libnvidia-ml.so.1")], check=True)
        gpu_state, gpu_trace = tmp / "gpu-state", tmp / "gpu-trace"
        gpu_state.write_text("74\n")
        env.update(LD_LIBRARY_PATH=str(tmp), REDIWM_TEST_GPU_STATE=str(gpu_state),
                   REDIWM_TEST_GPU_TRACE=str(gpu_trace))
        compositor, log = spawn_compositor(tmp, scale=str(scale), config_content=config, env_extra=env,
                                          binary=os.environ.get("REDIWM_TEST_BINARY"))
        fixtures = []
        monitor_pid = None
        try:
            with IPCClient(tmp, timeout=20) as ipc:
                def windows():
                    return [w for w in ipc.get_windows() if w["app_id"] == "rediwm-monitor"]

                def monitor():
                    return next(iter(windows()), None)

                def chord(*codes):
                    for code in codes:
                        ipc.key(code, True)
                    for code in reversed(codes):
                        ipc.key(code, False)

                def settled():
                    ipc.wait_for("window_geometry_settled", window_id=monitor()["id"])
                    ipc.wait_for_frame()

                def box():
                    return ipc.get_window_debug(monitor()["id"])["client_box"]

                def click(x, y):
                    b = box()
                    ipc.click_at(round(b["x"] + x), round(b["y"] + y))

                def shot(name, graph=False):
                    path = tmp / f"{name}.png"
                    ipc.wait_for_frame()
                    ipc.screenshot(path=str(path))
                    with Image.open(path) as image:
                        b = box()
                        output = ipc.get_outputs()[0]
                        factor = image.width / output["logical_width"]
                        region = ((b["x"] + 16, b["y"] + 14, b["x"] + b["width"] - 16, b["y"] + 136)
                                  if graph else (b["x"], b["y"], b["x"] + b["width"], b["y"] + b["height"]))
                        result = image.convert("RGB").crop(tuple(round(v * factor) for v in region))
                        if artifacts := os.environ.get("REDIWM_TEST_ARTIFACT_DIR"):
                            destination = Path(artifacts)
                            destination.mkdir(parents=True, exist_ok=True)
                            result.save(destination / f"monitor-{scale}-{'workspaces' if workspace else 'canvas'}-{name}.png")
                        return result

                def idle(label):
                    time.sleep(.4)  # finish pending buffer release and hover transitions
                    before = switches(monitor_pid)
                    time.sleep(2.2)
                    delta = switches(monitor_pid) - before
                    assert delta <= 2, f"{label}: monitor kept waking ({delta} context switches)"

                def taskbar_popup(name, target):
                    bar = ipc.get_shell_state()["taskbars"][0]
                    anchor = next(item["box"] for item in bar["right_items"] if item["name"] == name)
                    x = anchor["x"] + anchor["width"] // 2
                    ipc.click_at(x, anchor["y"] + anchor["height"] // 2)
                    point = x, bar["box"]["y"] - 40
                    assert ipc.hit_test(*point)["target_type"] == target
                    return point

                wifi_point = taskbar_popup("wifi", "wifi_popup")
                for _ in range(3):
                    chord(29, 56, 111)  # Ctrl+Alt+Delete, including activation while starting
                ipc.wait_for("window_mapped", app_id="rediwm-monitor", timeout_ms=15000)
                settled()
                assert len(windows()) == 1, windows()
                window_id = monitor()["id"]
                monitor_pid = monitor()["pid"]
                assert ipc.hit_test(*wifi_point)["target_type"] != "wifi_popup"
                assert ipc.get_input_state()["keyboard_focused_window_id"] == window_id

                # Every transient owner yields to the monitor binding, including
                # restoration while a popup has consumed the keyboard.
                for name, target in (("wifi", "wifi_popup"), ("clock", "calendar")):
                    ipc.minimize(window_id)
                    point = taskbar_popup(name, target)
                    chord(29, 56, 111)
                    wait_for(lambda: not monitor()["is_minimized"], f"{target} blocked restore")
                    assert ipc.hit_test(*point)["target_type"] != target
                    assert ipc.get_input_state()["keyboard_focused_window_id"] == window_id
                for panel, opener in (("start_menu", ipc.open_start_menu), ("power_menu", ipc.open_power_menu)):
                    opener()
                    ipc.wait_for(panel + "_opened")
                    chord(29, 56, 111)
                    ipc.wait_for(panel + "_closed")
                    assert ipc.get_input_state()["keyboard_focused_window_id"] == window_id

                ipc.open_control_center()
                # The switcher stays open only while Alt is held.
                ipc.key(56, True)
                ipc.key_down_up(15)
                chord(29, 111)
                ipc.key(56, False)  # Must not accept the switcher's old selection.
                assert ipc.get_input_state()["keyboard_focused_window_id"] == window_id
                chord(29, 42, 31)  # Ctrl+Shift+S: region screenshot selection.
                chord(29, 56, 111)
                assert ipc.get_input_state()["keyboard_focused_window_id"] == window_id
                assert len(windows()) == 1 and monitor()["id"] == window_id
                settings = next(w for w in ipc.get_windows() if w["backend"] == "shell")
                ipc.close_window(settings["id"])
                ipc.wait_for("window_closed", window_id=settings["id"])
                settled()
                time.sleep(1.2)
                debug = ipc.get_window_debug(window_id)
                assert debug["buffer_scale"] == 1, debug
                assert abs(debug["buffer_width"] - round(debug["client_box"]["width"] * scale)) <= 1, debug
                assert shot("initial").getpixel((4, 4)) == (32, 48, 64)
                assert "temperature" in gpu_trace.read_text().splitlines(), "GPU telemetry was not sampled"

                # A card expands to the full width over the gap between the two;
                # clicking its body, its collapse button or Escape brings both back.
                def gap_pixel(name):
                    image = shot(name)
                    factor = image.width / box()["width"]
                    return image.getpixel((round(box()["width"] / 2 * factor), round(75 * factor)))
                assert gap_pixel("cards") == (32, 48, 64)
                for name, card_x in (("cpu", 120), ("ram", box()["width"] - 120)):
                    for dismiss in ("pane", "button", "escape"):
                        click(card_x, 75)
                        time.sleep(1)
                        assert gap_pixel(f"{name}-expanded-{dismiss}") != (32, 48, 64), f"{name} card did not expand"
                        if dismiss == "pane":
                            click(box()["width"] / 2, 75)
                        elif dismiss == "button":
                            click(box()["width"] - 42, 38)
                        else:
                            chord(1)
                        time.sleep(1)
                        assert gap_pixel(f"{name}-collapsed-{dismiss}") == (32, 48, 64), f"{name} card did not collapse via {dismiss}"

                # Background collection follows visibility, independently of keyboard focus.
                ipc.open_control_center()
                before = switches(monitor_pid)
                time.sleep(2.2)
                assert switches(monitor_pid) - before >= 3, "collection stopped on focus loss"
                settings = next(w for w in ipc.get_windows() if w["backend"] == "shell")
                ipc.close_window(settings["id"])
                ipc.wait_for("window_closed", window_id=settings["id"])
                ipc.focus_window(window_id)
                settled()

                # Pause has no recurring worker or theme-stat timer.
                click(box()["width"] - 80, 171)
                idle("paused")
                assert gpu_trace.read_text().splitlines()[-1] == "shutdown", "paused monitor retained NVIDIA telemetry"
                paused = shot("paused", True)
                time.sleep(1.2)
                assert ImageChops.difference(paused, shot("still-paused", True)).getbbox() is None

                # Files' rounded hover and selection fills, with no idle timer.
                def move(x, y):
                    b = box()
                    ipc.move_cursor(round(b["x"] + x), round(b["y"] + y))

                def row_pixel(name, y):
                    image = shot(name)
                    factor = image.width / box()["width"]
                    return image.getpixel((round(20 * factor), round(y * factor)))

                assert row_pixel("row-idle", 252) == (32, 48, 64)
                assert row_pixel("row-stripe", 284) == (34, 40, 46)
                move(40, 252)
                time.sleep(.6)
                assert row_pixel("row-hover", 252) == (74, 96, 118)
                idle("hover settled")
                move(40, 284)
                time.sleep(.6)
                assert row_pixel("row-glide", 284) == (74, 96, 118)
                assert row_pixel("row-glide-old", 252) == (32, 48, 64)
                click(40, 284)
                time.sleep(.6)
                assert row_pixel("row-selected", 284) == (98, 118, 138)
                # Leaving the surface fades hover away without dropping selection.
                move(40, 316)
                time.sleep(.6)
                ipc.move_cursor(0, 0)
                time.sleep(.6)
                assert row_pixel("row-left", 316) == (32, 48, 64)
                assert row_pixel("row-selection-kept", 284) == (98, 118, 138)
                idle("row feedback settled")

                # Atomic theme replacement still wakes a paused app.
                changed = tmp / "theme-new.toml"
                changed.write_text(config.replace("#203040", "#304050"))
                changed.replace(tmp / "rediwm-config.toml")
                wait_for(lambda: shot("theme").getpixel((4, 4)) == (48, 64, 80), "live app theme did not update")
                click(box()["width"] - 80, 171)
                time.sleep(1.2)
                assert gpu_trace.read_text().splitlines()[-1] == "temperature", "resumed monitor did not restart GPU telemetry"
                gpu_state.write_text("-1\n")
                wait_for(lambda: gpu_trace.read_text().splitlines()[-1] == "unavailable", "GPU loss was not handled")
                shot("gpu-unavailable")
                gpu_state.write_text("74\n")

                # Minimize is a real xdg-shell v6 suspended configure. Restore
                # starts a fresh interval and repeated activation keeps this ID.
                ipc.minimize(window_id)
                idle("minimized")
                for _ in range(2):
                    chord(29, 56, 111)
                wait_for(lambda: monitor() and not monitor()["is_minimized"], "shortcut did not restore monitor")
                settled()
                assert len(windows()) == 1 and monitor()["id"] == window_id
                before = switches(monitor_pid)
                time.sleep(2.2)
                assert switches(monitor_pid) - before >= 3, "restored monitor did not resume"
                if workspace:
                    ipc.action("switch_workspace", {"workspace": 9})
                    chord(29, 56, 111)
                    ipc.wait_for("window_focused", window_id=window_id)
                    assert monitor()["id"] == window_id and len(windows()) == 1

                # Resize through maximize and return; the controls remain usable.
                original = box()
                ipc.maximize(window_id)
                wait_for(lambda: box()["width"] > original["width"], "monitor did not maximize")
                settled()
                assert box()["width"] > 640
                shot("footer-wide")
                ipc.restore(window_id)
                wait_for(lambda: box()["width"] == original["width"], "monitor did not restore its width")
                settled()
                ipc.action("set_window_size", {"id": window_id, "width": 640, "height": 480})
                wait_for(lambda: box()["width"] == 640, "monitor did not resize to its minimum width")
                settled()
                shot("footer-narrow")
                ipc.action("set_window_size", {"id": window_id, "width": original["width"], "height": original["height"]})
                wait_for(lambda: box()["width"] == original["width"], "monitor did not restore after narrow layout")
                settled()

                def fixture(ignore_term, replace_with=None):
                    name = f"rmon{os.getpid()}-{len(fixtures)}"[:15]
                    program = ('import ctypes,signal,time,sys;'
                               f'ctypes.CDLL(None).prctl(15,{name.encode()!r},0,0,0);' +
                               ('signal.signal(signal.SIGTERM,signal.SIG_IGN);' if ignore_term else '') +
                               'print("ready",flush=True);' +
                               ('sys.stdin.readline();import os;os.execv(sys.argv[1],["rediwm","120"])'
                                if replace_with else 'time.sleep(120)'))
                    argv = [sys.executable, "-c", program]
                    if replace_with:
                        argv.append(str(replace_with))
                    child = subprocess.Popen(argv, stdout=subprocess.PIPE, stdin=subprocess.PIPE, text=True)
                    fixtures.append(child)
                    assert child.stdout.readline().strip() == "ready"
                    stat = Path(f"/proc/{child.pid}/stat").read_text().rsplit(")", 1)[1].split()
                    with targets.open("a") as allowed:
                        allowed.write(f"{child.pid} {stat[19]}\n")
                    time.sleep(1.2)  # next collector snapshot contains this fixture
                    chord(29, 33)  # Ctrl+F
                    chord(29, 30)  # Ctrl+A
                    ipc.type_text(name)
                    time.sleep(.2)
                    chord(102)  # Home edits the field; Down transfers to the process list
                    chord(108)
                    time.sleep(.15)
                    return child

                normal = fixture(False)
                shot("footer-selected")
                click(box()["width"] - 224, box()["height"] - 61)
                wait_for(lambda: normal.poll() is not None, "End process did not terminate fixture")
                assert normal.returncode == -signal.SIGTERM

                stubborn = fixture(True)
                chord(111)
                time.sleep(.25)
                assert stubborn.poll() is None, "fixture did not ignore SIGTERM"
                click(box()["width"] - 90, box()["height"] - 61)
                time.sleep(.2)
                confirmation = shot("force-confirm")
                assert stubborn.poll() is None, "force quit ran before confirmation"
                chord(1)  # Escape cancels
                time.sleep(.2)
                assert stubborn.poll() is None
                assert ImageChops.difference(confirmation, shot("cancelled")).getbbox()
                chord(42, 111)
                time.sleep(.15)
                chord(15)  # Cancel is focused first; Tab focuses Force quit
                chord(28)
                wait_for(lambda: stubborn.poll() is not None, "confirmed Force quit did not terminate fixture")
                assert stubborn.returncode == -signal.SIGKILL

                # A confirmation owns its identity even after the target exits.
                gone = fixture(True)
                chord(42, 111)
                time.sleep(.15)
                gone.kill()
                gone.wait(timeout=5)
                time.sleep(1.2)  # list refresh clears selection while confirmation keeps its identity
                chord(15)
                chord(28)
                time.sleep(.15)
                assert monitor()["id"] == window_id

                # Recheck protection at execution: this disposable process
                # execs a protected executable name while confirmation is open.
                protected_exe = tmp / "rediwm"
                shutil.copyfile("/bin/sleep", protected_exe)
                protected_exe.chmod(0o700)
                protected = fixture(True, protected_exe)
                chord(42, 111)
                protected.stdin.write("exec\n")
                protected.stdin.flush()
                wait_for(lambda: Path(f"/proc/{protected.pid}/exe").resolve() == protected_exe,
                         "fixture did not exec the protected name")
                time.sleep(1.2)
                chord(15)
                chord(28)
                time.sleep(.15)
                assert protected.poll() is None, "confirmation bypassed refreshed session protection"

                # Close joins the worker, even if a sample has just started.
                chord(29, 16)  # Ctrl+Q
                ipc.wait_for("window_closed", window_id=window_id)
                wait_for(lambda: not Path(f"/proc/{monitor_pid}").exists(), "monitor worker outlived its window")
                assert not windows()
                # A paused app stays paused across minimize/restore, and a
                # hidden app must still consume close and join its worker.
                chord(29, 56, 111)
                ipc.wait_for("window_mapped", app_id="rediwm-monitor")
                settled()
                window_id = monitor()["id"]
                monitor_pid = monitor()["pid"]
                wait_for(lambda: gpu_trace.read_text().splitlines()[-1] == "temperature",
                         "reopened monitor did not start collecting")
                click(box()["width"] - 80, 171)
                wait_for(lambda: gpu_trace.read_text().splitlines()[-1] == "shutdown",
                         "monitor did not pause before minimizing")
                ipc.minimize(window_id)
                chord(29, 56, 111)
                wait_for(lambda: not monitor()["is_minimized"], "paused monitor did not restore")
                settled()
                idle("restored while paused")
                ipc.minimize(window_id)
                ipc.close_window(window_id)
                ipc.wait_for("window_closed", window_id=window_id)
                wait_for(lambda: not Path(f"/proc/{monitor_pid}").exists(), "hidden monitor did not stop")
                print(f"System Monitor: scale={scale} mode={'workspaces' if workspace else 'canvas'} passed", flush=True)
        finally:
            for child in fixtures:
                if child.poll() is None:
                    child.kill()
                child.wait(timeout=5)
                if child.stdout:
                    child.stdout.close()
                if child.stdin:
                    child.stdin.close()
            stop_process(compositor)
            log.close()
            errors = Path(log.name).read_text()
            if "panic" in errors or "error(gpa)" in errors:
                print(errors[-6000:], file=sys.stderr)
                raise AssertionError("compositor or monitor reported a panic/leak")


if __name__ == "__main__":
    os.umask(0o077)
    scale = float(os.environ.get("REDIWM_TEST_SCALE", "1"))
    run(scale, False)
    run(scale, True)

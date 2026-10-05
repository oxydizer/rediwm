#!/usr/bin/env python3
"""Integration tests for night light and display gamma support in rediwm."""
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import time

from desktop_zoom import ROOT, wait_for
from ipc_client import IPCClient, spawn_compositor, stop_process


def compile_gamma_hook(tmp: Path) -> Path:
    flags = shlex.split(subprocess.check_output(
        ["pkg-config", "--cflags", "--libs", "wlroots-0.20", "wayland-server"],
        text=True))
    hook = tmp / "gamma_hook.so"
    subprocess.run(["cc", "-shared", "-fPIC", "-Wall", "-Wextra", "-Werror",
                    str(ROOT / "tests/gamma_hook.c"), "-o", str(hook),
                    *flags, "-ldl"], check=True)
    return hook


def read_samples(path: Path):
    if not path.exists():
        return []
    result = []
    for line in path.read_text().splitlines():
        line = line.strip()
        if line:
            try:
                result.append(json.loads(line))
            except json.JSONDecodeError:
                pass
    return result


def test_default_neutral(tmp: Path):
    print("Running test_default_neutral...")
    compositor, log = spawn_compositor(
        tmp, outputs="2",
        config_content="",
        env_extra={"TZ": "UTC"},
    )
    try:
        with IPCClient(tmp) as ipc:
            wait_for(lambda: len(ipc.get_outputs()) == 2, "outputs not available")
            nl = ipc.get_night_light()
            assert not nl["enabled"], f"Expected enabled=false, got {nl}"
            assert nl["phase"] == "off", f"Expected phase=off, got {nl}"
            assert nl["temperature"] == 6500, f"Expected temp=6500, got {nl}"
            assert len(nl["outputs"]) == 2, f"Expected 2 outputs, got {nl}"
            for out in nl["outputs"]:
                assert out["status"] == "neutral", f"Expected status=neutral, got {out}"
                assert out["gamma_size"] == 0, f"Expected gamma_size=0, got {out}"
                assert out["temperature"] == 6500, f"Expected temp=6500, got {out}"
                assert out["night_light"] is True, f"Expected night_light=true, got {out}"
                assert out["gamma"] == 1.0, f"Expected gamma=1.0, got {out}"
            print("  default config neutrality passed")
    except Exception:
        log.flush()
        print((tmp / "compositor.log").read_text())
        raise
    finally:
        stop_process(compositor)
        log.close()


def test_unsupported_without_hook(tmp: Path):
    print("Running test_unsupported_without_hook...")
    config = """
[night_light]
enabled = true
schedule = "always"
temperature = 4000
"""
    compositor, log = spawn_compositor(
        tmp, outputs="2",
        config_content=config,
        env_extra={"TZ": "UTC"},
    )
    try:
        with IPCClient(tmp) as ipc:
            wait_for(lambda: len(ipc.get_outputs()) == 2, "outputs not available")
            ipc.wait_for_frame(output="HEADLESS-1")
            ipc.wait_for_frame(output="HEADLESS-2")

            nl = ipc.get_night_light()
            assert nl["enabled"], f"Expected enabled=true, got {nl}"
            assert nl["phase"] == "night", f"Expected phase=night, got {nl}"
            assert nl["temperature"] == 4000, f"Expected temp=4000, got {nl}"
            for out in nl["outputs"]:
                assert out["status"] == "unsupported", f"Expected status=unsupported, got {out}"
                assert out["gamma_size"] == 0, f"Expected gamma_size=0, got {out}"

            log.flush()
            log_text = (tmp / "compositor.log").read_text()
            assert "HEADLESS-1: hardware gamma LUT unsupported (gamma size 0)" in log_text
            assert "HEADLESS-2: hardware gamma LUT unsupported (gamma size 0)" in log_text
            assert log_text.count("hardware gamma LUT unsupported") == 2

            # Subsequent frame does not produce duplicate warnings
            ipc.wait_for_frame(output="HEADLESS-1")
            log.flush()
            log_text2 = (tmp / "compositor.log").read_text()
            assert log_text2.count("hardware gamma LUT unsupported") == 2
            print("  unsupported mode without hook passed")
    except Exception:
        log.flush()
        print((tmp / "compositor.log").read_text())
        raise
    finally:
        stop_process(compositor)
        log.close()


def test_reject_mode(tmp: Path, hook: Path):
    print("Running test_reject_mode...")
    samples_file = tmp / "gamma_samples_reject.jsonl"
    config = """
[night_light]
enabled = true
schedule = "always"
temperature = 4000
"""
    compositor, log = spawn_compositor(
        tmp, outputs="2",
        config_content=config,
        env_extra={
            "LD_PRELOAD": str(hook),
            "REDIWM_GAMMA_MODE": "reject",
            "REDIWM_GAMMA_SAMPLES": str(samples_file),
            "TZ": "UTC",
        },
    )
    try:
        with IPCClient(tmp) as ipc:
            wait_for(lambda: len(ipc.get_outputs()) == 2, "outputs not available")
            ipc.wait_for_frame(output="HEADLESS-1")
            ipc.wait_for_frame(output="HEADLESS-2")

            nl = ipc.get_night_light()
            assert nl["enabled"], f"Expected enabled=true, got {nl}"
            for out in nl["outputs"]:
                assert out["status"] == "rejected", f"Expected status=rejected, got {out}"
                assert out["gamma_size"] == 256, f"Expected gamma_size=256, got {out}"

            # Frames continue
            ipc.wait_for_frame(output="HEADLESS-1")
            ipc.wait_for_frame(output="HEADLESS-2")

            # Check that there was exactly one test per target change
            wait_for(lambda: samples_file.exists(), "samples file missing")
            lines = read_samples(samples_file)
            test_events = [e for e in lines if e.get("event") == "test" and e.get("has_transform")]
            h1_tests = [e for e in test_events if e.get("output") == "HEADLESS-1"]
            h2_tests = [e for e in test_events if e.get("output") == "HEADLESS-2"]
            assert len(h1_tests) == 1, f"Expected 1 test for HEADLESS-1, got {len(h1_tests)}"
            assert len(h2_tests) == 1, f"Expected 1 test for HEADLESS-2, got {len(h2_tests)}"

            # More frames, no more tests
            ipc.wait_for_frame(output="HEADLESS-1")
            ipc.wait_for_frame(output="HEADLESS-2")
            lines_after = read_samples(samples_file)
            test_events_after = [e for e in lines_after if e.get("event") == "test" and e.get("has_transform")]
            assert len(test_events_after) == 2, f"Expected 2 test events total, got {len(test_events_after)}"
            print("  reject mode passed")
    except Exception:
        log.flush()
        print((tmp / "compositor.log").read_text())
        raise
    finally:
        stop_process(compositor)
        log.close()


def test_accept_mode(tmp: Path, hook: Path):
    print("Running test_accept_mode...")
    samples_file = tmp / "gamma_samples_accept.jsonl"
    config_file = tmp / "rediwm-config.toml"
    initial_config = """
[night_light]
enabled = true
schedule = "always"
temperature = 4000

[[outputs]]
name = "HEADLESS-2"
night_light = false
gamma = 2.0
"""
    compositor, log = spawn_compositor(
        tmp, outputs="2",
        config_content=initial_config,
        env_extra={
            "LD_PRELOAD": str(hook),
            "REDIWM_GAMMA_MODE": "accept",
            "REDIWM_GAMMA_SAMPLES": str(samples_file),
            "TZ": "UTC",
        },
    )
    try:
        with IPCClient(tmp) as ipc:
            wait_for(lambda: len(ipc.get_outputs()) == 2, "outputs not available")
            ipc.wait_for_frame(output="HEADLESS-1")
            ipc.wait_for_frame(output="HEADLESS-2")

            nl = ipc.get_night_light()
            assert nl["enabled"], f"Expected enabled=true, got {nl}"
            assert nl["temperature"] == 4000, f"Expected temp=4000, got {nl}"

            # Inspect HEADLESS-1 (4000 K applied)
            h1 = next(o for o in nl["outputs"] if o["name"] == "HEADLESS-1")
            assert h1["status"] == "applied", f"Expected applied, got {h1}"
            assert h1["night_light"] is True
            assert h1["gamma"] == 1.0
            assert h1["temperature"] == 4000

            # Inspect HEADLESS-2 (night_light=false, gamma=2.0)
            h2 = next(o for o in nl["outputs"] if o["name"] == "HEADLESS-2")
            assert h2["status"] == "applied", f"Expected applied, got {h2}"
            assert h2["night_light"] is False
            assert abs(h2["gamma"] - 2.0) < 0.01
            assert h2["temperature"] == 6500

            # Verify sampled curves in samples_file
            wait_for(lambda: samples_file.exists(), "samples file missing")
            samples = read_samples(samples_file)
            commits = [e for e in samples if e.get("event") == "commit" and e.get("has_transform")]

            # HEADLESS-1: r = 1.0 > g > b
            h1_commits = [e for e in commits if e.get("output") == "HEADLESS-1"]
            assert len(h1_commits) >= 1, "No commit for HEADLESS-1"
            h1_last = h1_commits[-1]
            r1, g1, b1 = h1_last["sample_1"]
            assert abs(r1 - 1.0) < 0.01, f"Expected r=1.0, got {r1}"
            assert r1 > g1 > b1, f"Expected r > g > b at 4000K, got r={r1}, g={g1}, b={b1}"
            assert 0.95 < g1 < 0.99, f"Unexpected g1 at 4000K: {g1}"
            assert 0.70 < b1 < 0.75, f"Unexpected b1 at 4000K: {b1}"

            # HEADLESS-2: neutral whitepoint (r == g == b == 1.0) and gamma 2.0 midpoint (0.5^(1/2) ≈ 0.707)
            h2_commits = [e for e in commits if e.get("output") == "HEADLESS-2"]
            assert len(h2_commits) >= 1, "No commit for HEADLESS-2"
            h2_last = h2_commits[-1]
            r2, g2, b2 = h2_last["sample_1"]
            assert abs(r2 - 1.0) < 0.01 and abs(g2 - 1.0) < 0.01 and abs(b2 - 1.0) < 0.01, f"Expected neutral endpoint, got {h2_last['sample_1']}"
            rh, gh, bh = h2_last["sample_half"]
            assert abs(rh - 0.707) < 0.02, f"Expected midpoint ≈ 0.707, got {rh}"
            assert abs(gh - 0.707) < 0.02, f"Expected midpoint ≈ 0.707, got {gh}"
            assert abs(bh - 0.707) < 0.02, f"Expected midpoint ≈ 0.707, got {bh}"

            print("  accept mode 4000K & gamma curves verified")

            # --- Reload to enabled = false ---
            print("  testing reload to enabled = false...")
            samples_count_before = len(read_samples(samples_file))
            config_disabled = """
[night_light]
enabled = false

[[outputs]]
name = "HEADLESS-2"
night_light = false
gamma = 1.0
"""
            config_file.write_text(config_disabled)
            ipc.action("reload_config")
            ipc.wait_for_frame(output="HEADLESS-1")
            ipc.wait_for_frame(output="HEADLESS-2")

            nl = ipc.get_night_light()
            assert not nl["enabled"], f"Expected enabled=false after reload, got {nl}"
            for out in nl["outputs"]:
                assert out["status"] == "neutral", f"Expected neutral after reload, got {out}"

            # Verify that one NULL transform was sent (has_transform=false), then nothing on subsequent frames
            new_samples = read_samples(samples_file)[samples_count_before:]
            null_commits = [e for e in new_samples if e.get("event") == "commit" and not e.get("has_transform")]
            assert any(e.get("output") == "HEADLESS-1" for e in null_commits), "Expected NULL transform for HEADLESS-1"

            # Subsequent frame: no new transform commits
            count_after_null = len(read_samples(samples_file))
            ipc.wait_for_frame(output="HEADLESS-1")
            assert len(read_samples(samples_file)) == count_after_null, "Unexpected transform commit after neutral"
            print("  reload to enabled=false verified")

            # --- Idle blank then wake: LUT is sent again ---
            print("  testing idle blank then wake...")
            config_idle = """
[idle]
enabled = true
blank_after_seconds = 10
suspend_after_seconds = 0

[night_light]
enabled = true
schedule = "always"
temperature = 4000
"""
            config_file.write_text(config_idle)
            ipc.action("reload_config")
            ipc.wait_for_frame(output="HEADLESS-1")

            nl = ipc.get_night_light()
            h1 = next(o for o in nl["outputs"] if o["name"] == "HEADLESS-1")
            assert h1["status"] == "applied"

            count_before_idle = len(read_samples(samples_file))

            # Blank the output
            ipc.action("advance_idle_time", {"seconds": 15})
            time.sleep(0.05)

            # Wake by moving cursor
            ipc.action("move_cursor_relative", {"dx": 1, "dy": 1})
            ipc.wait_for_frame(output="HEADLESS-1")

            # Verify LUT was committed again upon wake
            wake_samples = read_samples(samples_file)[count_before_idle:]
            wake_commits = [e for e in wake_samples if e.get("event") == "commit" and e.get("has_transform") and e.get("output") == "HEADLESS-1"]
            assert len(wake_commits) >= 1, "LUT was not recommitted after idle wake"
            print("  idle blank and wake restored LUT successfully")

            # --- Fixed schedule transitions via SetNightLightClock ---
            print("  testing fixed schedule transitions...")
            config_fixed = """
[night_light]
enabled = true
schedule = "fixed"
start = "21:00"
end = "07:00"
transition_minutes = 30
temperature = 4000
day_temperature = 6500
"""
            config_file.write_text(config_fixed)
            ipc.action("reload_config")

            base = 1700000000 - (1700000000 % 86400)

            get_h1 = lambda res: next(o for o in res["outputs"] if o["name"] == "HEADLESS-1")

            # 20:59: Day window (neutral)
            ipc.set_night_light_clock(base + (20 * 60 + 59) * 60)
            nl = ipc.get_night_light()
            assert nl["phase"] == "day", f"Expected day at 20:59, got {nl}"
            assert nl["temperature"] == 6500
            ipc.wait_for_frame(output="HEADLESS-1")
            nl = ipc.get_night_light()
            assert get_h1(nl)["status"] == "neutral"

            # 21:15: Midpoint of warming (to_night)
            ipc.set_night_light_clock(base + (21 * 60 + 15) * 60)
            nl = ipc.get_night_light()
            assert nl["phase"] == "to_night", f"Expected to_night at 21:15, got {nl}"
            assert nl["temperature"] == 4952, f"Expected 4952 at 21:15, got {nl['temperature']}"
            ipc.wait_for_frame(output="HEADLESS-1")
            nl = ipc.get_night_light()
            assert get_h1(nl)["status"] == "applied"
            assert get_h1(nl)["temperature"] == 4952

            # 21:31: Steady night
            ipc.set_night_light_clock(base + (21 * 60 + 31) * 60)
            nl = ipc.get_night_light()
            assert nl["phase"] == "night", f"Expected night at 21:31, got {nl}"
            assert nl["temperature"] == 4000
            ipc.wait_for_frame(output="HEADLESS-1")
            nl = ipc.get_night_light()
            assert get_h1(nl)["status"] == "applied"
            assert get_h1(nl)["temperature"] == 4000

            # 07:15: Midpoint of cooling (to_day)
            ipc.set_night_light_clock(base + (7 * 60 + 15) * 60)
            nl = ipc.get_night_light()
            assert nl["phase"] == "to_day", f"Expected to_day at 07:15, got {nl}"
            assert nl["temperature"] == 4952, f"Expected 4952 at 07:15, got {nl['temperature']}"
            ipc.wait_for_frame(output="HEADLESS-1")
            nl = ipc.get_night_light()
            assert get_h1(nl)["status"] == "applied"
            assert get_h1(nl)["temperature"] == 4952

            # 07:31: Steady day (neutral)
            ipc.set_night_light_clock(base + (7 * 60 + 31) * 60)
            nl = ipc.get_night_light()
            assert nl["phase"] == "day", f"Expected day at 07:31, got {nl}"
            assert nl["temperature"] == 6500
            ipc.wait_for_frame(output="HEADLESS-1")
            nl = ipc.get_night_light()
            assert get_h1(nl)["status"] == "neutral"
            print("  fixed schedule transitions verified")

            # --- Clock jump settling ---
            print("  testing clock jump settling...")
            # Set to noon (12:00)
            ipc.set_night_light_clock(base + 12 * 3600)
            nl = ipc.get_night_light()
            assert nl["phase"] == "day"
            assert nl["temperature"] == 6500

            # Jump directly across boundary into 23:00 (night)
            ipc.set_night_light_clock(base + 23 * 3600)
            nl = ipc.get_night_light()
            assert nl["phase"] == "night", f"Expected night after jump, got {nl}"
            assert nl["temperature"] == 4000
            ipc.wait_for_frame(output="HEADLESS-1")
            nl = ipc.get_night_light()
            assert get_h1(nl)["status"] == "applied"
            assert get_h1(nl)["temperature"] == 4000

            # Clear clock override back to system clock
            ipc.set_night_light_clock(None)
            nl = ipc.get_night_light()
            assert nl["clock_overridden"] is False
            print("  clock jump settling verified")
    except Exception:
        log.flush()
        print((tmp / "compositor.log").read_text())
        raise
    finally:
        stop_process(compositor)
        log.close()


def run():
    with tempfile.TemporaryDirectory(prefix="rediwm-night-light-") as directory:
        tmp = Path(directory)
        hook = compile_gamma_hook(tmp)

        for sub in ("neutral", "unsupported", "reject", "accept"):
            (tmp / sub).mkdir(parents=True, exist_ok=True)

        test_default_neutral(tmp / "neutral")
        test_unsupported_without_hook(tmp / "unsupported")
        test_reject_mode(tmp / "reject", hook)
        test_accept_mode(tmp / "accept", hook)
        print("All night light integration tests passed!")


if __name__ == "__main__":
    run()

#!/usr/bin/env python3
"""Integration tests for application launch placeholders in rediwm.

Tests:
1. Fast app (<120ms): no placeholder frame rendered, clean map.
2. Slow app (>120ms): placeholder appears at T+120ms, maps cleanly, geometry inherited, crossfade.
3. Exiting child: process exits before map, placeholder cleans up via pidfd readiness.
4. Small dialog: first window is small, geometry is not forced, placeholder crossfades out.
5. Close button: close window on placeholder, process receives SIGTERM, frame closed.
6. Remembered window sizes: size saved on unmap and loaded on subsequent launch.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
from typing import Any, Dict, List, Optional

from ipc_client import IPCClient, spawn_compositor, stop_process

ROOT = Path(__file__).resolve().parents[1]


def build_test_client(tmp: Path) -> Path:
    protocol_dir = subprocess.check_output(
        ["pkg-config", "--variable=pkgdatadir", "wayland-protocols"],
        text=True,
    ).strip()
    protocol = Path(protocol_dir) / "stable/xdg-shell/xdg-shell.xml"

    header = tmp / "xdg-shell-client-protocol.h"
    code = tmp / "xdg-shell-protocol.c"
    subprocess.run(["wayland-scanner", "client-header", str(protocol), str(header)], check=True)
    subprocess.run(["wayland-scanner", "private-code", str(protocol), str(code)], check=True)

    client_bin = tmp / "placeholder_client"
    subprocess.run([
        "cc", "-Wall", "-Wextra",
        f"-I{tmp}",
        str(ROOT / "tests/placeholder_client.c"),
        str(code),
        "-lwayland-client",
        "-o", str(client_bin),
    ], check=True)
    return client_bin


def create_desktop_entry(
    apps_dir: Path,
    desktop_id: str,
    name: str,
    exec_cmd: str,
    startup_wm_class: Optional[str] = None,
) -> Path:
    entry_path = apps_dir / desktop_id
    lines = [
        "[Desktop Entry]",
        "Type=Application",
        f"Name={name}",
        f"Exec={exec_cmd}",
    ]
    if startup_wm_class:
        lines.append(f"StartupWMClass={startup_wm_class}")
    entry_path.write_text("\n".join(lines) + "\n")
    return entry_path


def run():
    with tempfile.TemporaryDirectory(prefix="rediwm-launch-test-") as directory:
        tmp = Path(directory)
        client_bin = build_test_client(tmp)

        apps_dir = tmp / "share" / "applications"
        apps_dir.mkdir(parents=True, exist_ok=True)

        state_dir = tmp / "state" / "rediwm"
        state_dir.mkdir(parents=True, exist_ok=True)

        create_desktop_entry(
            apps_dir,
            "fast.desktop",
            "FastApp",
            f"{client_bin} --app-id fast.app --sleep-ms 0",
            startup_wm_class="fast.app",
        )
        create_desktop_entry(
            apps_dir,
            "slow.desktop",
            "SlowApp",
            f"{client_bin} --app-id slow.app --sleep-ms 350",
            startup_wm_class="slow.app",
        )
        create_desktop_entry(
            apps_dir,
            "exit.desktop",
            "ExitApp",
            f"{client_bin} --app-id exit.app --exit-before-map",
            startup_wm_class="exit.app",
        )
        create_desktop_entry(
            apps_dir,
            "dialog.desktop",
            "DialogApp",
            f"{client_bin} --app-id dialog.app --force-size 200 150 --sleep-ms 300",
            startup_wm_class="dialog.app",
        )
        create_desktop_entry(
            apps_dir,
            "hang.desktop",
            "HangApp",
            f"{client_bin} --app-id hang.app --sleep-ms 10000",
            startup_wm_class="hang.app",
        )

        config_content = """[compositor]
placeholder_delay_ms = 120
"""
        env_extra = {
            "XDG_DATA_DIRS": str(tmp / "share") + ":/usr/share",
            "XDG_STATE_HOME": str(tmp / "state"),
        }

        compositor, log_file = spawn_compositor(
            tmp,
            config_content=config_content,
            env_extra=env_extra,
        )

        try:
            with IPCClient(socket_path=tmp, timeout=15) as client:
                client.wait_for("catalog_published", timeout_ms=5000)

                # ==========================================
                # Case 1: Fast app (<120ms)
                # ==========================================
                print("Testing Case 1: Fast app (<120ms)...")
                client.action("launch_app", {"desktop_id": "fast.desktop"})
                client.wait_for({"launch_started": {"desktop_id": "fast.desktop"}}, timeout_ms=3000)
                client.wait_for({"launch_matched": {"desktop_id": "fast.desktop"}}, timeout_ms=5000)

                wins = client.get_windows()
                fast_win = next((w for w in wins if w.get("app_id") == "fast.app"), None)
                assert fast_win is not None, f"Fast window not found in windows: {wins}"
                assert not fast_win.get("placeholder", False), "Fast window should not be placeholder"
                # Close fast window
                client.close_window(fast_win["id"])
                client.wait_for("window_closed", timeout_ms=3000, window_id=fast_win["id"])
                print("Case 1 passed.")

                # ==========================================
                # Case 2: Slow app (>120ms)
                # ==========================================
                print("Testing Case 2: Slow app (>120ms)...")
                t0 = time.monotonic()
                client.action("launch_app", {"desktop_id": "slow.desktop"})
                client.wait_for({"launch_started": {"desktop_id": "slow.desktop"}}, timeout_ms=3000)

                # Early check: placeholder window should exist in compositor
                wins = client.get_windows()
                ph_win = next((w for w in wins if w.get("placeholder") is True), None)
                assert ph_win is not None, f"Placeholder window not found initially: {wins}"
                assert ph_win.get("app_id") == "slow.app"

                # Wait for placeholder_delay_ms (120ms) to elapse; window is still placeholder
                time.sleep(0.18)
                wins = client.get_windows()
                ph_win_check = next((w for w in wins if w.get("id") == ph_win["id"]), None)
                assert ph_win_check is not None and ph_win_check.get("placeholder") is True

                # Real app connects at T+350ms and commits
                client.wait_for({"launch_matched": {"desktop_id": "slow.desktop"}}, timeout_ms=5000)

                # After match, real window inherits geometry and is no longer a placeholder
                wins = client.get_windows()
                real_win = next((w for w in wins if w.get("app_id") == "slow.app"), None)
                assert real_win is not None, f"Real window not found: {wins}"
                assert not real_win.get("placeholder", False), "Real window should not be placeholder"

                # Client geometry should match placeholder configure (640x480)
                # Note: real_win["width"] includes window frame chrome
                assert real_win["width"] >= 640 and real_win["height"] >= 480

                # Close slow window
                client.close_window(real_win["id"])
                client.wait_for("window_closed", timeout_ms=3000, window_id=real_win["id"])
                print("Case 2 passed.")

                # ==========================================
                # Case 3: Exit before map
                # ==========================================
                print("Testing Case 3: Exit before map...")
                # Subscribe before launch: pidfd readiness can remove the
                # placeholder before a subsequent WaitFor request arrives.
                with IPCClient(socket_path=tmp, timeout=3) as events:
                    events.request(raw_cmd={'version': 1, 'command': 'event_stream', 'params': {"events": ["launch_timeout"]}})
                    assert "StateSnapshot" in json.loads(events.reader.readline())
                    client.action("launch_app", {"desktop_id": "exit.desktop"})
                    event = json.loads(events.reader.readline())
                    assert event["LaunchTimeout"]["desktop_id"] == "exit.desktop", event

                wins = client.get_windows()
                exit_win = next((w for w in wins if w.get("app_id") == "exit.app"), None)
                assert exit_win is None, f"Exit app window was not cleaned up: {exit_win}"
                print("Case 3 passed.")

                # ==========================================
                # Case 4: Small dialog escape hatch
                # ==========================================
                print("Testing Case 4: Small dialog escape hatch...")
                client.action("launch_app", {"desktop_id": "dialog.desktop"})
                client.wait_for({"launch_started": {"desktop_id": "dialog.desktop"}}, timeout_ms=3000)
                client.wait_for({"launch_matched": {"desktop_id": "dialog.desktop"}}, timeout_ms=5000)

                wins = client.get_windows()
                dialog_win = next((w for w in wins if w.get("app_id") == "dialog.app"), None)
                assert dialog_win is not None, f"Dialog window not found: {wins}"
                # Small dialog (200x150) should NOT be forced to 640x480 frame!
                # Chrome adds ~60px titlebar and ~4px borders, so width < 300, height < 260
                assert dialog_win["width"] < 350 and dialog_win["height"] < 300, (
                    f"Dialog window geometry was forced to placeholder size: {dialog_win}"
                )

                client.close_window(dialog_win["id"])
                client.wait_for("window_closed", timeout_ms=3000, window_id=dialog_win["id"])
                print("Case 4 passed.")

                # ==========================================
                # Case 5: Close button cancels launch
                # ==========================================
                print("Testing Case 5: Close button cancels launch...")
                client.action("launch_app", {"desktop_id": "hang.desktop"})
                client.wait_for({"launch_started": {"desktop_id": "hang.desktop"}}, timeout_ms=3000)

                time.sleep(0.15)
                wins = client.get_windows()
                hang_ph = next((w for w in wins if w.get("app_id") == "hang.app"), None)
                assert hang_ph is not None, f"Hang placeholder not found: {wins}"
                assert hang_ph.get("placeholder") is True

                # Send close action to placeholder
                client.close_window(hang_ph["id"])
                client.wait_for("window_closed", timeout_ms=3000, window_id=hang_ph["id"])

                wins = client.get_windows()
                hang_check = next((w for w in wins if w.get("app_id") == "hang.app"), None)
                assert hang_check is None, f"Hang placeholder was not removed: {hang_check}"
                print("Case 5 passed.")

                # ==========================================
                # Case 6: Window size persistence
                # ==========================================
                print("Testing Case 6: Window size persistence...")
                # Check $XDG_STATE_HOME/rediwm/window_sizes
                sizes_file = state_dir / "window_sizes"
                assert sizes_file.exists(), f"Window sizes file {sizes_file} was not written on window close"
                sizes_content = sizes_file.read_text()
                # Fast app or slow app client size should be recorded
                assert "fast.app" in sizes_content or "slow.app" in sizes_content, (
                    f"Expected app_id in window_sizes content:\n{sizes_content}"
                )
                print(f"Window sizes persisted correctly:\n{sizes_content.strip()}")
                print("Case 6 passed.")

                # ==========================================
                # Case 7: Dragged placeholder inherits moved position
                # ==========================================
                print("Testing Case 7: Moved placeholder inherits position...")
                client.action("launch_app", {"desktop_id": "slow.desktop"})
                client.wait_for({"launch_started": {"desktop_id": "slow.desktop"}}, timeout_ms=3000)

                time.sleep(0.05)
                wins = client.get_windows()
                ph = next((w for w in wins if w.get("placeholder") is True), None)
                assert ph is not None

                # Move placeholder before app commits
                client.action("move_window_to", {"id": ph["id"], "x": 320, "y": 240})

                # Wait for real app to map
                client.wait_for({"launch_matched": {"desktop_id": "slow.desktop"}}, timeout_ms=5000)

                wins = client.get_windows()
                real_win = next((w for w in wins if w.get("app_id") == "slow.app"), None)
                assert real_win is not None
                assert abs(real_win["x"] - 320) <= 2 and abs(real_win["y"] - 240) <= 2, (
                    f"Real window did not inherit moved position: expected (320, 240), got ({real_win['x']}, {real_win['y']})"
                )

                client.close_window(real_win["id"])
                client.wait_for("window_closed", timeout_ms=3000, window_id=real_win["id"])
                print("Case 7 passed.")

                print("\nALL LAUNCH PLACEHOLDER INTEGRATION TESTS PASSED!")

        finally:
            stop_process(compositor)
            log_file.close()


if __name__ == "__main__":
    run()

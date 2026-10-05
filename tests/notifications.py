#!/usr/bin/env python3
"""Integration tests for notifications daemon, D-Bus service, and IPC."""
import os
from pathlib import Path
import re
import select
import subprocess
import sys
import tempfile
import time

from ipc_client import IPCClient, ROOT, spawn_compositor, stop_process

NAME = "org.freedesktop.Notifications"
PATH = "/org/freedesktop/Notifications"
IFACE = "org.freedesktop.Notifications"


def bus_call(member: str, signature: str = "", *args, check: bool = True):
    cmd = ["busctl", "--user", "--timeout=5", "call", NAME, PATH, IFACE, member]
    if signature:
        cmd.append(signature)
        cmd.extend(str(a) for a in args)
    return subprocess.run(cmd, capture_output=True, text=True, timeout=10, check=check)


def wait_for(predicate, description: str, timeout: float = 5.0, interval: float = 0.05):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        res = predicate()
        if res:
            return res
        time.sleep(interval)
    raise TimeoutError(f"Timed out waiting for: {description}")


def test_notifications(tmp_dir: Path):
    config = """
[notifications]
dnd = false
default_timeout_ms = 5000

[[notification_rules]]
app_name = "quiet_app"
mute = true

[[notification_rules]]
app_name = "vip_app"
urgency = 2
dnd_bypass = true
"""
    compositor, log = spawn_compositor(
        tmp_dir,
        outputs="1",
        scale=os.environ.get("REDIWM_TEST_SCALE", "1"),
        config_content=config,
        env_extra={"REDIWM_FORCE_DBUS": "1"},
    )
    monitor_proc = None
    try:
        with IPCClient(tmp_dir) as ipc:
            # 1. Wait for compositor to claim org.freedesktop.Notifications
            print("1. Waiting for D-Bus name acquisition...")
            wait_for(
                lambda: subprocess.run(
                    ["busctl", "--user", "status", NAME],
                    capture_output=True
                ).returncode == 0,
                f"D-Bus service {NAME} registered",
                timeout=5.0,
            )

            # 2. Test GetCapabilities
            print("2. Testing GetCapabilities...")
            res = bus_call("GetCapabilities")
            assert res.returncode == 0, res.stderr
            out = res.stdout.strip()
            for cap in ("actions", "body", "icon-static", "persistence"):
                assert cap in out, f"Capability '{cap}' not found in: {out}"

            # 3. Test GetServerInformation
            print("3. Testing GetServerInformation...")
            res = bus_call("GetServerInformation")
            assert res.returncode == 0, res.stderr
            out = res.stdout.strip()
            assert "rediwm" in out
            assert "rediwm" in out
            assert "0.1.0" in out
            assert "1.2" in out

            # Start background signal monitor
            monitor_proc = subprocess.Popen(
                ["dbus-monitor", "--session", f"type='signal',interface='{IFACE}'"],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            time.sleep(0.1)

            # 4. Post first notification via D-Bus Notify
            # signature: susssasa{sv}i
            print("4. Testing Notify method...")
            # "test_app", replaces_id=0, icon="", summary="First Title", body="First Body", 2 actions ("default", "Open"), 0 hints, timeout=5000
            res = bus_call(
                "Notify",
                "susssasa{sv}i",
                "test_app",
                0,
                "",
                "First Title",
                "First Body",
                2,
                "default",
                "Open",
                0,
                5000,
            )
            assert res.returncode == 0, res.stderr
            m = re.search(r"u\s+(\d+)", res.stdout)
            assert m is not None, f"Could not parse notification id from: {res.stdout}"
            id1 = int(m.group(1))
            assert id1 == 1, f"Expected id 1, got {id1}"

            # Verify via IPC get_notifications
            notifs = ipc.get_notifications()
            assert len(notifs["toasts"]) == 1, notifs
            toast1 = notifs["toasts"][0]
            assert toast1["id"] == 1
            assert toast1["app_name"] == "test_app"
            assert toast1["summary"] == "First Title"
            assert toast1["body"] == "First Body"
            assert toast1["urgency"] == 1
            assert toast1["expire_at_ms"] is not None
            assert len(notifs["history"]) == 1
            assert notifs["history"][0]["id"] == 1

            # Test IPC wait condition notification_count
            ipc.wait_for(condition={"notification_count": {"count": 1}})

            # 5. Test in-place update via replaces_id
            print("5. Testing replaces_id...")
            res = bus_call(
                "Notify",
                "susssasa{sv}i",
                "test_app",
                id1,
                "",
                "Updated Title",
                "Updated Body",
                0,
                0,
                5000,
            )
            assert res.returncode == 0, res.stderr
            m = re.search(r"u\s+(\d+)", res.stdout)
            assert m is not None and int(m.group(1)) == id1

            notifs = ipc.get_notifications()
            assert len(notifs["toasts"]) == 1
            assert notifs["toasts"][0]["summary"] == "Updated Title"
            assert notifs["toasts"][0]["body"] == "Updated Body"

            # 6. Test invoke_notification_action and ActionInvoked signal
            print("6. Testing invoke_notification_action and ActionInvoked signal...")
            ipc.invoke_notification_action(id1, "default")

            # Verify signal received by dbus-monitor
            def check_action_signal():
                poll = select.poll()
                poll.register(monitor_proc.stdout, select.POLLIN)
                while poll.poll(100):
                    line = monitor_proc.stdout.readline()
                    if "member=ActionInvoked" in line or "ActionInvoked" in line:
                        return True
                return False

            wait_for(check_action_signal, "ActionInvoked signal", timeout=3.0)

            # 7. Test dismiss_notification and NotificationClosed signal
            print("7. Testing dismiss_notification and NotificationClosed signal...")
            ipc.dismiss_notification(id1)

            def check_closed_signal():
                poll = select.poll()
                poll.register(monitor_proc.stdout, select.POLLIN)
                while poll.poll(100):
                    line = monitor_proc.stdout.readline()
                    if "member=NotificationClosed" in line or "NotificationClosed" in line:
                        return True
                return False

            wait_for(check_closed_signal, "NotificationClosed signal", timeout=3.0)

            # Wait for stack to be empty
            wait_for(
                lambda: len(ipc.get_notifications()["toasts"]) == 0,
                "Toasts stack empty after dismiss",
                timeout=3.0,
            )

            # 8. Test CloseNotification D-Bus method
            print("8. Testing CloseNotification method...")
            res = bus_call(
                "Notify",
                "susssasa{sv}i",
                "test_app",
                0,
                "",
                "Close Me",
                "Body",
                0,
                0,
                5000,
            )
            assert res.returncode == 0
            m = re.search(r"u\s+(\d+)", res.stdout)
            id2 = int(m.group(1))
            assert id2 == 2

            res = bus_call("CloseNotification", "u", id2)
            assert res.returncode == 0
            wait_for(
                lambda: len(ipc.get_notifications()["toasts"]) == 0,
                "Toasts stack empty after CloseNotification",
                timeout=3.0,
            )

            # 9. Test notification rules (mute=true for quiet_app)
            print("9. Testing notification rules: mute...")
            res = bus_call(
                "Notify",
                "susssasa{sv}i",
                "quiet_app",
                0,
                "",
                "Muted Notification",
                "Should not show toast",
                0,
                0,
                5000,
            )
            assert res.returncode == 0
            # Muted notification does not appear in active toasts stack, but is in history
            notifs = ipc.get_notifications()
            assert len(notifs["toasts"]) == 0
            in_hist = any(h["app_name"] == "quiet_app" for h in notifs["history"])
            assert in_hist, "quiet_app record not found in history"

            # 10. Test notification rules (urgency=2, dnd_bypass for vip_app)
            print("10. Testing notification rules: critical / dnd_bypass...")
            res = bus_call(
                "Notify",
                "susssasa{sv}i",
                "vip_app",
                0,
                "",
                "VIP Urgent Notice",
                "Critical urgency",
                0,
                0,
                1000,  # even with 1000ms timeout, urgency 2 must not expire
            )
            assert res.returncode == 0
            m = re.search(r"u\s+(\d+)", res.stdout)
            id_vip = int(m.group(1))

            notifs = ipc.get_notifications()
            assert len(notifs["toasts"]) == 1
            vip_toast = notifs["toasts"][0]
            assert vip_toast["id"] == id_vip
            assert vip_toast["urgency"] == 2
            assert vip_toast["expire_at_ms"] is None, "Critical notification must not have expire_at_ms"

            # 11. Test DND Mode toggle
            print("11. Testing DND mode...")
            ipc.set_dnd(True)
            notifs = ipc.get_notifications()
            assert notifs["dnd"] is True
            # vip_app toast survived DND because it is critical (urgency=2) and dnd_bypass
            assert len(notifs["toasts"]) == 1

            # Normal notification during DND is suppressed
            res = bus_call(
                "Notify",
                "susssasa{sv}i",
                "chat_app",
                0,
                "",
                "DND Chat",
                "Should be suppressed",
                0,
                0,
                5000,
            )
            assert res.returncode == 0
            notifs = ipc.get_notifications()
            assert len(notifs["toasts"]) == 1  # only vip_app still visible
            in_hist = any(h["summary"] == "DND Chat" for h in notifs["history"])
            assert in_hist, "DND Chat record not in history"

            ipc.set_dnd(False)
            assert ipc.get_notifications()["dnd"] is False

            # 12. Test clear_notifications
            print("12. Testing clear_notifications...")
            ipc.clear_notifications("all")
            notifs = ipc.get_notifications()
            assert len(notifs["history"]) == 0
            wait_for(
                lambda: len(ipc.get_notifications()["toasts"]) == 0,
                "Toasts stack empty after clear_notifications",
                timeout=3.0,
            )

            # Exercise the actual card and close hit target, plus expiry on an idle output.
            print("13. Testing card rendering, pointer dismissal and idle expiry...")
            bus_call("Notify", "susssasa{sv}i", "Downloads", 0,
                     "folder-download", "Download Complete",
                     "ubuntu-24.04.iso has finished downloading.", 0, 0, 0)
            time.sleep(0.35)  # entrance/reflow settled
            output = ipc.get_outputs()[0]
            preview = os.environ.get("REDIWM_NOTIFICATION_PREVIEW")
            if preview:
                ipc.screenshot(path=str(Path(preview).resolve()))
            # Card is inset 20px; close button is centered 28px inside its right edge.
            ipc.click_at(output["x"] + output["logical_width"] - 48,
                         output["y"] + 55)
            wait_for(lambda: not ipc.get_notifications()["toasts"], "pointer close")
            bus_call("Notify", "susssasa{sv}i", "Timer", 0, "", "Expires",
                     "No input or continuous repaint needed", 0, 0, 650)
            time.sleep(1.1)
            assert not ipc.get_notifications()["toasts"], "idle notification did not expire"

            print("All notifications integration tests passed successfully!")

    finally:
        if monitor_proc is not None:
            monitor_proc.terminate()
            monitor_proc.communicate(timeout=2)
        stop_process(compositor)
        log.close()


def main():
    if "--private" not in sys.argv:
        cmd = ["dbus-run-session", "--", sys.executable, __file__, "--private"]
        sys.exit(subprocess.call(cmd))

    with tempfile.TemporaryDirectory(prefix="rediwm-notif-test-") as td:
        test_notifications(Path(td))


if __name__ == "__main__":
    main()

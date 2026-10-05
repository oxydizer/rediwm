#!/usr/bin/env python3
"""Malformed titles stay connected and become valid UTF-8.

Requires the patched private wlroots build; see patches/wlroots/README.md.
Runs entirely on an isolated headless compositor.
"""
import os
from pathlib import Path
import subprocess
import tempfile

from desktop_zoom import build_client, wait_for
from ipc_client import IPCClient, spawn_compositor, stop_process
from xwayland import wayland_display_name


def run():
    with tempfile.TemporaryDirectory(prefix="rediwm-window-titles-") as directory:
        tmp = Path(directory)
        build_client(tmp)
        compositor, log = spawn_compositor(
            tmp, renderer=os.environ.get("REDIWM_TEST_RENDERER", "pixman"),
            env_extra={"DBUS_SESSION_BUS_ADDRESS": ""})
        client = None
        try:
            with IPCClient(tmp) as ipc, (tmp / "client.log").open("w") as client_log:
                ipc.wait_for("wallpaper_presented", timeout_ms=10000)
                live_file = tmp / "live"
                env = dict(os.environ, XDG_RUNTIME_DIR=str(tmp),
                           WAYLAND_DISPLAY=wayland_display_name(tmp),
                           REDIWM_TEST_LIVE_FILE=str(live_file))
                # Invalid even before the initial map, as well as after it.
                client = subprocess.Popen(
                    [os.fsencode(tmp / "client"), b"--title", b"Initial \xff title"],
                    env=env, stdout=client_log, stderr=client_log)

                def expect_title(expected):
                    def check():
                        assert client.poll() is None, (tmp / "client.log").read_text()
                        return next((w for w in ipc.get_windows()
                                     if w["title"] == expected), None)
                    return wait_for(check, f"title did not become {expected!r}")

                window = expect_title("Initial ? title")
                cases = [
                    ("Valid café 日本語 🙂".encode(), "Valid café 日本語 🙂"),
                    ("Boundaries \u0080\u07ff\u0800\ud7ff\ue000\uffff\U00010000\U0010ffff".encode(),
                     "Boundaries \u0080\u07ff\u0800\ud7ff\ue000\uffff\U00010000\U0010ffff"),
                    (b"lone \x80 byte", "lone ? byte"),
                    (b"overlong \xc0\xaf", "overlong ??"),
                    (b"surrogate \xed\xa0\x80", "surrogate ???"),
                    (b"too high \xf4\x90\x80\x80", "too high ????"),
                    (b"truncated \xe2\x82", "truncated ??"),
                    (b"mixed \xff caf\xc3\xa9 \xf0\x9f\x99\x82", "mixed ? café 🙂"),
                    (b"ASCII recovered", "ASCII recovered"),
                ]
                for raw, expected in cases:
                    pending = tmp / "next-live"
                    pending.write_bytes(b"ff112233 400 260 " + raw + b"\n")
                    pending.replace(live_file)
                    assert expect_title(expected)["id"] == window["id"]

                assert expect_title("ASCII recovered")["id"] == window["id"]
                live_file.unlink()
                # Replacement must not expand a legal-size request into a
                # title too large to forward to other Wayland clients.
                for raw, expected in ((b"\xff" * 3500, "?" * 3500), (b"", "")):
                    stop_process(client)
                    client = subprocess.Popen(
                        [os.fsencode(tmp / "client"), b"--title", raw],
                        env=env, stdout=client_log, stderr=client_log)
                    expect_title(expected)
                assert compositor.poll() is None
            print("PASS: malformed initial/live/long titles repaired, valid Unicode and empty titles preserved")
        except Exception:
            print((tmp / "compositor.log").read_text(errors="replace")[-4000:])
            raise
        finally:
            for process in (client, compositor):
                if process is not None:
                    stop_process(process)
            log.close()


if __name__ == "__main__":
    run()

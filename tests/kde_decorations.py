#!/usr/bin/env python3
"""KDE decoration negotiation, lifecycle, rule overrides and real chrome controls."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile

from desktop_zoom import wait_for
from ipc_client import ROOT, IPCClient, spawn_compositor, stop_process


def build_client(tmp):
    protocols = Path(subprocess.check_output(
        ["pkg-config", "--variable=pkgdatadir", "wayland-protocols"], text=True).strip())
    sources = []
    for name, xml in (
        ("xdg-shell", protocols / "stable/xdg-shell/xdg-shell.xml"),
        ("xdg-decoration", protocols / "unstable/xdg-decoration/xdg-decoration-unstable-v1.xml"),
        ("server-decoration", ROOT / "protocol/server-decoration.xml"),
    ):
        source = tmp / f"{name}-protocol.c"
        sources.append(str(source))
        for mode, dest in (("client-header", tmp / f"{name}-client-protocol.h"), ("private-code", source)):
            subprocess.run(["wayland-scanner", mode, str(xml), str(dest)], check=True)
    subprocess.run(["cc", "-Wall", "-Wextra", "-Wno-missing-field-initializers", f"-I{tmp}",
                    str(ROOT / "tests/kde_decoration_client.c"), *sources,
                    "-lwayland-client", "-o", str(tmp / "client")], check=True)


def run():
    with tempfile.TemporaryDirectory(prefix="rediwm-kde-decorations-") as directory:
        tmp = Path(directory)
        build_client(tmp)
        base_config = '[animations]\nreduced_motion = "on"\n'
        compositor, compositor_log = spawn_compositor(tmp, config_content=base_config, renderer=os.environ.get("REDIWM_TEST_RENDERER", "pixman"),
            env_extra={"DBUS_SESSION_BUS_ADDRESS": "unix:path=/nonexistent-rediwm-test-session-bus"})
        clients = []
        try:
            with IPCClient(tmp) as ipc:
                display = next(p.name for p in tmp.glob("wayland-*") if not p.name.endswith(".lock"))
                env = dict(os.environ, XDG_RUNTIME_DIR=str(tmp), WAYLAND_DISPLAY=display)

                def start(order, mode):
                    path = tmp / f"client-{len(clients)}.log"
                    with path.open("w") as log:
                        client = subprocess.Popen([str(tmp / "client"), order, str(mode)], env=env,
                                                  stdin=subprocess.PIPE, stdout=log, stderr=log)
                    clients.append(client)
                    win = wait_for(lambda: next(iter(ipc.get_windows()), None), "KDE client did not map")
                    assert "default 2" in path.read_text(), path.read_text()
                    return client, win["id"], path

                def send(client, command):
                    client.stdin.write(command.encode())
                    client.stdin.flush()

                def framed(window_id, expected):
                    debug = wait_for(lambda: (d if (d := ipc.get_window_debug(window_id))["decoration_mode"] ==
                                               ("server" if expected else "client") else None),
                                     f"decoration mode did not become {expected}")
                    assert (debug["titlebar_height"] > 0) == expected, debug
                    assert (debug["frame_border"] > 0) == expected, debug
                    assert (debug["footer_height"] > 0) == expected, debug
                    return debug

                def close(client, window_id):
                    ipc.action("close_window", {"id": window_id})
                    client.wait(timeout=5)
                    assert client.returncode == 0
                    wait_for(lambda: not ipc.get_windows(), "client did not close")

                def rules(mode):
                    config = "" if mode is None else f'[[window_rules]]\napp_id = "test.kde-decoration"\ndecorations = "{mode}"\n'
                    (tmp / "rediwm-config.toml").write_text(base_config + config)
                    ipc.action("reload_config")

                for order in ("early", "late"):
                    for mode in (-1, 0, 1, 2):
                        client, window_id, _ = start(order, mode)
                        framed(window_id, mode in (-1, 2))
                        close(client, window_id)
                print("PASS: KDE default/server/client/none, before and after shell role")

                client, window_id, path = start("early", 2)
                # The mode event alone must not move content or change chrome.
                send(client, "h1")
                wait_for(lambda: "mode 1" in path.read_text(), "mode request not acknowledged")
                framed(window_id, True)
                send(client, "p")
                framed(window_id, False)
                for mode in (0, 2):
                    send(client, str(mode))
                    framed(window_id, mode == 2)
                send(client, "f")
                wait_for(lambda: ipc.get_window_debug(window_id)["fullscreen"], "not fullscreen")
                framed(window_id, False)
                send(client, "w")
                framed(window_id, True)
                close(client, window_id)

                # HEAD has a deferred fullscreen-restore timer that can
                # configure an unmapped window. Keep that unrelated race out
                # of this decoration-remapping test by using a fresh window.
                client, window_id, path = start("early", 2)
                framed(window_id, True)
                send(client, "u")
                wait_for(lambda: not ipc.get_windows(), "did not unmap")
                send(client, "1m")
                wait_for(lambda: ipc.get_windows(), "did not remap")
                framed(window_id, False)
                send(client, "2")
                framed(window_id, True)
                send(client, "r")
                framed(window_id, False)
                send(client, "c")
                framed(window_id, True)
                send(client, "d")
                client.wait(timeout=5)
                assert client.returncode == 0, path.read_text()
                assert "destroyed surface before decoration" in path.read_text()
                wait_for(lambda: not ipc.get_windows(), "destroyed window remained")
                print("PASS: commit-synchronized mode changes, fullscreen, remap, release/recreate and surface-first destruction")

                for rule, request, expected in (("client", 2, False), ("server", 1, True)):
                    rules(rule)
                    client, window_id, path = start("early", request)
                    framed(window_id, expected)
                    rules("client" if expected else "server")
                    framed(window_id, not expected)
                    rules(None)
                    framed(window_id, request == 2)
                    close(client, window_id)
                print("PASS: initial rules, live rule changes and restoring client preference")

                client, window_id, _ = start("both", 2)
                framed(window_id, False)
                send(client, "x")
                framed(window_id, True)
                send(client, "1")
                framed(window_id, True)
                close(client, window_id)
                print("PASS: XDG negotiation takes precedence when both protocols are used")

                client, window_id, path = start("early", 2)
                debug = framed(window_id, True)
                ipc.action("focus_window", {"id": window_id})
                ipc.wait_for_frame()
                box = debug["chrome_box"]
                ipc.action("move_cursor", {"x": box["x"] + box["width"] - 30,
                                           "y": box["y"] + debug["titlebar_height"] // 2})
                ipc.action("pointer_button", {"button": 272, "pressed": True})
                ipc.action("pointer_button", {"button": 272, "pressed": False})
                client.wait(timeout=5)
                assert client.returncode == 0 and "close" in path.read_text(), path.read_text()
                print("PASS: compositor titlebar close button reaches KDE-decorated client")
                if "--ghostty" in sys.argv:
                    # Both Ghostty and the compositor use only this test's
                    # display and state. The entry point isolates D-Bus too.
                    ghostty_env = dict(env, HOME=str(tmp), XDG_CONFIG_HOME=str(tmp / "config"),
                                       XDG_STATE_HOME=str(tmp / "state"), XDG_CACHE_HOME=str(tmp / "cache"),
                                       DBUS_SYSTEM_BUS_ADDRESS="unix:path=/nonexistent-rediwm-test-system-bus",
                                       GDK_BACKEND="wayland")
                    ghostty_path = tmp / "ghostty.log"
                    with ghostty_path.open("w") as log:
                        ghostty = subprocess.Popen(["ghostty", "--config-default-files=false",
                            "--gtk-single-instance=false", "--window-decoration=server",
                            "--gtk-titlebar=false", "--confirm-close-surface=false",
                            "-e", "/bin/sleep", "60"], env=ghostty_env, stdout=log, stderr=log)
                    clients.append(ghostty)
                    win = wait_for(lambda: next((w for w in ipc.get_windows()
                        if "ghostty" in (w.get("app_id") or "").lower()), None), "Ghostty did not map")
                    framed(win["id"], True)
                    close(ghostty, win["id"])
                    print("PASS: real Ghostty with server decorations and gtk-titlebar=false")
                assert compositor.poll() is None
        except Exception:
            for path in tmp.glob("*.log"):
                print(path.name, path.read_text(errors="replace"))
            raise
        finally:
            for client in clients:
                if client.poll() is None:
                    stop_process(client)
                if client.stdin:
                    client.stdin.close()
            stop_process(compositor)
            compositor_log.close()


if __name__ == "__main__":
    if "--ghostty" in sys.argv and not os.environ.get("REDIWM_KDE_PRIVATE_BUS"):
        env = dict(os.environ, REDIWM_KDE_PRIVATE_BUS="1",
                   DBUS_SYSTEM_BUS_ADDRESS="unix:path=/nonexistent-rediwm-test-system-bus")
        raise SystemExit(subprocess.call(["dbus-run-session", "--", sys.executable, *sys.argv], env=env))
    run()

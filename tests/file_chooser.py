#!/usr/bin/env python3
"""FileChooser backend and Settings on a private bus and headless desktop."""
import json
import os
import shutil
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time

from ipc_client import IPCClient, ROOT, spawn_compositor, stop_process
from files_browser import wait_for
from ui_driver import UIDriver

BACKEND = "org.freedesktop.impl.portal.desktop.rediwm"
PATH = "/org/freedesktop/portal/desktop"
IFACE = "org.freedesktop.impl.portal.FileChooser"


def run():
    from gi.repository import Gio, GLib
    with tempfile.TemporaryDirectory(prefix="rediwm-chooser-") as directory:
        tmp = Path(directory)
        home = tmp / "Home"
        docs = home / "Documents"
        docs.mkdir(parents=True)
        (docs / "alpha.txt").write_text("keep this")
        (docs / "beta.txt").write_text("second")
        (docs / "image.png").write_bytes(b"fixture")
        recent_dir = home / "Other folder"
        recent_dir.mkdir()
        recent_text = recent_dir / "alpha.txt"
        recent_text.write_text("recent file in another directory")
        data = tmp / "data"
        data.mkdir()
        (data / "recently-used.xbel").write_text(
            '<xbel version="1.0">' + ''.join(
                f'<bookmark href="{path.as_uri()}" visited="2026-01-0{day}T00:00:00Z"/>'
                for path, day in [(docs / "beta.txt", 1), (recent_text, 2), (docs / "image.png", 3)]
            ) + '</xbel>')
        cfg = tmp / "config"
        portals = cfg / "xdg-desktop-portal" / "rediwm-portals.conf"
        portals.parent.mkdir(parents=True)
        portals.write_text("# preserved\n[preferred]\ndefault=gtk\norg.freedesktop.impl.portal.ScreenCast=wlr\norg.freedesktop.impl.portal.Settings=rediwm;gtk\norg.freedesktop.impl.portal.FileChooser=rediwm;gtk\n")
        proc, log = spawn_compositor(tmp, env_extra={"HOME": str(home), "XDG_CONFIG_HOME": str(cfg), "XDG_DATA_HOME": str(data), "REDIWM_FILES_DEVICES": "0", "REDIWM_FORCE_DBUS": "1", "GIO_USE_VFS": "local"})
        try:
            sock = wait_for(lambda: next(iter(tmp.glob("rediwm-*.sock")), None), "IPC")
            with IPCClient(str(sock)) as ipc:
                bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
                def owned():
                    return bus.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "NameHasOwner", GLib.Variant("(s)", (BACKEND,)), None, Gio.DBusCallFlags.NONE, 1000, None).unpack()[0]
                wait_for(owned, "backend bus name")
                version = bus.call_sync(BACKEND, PATH, "org.freedesktop.DBus.Properties", "Get", GLib.Variant("(ss)", (IFACE, "version")), None, Gio.DBusCallFlags.NONE, 2000, None).unpack()[0]
                assert version == 3, version
                sequence = 0
                def windows():
                    return [w for w in ipc.get_windows() if w["app_id"] == "rediwm-file-chooser"]
                def key(code, ctrl=False):
                    if ctrl: ipc.key(29, True)
                    ipc.key_down_up(code)
                    if ctrl: ipc.key(29, False)
                    time.sleep(.12)
                def start(method, options=None, connection=None):
                    nonlocal sequence
                    sequence += 1
                    handle = f"/org/freedesktop/portal/desktop/request/test/r{sequence}"
                    opts = {"current_folder": GLib.Variant("ay", os.fsencode(docs) + b"\0")}
                    opts.update(options or {})
                    result = []
                    def call():
                        try:
                            reply = (connection or bus).call_sync(BACKEND, PATH, IFACE, method,
                                GLib.Variant("(osssa{sv})", (handle, "org.test.Chooser", "", "Test file dialog", opts)),
                                None, Gio.DBusCallFlags.NONE, 15000, None)
                            result.append(reply.unpack())
                        except Exception as error:
                            result.append(error)
                    thread = threading.Thread(target=call)
                    thread.start()
                    window = wait_for(lambda: next(iter(windows()), None), f"{method} dialog")
                    ipc.focus_window(window["id"])
                    time.sleep(.3)
                    return handle, thread, result, window
                def finish(request):
                    _, thread, result, _ = request
                    thread.join(timeout=5)
                    assert not thread.is_alive(), "portal call did not complete"
                    assert result and not isinstance(result[0], Exception), result
                    wait_for(lambda: not windows(), "dialog closes")
                    return result[0]
                def click(window, x, y):
                    ipc.click_at(round(window["x"] + 1 + x), round(window["y"] + 61 + y))
                    time.sleep(.15)

                filters = GLib.Variant("a(sa(us))", [("Text files", [(0, "*.txt")])])
                request = start("OpenFile", {"filters": filters})
                if preview := os.environ.get("REDIWM_CHOOSER_PREVIEW"):
                    ipc.screenshot(preview)
                key(108)  # first filtered file
                key(28)
                code, result = finish(request)
                assert code == 0 and result["uris"] == [(docs / "alpha.txt").as_uri()], (code, result)
                assert result["current_filter"] == ("Text files", [(0, "*.txt")]), result
                print("open uses Files selection and returns its filter", flush=True)

                request = start("OpenFile", {"filters": filters, "multiple": GLib.Variant("b", True)})
                key(30, ctrl=True)
                key(28)
                code, result = finish(request)
                assert code == 0 and set(result["uris"]) == {(docs / "alpha.txt").as_uri(), (docs / "beta.txt").as_uri()}, result
                print("multiple selection excludes filtered files", flush=True)

                for multiple in (False, True):
                    request = start("OpenFile", {"filters": filters, "multiple": GLib.Variant("b", multiple)})
                    click(request[3], 70, 190)  # Recent, below Trash
                    if multiple:
                        key(30, ctrl=True)
                    else:
                        key(102)  # newest matching file
                    key(28)
                    code, result = finish(request)
                    expected = {recent_text.as_uri(), (docs / "beta.txt").as_uri()} if multiple else {recent_text.as_uri()}
                    assert code == 0 and set(result["uris"]) == expected, (code, result)
                print("Recent opens full paths across folders with filters and multiple selection", flush=True)

                request = start("OpenFile", {"filters": GLib.Variant("a(sa(us))", [("Text files", [(0, "*.txt")]), ("Images", [(0, "*.png")])])})
                click(request[3], 650, 490)
                key(108)
                key(28)
                click(request[3], 350, 180)
                key(28)
                code, result = finish(request)
                assert code == 0 and result["uris"] == [(docs / "image.png").as_uri()], result
                assert result["current_filter"][0] == "Images", result
                print("file-type menu changes the visible files and returned filter", flush=True)

                request = start("SaveFile", {"current_name": GLib.Variant("s", "choices.txt"), "choices": GLib.Variant("a(ssa(ss)s)", [("compress", "Compress", [], "false"), ("quality", "Quality", [("low", "Low"), ("high", "High")], "low")])})
                key(15)  # filter
                key(15)  # boolean choice
                key(57)
                key(15)  # enum choice
                key(57)
                key(15)  # Cancel
                key(15)  # Save
                key(28)
                code, result = finish(request)
                assert code == 0 and result["choices"] == [("compress", "true"), ("quality", "high")], result
                print("custom portal choices are keyboard accessible and returned", flush=True)

                request = start("SaveFile", {"current_name": GLib.Variant("s", "new file.txt")})
                key(28)
                code, result = finish(request)
                assert code == 0 and result["uris"] == [(docs / "new file.txt").as_uri()], result
                assert not (docs / "new file.txt").exists()
                request = start("SaveFile", {"current_name": GLib.Variant("s", "alpha.txt")})
                key(28)
                assert request[1].is_alive() and windows(), "overwrite was not confirmed"
                key(28)
                code, result = finish(request)
                assert code == 0 and result["uris"] == [(docs / "alpha.txt").as_uri()]
                assert (docs / "alpha.txt").read_text() == "keep this"
                print("save returns a destination and confirms replacement without writing it", flush=True)

                request = start("OpenFile", {"directory": GLib.Variant("b", True)})
                # Breadcrumb Home goes up without typing.
                click(request[3], 144, 28)
                key(28)
                code, result = finish(request)
                assert code == 0 and result["uris"] == [home.as_uri()], result
                print("clickable breadcrumbs and directory selection", flush=True)

                request = start("OpenFile", {"directory": GLib.Variant("b", True)})
                key(38, ctrl=True)
                ipc.type_text(str(home))
                key(28)
                key(28)
                assert finish(request)[1]["uris"] == [home.as_uri()]
                print("Ctrl+L accepts a pasted path", flush=True)

                request = start("SaveFiles", {"files": GLib.Variant("aay", [b"alpha.txt\0", b"new.txt\0"])})
                key(28)
                code, result = finish(request)
                assert code == 0 and result["uris"] == [(docs / "alpha.txt.1").as_uri(), (docs / "new.txt").as_uri()], result
                print("batch save chooses non-conflicting names", flush=True)

                request = start("OpenFile")
                key(1)
                assert finish(request) == (1, {})
                request = start("SaveFile")
                bus.call_sync(BACKEND, request[0], "org.freedesktop.impl.portal.Request", "Close", None, None, Gio.DBusCallFlags.NONE, 2000, None)
                assert finish(request) == (1, {})
                sequence -= 1  # Reusing a completed request path must be safe.
                request = start("OpenFile")
                key(1)
                assert finish(request) == (1, {})
                print("Escape and portal Close cancel; completed request paths can be reused", flush=True)

                # A different bus peer cannot cancel someone else's request.
                request = start("OpenFile")
                outsider = Gio.DBusConnection.new_for_address_sync(os.environ["DBUS_SESSION_BUS_ADDRESS"], Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION, None, None)
                try:
                    outsider.call_sync(BACKEND, request[0], "org.freedesktop.impl.portal.Request", "Close", None, None, Gio.DBusCallFlags.NONE, 2000, None)
                    raise AssertionError("foreign caller cancelled the request")
                except GLib.Error as error:
                    assert "AccessDenied" in str(error), error
                outsider.close_sync(None)
                key(1)
                assert finish(request) == (1, {})
                print("request cancellation is restricted to its caller", flush=True)

                departed = Gio.DBusConnection.new_for_address_sync(os.environ["DBUS_SESSION_BUS_ADDRESS"], Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION, None, None)
                request = start("OpenFile", connection=departed)
                departed.close_sync(None)
                request[1].join(timeout=5)
                wait_for(lambda: not windows(), "disconnected caller's dialog closes")
                print("caller disconnect closes its dialog", flush=True)

                # Exercise the public frontend used by applications, including
                # its asynchronous Request.Response signal.
                xdp = next((p for p in ("/usr/lib/xdg-desktop-portal", "/usr/libexec/xdg-desktop-portal") if os.access(p, os.X_OK)), None)
                if xdp:
                    descriptors = tmp / "portals"
                    descriptors.mkdir()
                    shutil.copy(ROOT / "data/rediwm.portal", descriptors)
                    shutil.copy(ROOT / "data/rediwm-portals.conf", descriptors)
                    portal_env = dict(os.environ, XDG_DESKTOP_PORTAL_DIR=str(descriptors), XDG_CURRENT_DESKTOP="rediwm", XDG_CONFIG_HOME=str(cfg), XDG_RUNTIME_DIR=str(tmp), GIO_USE_VFS="local")
                    portal_env.pop("DISPLAY", None)
                    portal_env.pop("WAYLAND_DISPLAY", None)
                    with (tmp / "portal.log").open("w") as portal_log:
                        frontend = subprocess.Popen([xdp, "--verbose"], env=portal_env, stdout=portal_log, stderr=subprocess.STDOUT)
                        try:
                            def frontend_owned():
                                return bus.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "NameHasOwner", GLib.Variant("(s)", ("org.freedesktop.portal.Desktop",)), None, Gio.DBusCallFlags.NONE, 1000, None).unpack()[0]
                            wait_for(frontend_owned, "portal frontend")
                            replies = []
                            subscription = bus.signal_subscribe("org.freedesktop.portal.Desktop", "org.freedesktop.portal.Request", "Response", None, None, Gio.DBusSignalFlags.NONE, lambda conn, sender, path, iface, signal, parameters, data: replies.append(parameters.unpack()), None)
                            try:
                                bus.call_sync("org.freedesktop.portal.Desktop", PATH, "org.freedesktop.portal.FileChooser", "OpenFile", GLib.Variant("(ssa{sv})", ("", "Public portal dialog", {"current_folder": GLib.Variant("ay", os.fsencode(docs) + b"\0"), "filters": filters})), None, Gio.DBusCallFlags.NONE, 5000, None)
                                window = wait_for(lambda: next(iter(windows()), None), "frontend dialog")
                                ipc.focus_window(window["id"])
                                time.sleep(.3)
                                key(108)
                                key(28)
                                def response():
                                    while GLib.MainContext.default().iteration(False):
                                        pass
                                    return replies
                                wait_for(response, "public portal response")
                                assert replies[0][0] == 0 and replies[0][1]["uris"] == [(docs / "alpha.txt").as_uri()], replies
                                print("real xdg-desktop-portal returns the chosen file to an application", flush=True)
                            finally:
                                bus.signal_unsubscribe(subscription)
                        finally:
                            stop_process(frontend)
                            if sys.exc_info()[0]:
                                print((tmp / "portal.log").read_text()[-4000:], file=sys.stderr)
                else:
                    print("SKIP: public frontend (xdg-desktop-portal not installed)", flush=True)

                ipc.open_control_center()
                ui = UIDriver(ipc)
                ui.wait_settled("control_center")
                field = ui.find("portal_file_chooser", "control_center")
                ipc.click_widget(field["path"])
                key(108)
                key(28)
                wait_for(lambda: "org.freedesktop.impl.portal.FileChooser=gtk" in portals.read_text(), "portal preference saved")
                assert "org.freedesktop.impl.portal.ScreenCast=wlr" in portals.read_text()
                assert "org.freedesktop.impl.portal.Settings=rediwm;gtk" in portals.read_text()
                assert "default=gtk" in portals.read_text()
                field = ui.find("portal_default", "control_center")
                ipc.click_widget(field["path"])
                key(108)
                key(28)
                wait_for(lambda: "default=kde" in portals.read_text(), "default portal preference saved")
                assert "org.freedesktop.impl.portal.FileChooser=gtk" in portals.read_text()
                assert "org.freedesktop.impl.portal.ScreenCast=wlr" in portals.read_text()
                print("Settings persists default and chooser preferences independently", flush=True)
        finally:
            stop_process(proc)
            log.close()
            if sys.exc_info()[0]:
                print((tmp / "compositor.log").read_text()[-6000:], file=sys.stderr)


if __name__ == "__main__":
    os.umask(0o077)
    if "--private-bus" not in sys.argv:
        with tempfile.TemporaryDirectory(prefix="rediwm-chooser-bus-") as directory:
            root = Path(directory)
            (root / "home").mkdir()
            env = dict(os.environ, HOME=str(root / "home"), XDG_RUNTIME_DIR=str(root),
                       XDG_CONFIG_HOME=str(root / "config"), XDG_DATA_HOME=str(root / "data"),
                       XDG_CACHE_HOME=str(root / "cache"), XDG_STATE_HOME=str(root / "state"),
                       GIO_USE_VFS="local", DBUS_SYSTEM_BUS_ADDRESS="unix:path=/nonexistent-rediwm-test-system-bus")
            try:
                status = subprocess.call(["dbus-run-session", "--", sys.executable, __file__, "--private-bus"], env=env)
            finally:
                # The private document portal may leave its test FUSE mount
                # behind as the bus exits. Unmount only our temporary runtime.
                if unmount := shutil.which("fusermount3"):
                    subprocess.run([unmount, "-u", "-z", str(root / "doc")], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            raise SystemExit(status)
    run()

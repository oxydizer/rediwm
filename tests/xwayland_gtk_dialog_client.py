#!/usr/bin/env python3
"""Real-GTK fixture for tests/xwayland.py's transient-dialog stacking/focus
and file-dialog checks.

The plain "dialog" command opens a top-level GtkDialog with
WM_TRANSIENT_FOR set to the main window - a managed X11 window (not
override-redirect), unlike xwayland_gtk_client.py's popup menu. Exercises
Toplevel.owner() / World.raiseTransientChildren() / the focus-restore-to-
owner path in Toplevel.handleUnmapped(), none of which the override-redirect
popup path touches.

The "filedialog" command opens a real Gtk.FileChooserDialog instead - the
specific dialog type the plan calls out by name, distinct from a generic
GtkDialog mainly in how much is going on inside it (a places sidebar, a
file listing, action buttons), which is exactly what "stays aligned and
clickable" needs a real instance of to mean anything.

Speaks line commands on stdin, one status line per event on stdout. Never
touches the host DISPLAY; the test harness sets ours via the environment.
"""
import sys
import json

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Gdk, GLib, Gtk  # noqa: E402

window = None
dialog = None
filedialog = None
owner_destroyed = False


def emit(line):
    print(line, flush=True)


def open_dialog():
    global dialog
    if dialog is not None:
        return
    dialog = Gtk.Dialog(title="Dialog", transient_for=window, modal=True)
    dialog.add_button("OK", Gtk.ResponseType.OK)
    dialog.set_default_size(200, 100)
    dialog.connect("map-event", lambda *_a: (emit("dialog-mapped"), False)[1])
    dialog.connect("unmap-event", lambda *_a: (emit("dialog-unmapped"), False)[1])

    def on_destroy(_widget):
        global dialog
        dialog = None
        emit("dialog-destroyed")
        if owner_destroyed:
            Gtk.main_quit()

    dialog.connect("destroy", on_destroy)
    dialog.show()
    emit("dialog-created")


def close_dialog():
    if dialog is not None:
        dialog.destroy()


def open_filedialog():
    global filedialog
    if filedialog is not None:
        return
    filedialog = Gtk.FileChooserDialog(
        title="Open File", transient_for=window, action=Gtk.FileChooserAction.OPEN,
        use_header_bar=False,
    )
    filedialog.add_buttons("_Cancel", Gtk.ResponseType.CANCEL, "_Open", Gtk.ResponseType.OK)
    filedialog.set_default_size(400, 300)
    filedialog.add_events(Gdk.EventMask.BUTTON_PRESS_MASK)
    filedialog.connect("button-press-event", lambda *_a: emit("filedialog-clicked"))
    filedialog.connect("map-event", lambda *_a: (emit("filedialog-mapped"), False)[1])
    filedialog.connect("response", lambda _d, resp: emit(f"filedialog-response {int(resp)}"))

    def on_destroy(_widget):
        global filedialog
        filedialog = None
        emit("filedialog-destroyed")

    filedialog.connect("destroy", on_destroy)
    filedialog.show()
    emit("filedialog-created")


def handle_command(line):
    line = line.strip()
    if line == "dialog":
        open_dialog()
    elif line == "close_dialog":
        close_dialog()
    elif line == "filedialog":
        open_filedialog()
    elif line == "filedialog_geometry":
        button = filedialog.get_widget_for_response(Gtk.ResponseType.CANCEL)
        x, y = button.translate_coordinates(filedialog, 0, 0)
        a = button.get_allocation()
        emit("filedialog-button " + json.dumps({"x": x + a.width / 2, "y": y + a.height / 2}))
    elif line == "close_filedialog":
        if filedialog is not None:
            filedialog.destroy()
    elif line == "close":
        window.close()
    elif line == "destroy_owner":
        global owner_destroyed
        owner_destroyed = True
        window.destroy()
        emit("owner-destroyed")
    elif line == "quit":
        Gtk.main_quit()


def on_stdin(fd, _condition):
    line = fd.readline()
    if not line:
        Gtk.main_quit()
        return False
    handle_command(line)
    return True


def main():
    global window
    window = Gtk.Window(title="GTK Dialog Fixture")
    window.set_wmclass("gtk-xwayland-dialog-fixture", "GtkXwaylandDialogFixture")
    window.set_default_size(300, 200)
    window.connect("destroy", lambda *_a: None if owner_destroyed else Gtk.main_quit())
    window.show_all()
    GLib.io_add_watch(sys.stdin, GLib.IO_IN, on_stdin)
    emit("created")
    Gtk.main()


if __name__ == "__main__":
    main()

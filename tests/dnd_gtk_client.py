#!/usr/bin/env python3
"""Real-GTK drag-and-drop fixture for tests/xwayland.py's DnD check.

Runs as either a drag source or a drag destination (argv[1]), and as either
an X11 client (GDK_BACKEND=x11) or a native Wayland client
(GDK_BACKEND=wayland) - GDK's DnD API is backend-agnostic, so the same
script covers all four source/destination x X11/Wayland combinations. The
actual drag gesture (press, move, release) is driven externally via the
compositor's IPC Drag action - this fixture only responds to the signals
GTK fires when the seat delivers drag protocol events.

Offers/accepts both text/plain and text/uri-list targets so one drag
exercises both text and URI DnD at once. Prints one status line per event on
stdout. Never touches the host DISPLAY/WAYLAND_DISPLAY; the test harness
sets ours via the environment.
"""
import sys

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Gdk, GLib, Gtk  # noqa: E402

DRAG_TEXT = "drag-payload-text"
DRAG_URI = "file:///tmp/drag-test-file.txt"

TARGETS = [
    Gtk.TargetEntry.new("text/uri-list", 0, 0),
    Gtk.TargetEntry.new("text/plain", 0, 1),
]

window = None


def emit(line):
    print(line, flush=True)


def build_source():
    box = Gtk.EventBox()
    box.drag_source_set(Gdk.ModifierType.BUTTON1_MASK, TARGETS, Gdk.DragAction.COPY)

    def on_drag_data_get(_widget, _context, selection_data, info, _time):
        if info == 0:
            selection_data.set_uris([DRAG_URI])
            emit(f"drag-data-get text/uri-list {DRAG_URI}")
        else:
            selection_data.set_text(DRAG_TEXT, -1)
            emit(f"drag-data-get text/plain {DRAG_TEXT}")

    box.connect("drag-data-get", on_drag_data_get)
    box.connect("drag-begin", lambda *_a: emit("drag-begin"))
    box.connect("drag-end", lambda *_a: emit("drag-end"))
    window.add(box)


def build_dest():
    box = Gtk.EventBox()
    box.drag_dest_set(Gtk.DestDefaults.ALL, TARGETS, Gdk.DragAction.COPY)

    def on_drag_data_received(_widget, _context, _x, _y, selection_data, info, _time):
        if info == 0:
            uris = selection_data.get_uris()
            emit(f"drag-data-received text/uri-list {list(uris)}")
        else:
            text = selection_data.get_text()
            emit(f"drag-data-received text/plain {text}")

    box.connect("drag-data-received", on_drag_data_received)
    box.connect("drag-motion", lambda *_a: emit("drag-motion"))
    box.connect("drag-drop", lambda *_a: emit("drag-drop"))
    window.add(box)


def handle_command(line):
    if line.strip() == "quit":
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
    role = sys.argv[1]
    window = Gtk.Window(title=f"GTK DnD Fixture ({role})")
    window.set_wmclass(f"gtk-dnd-fixture-{role}", f"GtkDndFixture{role.capitalize()}")
    window.set_default_size(200, 150)
    window.connect("destroy", lambda *_a: Gtk.main_quit())
    if role == "source":
        build_source()
    elif role == "dest":
        build_dest()
    else:
        raise SystemExit(f"unknown role: {role}")
    window.show_all()
    GLib.io_add_watch(sys.stdin, GLib.IO_IN, on_stdin)
    emit("created")
    Gtk.main()


if __name__ == "__main__":
    main()

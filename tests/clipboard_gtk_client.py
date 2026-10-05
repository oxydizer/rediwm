#!/usr/bin/env python3
"""Real-GTK clipboard fixture for tests/xwayland.py's bidirectional clipboard
check. The same script runs as either an X11 client (GDK_BACKEND=x11) or a
native Wayland client (GDK_BACKEND=wayland) - GDK's clipboard API is backend-
agnostic, so this exercises whichever side wlroots' XWM selection bridge is
supposed to translate through, without a separate fixture per backend.

Set CLIPBOARD_SELECTION=primary to use the PRIMARY selection instead of
CLIPBOARD (X11's "select text, middle-click to paste" selection - distinct
from the regular copy/paste clipboard).

Speaks line commands on stdin, one status line per event on stdout. Never
touches the host DISPLAY/WAYLAND_DISPLAY; the test harness sets ours via the
environment.
"""
import os
import sys

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Gdk, GLib, Gtk  # noqa: E402

window = None
SELECTION = Gdk.SELECTION_PRIMARY if os.environ.get("CLIPBOARD_SELECTION") == "primary" else Gdk.SELECTION_CLIPBOARD


def emit(line):
    print(line, flush=True)


def do_copy(text):
    clipboard = Gtk.Clipboard.get(SELECTION)
    clipboard.set_text(text, -1)
    emit(f"copied {len(text)} bytes")


def do_paste():
    clipboard = Gtk.Clipboard.get(SELECTION)
    text = clipboard.wait_for_text()
    if text is None:
        emit("pasted-none")
    else:
        emit(f"pasted {len(text)} bytes: {text[:80]!r}")


def on_key_press(_widget, event):
    if event.keyval in (Gdk.KEY_v, Gdk.KEY_V) and event.state & Gdk.ModifierType.CONTROL_MASK:
        do_paste()
    return False


def on_button_press(_widget, event):
    if event.button == 2:
        do_paste()
        return True
    return False


def handle_command(line):
    line = line.rstrip("\n")
    if line.startswith("copy "):
        do_copy(line[len("copy "):])
    elif line == "paste":
        do_paste()
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
    window = Gtk.Window(title="GTK Clipboard Fixture")
    window.set_wmclass("gtk-clipboard-fixture", "GtkClipboardFixture")
    window.set_default_size(200, 100)
    window.connect("destroy", lambda *_a: Gtk.main_quit())
    window.connect("key-press-event", on_key_press)
    window.add_events(Gdk.EventMask.BUTTON_PRESS_MASK)
    window.connect("button-press-event", on_button_press)
    window.show_all()
    GLib.io_add_watch(sys.stdin, GLib.IO_IN, on_stdin)
    emit("created")
    Gtk.main()


if __name__ == "__main__":
    main()

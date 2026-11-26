#!/usr/bin/env python3
"""Real-GTK fixture for tests/xwayland.py's context-menu alignment check.

Unlike tests/xwayland_client.c (a synthetic XCB window that never sets
WM_TRANSIENT_FOR on its popup), this spawns an actual GtkMenu. GDK sets a
real transient-for hint on the popup's override-redirect X window, so this
exercises xwayland_unmanaged.zig's parent-relative syncPosition() math, not
just the position-equals-root-coordinates fallback path.

Speaks line commands on stdin, one status line per event on stdout. Never
touches the host DISPLAY; the test harness sets ours via the environment.
"""
import os
import sys

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Gdk, GLib, Gtk  # noqa: E402

window = None
menu = None
combo = None
tooltip_button = None


def emit(line):
    print(line, flush=True)


def build_menu():
    m = Gtk.Menu()
    for label in ("One", "Two", "Three"):
        item = Gtk.MenuItem(label=label)
        item.connect("activate", lambda _item, name=label: emit(f"activated {name}"))
        item.show()
        m.append(item)
    m.attach_to_widget(window, None)
    return m


def on_button_press(_widget, event):
    if os.getenv("REDIWM_TEST_POINTER_LOG") and event.type == Gdk.EventType.BUTTON_PRESS:
        emit(f"button {int(event.button)} {round(event.x)} {round(event.y)}")
    if event.button == 3:
        menu.popup_at_pointer(event)
        emit("popup")
    return True


def on_button_release(_widget, event):
    emit(f"release {int(event.button)} {round(event.x)} {round(event.y)}")
    return True


def on_configure_event(_widget, event):
    emit(f"configure {event.x} {event.y} {event.width} {event.height}")
    return False


def handle_command(line):
    line = line.strip()
    if line == "close":
        window.close()
    elif line == "popdown":
        menu.popdown()
    elif line.startswith("resize "):
        w, h = (int(v) for v in line.split()[1:3])
        window.resize(w, h)
    elif line == "combo":
        combo.popup()
        emit("combo-popup")
    elif line == "tooltip":
        Gtk.Tooltip.trigger_tooltip_query(Gdk.Display.get_default())
        emit("tooltip-query")
    elif line.startswith("xwm-barrier "):
        # Let GTK finish repainting after ConfigureNotify, including its opaque
        # region property. Publish one final property on the same X connection
        # so the harness can observe wlroots consuming everything before it.
        title = line.split(" ", 1)[1]
        clock = window.get_frame_clock()
        def after_paint(clock):
            clock.disconnect(handler)
            window.get_window().set_utf8_property("_NET_WM_NAME", title)
            Gdk.Display.get_default().flush()
        handler = clock.connect("after-paint", after_paint)
        window.queue_draw()
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
    global window, menu, combo, tooltip_button
    window = Gtk.Window(title=os.getenv("REDIWM_TEST_TITLE", "GTK Xwayland Fixture"))
    window.set_wmclass("gtk-xwayland-fixture", "GtkXwaylandFixture")
    window.set_default_size(300, 200)
    window.add_events(Gdk.EventMask.BUTTON_PRESS_MASK)
    window.connect("button-press-event", on_button_press)
    if os.getenv("REDIWM_TEST_POINTER_LOG"):
        window.connect("enter-notify-event", lambda w, e: emit(f"enter {round(e.x)} {round(e.y)}"))
        window.add_events(Gdk.EventMask.BUTTON_RELEASE_MASK)
        window.connect("button-release-event", on_button_release)
    window.connect("configure-event", on_configure_event)
    window.connect("destroy", lambda *_a: Gtk.main_quit())
    fixed = Gtk.Fixed()
    window.add(fixed)
    combo = Gtk.ComboBoxText()
    for label in ("Alpha", "Beta", "Gamma"):
        combo.append_text(label)
    combo.set_active(0)
    fixed.put(combo, 170, 20)
    tooltip_button = Gtk.Button(label="Hover me")
    tooltip_button.set_tooltip_text("Xwayland tooltip")
    fixed.put(tooltip_button, 170, 100)
    menu = build_menu()
    menu.connect("hide", lambda *_a: emit("menu-hidden"))
    window.show_all()
    GLib.io_add_watch(sys.stdin, GLib.IO_IN, on_stdin)
    emit("created")
    Gtk.main()


if __name__ == "__main__":
    main()

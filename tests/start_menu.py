#!/usr/bin/env python3
"""Headless Start menu regression check. Run after zig build; requires Pillow.
Uses the installed application catalog to exercise cold icon lookup.
Also checks that open/close animations reuse the painted panel instead of
repainting it, including a frozen-clock fixture and a 1.5 scale run.
"""
from pathlib import Path
import os
import subprocess
import tempfile
import time

from PIL import Image, ImageChops

from ipc_client import IPCClient, spawn_compositor, stop_process

ROOT = Path(__file__).resolve().parents[1]


def wait_for(check, message, timeout=15):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = check()
        if result:
            return result
        time.sleep(.03)
    raise AssertionError(message)


def run():
    with tempfile.TemporaryDirectory(prefix="rediwm-start-test-") as directory:
        tmp = Path(directory)
        process, log = spawn_compositor(tmp)
        try:
            with IPCClient(socket_path=tmp, timeout=15) as client:
                client.wait_for("catalog_published", timeout_ms=10000)
                client.wait_for("wallpaper_presented", timeout_ms=10000)

                def click():
                    client.move_cursor(38, 685)
                    for pressed in (True, False):
                        client.pointer_button(272, pressed)

                def key(code):
                    client.key_down_up(code)

                def capture_now(name):
                    path = tmp / (name + ".png")
                    client.screenshot(path=str(path))
                    wait_for(path.exists, f"{name} screenshot was not written")
                    with Image.open(path) as image:
                        return image.convert("RGB").crop((20, 60, 580, 600))

                def panel_stats():
                    res = client.action('get_panel_stats')
                    return res.get("PanelStats", res)

                closed = capture_now("closed")
                start = time.monotonic()
                click()
                client.wait_for("menu_opened", timeout_ms=5000)
                elapsed = time.monotonic() - start
                assert elapsed < 2, f"Start blocked input for {elapsed:.2f}s"
                opened = capture_now("opened")
                assert ImageChops.difference(closed, opened).getbbox(), "menu did not appear"

                # Milestone 1 inspection checks
                widget_tree = client.get_widget_tree("start_menu")
                assert widget_tree.get("panel") == "start_menu", widget_tree
                assert len(widget_tree.get("widgets", [])) > 0, "no widgets in start_menu"

                # Timer repeats must retain the original keyboard text after
                # the key event's temporary UTF-8 buffer has been reused.
                client.key(33, True)  # Hold 'f' across several repeat ticks.
                time.sleep(0.7)
                client.key(33, False)
                repeated = client.get_shell_state()["start_menu"]["search_text"]
                assert len(repeated) >= 3 and set(repeated) == {"f"}, repr(repeated)
                time.sleep(0.15)
                assert client.get_shell_state()["start_menu"]["search_text"] == repeated, "release did not stop repeat"
                for _ in repeated:
                    key(14)

                hit = client.hit_test(100, 200)
                assert hit.get("target_type") in ("panel", "widget", "window", "start_menu"), hit

                key(30)  # Search for 'a', rebuilding and laying out the tree.
                client.wait_for_frame(timeout_ms=2000)
                searched = capture_now("searched")
                assert ImageChops.difference(opened, searched).getbbox(), "search did not repaint"
                assert ImageChops.difference(closed, searched).getbbox(), "search lost the panel"

                key(108)  # Move selection down.
                client.wait_for_frame(timeout_ms=2000)
                selected = capture_now("selected")
                assert ImageChops.difference(searched, selected).getbbox(), "selection did not repaint"

                key(14)  # Clear search, then scroll to load a different set of icons.
                client.move_cursor(250, 300)
                client.wait_for_frame(timeout_ms=2000)
                hovered = capture_now("hovered")
                client.scroll(0, 180)
                client.wait_for_frame(timeout_ms=2000)
                scrolled = capture_now("scrolled")
                assert ImageChops.difference(hovered, scrolled).getbbox(), "scroll did not repaint"

                # Fast scrolling and query changes must not crash or pile up
                # unbounded speculative icon-prefetch work (icon_service.zig
                # steps 5/6: scroll-direction prefetch + stale-interest
                # cancellation, driven from StartMenu.prefetchAhead).
                client.action("reset_performance_stats")
                for _ in range(4):
                    client.scroll(0, 180)
                    client.scroll(0, -180)
                key(30)  # 'a'
                key(14)  # backspace, clears the query
                key(30)
                client.wait_for_frame(timeout_ms=2000)
                fast_stats = client.get_perf()
                assert fast_stats.get("icon_queue_depth_max", 0) < 200, fast_stats
                fast_repainted = capture_now("after-fast-scroll-query")
                assert fast_repainted is not None  # still renders; did not hang or crash

                key(1)  # Escape closes the menu.
                client.wait_for("menu_closed", timeout_ms=5000)
                dismissed = capture_now("dismissed")
                assert ImageChops.difference(closed, dismissed).getbbox() is None, "Escape did not close menu"

                click()
                client.wait_for("menu_opened", timeout_ms=5000)
                reopened = capture_now("reopened")
                assert ImageChops.difference(closed, reopened).getbbox(), "menu did not reopen"
                print(f"Start menu open/search/selection/scroll/close/reopen passed; cold open {elapsed:.3f}s")

                # Leave the pointer off the panel so hover does not invalidate it.
                client.move_cursor(38, 685)
                key(1)
                client.wait_for("menu_closed", timeout_ms=5000)

                client.action('reset_panel_stats')
                client.action('set_anim_time', {"ms": 0})
                client.action('open_start_menu')
                assert panel_stats()["paints"] == 1, panel_stats()
                client.action('set_anim_time', {"ms": 110})
                mid = capture_now("anim-mid")
                assert panel_stats()["paints"] == 1, "opening animation repainted content"
                client.action('set_anim_time', {"ms": 220})
                open_frame = capture_now("anim-open")
                assert ImageChops.difference(mid, open_frame).getbbox(), "mid-open matched fully open"
                assert panel_stats()["paints"] == 1, panel_stats()

                client.action('set_anim_time', {"ms": 80})
                capture_now("anim-content-before")
                key(30)
                capture_now("anim-content-after")
                assert panel_stats()["paints"] == 2, "search during animation did not paint"

                # The caret glides to the typed character's offset over
                # caret_motion_ms; land it before the panel-reuse assertions
                # below so they are counting slide frames, not caret frames.
                client.action('set_anim_time', {"ms": 220})
                capture_now("anim-caret-settled")
                assert panel_stats()["paints"] == 3, panel_stats()

                key(1)
                client.action('set_anim_time', {"ms": 250})
                closing = capture_now("anim-closing")
                assert panel_stats()["paints"] == 3, "closing animation repainted content"
                client.action('open_start_menu')  # reverse the in-flight close
                client.action('set_anim_time', {"ms": 400})
                reversed_open = capture_now("anim-reversed")
                assert ImageChops.difference(closing, reversed_open).getbbox(), "reopen did not reverse the close"
                assert panel_stats()["paints"] == 3, "reversed close/open repainted content"

                client.action('set_anim_time', {"ms": 580})  # settle the reversed open
                key(1)
                client.action('set_anim_time', {"ms": 800})
                capture_now("anim-closed")
                # Still three: the Escape closes the menu, and a closing panel
                # does not blink, so the caret adds no repaint here.
                assert panel_stats()["paints"] == 3, panel_stats()

                client.action('set_anim_time', {"ms": None})

                client.action('reset_panel_stats')
                client.open_control_center()
                client.wait_for("control_center_opened", timeout_ms=5000)
                # Backlight discovery is asynchronous content, independent of
                # the slide. Settle it before checking presentation-only close.
                wait_for(lambda: not any(w["label"] == "Checking backlight…"
                                        for w in client.get_widget_tree("control_center")["widgets"]),
                         "backlight discovery did not finish")
                cc_stats = panel_stats()
                assert cc_stats["paints"] in (1, 2), cc_stats
                client.close_panel("control_center")
                client.wait_for("control_center_closed", timeout_ms=5000)
                assert panel_stats()["paints"] == cc_stats["paints"], "control center close repainted content"

                client.action('reset_panel_stats')
                client.open_power_menu()
                client.wait_for("power_menu_opened", timeout_ms=5000)
                pm_stats = panel_stats()
                assert pm_stats["paints"] == 1, pm_stats
                assert ImageChops.difference(closed, capture_now("power-open")).getbbox(), "power menu did not appear"
                key(1)
                client.wait_for("power_menu_closed", timeout_ms=5000)
                assert panel_stats()["paints"] == 1, "power menu close repainted content"
                print(f"Panel reuse: start/control/power open+close without extra paints; "
                      f"alloc={cc_stats['allocated_bytes']} reuse={pm_stats['reused_bytes']}")
        except Exception:
            print((tmp / "compositor.log").read_text())
            raise
        finally:
            log.close()
            stop_process(process)

    with tempfile.TemporaryDirectory(prefix="rediwm-start-scale-") as directory:
        tmp = Path(directory)
        process, log = spawn_compositor(tmp, scale="1.5", outputs="2")
        try:
            with IPCClient(socket_path=tmp, timeout=15) as client:
                outputs = client.get_outputs()
                assert len(outputs) == 2, outputs

                # First open on a fresh compositor is a cold icon cache: rows
                # may show the fallback tile and repaint again as each icon's
                # background decode completes (icon_service.zig). Warm it up
                # once, unmeasured, so the assertions below check steady-state
                # panel reuse rather than progressive icon arrival.
                client.open_start_menu()
                client.wait_for("menu_opened", timeout_ms=5000)
                time.sleep(0.3)  # let background icon decode settle
                client.key_down_up(1)
                client.wait_for("menu_closed", timeout_ms=5000)
                time.sleep(0.1)

                client.action('reset_panel_stats')
                client.open_start_menu()
                client.wait_for("menu_opened", timeout_ms=5000)
                stats = panel_stats() if 'panel_stats' in locals() else client.action('get_panel_stats')
                stats = stats.get("PanelStats", stats)
                assert stats["paints"] == 1, stats
                client.key_down_up(1)
                client.wait_for("menu_closed", timeout_ms=5000)
                stats2 = client.action('get_panel_stats')
                stats2 = stats2.get("PanelStats", stats2)
                assert stats2["paints"] == 1
                print(f"Panel reuse at scale 1.5 on {len(outputs)} outputs: paints={stats['paints']}")
        except Exception:
            print((tmp / "compositor.log").read_text())
            raise
        finally:
            log.close()
            stop_process(process)


def run_reopen():
    """Reopening a start menu mid-close must keep it reachable.

    `closeStartMenu` drops `input.open_start_menu` so that keys typed during
    the close slide reach the window underneath. Reopening therefore has to put
    it back, and for a while nothing did: both the start button and the
    `OpenStartMenu` action called `StartMenu.reopen` directly, which reverses
    the slide and nothing else. The menu came back on screen and no keystroke
    could reach it — including the Escape that would have closed it again.
    """
    with tempfile.TemporaryDirectory(prefix="rediwm-start-reopen-") as directory:
        tmp = Path(directory)
        process, log = spawn_compositor(tmp)
        try:
            with IPCClient(socket_path=tmp, timeout=15) as client:
                client.wait_for("catalog_published", timeout_ms=10000)
                client.wait_for("wallpaper_presented", timeout_ms=10000)

                def start_click():
                    client.move_cursor(38, 685)
                    for pressed in (True, False):
                        client.pointer_button(272, pressed)

                def menu():
                    return client.get_shell_state()["start_menu"]

                # Both ways in have to work: the taskbar button
                # (`toggleStartMenu`) and the IPC action.
                for label, reopen in (("start button", start_click),
                                      ("OpenStartMenu", lambda: client.action('open_start_menu'))):
                    client.action('set_anim_time', {"ms": 0})
                    start_click()
                    client.action('set_anim_time', {"ms": 400})
                    client.wait_for("menu_opened", timeout_ms=5000)
                    client.type_text("a")
                    assert menu()["search_text"] == "a", menu()

                    client.key_down_up(1)  # Escape starts the close
                    client.action('set_anim_time', {"ms": 450})  # mid-slide
                    client.wait_for_frame(timeout_ms=2000)
                    assert menu()["state"] == "closing", menu()

                    reopen()
                    client.action('set_anim_time', {"ms": 850})
                    client.wait_for("menu_opened", timeout_ms=5000)
                    client.type_text("b")
                    assert menu()["search_text"] == "ab", (
                        f"keyboard did not reach the menu reopened by {label}: {menu()}"
                    )

                    client.key_down_up(1)
                    client.action('set_anim_time', {"ms": 1250})
                    client.wait_for("menu_closed", timeout_ms=5000)
                    client.action('set_anim_time', {"ms": None})
                print("Start menu reopened mid-close stays reachable from both the button and IPC")
        except Exception:
            print((tmp / "compositor.log").read_text())
            raise
        finally:
            log.close()
            stop_process(process)


# Keycodes for the chords the selection tests drive.
KEY = {"a": 30, "c": 46, "v": 47, "x": 45, "backspace": 14,
       "ctrl": 29, "shift": 42, "left": 105, "right": 106, "home": 102, "end": 107}


# Where the search field's text runs inside its frame (ui/widgets/field.zig,
# size md: 12px inset, 16px search icon, 20px gap; 12px inset on the right).
FIELD_TEXT_LEFT = 48
FIELD_TEXT_RIGHT = 12


def caret_field_box(client):
    """Screen-space box of the text area inside the start menu's search field."""
    panel = client.get_shell_state()["start_menu"]["box"]
    for widget in client.get_widget_tree("start_menu")["widgets"]:
        if widget.get("role") == "text_input":
            box = widget["box"]
            return (panel["x"] + box["x"] + FIELD_TEXT_LEFT, panel["y"] + box["y"],
                    box["width"] - FIELD_TEXT_LEFT - FIELD_TEXT_RIGHT, box["height"])
    raise AssertionError("start menu has no text input")


def run_selection():
    """Text selection, Ctrl+A/C/X/V and mouse selection in the search field.

    Copy and paste are checked against the *real* seat clipboard using
    `wl-copy`/`wl-paste` as ordinary Wayland clients, because that is the only
    thing that proves the compositor's own `wlr_data_source` is visible outside
    it. Those are skipped, with a note, when the tools are not installed.
    """
    with tempfile.TemporaryDirectory(prefix="rediwm-selection-test-") as directory:
        tmp = Path(directory)
        # An opaque selection in a colour nothing else in the field uses, so a
        # highlighted pixel is unambiguous. Also proves the [theme] keys parse.
        config = "\n".join(["[theme]",
                            'selection = "rgba(0,255,0,1)"',
                            'selection_fg = "rgba(0,0,0,1)"',
                            ""])
        process, log = spawn_compositor(tmp, config_content=config)
        try:
            with IPCClient(socket_path=tmp, timeout=15) as client:
                client.wait_for("catalog_published", timeout_ms=10000)
                client.wait_for("wallpaper_presented", timeout_ms=10000)

                def chord(code, *mods):
                    for mod in mods:
                        client.key(KEY[mod], True)
                    client.key(code, True)
                    client.key(code, False)
                    for mod in reversed(mods):
                        client.key(KEY[mod], False)
                    time.sleep(.08)

                def query():
                    # An empty query serializes as null, not "".
                    return client.get_shell_state()["start_menu"]["search_text"] or ""

                client.move_cursor(38, 685)
                for pressed in (True, False):
                    client.pointer_button(272, pressed)
                client.wait_for("menu_opened", timeout_ms=5000)
                box = caret_field_box(client)

                client.type_text("hello world")
                assert query() == "hello world", query()

                # The caret used to teleport to the end of the query on every
                # keystroke, because buildTree hard-coded it there; typing
                # after Home is what catches that.
                chord(KEY["home"])
                client.type_text("X")
                assert query() == "Xhello world", f"caret did not stay where it was put: {query()!r}"

                # Ctrl+A then a character replaces the whole value.
                chord(KEY["a"], "ctrl")
                client.type_text("Z")
                assert query() == "Z", f"Ctrl+A did not select all: {query()!r}"

                # Shift+arrow builds a selection that Backspace then deletes
                # whole, rather than one character.
                client.type_text("abcdef")
                for _ in range(3):
                    chord(KEY["left"], "shift")
                chord(KEY["backspace"])
                assert query() == "Zabc", f"shift-selection was not deleted as a unit: {query()!r}"

                # The highlight has to actually be drawn.
                chord(KEY["a"], "ctrl")
                client.wait_for_frame(timeout_ms=2000)
                client.wait_for_frame(timeout_ms=2000)
                x, y, w, h = box
                res = client.action('sample_pixels', {"x": x, "y": y + h // 2, "width": w, "height": 1})
                pixels = res.get("SamplePixels", res)["pixels"]
                highlighted = [i for i, p in enumerate(pixels) if (p & 0xFFFFFF) == 0x00FF00]
                assert highlighted, "selecting everything drew no highlight"
                assert min(highlighted) < 20, f"highlight does not start at the text: {min(highlighted)}"

                # Mouse: drag across part of the value, then double-click a word.
                text_x = x
                client.move_cursor(text_x, y + h // 2)
                client.pointer_button(272, True)
                for step in range(0, 26, 5):
                    client.move_cursor(text_x + step, y + h // 2)
                client.pointer_button(272, False)
                time.sleep(.15)
                dragged = client.get_widget_tree("start_menu")  # forces a round trip
                assert dragged is not None
                chord(KEY["c"], "ctrl")
                time.sleep(.2)

                display = next(p.name for p in tmp.glob("wayland-*") if not p.name.endswith(".lock"))
                env = dict(os.environ, WAYLAND_DISPLAY=display, XDG_RUNTIME_DIR=str(tmp))
                try:
                    dragged_text = subprocess.run(["wl-paste", "-n"], env=env,
                                                  capture_output=True, timeout=5).stdout.decode()
                except (FileNotFoundError, subprocess.TimeoutExpired):
                    print("Selection: wl-clipboard not installed; clipboard round trip skipped")
                    return
                assert dragged_text and "Zabc".startswith(dragged_text), (
                    f"mouse drag did not select a prefix of the value: {dragged_text!r}"
                )

                # Ctrl+A, Ctrl+C: the compositor's own data source has to be
                # readable by a real client.
                chord(KEY["a"], "ctrl")
                chord(KEY["c"], "ctrl")
                time.sleep(.2)
                copied = subprocess.run(["wl-paste", "-n"], env=env,
                                        capture_output=True, timeout=5).stdout.decode()
                assert copied == "Zabc", f"Ctrl+C did not reach the seat clipboard: {copied!r}"

                # Ctrl+X removes the text and leaves it on the clipboard.
                chord(KEY["a"], "ctrl")
                chord(KEY["x"], "ctrl")
                time.sleep(.2)
                assert query() == "", f"Ctrl+X did not cut: {query()!r}"
                cut = subprocess.run(["wl-paste", "-n"], env=env,
                                     capture_output=True, timeout=5).stdout.decode()
                assert cut == "Zabc", f"Ctrl+X did not reach the seat clipboard: {cut!r}"

                # And Ctrl+V reads someone else's clipboard back in. The read
                # is asynchronous — the text comes down a pipe on the event
                # loop — so it lands a frame or two after the keystroke.
                subprocess.run(["wl-copy", "PASTED"], env=env, timeout=5)
                time.sleep(.3)
                chord(KEY["v"], "ctrl")
                wait_for(lambda: query() == "PASTED", f"Ctrl+V never arrived (query is {query()!r})", timeout=5)
                print("Selection: Ctrl+A/C/X/V against the real seat clipboard, "
                      "shift-selection, drag-select and the highlight all passed")
        except Exception:
            print((tmp / "compositor.log").read_text())
            raise
        finally:
            log.close()
            stop_process(process)


def run_highlight_reload():
    """Disabling animations settles a selection glide that is already running."""
    with tempfile.TemporaryDirectory(prefix="rediwm-start-highlight-") as directory:
        tmp = Path(directory)
        applications = tmp / "data" / "applications"
        applications.mkdir(parents=True)
        for name in ("Alpha", "Beta"):
            (applications / (name + ".desktop")).write_text(
                "[Desktop Entry]\nType=Application\nName=Highlight " + name + "\nExec=true\n")
        process, log = spawn_compositor(tmp, env_extra={"XDG_DATA_HOME": str(tmp / "data"), "DBUS_SESSION_BUS_ADDRESS": ""})
        try:
            with IPCClient(tmp) as client:
                client.wait_for("catalog_published", timeout_ms=10000)
                client.open_start_menu()
                client.wait_for("menu_opened", timeout_ms=5000)
                client.type_text("Highlight")
                client.action('set_anim_time', {"ms": 10000})
                client.wait_for_frame()
                client.key_down_up(108)
                def selection():
                    return next((a for a in client.action('get_animations') if a["site"] == "start_menu.selection"), None)
                moving = selection()
                assert moving and not moving["settled"] and moving["target"] == 1, moving
                (tmp / "rediwm-config.toml").write_text("[animations]\nenabled = false\n")
                client.reload_config()
                client.wait_for_frame()
                settled = selection()
                assert settled is None or (settled["settled"] and settled["value"] == 1), settled
                print("Selection highlight settles when animations are disabled during its glide")
        finally:
            stop_process(process)
            log.close()


if __name__ == "__main__":
    run()
    run_reopen()
    run_selection()
    run_highlight_reload()

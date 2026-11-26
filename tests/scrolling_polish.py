"""Stage 6 of the scrolling layout: the strip overview, the position
indicator, and motion when a column opens or closes."""
from pathlib import Path
import tempfile
import time

from PIL import Image

from desktop_zoom import build_client, wait_for
from overview import blue_windows


def polish():
    from scrolling import BASE, Session
    with tempfile.TemporaryDirectory(prefix="rediwm-strip-polish-") as directory:
        tmp = Path(directory)
        build_client(tmp)
        config = BASE.format(mode="scrolling").replace("[compositor]", "[compositor]\nmini_map_hide_ms = 500\ninactive_dim = false") + \
            '[theme]\nshell_accent = "#00ff00"\nswitcher_selected_border = "#ff00ff"\n' + \
            '[animations]\nenabled = true\nreduced_motion = "off"\n'
        s = Session(tmp, config)
        try:
            ids = [s.launch(name) for name in ("polish-a", "polish-b", "polish-c", "polish-d")]
            s.settle_all()
            check_motion(s, ids)
            check_indicator(s, ids)
            check_overview(s, ids)
        except Exception:
            s.dump_log()
            raise
        finally:
            s.stop()
    print("PASS: strip overview, position indicator, and gliding columns on open and close")


def shot(s, name):
    path = s.tmp / f"{name}.png"
    path.unlink(missing_ok=True)
    s.ipc.screenshot(path=str(path))
    with Image.open(path) as image:
        return image.convert("RGB")


def gliding(s, id):
    return any(e["site"] == f"window.{id}.move_x" and not e["settled"] for e in s.ipc.query("get_animations"))


def check_motion(s, ids):
    """A column opening after the focused one pushes the rest aside, and
    closing it brings them back, both gliding."""
    ipc = s.ipc
    a, b, c, d = ids
    ipc.focus_window(a)
    s.settle_all()
    x = s.frame(b)[0]
    s.launch("polish-new")
    wait_for(lambda: gliding(s, b), "b glides aside for the new column")
    s.settle_all()
    assert s.frame(b)[0] > x
    s.close("polish-new")
    wait_for(lambda: gliding(s, b), "b glides back when it closes")
    s.settle_all()
    assert s.frame(b)[0] == x


def indicator(image, out):
    """Green thumb pixels along the bottom gap of the display."""
    y = round((out["logical_height"] - out.get("bottom_exclusion", 0) - 6) * out["scale"])
    return sum(1 for x in range(image.width)
               if (lambda p: p[1] > 150 and p[0] < 90 and p[2] < 90)(image.getpixel((x, y))))


def check_indicator(s, ids):
    ipc = s.ipc
    out = ipc.get_outputs()[0]
    # The glides just before showed it too; at rest it fades away.
    wait_for(lambda: indicator(shot(s, "rest"), out) == 0, "no indicator at rest", timeout=4)
    # While the strip moves, a bar shows where the view is; it fades after.
    ipc.action("swipe", {"phase": "begin", "fingers": 3})
    ipc.action("swipe", {"phase": "update", "dx": -150, "dy": 0})
    ipc.wait_for_frame()
    thumb = indicator(shot(s, "moving"), out)
    width = out["logical_width"] * out["scale"]
    assert width * 0.2 < thumb < width * 0.8, (thumb, width)
    ipc.action("swipe", {"phase": "end"})
    s.settle_all()
    wait_for(lambda: indicator(shot(s, "faded"), out) == 0, "indicator fades once the strip rests", timeout=4)


def check_overview(s, ids):
    ipc = s.ipc
    a, b, c, d = ids
    ipc.focus_window(a)
    s.settle_all()
    view = s.workspace(1)["view"]
    assert view == 0 and not s.shown(d)
    # Super+A: the display zooms out over the whole strip, culled columns too.
    s.chord("a")
    rows = wait_for(lambda: (lambda r: r if len(r) == 1 and len(r[0]) == 4 else None)(blue_windows(shot(s, "overview"))),
                    "all four columns side by side")
    lefts = [box[0] for box in rows[0]]
    assert lefts == sorted(lefts)
    # Escape leaves everything as it was.
    ipc.key_press("Escape")
    # Back to the two columns on screen, full size; then the spread is done.
    wait_for(lambda: (lambda r: len(r) == 1 and len(r[0]) == 2)(blue_windows(shot(s, "closed"))), "overview closed")
    time.sleep(0.3)
    assert s.workspace(1)["view"] == view and ipc.get_focused_window()["id"] == a
    # A click on a column focuses it and the strip goes there.
    s.chord("a")
    rows = wait_for(lambda: (lambda r: r if len(r) == 1 and len(r[0]) == 4 else None)(blue_windows(shot(s, "overview2"))),
                    "overview again")
    x0, y0, x1, y1 = rows[0][3]
    scale = ipc.get_outputs()[0]["scale"]
    time.sleep(0.4)  # the spread settles before the pick
    ipc.click_at(round((x0 + x1) / 2 / scale), round((y0 + y1) / 2 / scale))
    wait_for(lambda: ipc.get_focused_window()["id"] == d, "the clicked column is focused")
    s.settle_all()
    assert s.shown(d) and s.workspace(1)["view"] > 0


if __name__ == "__main__":
    polish()

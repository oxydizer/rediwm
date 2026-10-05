#!/usr/bin/env python3
"""Integration tests for standalone rediwm-pdf in a headless Wayland session."""
import os
from pathlib import Path
import subprocess
import shutil
import tempfile
import time
import sys
import cairo
from PIL import Image
from ipc_client import IPCClient, ROOT
from files_browser import wait_for


def generate_fixture_pdf(path: Path):
    surface = cairo.PDFSurface(str(path), 300, 400)
    cr = cairo.Context(surface)

    # Page 1: Blue rectangle
    cr.set_source_rgb(0, 0, 1)
    cr.rectangle(20, 30, 80, 100)
    cr.fill()
    cr.select_font_face("Sans", cairo.FONT_SLANT_NORMAL, cairo.FONT_WEIGHT_NORMAL)
    cr.set_font_size(16)
    cr.move_to(30, 160)
    cr.show_text("Page 1 Content")
    # Strip along the bottom edge: visible only when the whole page fits.
    cr.set_source_rgb(1, 0, 1)
    cr.rectangle(0, 380, 300, 20)
    cr.fill()
    surface.show_page()

    # Page 2: Red rectangle
    cr.set_source_rgb(1, 0, 0)
    cr.rectangle(40, 50, 90, 80)
    cr.fill()
    cr.move_to(30, 160)
    cr.show_text("Page 2 Content")
    surface.show_page()

    surface.finish()


def run(scale: int = 1):
    with tempfile.TemporaryDirectory(prefix="rediwm-pdf-") as directory:
        tmp = Path(directory)
        doc_path = tmp / "document.pdf"
        generate_fixture_pdf(doc_path)

        config = tmp / "config.toml"
        config.write_text('[compositor]\nxwayland = false\n')

        env = dict(
            os.environ,
            HOME=str(tmp),
            XDG_RUNTIME_DIR=directory,
            XDG_CONFIG_HOME=str(tmp / "config"),
            XDG_DATA_HOME=str(tmp / "data"),
            XDG_DATA_DIRS=str(tmp / "data"),
            XDG_CONFIG_DIRS=str(tmp / "config"),
            XDG_CACHE_HOME=str(tmp / "cache"),
            XDG_STATE_HOME=str(tmp / "state"),
            REDIWM_CONFIG=str(config),
            WLR_BACKENDS="headless", REDIWM_FILES_DEVICES="0",
            WLR_HEADLESS_OUTPUTS="1",
            WLR_RENDERER=os.environ.get("REDIWM_TEST_RENDERER", "pixman"),
            REDIWM_SCALE=str(scale),
            DBUS_SESSION_BUS_ADDRESS="",
            DBUS_SYSTEM_BUS_ADDRESS="unix:path=/nonexistent-rediwm-test-system-bus",
        )
        env.pop("WAYLAND_DISPLAY", None)
        env.pop("REDIWM_SOCKET", None)
        processes = []

        def start(binary, *args, **extra):
            with (tmp / f"{binary}-{len(processes)}.log").open("w") as log:
                proc = subprocess.Popen(
                    [str(ROOT / "zig-out/bin" / binary), *args],
                    env=dict(env, **extra),
                    stdout=log,
                    stderr=log,
                )
            processes.append(proc)
            return proc

        try:
            start("rediwm")
            sock = wait_for(lambda: next(tmp.glob("rediwm-*.sock"), None), "IPC unavailable")
            display = next(p.name for p in tmp.glob("wayland-*") if not p.name.endswith(".lock"))

            with IPCClient(sock) as ipc:
                def windows(app):
                    return [w for w in ipc.get_windows() if w["app_id"] == app]

                def key(code, ctrl=False, shift=False):
                    if ctrl:
                        ipc.action('key', {"keycode": 29, "pressed": True})
                    if shift:
                        ipc.action('key', {"keycode": 42, "pressed": True})
                    for pressed in (True, False):
                        ipc.action('key', {"keycode": code, "pressed": pressed})
                    if shift:
                        ipc.action('key', {"keycode": 42, "pressed": False})
                    if ctrl:
                        ipc.action('key', {"keycode": 29, "pressed": False})
                    time.sleep(0.12)

                def viewer():
                    return next(iter(windows("rediwm-pdf")), None)

                def expect_title(prefix):
                    return wait_for(
                        lambda: (w := viewer()) and prefix in w["title"] and w,
                        f"viewer did not reach {prefix}",
                    )

                pdf_proc = start("rediwm-pdf", str(doc_path), WAYLAND_DISPLAY=display)
                win = wait_for(lambda: viewer(), "PDF viewer did not map")
                ipc.focus_window(win["id"])
                time.sleep(0.5)

                # Check initial title
                expect_title("(1/2)")
                assert len(windows("rediwm-pdf")) == 1
                assert win["sandbox"]["engine"] == "org.rediwm.pdf", win

                # Ctrl+O explains how to launch another viewer; it must not
                # expose a path field or replace this process's document.
                key(24, ctrl=True)
                key(1)
                expect_title("(1/2)")

                # Take screenshot to verify rendering
                shot_path = tmp / "screenshot.png"
                ipc.screenshot(path=str(shot_path))
                with Image.open(shot_path) as shot:
                    # Check for blue pixels from page 1
                    rgb = shot.convert("RGB")
                    colors = rgb.getcolors(rgb.width * rgb.height) or []
                    has_blue = any(b > 180 and r < 80 and g < 80 for n, (r, g, b) in colors)
                    assert has_blue, "Page 1 blue box did not render on screen"

                    # A new document opens fitted: the page's bottom edge is in
                    # the canvas (right of the 180px sidebar, below the 44px
                    # toolbar), not cut off at 100% zoom. Sidebar thumbnails
                    # also show the strip, hence the crop.
                    box = ipc.get_window_debug(win["id"])["client_box"]
                    canvas = rgb.crop(tuple(round(v * scale) for v in (
                        box["x"] + 180, box["y"] + 44,
                        box["x"] + box["width"], box["y"] + box["height"])))
                    canvas_colors = canvas.getcolors(canvas.width * canvas.height) or []
                    assert any(r > 200 and b > 200 and g < 60 for n, (r, g, b) in canvas_colors), \
                        "Page 1 bottom edge is clipped on open"

                # Next page via keyboard shortcut (PageDown = keycode 109)
                key(109)
                time.sleep(0.3)
                expect_title("(2/2)")

                # Prev page via keyboard shortcut (PageUp = keycode 104)
                key(104)
                time.sleep(0.3)
                expect_title("(1/2)")

                # Rotate via keyboard shortcut R (keycode 19)
                key(19)
                time.sleep(0.3)

                # Close via Ctrl+W (keycode 17 = W)
                key(17, ctrl=True)
                wait_for(lambda: len(windows("rediwm-pdf")) == 0, "PDF viewer did not close")

                pdf_proc.wait(timeout=5)
                assert pdf_proc.returncode == 0, f"rediwm-pdf exited with code {pdf_proc.returncode}"

                # Files opens PDFs itself, without an installed MIME association.
                documents = tmp / "documents"
                documents.mkdir()
                selected_pdf = documents / "a document #.PDF"
                shutil.copyfile(doc_path, selected_pdf)
                files = start("rediwm-files", str(documents), WAYLAND_DISPLAY=display)
                file_win = wait_for(lambda: next(iter(windows("rediwm-files")), None), "Files did not map")
                ipc.focus_window(file_win["id"])
                time.sleep(.4)
                key(102)  # Home selects the PDF.
                key(57)   # Space opens our PDF viewer.
                win = expect_title(selected_pdf.name)
                assert win["sandbox"]["engine"] == "org.rediwm.pdf", win
                ipc.focus_window(win["id"])
                key(17, ctrl=True)
                wait_for(lambda: not viewer(), "Space-opened PDF did not close")

                ipc.focus_window(file_win["id"])
                time.sleep(.4)
                box = ipc.get_window_debug(file_win["id"])["client_box"]
                ipc.move_cursor(int(box["x"] + 260), int(box["y"] + 160))
                for _ in range(2):
                    for pressed in (True, False):
                        ipc.action('pointer_button', {"button": 272, "pressed": pressed})
                    time.sleep(.08)
                win = expect_title(selected_pdf.name)
                assert win["sandbox"]["engine"] == "org.rediwm.pdf", win
                ipc.focus_window(win["id"])
                key(17, ctrl=True)
                wait_for(lambda: not viewer(), "Double-clicked PDF did not close")
                files.terminate()
                files.wait(timeout=5)

                if shutil.which("qpdf"):
                    encrypted = tmp / "encrypted.pdf"
                    subprocess.run(["qpdf", "--encrypt", "secretpass", "ownerpass", "256",
                                    "--", str(doc_path), str(encrypted)], check=True)
                    protected_proc = start("rediwm-pdf", str(encrypted), WAYLAND_DISPLAY=display)
                    protected_win = wait_for(viewer, "encrypted PDF viewer did not map")
                    ipc.focus_window(protected_win["id"])
                    # The worker's password-required result reaches the UI
                    # after the initial window has mapped.
                    time.sleep(0.3)
                    ipc.type_text("wrongpassword")
                    key(28)
                    time.sleep(0.3)
                    expect_title("(1/0)")
                    # Replacing the pathname must not replace the open inode.
                    encrypted.unlink()
                    encrypted.write_bytes(b"not the selected PDF")
                    ipc.type_text("secretpass")
                    key(28)
                    expect_title("(1/2)")
                    assert protected_proc.poll() is None
                    key(17, ctrl=True)
                    wait_for(lambda: not windows("rediwm-pdf"), "encrypted viewer did not close")
                    assert protected_proc.wait(timeout=5) == 0
                else:
                    print("SKIP: encrypted UI retry test needs qpdf")

                # A sandboxed process needs its one document at startup.
                empty_proc = start("rediwm-pdf", WAYLAND_DISPLAY=display)
                empty_proc.wait(timeout=5)
                assert empty_proc.returncode != 0
                assert not windows("rediwm-pdf")

                print("PDF viewer integration test passed successfully!")

        except Exception:
            for path in tmp.glob("*.log"):
                print(path.name, path.read_text(errors="replace")[-4000:])
            raise
        finally:
            for p in reversed(processes):
                if p.poll() is None:
                    p.terminate()
                    try:
                        p.wait(timeout=2)
                    except subprocess.TimeoutExpired:
                        p.kill()


if __name__ == "__main__":
    run(int(os.environ.get("REDIWM_SCALE", "1")))

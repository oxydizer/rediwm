#!/usr/bin/env python3
"""MIME icons, app-icon fallback and real GIO opening with private associations."""
import os
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time
from PIL import Image, ImageChops

from files_browser import wait_for
from ipc_client import IPCClient, IPCError, spawn_compositor, stop_process

ROOT = Path(__file__).resolve().parents[1]


def appimage_fixture(tmp):
    """A real ELF with an appended SquashFS, never executed during registration."""
    folder = tmp / 'portable'
    folder.mkdir()
    appdir = tmp / 'appdir'
    appdir.mkdir()
    (appdir / 'portable.desktop').write_text(
        '[Desktop Entry]\nType=Application\nName=Portable Hub\nName[en_NZ]=Portable Hub NZ\n'
        'Exec="AppRun" --fixture %U\nIcon=portable\nTerminal=false\n'
        'Categories=Development;\nMimeType=x-scheme-handler/rediwm-appimage-test;x-scheme-handler/rediwm-existing-test;application/x-rediwm-specific;\n'
        'TryExec=/nonexistent/appimage\nPath=/nonexistent/appdir\nDBusActivatable=true\n'
        'Actions=unsafe;\n[Desktop Action unsafe]\nName=Unsafe\nExec=/usr/bin/false\n')
    icon = appdir / 'usr/share/icons/portable.png'
    icon.parent.mkdir(parents=True)
    Image.new('RGBA', (32, 32), (36, 120, 220, 255)).save(icon)
    (appdir / '.DirIcon').symlink_to('usr/share/icons/portable.png')
    squash = tmp / 'appimage.squashfs'
    subprocess.run(['mksquashfs', str(appdir), str(squash), '-noappend', '-no-progress',
                    '-processors', '1'], check=True, capture_output=True)
    marker = tmp / 'appimage-opened'
    source = tmp / 'appimage.c'
    source.write_text('#include <stdio.h>\nint main(int argc, char **argv) {\n'
        f'FILE *f = fopen({json.dumps(str(marker))}, "w"); if (!f) return 1;\n'
        'for (int i = 1; i < argc; ++i) fprintf(f, "%s\\n", argv[i]); fclose(f); return 0; }\n')
    # Exercise both Desktop Entry escaping layers, field-code escaping, and
    # argv passing without letting shell punctuation become a shell command.
    image = folder / 'Hub $`"\\100%.AppImage'
    subprocess.run(['cc', str(source), '-o', str(image)], check=True, capture_output=True)
    elf = bytearray(image.read_bytes())
    elf[8:11] = b'AI\x02'
    image.write_bytes(elf + squash.read_bytes())
    image.chmod(0o600)
    return folder, image, marker, icon.read_bytes()


def check_appimage(ipc, key, click, portable, appimage, appimage_marker, appimage_icon, apps, data, config, env):
    # The AppImage's third context action integrates it without
    # executing it. All registrations remain in the private XDG dirs.
    ipc.action('key', {"keycode": 29, "pressed": True})
    key(38)  # Ctrl+L
    ipc.action('key', {"keycode": 29, "pressed": False})
    ipc.type_text(str(portable))
    key(28)
    wait_for(lambda: any(w['title'] == 'portable — RediWM Files' for w in ipc.get_windows()),
             'AppImage folder did not open')
    time.sleep(.3)

    def add_appimage():
        click(260, 160, 273)
        key(108)
        key(108)
        key(28)

    add_appimage()
    registered = lambda: list(apps.glob('rediwm-appimage-*.desktop'))
    wait_for(lambda: len(registered()) == 1, 'Add to applications did not create a launcher')
    entry = registered()[0]
    text = entry.read_text()
    assert 'Name=Portable Hub\n' in text and 'Name[en_NZ]=Portable Hub NZ\n' in text, text
    for unsafe in ('TryExec=', 'Path=', 'DBusActivatable=', 'Actions=', '[Desktop Action'):
        assert unsafe not in text, text
    assert not appimage_marker.exists(), 'registration executed the AppImage'
    assert appimage.stat().st_mode & 0o777 == 0o700
    installed_icon = next((data / 'icons').rglob('rediwm-appimage-*.png'))
    assert installed_icon.read_bytes() == appimage_icon
    uri = 'rediwm-appimage-test://login?code=private%20callback&state=a-b'
    def callback_registered():
        result = subprocess.run(['gio', 'mime', 'x-scheme-handler/rediwm-appimage-test'],
                                env=env, capture_output=True, text=True)
        return entry.name in result.stdout
    wait_for(callback_registered, 'AppImage URL handler was not registered')
    subprocess.run(['gio', 'open', uri], env=env, check=True, capture_output=True)
    wait_for(appimage_marker.exists, 'browser callback did not launch the registered AppImage')
    assert appimage_marker.read_text() == '--fixture\n' + uri + '\n'
    assert 'application/x-rediwm-specific=openscad.desktop;' in (config / 'mimeapps.list').read_text()
    existing = subprocess.run(['gio', 'mime', 'x-scheme-handler/rediwm-existing-test'], env=env,
                              check=True, capture_output=True, text=True)
    assert 'Default application for' in existing.stdout and 'existing-link.desktop' in existing.stdout.splitlines()[0], existing.stdout
    appimage_marker.unlink()
    time.sleep(.3)
    add_appimage()
    time.sleep(.5)
    assert len(registered()) == 1 and entry.read_text() == text, 'repeated Add duplicated the launcher'
    assert not appimage_marker.exists()
    # The start menu's live catalogue and its own Exec parser must see the
    # new launcher too, including the same punctuation-heavy image path.
    def launch_from_catalogue():
        try:
            ipc.launch(entry.name)
        except IPCError as error:
            if 'UnknownDesktopId' in str(error):
                return False
            raise
        return True
    wait_for(launch_from_catalogue, 'the application catalogue did not discover the AppImage')
    wait_for(appimage_marker.exists, 'the start menu launcher did not run the AppImage')
    assert appimage_marker.read_text() == '--fixture\n'
    appimage_marker.unlink()


def run():
    with tempfile.TemporaryDirectory(prefix="rediwm-files-associations-") as directory:
        tmp = Path(directory)
        portable, appimage, appimage_marker, appimage_icon = appimage_fixture(tmp)
        data, config, home = tmp / "data", tmp / "config", tmp / "home"
        apps = data / "applications"
        mime = data / "mime"
        icons = data / "icons/hicolor"
        for path in (apps, mime / "packages", icons / "48x48/apps", config, home):
            path.mkdir(parents=True, exist_ok=True)
        (icons / "index.theme").write_text('[Icon Theme]\nName=Test\nDirectories=48x48/apps\n'
                                          '[48x48/apps]\nSize=48\nType=Fixed\nContext=Applications\n')
        colours = {"openscad": "#ff0000", "specific-file": "#0000ff", "override-app": "#ff00ff", "application-x-generic": "#00ff00"}
        for name, colour in colours.items():
            (icons / f"48x48/apps/{name}.svg").write_text(
                '<svg xmlns="http://www.w3.org/2000/svg" width="48" height="48">'
                f'<rect width="48" height="48" fill="{colour}"/></svg>')
        types = [("application/x-openscad", "scad", None),
                 ("application/x-rediwm-specific", "specific", "specific-file"),
                 ("application/x-rediwm-override", "override", None),
                 ("application/x-rediwm-noicon", "noicon", None),
                 ("application/pdf", "pdf", None),
                 ("video/mp4", "mp4", None)]
        xml = '<mime-info xmlns="http://www.freedesktop.org/standards/shared-mime-info">'
        for mime_type, extension, icon in types:
            xml += f'<mime-type type="{mime_type}"><comment>Test model</comment><glob pattern="*.{extension}" weight="80"/>'
            if icon:
                xml += f'<icon name="{icon}"/>'
            xml += '</mime-type>'
        (mime / "packages/test.xml").write_text(xml + '</mime-info>')
        marker = tmp / "opened"
        launcher = tmp / "record-open"
        launcher.write_text('#!/usr/bin/python3\nimport pathlib,sys\npathlib.Path(' + repr(str(marker)) + ').write_text(sys.argv[1]+"\\n"+sys.argv[2])\n')
        launcher.chmod(0o755)
        for app, icon in (("openscad", "openscad"), ("override", "override-app"),
                          ("missing", "no-such-app-icon-rediwm"), ("celluloid", "override-app"),
                          ("thunar", "no-such-app-icon-rediwm")):
            (apps / f"{app}.desktop").write_text('[Desktop Entry]\nType=Application\n'
                f'Name={app}\nIcon={icon}\nExec={launcher} {app} %f\nTerminal=false\n'
                'MimeType=' + ';'.join(t[0] for t in types) +
                (';x-scheme-handler/file;\n' if app == 'thunar' else ';\n'))
        (apps / "alternate.desktop").write_text('[Desktop Entry]\nType=Application\n'
            f'Name=Alternate Editor\nIcon=override-app\nExec={launcher} alternate %f\nTerminal=false\n')
        for i in range(12):
            (apps / f"extra-{i}.desktop").write_text('[Desktop Entry]\nType=Application\n'
                f'Name=Z Extra {i:02d}\nExec={launcher} extra-{i} %f\nTerminal=false\n')
        (apps / 'existing-link.desktop').write_text('[Desktop Entry]\nType=Application\n'
            'Name=Existing link handler\nExec=/usr/bin/true %U\nMimeType=x-scheme-handler/rediwm-existing-test;\n')
        defaults = ["openscad", "openscad", "override", "missing", "", "celluloid"]
        (config / "mimeapps.list").write_text('[Default Applications]\n' + ''.join(
            f'{t[0]}={app}.desktop;\n' for t, app in zip(types, defaults) if app) +
            'x-scheme-handler/file=thunar.desktop;\nx-scheme-handler/rediwm-existing-test=existing-link.desktop;\n')
        for name in ("a model #.scad", "b.specific", "c.override", "d.noicon"):
            (home / name).write_text('cube([1, 2, 3]);\n')
        env = dict(os.environ, HOME=str(home), XDG_DATA_HOME=str(data), XDG_DATA_DIRS=str(data),
                   XDG_CONFIG_HOME=str(config), XDG_CONFIG_DIRS=str(config), XDG_STATE_HOME=str(tmp / "state"),
                   XDG_CURRENT_DESKTOP="RediWM", BROWSER="/usr/bin/false", REDIWM_ICON_THEME="hicolor",
                   XDG_RUNTIME_DIR=str(tmp), REDIWM_CONFIG=str(tmp / "rediwm-config.toml"),
                   WLR_BACKENDS="headless", REDIWM_FILES_DEVICES="0", WLR_RENDERER="gles2", WLR_HEADLESS_OUTPUTS="1", REDIWM_SCALE="1",
                   DBUS_SYSTEM_BUS_ADDRESS="unix:path=/nonexistent-rediwm-test-system-bus",
                   DBUS_SESSION_BUS_ADDRESS="unix:path=/nonexistent-rediwm-associations")
        for key in ("WAYLAND_DISPLAY", "DISPLAY", "XAUTHORITY", "REDIWM_SOCKET", "WAYLAND_DEBUG"):
            env.pop(key, None)
        subprocess.run(["update-mime-database", str(mime)], env=env, check=True, capture_output=True)
        subprocess.run(["update-desktop-database", str(apps)], env=env, check=True)
        comp, log = spawn_compositor(tmp, config_content='[compositor]\nxwayland = false\n', env_extra=env)
        client = None
        try:
            with IPCClient(tmp).connect() as ipc:
                display = next(p.name for p in tmp.glob("wayland-*") if not p.name.endswith(".lock"))
                with (tmp / "files.log").open("w") as out:
                    client = subprocess.Popen([str(ROOT / "zig-out/bin/rediwm-files"), str(home)],
                        env=dict(env, XDG_RUNTIME_DIR=str(tmp), WAYLAND_DISPLAY=display,
                                 REDIWM_CONFIG=str(tmp / "rediwm-config.toml")), stdout=out, stderr=out)
                win = wait_for(lambda: next((w for w in ipc.get_windows() if w["app_id"] == "rediwm-files"), None), "Files did not map")
                ipc.action('set_window_size', {"id": win["id"], "width": 960, "height": 540})
                ipc.action('move_window_to', {"id": win["id"], "x": 10, "y": 10})
                ipc.focus_window(win["id"])
                ipc.wait_for('window_geometry_settled', window_id=win['id'])
                box = ipc.get_window_debug(win["id"])["client_box"]
                def key(code):
                    for pressed in (True, False):
                        ipc.action('key', {"keycode": code, "pressed": pressed})

                def click(x, y, button=272):
                    ipc.move_cursor(int(box["x"] + x), int(box["y"] + y))
                    for pressed in (True, False):
                        ipc.action('pointer_button', {"button": button, "pressed": pressed})

                if "--appimage-only" in sys.argv:
                    check_appimage(ipc, key, click, portable, appimage, appimage_marker, appimage_icon, apps, data, config, env)
                    print("PASS: AppImage context action, metadata, defaults, idempotence, browser callback and catalogue launch")
                    return
                screenshot = tmp / "icons.png"
                expected = [(255, 0, 0), (0, 0, 255), (255, 0, 255), (0, 255, 0)]
                def correct_icons():
                    ipc.screenshot(path=str(screenshot))
                    with Image.open(screenshot) as image:
                        return all(image.convert("RGB").getpixel((int(box["x"] + 278 + i % 3 * 239),
                            int(box["y"] + 176 + i // 3 * 156))) == colour for i, colour in enumerate(expected))
                wait_for(correct_icons, "MIME/app/fallback icon pixels differ")
                # Real GIO opening must honor the same association, including %f
                # argument handling for spaces and punctuation in the filename.
                for i, name, app in ((0, "a model #.scad", "openscad"), (2, "c.override", "override")):
                    marker.unlink(missing_ok=True)
                    ipc.move_cursor(int(box["x"] + 260 + i * 239), int(box["y"] + 160))
                    for pressed in (True, False):
                        ipc.action('pointer_button', {"button": 272, "pressed": pressed})
                    for pressed in (True, False):
                        ipc.action('key', {"keycode": 28, "pressed": pressed})
                    wait_for(lambda: marker.exists(), "associated application was not launched")
                    assert marker.read_text() == app + '\n' + str(home / name), marker.read_text()
                def drag_title(x, y, dx, dy):
                    path = tmp / "dialog-drag.png"
                    path.unlink(missing_ok=True)
                    ipc.screenshot(path=str(path))
                    with Image.open(path) as image:
                        region = (int(box["x"] + x - 10), int(box["y"] + y - 5),
                                  int(box["x"] + x + 110), int(box["y"] + y + 15))
                        before = image.convert("RGB").crop(region)
                    ipc.move_cursor(int(box["x"] + x), int(box["y"] + y))
                    ipc.action('pointer_button', {"button": 272, "pressed": True})
                    ipc.move_cursor(int(box["x"] + x + dx), int(box["y"] + y + dy))
                    ipc.action('pointer_button', {"button": 272, "pressed": False})
                    time.sleep(.2)
                    path.unlink(missing_ok=True)
                    ipc.screenshot(path=str(path))
                    with Image.open(path) as image:
                        after = image.convert("RGB").crop((region[0] + dx, region[1] + dy,
                                                            region[2] + dx, region[3] + dy))
                    assert ImageChops.difference(before, after).getbbox() is None, "dialog titlebar did not move"

                def picker():
                    click(260, 160, 273)
                    key(108)  # Open With is exactly one row below Open.
                    key(28)
                    time.sleep(.15)

                # Properties is the last context action; its permission cells
                # change only the chosen bit, and Alt+Enter opens the same card.
                target = home / 'a model #.scad'
                target.chmod(0o640)
                click(260, 160, 273)
                key(103)  # Up wraps from Open to Properties.
                key(28)
                time.sleep(.2)
                preview = os.environ.get("REDIWM_PROPERTIES_PREVIEW")
                if preview:
                    Path(preview).unlink(missing_ok=True)
                    ipc.screenshot(path=preview)
                # Moving the card must also move its permission hit targets.
                drag_title(320, 30, 70, 0)
                click(495, 469)  # Owner Execute.
                wait_for(lambda: target.stat().st_mode & 0o777 == 0o740,
                         "Properties did not toggle owner execute")
                click(495, 469)
                wait_for(lambda: target.stat().st_mode & 0o777 == 0o640,
                         "Properties changed unrelated permission bits")
                click(740, 35)  # Close uses the moved chrome position.
                time.sleep(.2)
                click(260, 160)
                ipc.action('key', {"keycode": 56, "pressed": True})
                key(28)
                ipc.action('key', {"keycode": 56, "pressed": False})
                key(15)  # Open.
                key(15)  # Owner Read.
                key(15)  # Group Read.
                key(15)  # Others Read.
                key(57)
                wait_for(lambda: target.stat().st_mode & 0o777 == 0o644,
                         "Alt+Enter or keyboard permission navigation failed")
                # A renamed/replaced path must not redirect a permission edit.
                original = home / 'original.scad'
                target.rename(original)
                target.write_text('replacement')
                target.chmod(0o600)
                key(57)
                wait_for(lambda: original.stat().st_mode & 0o777 == 0o640,
                         "Properties lost the original inode after replacement")
                assert target.stat().st_mode & 0o777 == 0o600
                target.unlink()
                original.rename(target)
                key(1)
                time.sleep(.2)
                # The bottom row remains keyboard accessible at minimum size.
                click(260, 160, 273)
                key(103)
                key(28)
                ipc.action('set_window_size', {"id": win["id"], "width": 360, "height": 280})
                time.sleep(.3)
                for _ in range(10):
                    key(15)  # Others Execute, scrolled into view.
                key(57)
                wait_for(lambda: target.stat().st_mode & 0o777 == 0o641,
                         "compact Properties lost its keyboard targets")
                key(57)
                key(1)
                ipc.action('set_window_size', {"id": win["id"], "width": 960, "height": 540})
                time.sleep(.3)
                box = ipc.get_window_debug(win["id"])["client_box"]

                # Cancel preserves the association and launches nothing.
                marker.unlink()
                picker()
                drag_title(300, 66, 70, 30)
                preview = os.environ.get("REDIWM_OPEN_WITH_PREVIEW")
                if preview:
                    ipc.screenshot(path=preview)
                key(1)
                assert not marker.exists()
                assert 'application/x-openscad=openscad.desktop;' in (config / 'mimeapps.list').read_text()

                # Browse other installed apps, explicitly choose one, and keep
                # the original default when the checkbox is unchecked.
                picker()
                key(15)  # Tab to Choose another app.
                key(28)
                key(28)  # The first non-recommended app is Alternate Editor.
                wait_for(marker.exists, "Open With did not launch the chosen application")
                assert marker.read_text() == 'alternate\n' + str(home / 'a model #.scad')
                assert 'application/x-openscad=openscad.desktop;' in (config / 'mimeapps.list').read_text()

                # Other apps remain reachable beyond the visible rows.
                marker.unlink()
                picker()
                key(15)
                key(28)
                key(107)  # End scrolls to the last installed app.
                key(28)
                wait_for(marker.exists, "last application was not reachable")
                assert marker.read_text() == 'extra-11\n' + str(home / 'a model #.scad')

                # Save a default through the same picker, then ordinary Open
                # must use it, including correct escaping of the file path.
                marker.unlink()
                picker()
                key(15)
                key(28)
                key(15)
                key(15)  # Remember checkbox.
                key(57)
                key(15)  # Cancel.
                key(15)  # Open.
                key(28)
                wait_for(marker.exists, "remembered application was not launched")
                assert marker.read_text() == 'alternate\n' + str(home / 'a model #.scad')
                wait_for(lambda: 'application/x-openscad=alternate.desktop;' in (config / 'mimeapps.list').read_text(),
                         "Open With did not save the default")
                marker.unlink()
                time.sleep(.3)  # Wait for the directory refresh following Open.
                click(260, 160)
                key(28)
                wait_for(marker.exists, "ordinary Open ignored the chosen default")
                assert marker.read_text() == 'alternate\n' + str(home / 'a model #.scad')

                # Pointer targets remain aligned when the modal is compact.
                picker()
                ipc.action('set_window_size', {"id": win["id"], "width": 360, "height": 280})
                time.sleep(.3)
                small = ipc.get_window_debug(win["id"])["client_box"]
                # Same geometry as the compact modal: right edge is 12 px in,
                # the header close control follows the shared chrome metrics.
                ipc.move_cursor(int(small["x"] + small["width"] - 43), int(small["y"] + 33))
                for pressed in (True, False):
                    ipc.action('pointer_button', {"button": 272, "pressed": pressed})
                ipc.action('set_window_size', {"id": win["id"], "width": 960, "height": 540})
                time.sleep(.3)
                box = ipc.get_window_debug(win["id"])["client_box"]

                # PDFs keep their bundled fallback but an explicitly selected
                # alternative must also become the ordinary Open handler.
                pdf = home / 'e.pdf'
                pdf.write_bytes(b'%PDF-1.4\n')
                key(63)
                time.sleep(.4)
                key(107)  # End selects the new PDF.
                key(127)  # Keyboard context menu.
                key(108)
                key(28)
                key(15)
                key(28)  # Other apps, initially Alternate Editor.
                key(15)
                key(15)
                key(57)  # Remember.
                key(15)
                key(15)
                marker.unlink()
                key(28)
                wait_for(marker.exists, "chosen PDF application did not launch")
                assert marker.read_text() == 'alternate\n' + str(pdf)
                time.sleep(.3)
                marker.unlink()
                key(28)
                wait_for(marker.exists, "ordinary PDF Open ignored the saved default")
                assert marker.read_text() == 'alternate\n' + str(pdf)

                # A file:// handler must not override the video's MIME default
                # when the user double-clicks it.
                video = home / 'z-video.mp4'
                video.write_bytes(b'\x00\x00\x00\x18ftypmp42')
                key(63)  # Refresh the directory listing.
                time.sleep(.4)
                marker.unlink(missing_ok=True)
                click(738, 316)
                click(738, 316)
                wait_for(marker.exists, "double-click ignored the video MIME default")
                assert marker.read_text() == 'celluloid\n' + str(video)

                # A directory's second action remains Cut, not Open With.
                folder = home / '0-folder'
                folder.mkdir()
                key(63)  # F5 refresh.
                time.sleep(.4)
                click(260, 160, 273)
                key(108)
                key(28)
                key(28)  # Open the selected folder; a modal would intercept this.
                wait_for(lambda: any(w['title'] == '0-folder — RediWM Files' for w in ipc.get_windows()),
                         "folder context menu unexpectedly opened an app picker")
                check_appimage(ipc, key, click, portable, appimage, appimage_marker, appimage_icon, apps, data, config, env)
                assert client.poll() is None
                print("PASS: MIME icons, Properties, Open With, default persistence, AppImage registration and URL callbacks")
        except Exception:
            if (tmp / "compositor.log").exists():
                print((tmp / "compositor.log").read_text()[-5000:])
            if (tmp / "files.log").exists():
                print((tmp / "files.log").read_text()[-5000:])
            raise
        finally:
            if client:
                stop_process(client)
            stop_process(comp)
            log.close()


if __name__ == "__main__":
    run()

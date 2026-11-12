#!/usr/bin/env python3
"""Application palettes: manual exports and opt-in live GTK/Qt synchronization."""
from pathlib import Path
import tempfile
import time
import tomllib
import os
import json
import subprocess
import sys
import shutil

from ipc_client import IPCClient, spawn_compositor, stop_process
from ui_driver import UIDriver
from desktop_zoom import wait_for

# The RediWM Qt style beside the compositor under test (build/qt_style.zig).
QT_STYLE_DIR = Path(__file__).resolve().parent.parent / "zig-out/lib/rediwm"


def qt_style_built(major):
    return (QT_STYLE_DIR / f"qt{major}/styles/librediwm-style.so").exists()


def check_qt_frame(package, colors):
    """Chromium's Qt frame is the style's active title bar: never the accent."""
    if not qt_style_built(package[2]):
        return
    assert colors["style"] != "QFusionStyle", (package, colors)
    near = lambda a, b: all(abs(int(a[i:i + 2], 16) - int(b[i:i + 2], 16)) <= 12 for i in (1, 3, 5))
    assert near(colors["frame"], colors["bg"]) and not near(colors["frame"], colors["accent"]), (package, colors)


def test_app_colors():
    with tempfile.TemporaryDirectory(prefix="rediwm-app-colors-") as directory:
        tmp = Path(directory)
        config = tmp / "custom, config"
        helpers = tmp / "bin"
        helpers.mkdir()
        for name in ("qt5ct", "qt6ct"):
            helper = helpers / name
            helper.write_text("#!/bin/sh\nexit 0\n")
            helper.chmod(0o700)
        gtk_original = "/* User CSS survives */\nlabel.user-rule { color: red; }\n"
        for version in ("gtk-3.0", "gtk-4.0"):
            (config / version).mkdir(parents=True)
            (config / version / "gtk.css").write_text(gtk_original)
        qt_original = "# User preferences\n[Appearance]\ncustom_palette=false\nstyle=Old\n[Fonts]\ngeneral=Example\n[Other]\ncustom_palette=false\n"
        for version in ("qt5ct", "qt6ct"):
            (config / version).mkdir()
            (config / version / (version + ".conf")).write_text(qt_original)
        theme = ('[compositor]\nxwayland = false\n[theme]\napp_bg = "#123456"\nwindow_fg = "#e1e2e3"\n'
                 'app_toolbar = "#234567"\napp_sidebar = "#345678"\nshell_accent = "#abcdef"\n'
                 '[taskbar_theme]\nwindow_fg = "#010203"\nstart_menu_selected_marker = "#ff0000"\n')
        env = {"HOME": str(tmp / "home"), "XDG_CONFIG_HOME": str(config),
               "XDG_DATA_HOME": str(tmp / "custom-data"), "XDG_DATA_DIRS": str(tmp / "empty-data"),
               "XDG_CACHE_HOME": str(tmp / "cache"), "DBUS_SESSION_BUS_ADDRESS": "",
               "PATH": str(helpers), "QT_QPA_PLATFORMTHEME": "gtk3",
               "QT_STYLE_OVERRIDE": "kvantum", "REDIWM_FILES_DEVICES": "0"}
        process, log = spawn_compositor(tmp, config_content=theme, env_extra=env)
        try:
            with IPCClient(tmp, timeout=15) as ipc:
                ui = UIDriver(ipc)
                ipc.action("open_appearance")
                ui.wait_settled("control_center")

                def message():
                    return " ".join((w.get("label") or "") for w in ui.widgets("control_center") if (w.get("name") or "").startswith("app_colors_status_"))

                def apply(name, expected):
                    ui.click(ui.scroll_into_view(name))
                    wait_for(lambda: expected in message(), expected)

                apply("apply_gtk_colors", "GTK colors applied")
                apply("apply_gtk_colors", "GTK colors applied")
                for version in ("gtk-3.0", "gtk-4.0"):
                    css = (config / version / "gtk.css").read_text()
                    assert css.count("BEGIN REDIWM APP COLORS") == 1
                    assert css.startswith(gtk_original), css
                    assert (config / version / "gtk.css.rediwm-backup").read_text() == gtk_original
                    assert "window_bg_color #123456" in (config / version / "rediwm-colors.css").read_text()

                apply("apply_qt_colors", "Qt 5 and Qt 6 colors applied")
                for version in ("qt5ct", "qt6ct"):
                    settings = (config / version / (version + ".conf")).read_text()
                    style = "RediWM" if qt_style_built(version[2]) else "Fusion"
                    assert f"style={style}" in settings and "[Fonts]\ngeneral=Example" in settings
                    assert "[Other]\ncustom_palette=false" in settings
                    assert (config / version / (version + ".conf.rediwm-backup")).read_text() == qt_original
                    palette = (config / version / "colors/rediwm.conf").read_text()
                    for line in palette.splitlines()[1:]:
                        assert len(line.split("=", 1)[1].split(",")) == 22
                assert "qt=true" in (config / "rediwm/app-colors.conf").read_text()
                if preview := os.environ.get("REDIWM_SETTINGS_PREVIEW"):
                    Path(preview).mkdir(parents=True, exist_ok=True)
                    ui.scroll_into_view("apply_gtk_colors")
                    ui.wait_settled("control_center")
                    capture = Path(preview) / "app-colors.png"
                    capture.unlink(missing_ok=True)
                    ipc.screenshot(str(capture))

                # Check the environment delivered to a newly launched app.
                received = tmp / "child-env.json"
                probe = tmp / "env.py"
                probe.write_text("""import os,json,sys
from pathlib import Path
keys = ('HOME', 'XDG_RUNTIME_DIR', 'XDG_CONFIG_HOME', 'XDG_DATA_HOME',
        'XDG_DATA_DIRS', 'XDG_CACHE_HOME', 'WAYLAND_DISPLAY', 'DISPLAY',
        'DBUS_SESSION_BUS_ADDRESS', 'DBUS_SYSTEM_BUS_ADDRESS',
        'QT_QPA_PLATFORMTHEME', 'QT_QPA_PLATFORMTHEME_QT6', 'QT_STYLE_OVERRIDE', 'QT_PLUGIN_PATH',
        'PATH', 'LANG', 'LC_ALL', 'XDG_CURRENT_DESKTOP', 'XDG_SESSION_TYPE')
Path(sys.argv[1]).write_text(json.dumps({k: os.environ[k] for k in keys if k in os.environ}))
""")
                ipc.action("spawn", {"argv": [sys.executable, str(probe), str(received)]})
                wait_for(received.exists, "app environment")
                child_env = json.loads(received.read_text())
                assert child_env["QT_QPA_PLATFORMTHEME"] == "qt5ct", child_env
                # Empty: qt5ct/qt6ct choose the style per Qt major.
                assert child_env["QT_STYLE_OVERRIDE"] == "", child_env
                for major in (5, 6):
                    if qt_style_built(major):
                        assert str((QT_STYLE_DIR / f"qt{major}").resolve()) in child_env["QT_PLUGIN_PATH"].split(":"), child_env

                # These clients use real toolkit loaders, on the private display.
                root = Path(__file__).resolve().parent
                for package, source, compiler, extra in (
                        ("gtk+-3.0", "app_colors_gtk_client.c", "cc", []),
                        ("gtk4", "app_colors_gtk_client.c", "cc", []),
                        ("libadwaita-1", "app_colors_gtk_client.c", "cc", ["-DUSE_ADWAITA"]),
                        ("Qt5Widgets", "app_colors_qt_client.cpp", "c++", ["-fPIC"]),
                        ("Qt6Widgets", "app_colors_qt_client.cpp", "c++", ["-fPIC"])):
                    if subprocess.run(["pkg-config", "--exists", package]).returncode:
                        print("SKIP: app palette probe for", package)
                        continue
                    binary = tmp / package
                    flags = subprocess.check_output(["pkg-config", "--cflags", "--libs", package], text=True).split()
                    subprocess.run([compiler, str(root / source), "-o", str(binary), *extra, *flags], check=True, capture_output=True)
                    result = subprocess.run([str(binary)], env=child_env, text=True, capture_output=True, timeout=20, check=True)
                    assert "Theme parser error" not in result.stderr and "Theme parsing error" not in result.stderr, result.stderr
                    colors = json.loads(result.stdout)
                    assert colors["bg"] == "#123456" and colors["fg"] == "#e1e2e3", (package, colors, result.stderr)
                    if "accent" in colors:
                        assert colors["accent"] == "#abcdef" and colors["on_accent"] == "#000000", colors
                        assert colors["disabled"] != colors["fg"], colors
                    if "qt6_accent" in colors:
                        assert colors["qt6_accent"] == "#abcdef", colors
                    if "frame" in colors:
                        check_qt_frame(package, colors)

                # A symlinked gtk.css becomes a regular file with its content merged.
                gtk4_css = config / "gtk-4.0/gtk.css"
                gtk4_css.unlink()
                external = tmp / "external.css"
                external.write_text("/* external */\n")
                gtk4_css.symlink_to(external)
                apply("apply_gtk_colors", "GTK colors applied")
                wait_for(lambda: not gtk4_css.is_symlink(), "gtk.css replaced")
                assert "/* external */" in gtk4_css.read_text() and "rediwm-colors.css" in gtk4_css.read_text()
                assert external.read_text() == "/* external */\n"
                gtk4_css.unlink()
                (config / "qt6ct/qt6ct.conf").unlink()
                (config / "qt6ct/qt6ct.conf").mkdir()
                apply("apply_qt_colors", "Could not apply app colors")
                assert "InvalidFile" in message(), message()
                for name in ("qt5ct", "qt6ct"):
                    (helpers / name).unlink()
                apply("apply_qt_colors", "Install qt5ct")

            stop_process(process)
            assert process.returncode == 0, (tmp / "compositor.log").read_text()
        finally:
            stop_process(process)
            log.close()
        # The Qt opt-in survives compositor restart, including launches before
        # Settings has ever been opened.
        process, log = spawn_compositor(tmp, config_content=theme, env_extra=env)
        try:
            received.unlink()
            with IPCClient(tmp) as ipc:
                ipc.action("spawn", {"argv": [sys.executable, str(probe), str(received)]})
                wait_for(received.exists, "persisted app environment")
                assert json.loads(received.read_text())["QT_QPA_PLATFORMTHEME"] == "qt5ct"
        finally:
            stop_process(process)
            log.close()
        print("PASS: app colors buttons, GTK/Qt palettes, preservation, failures and launch environment")



def test_follow_private(tmp):
    """Real settings bus and toolkit clients, all using a scratch HOME/XDG tree."""
    config = Path(os.environ['XDG_CONFIG_HOME'])
    data = Path(os.environ['XDG_DATA_HOME'])
    colors = ('#123456', '#234567', '#345678')
    def content(bg, on=True, taskbar='#ff0000'):
        return (f'[compositor]\nxwayland = false\nfollow_app_colors = {str(on).lower()}\n'
                f'[theme]\napp_bg = "{bg}"\nwindow_fg = "#e1e2e3"\n'
                'app_toolbar = "#456789"\nshell_accent = "#abcdef"\n'
                f'[taskbar_theme]\napp_bg = "{taskbar}"\n')

    # Starting with the default off never creates toolkit configuration.
    process, log = spawn_compositor(tmp, config_content=content(colors[0], False),
                                    scale=os.environ.get('REDIWM_TEST_SCALE', '1'),
                                    env_extra={'REDIWM_FORCE_DBUS': '1'})
    clients = []
    streams = []
    try:
        with IPCClient(tmp, timeout=20) as ipc:
            assert not (config / 'gtk-3.0').exists()
            # Generators (matugen/DMS, KDE colors.css) define the standard
            # names in user CSS, which outranks any theme: following must win.
            competing = '/* BEGIN DMS OVERRIDE */\n@define-color window_bg_color #242730;\n/* END DMS OVERRIDE */\n'
            (config / 'gtk-3.0').mkdir(parents=True)
            (config / 'gtk-3.0/gtk.css').write_text(competing)
            ipc.action('open_appearance')
            ui = UIDriver(ipc)
            ui.wait_settled('control_center')
            toggle = ui.scroll_into_view('follow_app_colors')
            def manual_buttons():
                return {w.get('name') for w in ui.widgets()} & {'apply_gtk_colors', 'apply_qt_colors'}
            assert manual_buttons() == {'apply_gtk_colors', 'apply_qt_colors'}
            ui.click(toggle)
            def selected():
                p = config / 'gtk-3.0/settings.ini'
                if not p.exists():
                    return None
                return next((line.split('=', 1)[1] for line in p.read_text().splitlines()
                             if line.startswith('gtk-theme-name=')), None)
            wait_for(lambda: selected() in ('RediWM-a', 'RediWM-b'), 'follow enabled')
            path = tmp / 'rediwm-config.toml'
            assert tomllib.loads(path.read_text())['compositor']['follow_app_colors']
            # Following replaces the manual snapshot buttons.
            wait_for(lambda: not manual_buttons(), 'manual buttons hidden while following')
            def portal_theme():
                r = subprocess.run(['busctl', '--user', '--timeout=3', 'call',
                    'org.freedesktop.impl.portal.desktop.rediwm', '/org/freedesktop/portal/desktop',
                    'org.freedesktop.impl.portal.Settings', 'Read', 'ss',
                    'org.gnome.desktop.interface', 'gtk-theme'], capture_output=True, text=True)
                return r.stdout.strip()
            wait_for(lambda: portal_theme() == f'v s "{selected()}"', 'GTK theme published')
            assert (config / 'rediwm/gtk-theme.gsettings-backup').exists()
            user_css = (config / 'gtk-3.0/gtk.css').read_text()
            assert user_css.startswith(competing), user_css
            assert '@define-color window_bg_color @rediwm_window_bg_color;' in user_css, user_css
            # Setup remains generic: no absent browser profile is created.
            for name in ('BraveSoftware', 'google-chrome', 'falkon', 'mozilla'):
                assert not (config / name).exists()

            probe = tmp / 'env.py'
            received = tmp / 'env.json'
            probe.write_text('import os,json,sys\nfrom pathlib import Path\nPath(sys.argv[1]).write_text(json.dumps(dict(os.environ)))\n')
            ipc.action('spawn', {'argv': [sys.executable, str(probe), str(received)]})
            wait_for(received.exists, 'follow launch environment')
            child_env = json.loads(received.read_text())
            assert 'GTK_THEME' not in child_env
            if preview := os.environ.get('REDIWM_SETTINGS_PREVIEW'):
                Path(preview).mkdir(parents=True, exist_ok=True)
                ui.scroll_into_view('follow_app_colors')
                shot = Path(preview) / 'follow-app-colors.png'
                shot.unlink(missing_ok=True)
                ipc.screenshot(str(shot))
            # Close Settings: palette following must outlive its widgets.
            ipc.action('close_window')

            root = Path(__file__).resolve().parent
            import threading
            for package, source, compiler, extra in (
                ('gtk+-3.0', 'app_colors_gtk_client.c', 'cc', []),
                ('gtk4', 'app_colors_gtk_client.c', 'cc', []),
                ('Qt5Widgets', 'app_colors_qt_client.cpp', 'c++', ['-fPIC']),
                ('Qt6Widgets', 'app_colors_qt_client.cpp', 'c++', ['-fPIC']),
            ):
                if subprocess.run(['pkg-config', '--exists', package]).returncode:
                    print('SKIP live palette:', package)
                    continue
                if package.startswith('Qt') and not shutil.which('qt' + package[2] + 'ct'):
                    print('SKIP live palette plugin:', package)
                    continue
                binary = tmp / package
                flags = subprocess.check_output(['pkg-config', '--cflags', '--libs', package], text=True).split()
                subprocess.run([compiler, str(root / source), '-o', str(binary), *extra, *flags], check=True, capture_output=True)
                errors = (tmp / (package + '.log')).open('w')
                streams.append(errors)
                proc = subprocess.Popen([str(binary), '--watch'], env=child_env,
                                        stdout=subprocess.PIPE, stderr=errors, text=True)
                samples = []
                def collect(proc=proc, samples=samples):
                    for line in proc.stdout:
                        samples.append(json.loads(line))
                threading.Thread(target=collect, daemon=True).start()
                clients.append((package, proc, samples))
                wait_for(lambda: samples and samples[-1]['bg'] == colors[0], f'{package} initial palette', timeout=15)
                if 'frame' in samples[-1]:
                    check_qt_frame(package, samples[-1])

            # Same palette and taskbar-only changes leave the named theme and
            # watched toolkit files untouched.
            first = selected()
            gtk_file = data / 'themes' / first / 'gtk-3.0/gtk.css'
            stamp = gtk_file.stat().st_mtime_ns
            path.write_text(content(colors[0], taskbar='#00ff00'))
            ipc.reload_config()
            assert selected() == first and gtk_file.stat().st_mtime_ns == stamp
            for bg in colors[1:]:
                old = selected()
                path.write_text(content(bg))
                ipc.reload_config()
                wait_for(lambda: selected() != old, 'new named GTK palette')
                wait_for(lambda: portal_theme() == f'v s "{selected()}"', 'new theme published')
                for package, proc, samples in clients:
                    wait_for(lambda: samples and samples[-1]['bg'] == bg,
                             f'{package} live palette {bg}', timeout=15)
                    assert samples[-1]['fg'] == '#e1e2e3', (package, samples)
            # Rapid edits may overlap one worker; the final request must win.
            for bg in ('#224466', '#335577', '#446688', colors[-1]):
                path.write_text(content(bg))
                ipc.reload_config()
            wait_for(lambda: f'window_bg_color {colors[-1]}' in
                     (data / 'themes' / selected() / 'gtk-3.0/gtk.css').read_text(),
                     'latest palette wins')
            for package, proc, samples in clients:
                wait_for(lambda: samples and samples[-1]['bg'] == colors[-1],
                         f'{package} final palette', timeout=15)
            assert len(list((data / 'themes').glob('RediWM-*'))) == 2

            # Disabling following keeps the current colors and stops future
            # exports, both immediately and after a compositor restart.
            last = selected()
            last_file = data / 'themes' / last / 'gtk-3.0/gtk.css'
            last_bytes = last_file.read_bytes()
            path.write_text(content('#778899', False))
            ipc.reload_config()
            assert selected() == last and last_file.read_bytes() == last_bytes
            assert not portal_theme()
        for _, proc, _ in clients:
            stop_process(proc)
        clients.clear()
        stop_process(process)
        log.close()
        process, log = spawn_compositor(tmp, config_content=content('#778899', False))
        with IPCClient(tmp):
            assert selected() == last and last_file.read_bytes() == last_bytes
        stop_process(process)
        log.close()
        # Startup following also works without ever opening Settings.
        process, log = spawn_compositor(tmp, config_content=content('#778899'))
        with IPCClient(tmp):
            wait_for(lambda: selected() != last, 'startup palette export')
        print('PASS: opt-in persistence, live GTK3/GTK4/Qt palettes, portal, closed Settings, bounded themes, off and restart')
    finally:
        for _, proc, _ in clients:
            stop_process(proc)
        for stream in streams:
            stream.close()
        stop_process(process)
        log.close()


def test_follow_colors():
    with tempfile.TemporaryDirectory(prefix='rediwm-follow-colors-') as directory:
        tmp = Path(directory)
        env = dict(os.environ, HOME=str(tmp / 'home'), XDG_CONFIG_HOME=str(tmp / 'config'),
                   XDG_DATA_HOME=str(tmp / 'data'), XDG_CACHE_HOME=str(tmp / 'cache'),
                   XDG_STATE_HOME=str(tmp / 'state'), XDG_RUNTIME_DIR=str(tmp),
                   GSETTINGS_BACKEND='keyfile', GTK_THEME='Adwaita',
                   REDIWM_FILES_DEVICES='0', REDIWM_FORCE_DBUS='1',
                   GIO_USE_VFS='local', NO_AT_BRIDGE='1', GTK_A11Y='none')
        env.pop('DBUS_SESSION_BUS_ADDRESS', None)
        env.pop('DISPLAY', None)
        env.pop('WAYLAND_DISPLAY', None)
        env.pop('REDIWM_THEME', None)
        # The bus and its activation environment must also use the scratch
        # home; only then can GSettings or portal services be safely exercised.
        subprocess.run(['dbus-run-session', '--', sys.executable, __file__, '--follow-private', str(tmp)],
                       env=env, check=True, timeout=180)


def test_follow_without_helpers():
    with tempfile.TemporaryDirectory(prefix='rediwm-follow-minimal-') as directory:
        tmp = Path(directory)
        config = tmp / 'config'
        process, log = spawn_compositor(tmp,
            config_content='[compositor]\nxwayland=false\nfollow_app_colors=true\n[theme]\napp_bg="#314159"\n',
            env_extra={'HOME': str(tmp / 'home'), 'XDG_CONFIG_HOME': str(config),
                       'XDG_DATA_HOME': str(tmp / 'data'), 'XDG_CACHE_HOME': str(tmp / 'cache'),
                       'PATH': str(tmp / 'missing-tools'), 'DBUS_SESSION_BUS_ADDRESS': ''})
        try:
            with IPCClient(tmp) as ipc:
                exported = config / 'gtk-3.0/rediwm-colors.css'
                wait_for(exported.exists, 'GTK fallback without optional tools')
                assert 'window_bg_color #314159' in exported.read_text()
                assert not (config / 'qt5ct').exists() and not (config / 'qt6ct').exists()
                ipc.action('open_appearance')
                ui = UIDriver(ipc)
                ui.wait_settled('control_center')
                note = ' '.join(w.get('label') or '' for w in ui.widgets()
                                if (w.get('name') or '').startswith('app_colors_status_'))
                assert 'GTK live updates are unavailable' in note, note
            print('PASS: GTK snapshots and clear status when optional tools are absent')
        finally:
            stop_process(process)
            log.close()


if __name__ == '__main__':
    if '--follow-private' in sys.argv:
        test_follow_private(Path(sys.argv[-1]))
    elif '--follow-only' in sys.argv:
        test_follow_colors()
    else:
        test_app_colors()
        test_follow_colors()
        test_follow_without_helpers()

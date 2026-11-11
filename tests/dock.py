#!/usr/bin/env python3
"""Optional dock: settings persistence, input, window lifecycle and scaling."""
import os
import signal
import shutil
from pathlib import Path
import subprocess
import tempfile
import time
import tomllib

from PIL import Image, ImageChops
from desktop_zoom import build_client, wait_for
from ipc_client import IPCClient, spawn_compositor, stop_process
from ui_driver import UIDriver


def count_badge(ipc, ui, name, scale, path):
    """The icon's top-right corner, clear of its running/focus pill."""
    ipc.move_cursor(5, 5)
    ipc.wait_for_frame()
    box = next(w['global_box'] for w in ui.widgets('dock') if w['name'] == name)
    path.unlink(missing_ok=True)
    ipc.screenshot(str(path))
    with Image.open(path) as image:
        return image.convert('RGB').crop(tuple(round(v * scale) for v in
            (box['x'] + box['width'] / 2, box['y'] + box['height'] / 8,
             box['x'] + box['width'] * 7 / 8, box['y'] + box['height'] / 2)))


def run():
    scale = float(os.environ.get('REDIWM_TEST_SCALE', '1'))
    with tempfile.TemporaryDirectory(prefix='rediwm-dock-') as directory:
        tmp = Path(directory)
        build_client(tmp)
        applications = tmp / 'data' / 'applications'
        applications.mkdir(parents=True)
        for name, app_id, category in (
            ('dock-files', 'dock.files.running', 'FileManager'),
            ('dock-terminal', 'dock.terminal.running', 'TerminalEmulator'),
        ):
            (applications / f'{name}.desktop').write_text(
                f'[Desktop Entry]\nType=Application\nName={name}\nStartupWMClass={app_id}\n'
                f'Categories={category};\nExec={tmp / "client"} --app-id {app_id}\n')
        fallback = tmp / 'fallback-terminal'
        shutil.copyfile(tmp / 'client', fallback)
        fallback.chmod(0o700)
        (applications / 'fallback.desktop').write_text(
            '[Desktop Entry]\nType=Application\nName=Fallback\nStartupWMClass=dock.fallback\n'
            f'Categories=TerminalEmulator;\nExec={fallback} --app-id dock.fallback\n')
        process, log = spawn_compositor(tmp, scale=scale, outputs=os.environ.get('REDIWM_TEST_OUTPUTS', '1'), config_content='''[compositor]
xwayland = false
default_file_manager = "dock-files.desktop"
default_terminal = "dock-terminal.desktop"
[animations]
enabled = false
''', env_extra={'DBUS_SESSION_BUS_ADDRESS': '', 'DBUS_SYSTEM_BUS_ADDRESS': 'unix:path=/nonexistent',
               'XDG_CONFIG_HOME': str(tmp / 'config'), 'XDG_DATA_HOME': str(tmp / 'data'),
               'XDG_DATA_DIRS': str(tmp / 'empty'), 'XDG_CACHE_HOME': str(tmp / 'cache'),
               'TERMINAL': f'"{fallback}" --app-id dock.fallback', 'REDIWM_FILES_DEVICES': '0'})
        clients = []
        try:
            with IPCClient(tmp) as ipc:
                ipc.wait_for('wallpaper_presented', timeout_ms=10000)
                ui = UIDriver(ipc)
                def dock():
                    return ui.widgets('dock')
                def button(name):
                    return next(w for w in dock() if w['name'] == name)
                def center(widget):
                    b = widget['global_box']
                    return round(b['x'] + b['width'] / 2), round(b['y'] + b['height'] / 2)
                def click(widget):
                    ipc.click_at(*center(widget))
                    ipc.wait_for_frame()
                def shot(name):
                    path = tmp / (name + '.png')
                    ipc.screenshot(str(path))
                    with Image.open(path) as image:
                        return image.convert('RGB')
                def pill(name, screenshot):
                    ipc.move_cursor(5, 5)
                    ipc.wait_for_frame()
                    b = button(name)['global_box']
                    root = dock()[0]['global_box']
                    x, y = b['x'] + b['width'] / 2, b['y'] + b['height'] + 1
                    return shot(screenshot).crop(tuple(round(v * scale) for v in
                        (x - 12, y, x + 12, root['y'] + root['height'] - 2)))
                def shortcuts_only():
                    return {w['name'] for w in dock() if w['name']} == {'applications', 'files', 'terminal', 'settings', 'trash'}
                assert not dock(), 'dock must default off'
                ipc.action('open_control_center')
                ipc.wait_for_panel_settled('control_center')
                click(ui.find('Appearance', panel='control_center'))
                toggle = ui.scroll_into_view('dock_enabled')
                assert toggle['on'] is False
                click(toggle)
                wait_for(dock, 'dock enabled')
                assert tomllib.loads((tmp / 'rediwm-config.toml').read_text())['compositor']['dock_enabled']
                click(ui.scroll_into_view('dock_enabled'))
                wait_for(lambda: not dock(), 'dock disabled')
                assert not tomllib.loads((tmp / 'rediwm-config.toml').read_text())['compositor']['dock_enabled']
                click(ui.scroll_into_view('dock_enabled'))
                wait_for(dock, 'dock enabled again')
                assert ui.scroll_into_view('dock_position')['selected_index'] == 1
                for index, position in ((0, 'top'), (2, 'left'), (3, 'right'), (1, 'bottom')):
                    area = ui.scroll_into_view('dock_position')['global_box']
                    ipc.click_at(round(area['x'] + area['width'] * (index + .5) / 4),
                                 round(area['y'] + area['height'] / 2))
                    wait_for(lambda: tomllib.loads((tmp / 'rediwm-config.toml').read_text())['compositor'].get('dock_position') == position, 'dock position saved')
                    wait_for(lambda: dock()[0]['global_box']['width' if position in ('left', 'right') else 'height'] == 68, 'dock position applied')
                    root = dock()[0]['global_box']
                    assert root['width' if position in ('left', 'right') else 'height'] == 68
                    assert ui.find('dock_position', panel='control_center')['selected_index'] == index
                ipc.action('close_panel', {'panel': 'control_center'})
                ipc.action('open_appearance')
                ipc.wait_for_panel_settled('control_center')
                assert ui.scroll_into_view('dock_position')['selected_index'] == 1
                slider = ui.scroll_into_view('dock_height')
                assert (slider['min'], slider['max'], slider['step'], slider['value']) == (48, 96, 2, 68)
                root = dock()[0]['global_box']
                bottom = root['y'] + root['height']
                for height in (48, 96, 68):
                    slider = ui.scroll_into_view('dock_height')
                    area = slider['global_box']
                    fraction = (height - 48) / 48
                    for _ in range(3):
                        point = (round(area['x'] + min(area['width'] - 1, area['width'] * fraction)),
                                 round(area['y'] + area['height'] / 2))
                        if ipc.hit_test(*point)['target_type'] != 'dock':
                            break
                        # A large dock can cover the bottom of the Settings
                        # window. Scroll the control farther up before clicking.
                        viewport = next(w['global_box'] for w in ui.widgets('control_center') if w['role'] == 'scroll_container')
                        ipc.move_cursor(viewport['x'] + viewport['width'] - 8, viewport['y'] + 40)
                        ipc.scroll(0, -130)
                        previous_y = area['y']
                        wait_for(lambda: ui.find('dock_height', panel='control_center')['global_box']['y'] < previous_y, 'slider scrolled above dock')
                        area = ui.scroll_into_view('dock_height')['global_box']
                    ipc.click_at(*point)
                    wait_for(lambda: dock()[0]['global_box']['height'] == height,
                             f'dock height changed live to {height}: slider={ui.find("dock_height", panel="control_center")["value"]}, dock={dock()[0]["global_box"]}')
                    assert tomllib.loads((tmp / 'rediwm-config.toml').read_text())['compositor']['dock_height'] == height
                    root = dock()[0]['global_box']
                    assert root['y'] + root['height'] == bottom, 'resize moved the dock bottom'
                    for item in (w for w in dock() if w['name']):
                        box = item['global_box']
                        assert 30 <= box['height'] <= 68 and box['width'] == box['height']
                        assert root['x'] <= box['x'] and box['x'] + box['width'] <= root['x'] + root['width']
                        assert root['y'] <= box['y'] and box['y'] + box['height'] < bottom
                        assert ipc.hit_test(*center(item))['target_type'] == 'dock'
                    if height == 96:
                        ipc.action('close_panel', {'panel': 'control_center'})
                        ipc.action('open_appearance')
                        ipc.wait_for_panel_settled('control_center')
                        assert ui.scroll_into_view('dock_height')['value'] == 96
                zoom_slider = ui.scroll_into_view('dock_hover_zoom')
                assert (zoom_slider['min'], zoom_slider['max']) == (1, 1.5)
                assert abs(zoom_slider['step'] - .05) < .001
                assert abs(zoom_slider['value'] - 1.05) < .001
                for zoom in (1, 1.5, 1.05):
                    area = ui.scroll_into_view('dock_hover_zoom')['global_box']
                    for _ in range(3):
                        point = (round(area['x'] + min(area['width'] - 1, area['width'] * (zoom - 1) / .5)),
                                 round(area['y'] + area['height'] / 2))
                        if ipc.hit_test(*point)['target_type'] != 'dock':
                            break
                        viewport = next(w['global_box'] for w in ui.widgets() if w['role'] == 'scroll_container')
                        ipc.move_cursor(viewport['x'] + viewport['width'] - 8, viewport['y'] + 40)
                        ipc.scroll(0, -130)
                        wait_for(lambda: ui.find('dock_hover_zoom')['global_box']['y'] < area['y'], 'zoom scrolled above dock')
                        area = ui.scroll_into_view('dock_hover_zoom')['global_box']
                    ipc.click_at(*point)
                    wait_for(lambda: abs(tomllib.loads((tmp / 'rediwm-config.toml').read_text())['compositor'].get('dock_hover_zoom', 0) - zoom) < .001, 'zoom saved')
                ipc.action('close_panel', {'panel': 'control_center'})
                ipc.action('open_appearance')
                ipc.wait_for_panel_settled('control_center')
                assert abs(ui.scroll_into_view('dock_hover_zoom')['value'] - 1.05) < .001
                # Opacity, corner radius and the active app's rectangle are settings too.
                settings_cfg = tmp / 'rediwm-config.toml'
                settings_before = settings_cfg.read_text()
                def click_slider(name, fraction):
                    for _ in range(3):
                        area = ui.scroll_into_view(name)['global_box']
                        point = (round(area['x'] + min(area['width'] - 1, area['width'] * fraction)),
                                 round(area['y'] + area['height'] / 2))
                        if ipc.hit_test(*point)['target_type'] != 'dock':
                            break
                        viewport = next(w['global_box'] for w in ui.widgets() if w['role'] == 'scroll_container')
                        ipc.move_cursor(viewport['x'] + viewport['width'] - 8, viewport['y'] + 40)
                        ipc.scroll(0, -130)
                    ipc.click_at(*point)
                opacity = ui.scroll_into_view('dock_opacity')
                assert (opacity['min'], opacity['max']) == (0, 100)
                radius = ui.scroll_into_view('dock_radius')
                assert (radius['min'], radius['max']) == (1, 48)
                assert radius['value'] == 10, 'dock radius slider must show the window radius it follows'
                assert ui.scroll_into_view('dock_active_highlight')['on'] is False, 'active app rectangle must default off'
                click_slider('dock_opacity', .3)
                wait_for(lambda: abs(tomllib.loads(settings_cfg.read_text())['compositor'].get('dock_opacity', 9) - .3) < .03, 'dock opacity saved')
                click_slider('dock_radius', .3)
                wait_for(lambda: abs(tomllib.loads(settings_cfg.read_text()).get('theme', {}).get('dock_radius', 0) - 15) <= 1, 'dock radius saved')
                click(ui.scroll_into_view('dock_active_highlight'))
                wait_for(lambda: tomllib.loads(settings_cfg.read_text())['compositor'].get('dock_active_highlight') is True, 'active app rectangle saved')
                # The Trash shows by default, last on the dock; the switch removes it.
                assert ui.scroll_into_view('dock_show_trash')['on'] is True, 'dock trash must default on'
                assert dock()[-1]['name'] == 'trash', 'trash must be the last dock item'
                click(ui.scroll_into_view('dock_show_trash'))
                wait_for(lambda: tomllib.loads(settings_cfg.read_text())['compositor'].get('dock_show_trash') is False, 'dock trash setting saved')
                wait_for(lambda: all(w['name'] != 'trash' for w in dock()), 'trash leaves the dock')
                settings_cfg.write_text(settings_before)
                ipc.reload_config()
                wait_for(lambda: dock()[-1]['name'] == 'trash', 'reload brings the trash back')
                ipc.action('close_panel', {'panel': 'control_center'})
                ipc.wait_for_frame()
                assert ipc.get_shell_state()['taskbars'], 'dock must coexist with taskbar'
                assert ipc.hit_test(*center(button('terminal')))['target_type'] == 'dock'
                ipc.move_cursor(5, 5)
                # The dock's raster and glass mask follow the window radius,
                # including a live reload back to a previously painted shape.
                cfg = tmp / 'rediwm-config.toml'
                original = cfg.read_text()
                corners = []
                for index, radius in enumerate((0, 24, 0)):
                    cfg.write_text(original + f'\n[theme]\nradius_lg = {radius}\n')
                    ipc.reload_config()
                    ipc.wait_for_frame()
                    box = button('applications')['global_box']
                    x, y = box['x'] - 12, box['y'] - 8
                    corners.append(shot(f'radius-{index}').crop(tuple(round(v * scale) for v in
                        (x, y, x + 8, y + 8))))
                assert ImageChops.difference(corners[0], corners[1]).getbbox(), 'dock ignores window radius'
                assert not ImageChops.difference(corners[0], corners[2]).getbbox(), 'dock radius did not restore'
                cfg.write_text(original)
                ipc.reload_config()
                ipc.wait_for_frame()
                plain = shot('plain')
                ipc.move_cursor(*center(button('terminal')))
                ipc.wait_for_frame()
                hover = shot('hover')
                assert ImageChops.difference(plain, hover).getbbox(), 'no hover feedback'
                # The enlarged icon is the feedback: no rectangle behind it, not even in the strip the icon never reaches.
                edge = button('terminal')['global_box']
                strip = tuple(round(v * scale) for v in (edge['x'], edge['y'] + edge['height'] / 2 - 6, edge['x'] + 3, edge['y'] + edge['height'] / 2 + 6))
                assert not ImageChops.difference(plain.crop(strip), hover.crop(strip)).getbbox(), 'hover rectangle shown with hover zoom'
                # Leaving in one jump unhovers the dock; motion elsewhere then paints nothing.
                ipc.move_cursor(5, 5)
                ipc.wait_for_frame()
                def panel_bytes():
                    perf = ipc.get_perf()
                    return perf['panel_allocated_bytes'] + perf['panel_reused_bytes']
                painted = panel_bytes()
                for x in range(40, 60):
                    ipc.move_cursor(x, 40)
                ipc.wait_for_frame()
                assert panel_bytes() == painted, 'motion off the dock repaints it'
                if preview := os.environ.get('REDIWM_DOCK_PREVIEW'):
                    hover.save(preview)
                click(button('applications'))
                wait_for(lambda: ipc.get_shell_state()['start_menu'], 'dock launcher')
                ipc.action('close_panel', {'panel': 'start_menu'})
                ipc.wait_for_frame()
                settings_idle = pill('settings', 'settings-idle')
                click(button('settings'))
                wait_for(lambda: ipc.get_shell_state()['control_center'], 'dock settings')
                wait_for(shortcuts_only, 'Settings shares its shortcut')
                assert ImageChops.difference(settings_idle, pill('settings', 'settings-running')).getbbox()
                # A running shortcut has the same window actions as an unpinned app.
                ipc.move_cursor(*center(button('settings')))
                ipc.pointer_button(273, True)
                ipc.pointer_button(273, False)
                for code in (108, 28):  # Down selects Close; Enter activates it.
                    ipc.key(code, True)
                    ipc.key(code, False)
                wait_for(lambda: not ipc.get_shell_state()['control_center'], 'shortcut menu closes Settings')
                ipc.wait_for_frame()
                ipc.wait_for('catalog_published', timeout_ms=10000)
                for shortcut, app_id, desktop_id, height in (
                    ('files', 'dock.files.running', 'dock-files.desktop', 48),
                    ('terminal', 'dock.terminal.running', 'dock-terminal.desktop', 96),
                    ('terminal', 'dock.fallback', None, 68),
                ):
                    text = cfg.read_text()
                    previous_height = tomllib.loads(text)['compositor']['dock_height']
                    cfg.write_text(text.replace(f'dock_height = {previous_height}', f'dock_height = {height}'))
                    ipc.reload_config()
                    wait_for(lambda: dock()[0]['global_box']['height'] == height, 'height reload')
                    if desktop_id is None:
                        cfg.write_text(cfg.read_text().replace('default_terminal = "dock-terminal.desktop"', 'default_terminal = ""'))
                        ipc.reload_config()
                        ipc.wait_for_frame()
                    idle = pill(shortcut, f'{app_id}-idle')
                    position = button(shortcut)['global_box']
                    click(button(shortcut))
                    win = wait_for(lambda: next((w for w in ipc.get_windows() if w['app_id'] == app_id), None), 'shortcut launch')
                    wid = win['id']
                    wait_for(shortcuts_only, 'launch must not add another dock icon')
                    assert button(shortcut)['global_box'] == position, 'launch changed dock geometry'
                    running = pill(shortcut, f'{app_id}-running')
                    assert ImageChops.difference(idle, running).getbbox(), 'running pill missing'
                    click(button(shortcut))
                    wait_for(lambda: next(w for w in ipc.get_windows() if w['id'] == wid)['is_minimized'], 'shortcut minimizes its app')
                    assert len(ipc.get_windows()) == 1, 'shortcut launched another instance'
                    click(button(shortcut))
                    wait_for(lambda: not next(w for w in ipc.get_windows() if w['id'] == wid)['is_minimized'], 'shortcut restores its app')
                    assert len(ipc.get_windows()) == 1
                    assert ipc.get_focused_window()['id'] == wid
                    if desktop_id:
                        single = count_badge(ipc, ui, shortcut, scale, tmp / 'badge-single.png')
                        ipc.action('launch_app', {'desktop_id': desktop_id})
                        second = wait_for(lambda: next((w for w in ipc.get_windows() if w['id'] != wid), None), 'second instance')
                        wait_for(shortcuts_only, 'multiple windows share one shortcut')
                        double = count_badge(ipc, ui, shortcut, scale, tmp / 'badge-double.png')
                        assert ImageChops.difference(single, double).getbbox(), 'two windows have no count badge'
                        click(button(shortcut))
                        wait_for(lambda: len([w for w in ui.widgets('window_picker') if w['role'] == 'row']) == 2, 'two-window picker')
                        picker = ui.widgets('window_picker')
                        rows = [w for w in picker if w['role'] == 'row']
                        assert {w['name'] for w in rows} == {f'window_{wid}', f'window_{second["id"]}'}
                        assert all(w['global_box']['height'] == 40 for w in rows), 'window rows should be compact'
                        assert len([w for w in picker if w['role'] == 'text' and w['label']]) == 2, 'window titles missing'
                        assert {w['name'] for w in picker if w['role'] == 'button'} == {f'close_window_{wid}', f'close_window_{second["id"]}'}, 'window close buttons missing'
                        ipc.key(1, True)
                        ipc.key(1, False)
                        wait_for(lambda: not ui.widgets('window_picker'), 'Escape closes window picker')
                        ipc.action('minimize_window', {'id': second['id']})
                        minimized = count_badge(ipc, ui, shortcut, scale, tmp / 'badge-minimized.png')
                        assert not ImageChops.difference(double, minimized).getbbox(), 'minimized window missing from count'
                        click(button(shortcut))
                        wait_for(lambda: bool(ui.widgets('window_picker')), 'picker includes minimized window')
                        click(ui.find(f'window_{second["id"]}', panel='window_picker'))
                        wait_for(lambda: not next(w for w in ipc.get_windows() if w['id'] == second['id'])['is_minimized'], 'picker restores chosen window')
                        assert ipc.get_focused_window()['id'] == second['id']
                        assert not ui.widgets('window_picker'), 'selection left picker open'
                        click(button(shortcut))
                        ipc.click_at(5, 5)
                        wait_for(lambda: not ui.widgets('window_picker'), 'outside click closes picker')
                        click(button(shortcut))
                        ipc.key(108, True)  # Down selects the first window.
                        ipc.key(108, False)
                        ipc.key(28, True)
                        ipc.key(28, False)
                        wait_for(lambda: not ui.widgets('window_picker'), 'keyboard selection closes picker')
                        assert ipc.get_focused_window()['id'] == wid, 'keyboard chose the wrong window'
                        ipc.action('launch_app', {'desktop_id': desktop_id})
                        third = wait_for(lambda: next((w for w in ipc.get_windows() if w['id'] not in (wid, second['id'])), None), 'third instance')
                        triple = count_badge(ipc, ui, shortcut, scale, tmp / 'badge-triple.png')
                        assert ImageChops.difference(double, triple).getbbox(), 'count did not change from two to three'
                        click(button(shortcut))
                        close = ui.find(f'close_window_{third["id"]}', panel='window_picker')
                        ipc.move_cursor(*center(ui.find(f'window_{third["id"]}', panel='window_picker')))
                        ipc.wait_for_frame()
                        box = close['global_box']
                        close_box = tuple(round(v * scale) for v in (box['x'], box['y'], box['x'] + box['width'], box['y'] + box['height']))
                        resting = shot(f'{shortcut}-close-rest').crop(close_box)
                        ipc.move_cursor(*center(close))
                        ipc.wait_for_frame()
                        assert ImageChops.difference(resting, shot(f'{shortcut}-close-hover').crop(close_box)).getbbox(), 'close button has no hover feedback'
                        click(close)
                        wait_for(lambda: len(ipc.get_windows()) == 2, 'third window closed')
                        assert not ui.widgets('window_picker'), 'close button left picker open'
                        assert not ImageChops.difference(double, count_badge(ipc, ui, shortcut, scale, tmp / 'badge-two-left.png')).getbbox(), 'count did not return to two'
                        ipc.action('focus_window', {'id': wid})
                        ipc.action('minimize_window', {'id': second['id']})
                        click(button(shortcut))
                        click(ui.find(f'close_window_{second["id"]}', panel='window_picker'))
                        wait_for(lambda: len(ipc.get_windows()) == 1, 'second window closed')
                        assert ipc.get_focused_window()['id'] == wid, 'closing a minimized window changed focus'
                        assert not ImageChops.difference(single, count_badge(ipc, ui, shortcut, scale, tmp / 'badge-one-left.png')).getbbox(), 'badge survived with one window left'
                        assert ImageChops.difference(idle, pill(shortcut, f'{app_id}-one-left')).getbbox(), 'pill disappeared with a window left'
                    if shortcut == 'files':
                        before_removal = cfg.read_text()
                        ipc.move_cursor(*center(button(shortcut)))
                        ipc.pointer_button(273, True)
                        ipc.pointer_button(273, False)
                        assert not ui.widgets('window_picker'), 'right click opened a window picker'
                        for code in (103, 28):  # Up selects Remove from dock.
                            ipc.key(code, True)
                            ipc.key(code, False)
                        wait_for(lambda: not any(w['name'] == 'files' for w in dock()), 'running shortcut removed')
                        # Only the launcher goes: the running app still shows, as a window.
                        wait_for(lambda: sum((w['name'] or '').startswith('window_') for w in dock()) == 1, 'removed shortcut hid its running app')
                        assert len(ipc.get_windows()) == 1, 'removing shortcut closed the app'
                        cfg.write_text(before_removal)
                        ipc.reload_config()
                        wait_for(shortcuts_only, 'shortcut restored with its running app')
                    ipc.action('close_window', {'id': wid})
                    wait_for(lambda: not ipc.get_windows(), 'last window closed')
                    ipc.wait_for_frame()
                    restored = pill(shortcut, f'{app_id}-closed')
                    difference = ImageChops.difference(idle, restored)
                    assert max(high for low, high in difference.getextrema()) <= 1, 'pill survived the last window'
                display = wait_for(lambda: next((p.name for p in tmp.glob('wayland-*') if not p.name.endswith('.lock')), None), 'display')
                clients.append(subprocess.Popen([str(tmp / 'client'), '--app-id', 'dock.test', '--title', 'Dock test'],
                    env=dict(os.environ, XDG_RUNTIME_DIR=str(tmp), WAYLAND_DISPLAY=display), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
                win = wait_for(lambda: next((w for w in ipc.get_windows() if w['app_id'] == 'dock.test'), None), 'test window')
                wid = win['id']
                name = f'window_{wid}'
                wait_for(lambda: any(w['name'] == name for w in dock()), 'window in dock')
                ipc.wait_for('window_geometry_settled', window_id=wid)
                click(button(name))
                wait_for(lambda: next(w for w in ipc.get_windows() if w['id'] == wid)['is_minimized'], 'dock minimize')
                click(button(name))
                wait_for(lambda: not next(w for w in ipc.get_windows() if w['id'] == wid)['is_minimized'], 'dock restore')
                assert ipc.get_focused_window()['id'] == wid
                single = count_badge(ipc, ui, name, scale, tmp / 'window-badge-single.png')
                clients.append(subprocess.Popen([str(tmp / 'client'), '--app-id', 'dock.test'],
                    env=dict(os.environ, XDG_RUNTIME_DIR=str(tmp), WAYLAND_DISPLAY=display),
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
                second = wait_for(lambda: next((w for w in ipc.get_windows() if w['id'] != wid), None), 'second unpinned window')
                double = count_badge(ipc, ui, name, scale, tmp / 'window-badge-double.png')
                assert ImageChops.difference(single, double).getbbox(), 'unpinned app has no window count'
                click(button(name))
                wait_for(lambda: len([w for w in ui.widgets('window_picker') if w['role'] == 'row']) == 2, 'unpinned window picker')
                ipc.action('close_window', {'id': second['id']})
                wait_for(lambda: len(ipc.get_windows()) == 1, 'second unpinned window closed')
                assert not ui.widgets('window_picker'), 'closing a listed window left a stale picker'
                assert not ImageChops.difference(single, count_badge(ipc, ui, name, scale, tmp / 'window-badge-one-left.png')).getbbox(), 'unpinned count survived with one window'
                ipc.action('focus_window', {'id': wid})
                ipc.wait_for_frame()
                # The focused app's rectangle is off by default; the setting draws it.
                # A strip beside the icon, inside the button, shows it.
                ipc.move_cursor(5, 5)
                ipc.wait_for_frame()
                focused_box = button(name)['global_box']
                beside = tuple(round(v * scale) for v in (focused_box['x'], focused_box['y'] + focused_box['height'] / 2 - 6,
                                                          focused_box['x'] + 3, focused_box['y'] + focused_box['height'] / 2 + 6))
                dock_root = dock()[0]['global_box']
                backdrop = tuple(round(v * scale) for v in (dock_root['x'] + 3, dock_root['y'] + dock_root['height'] / 2 - 6,
                                                            dock_root['x'] + 8, dock_root['y'] + dock_root['height'] / 2 + 6))
                base_config = cfg.read_text()
                def with_dock(lines, name):
                    cfg.write_text(base_config.replace('[compositor]', '[compositor]\n' + lines, 1))
                    ipc.reload_config()
                    ipc.wait_for_frame()
                    ipc.move_cursor(5, 5)
                    ipc.wait_for_frame()
                    return shot(name)
                plain_dock = shot('dock-plain')
                highlighted = with_dock('dock_active_highlight = true', 'dock-highlighted')
                assert ImageChops.difference(plain_dock.crop(beside), highlighted.crop(beside)).getbbox(), 'active app rectangle missing when enabled'
                assert not ImageChops.difference(plain_dock.crop(backdrop), highlighted.crop(backdrop)).getbbox()
                # Opacity changes the background and nothing else of the icon strip.
                solid = with_dock('dock_opacity = 1.0', 'dock-solid')
                clear = with_dock('dock_opacity = 0.0', 'dock-clear')
                assert ImageChops.difference(solid.crop(backdrop), clear.crop(backdrop)).getbbox(), 'dock opacity ignored'
                cfg.write_text(base_config)
                ipc.reload_config()
                ipc.wait_for_frame()
                fullscreen_point = center(button(name))
                ipc.action('fullscreen_window', {'id': wid})
                wait_for(lambda: not dock(), 'fullscreen hides dock')
                # Fullscreen on one monitor must leave the other dock visible.
                for bar in ipc.get_shell_state()['taskbars']:
                    b = bar['box']
                    x, y = b['x'] + b['width'] // 2, b['y'] - 40
                    if not b['x'] <= fullscreen_point[0] < b['x'] + b['width']:
                        assert ipc.hit_test(x, y)['target_type'] == 'dock'
                ipc.action('fullscreen_window', {'id': wid})
                wait_for(dock, 'leave fullscreen restores dock')
                ipc.move_cursor(*center(button(name)))
                ipc.action('close_window', {'id': wid})
                wait_for(lambda: not any(w['name'] == name for w in dock()), 'closed hovered window removed')
                if os.environ.get('REDIWM_DOCK_OVERFLOW'):
                    capacity = (ipc.get_outputs()[0]['logical_width'] - 40) // 56 - 4
                    for index in range(capacity + 2):
                        clients.append(subprocess.Popen([str(tmp / 'client'), '--app-id', f'dock.overflow{index}'],
                            env=dict(os.environ, XDG_RUNTIME_DIR=str(tmp), WAYLAND_DISPLAY=display),
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
                    wait_for(lambda: len(ipc.get_windows()) == capacity + 2, 'overflow windows')
                    ipc.wait_for_frame()
                    def shown():
                        return {w['name'] for w in dock() if (w['name'] or '').startswith('window_')}
                    first = shown()
                    assert len(first) == capacity
                    ipc.move_cursor(*center(button('terminal')))
                    # Poll: with two outputs the next frame may be the other output's.
                    ipc.scroll(0, -120)
                    try:
                        wait_for(lambda: shown() != first, 'scroll', timeout=2)
                    except AssertionError:
                        ipc.scroll(0, 120)
                        wait_for(lambda: shown() != first, 'overflow windows cannot be reached')
                    for client in clients:
                        stop_process(client)
                    wait_for(lambda: not ipc.get_windows(), 'overflow cleanup')
                    wait_for(lambda: not shown(), 'closed windows left in the dock')
                # Config reload relocates the dock above a bottom taskbar only.
                cfg = tmp / 'rediwm-config.toml'
                before = button('terminal')['global_box']['y']
                cfg.write_text(cfg.read_text().replace('[compositor]', '[compositor]\ntaskbar_position = "top"'))
                ipc.reload_config()
                wait_for(lambda: button('terminal')['global_box']['y'] > before, 'dock moved down')
                x, y = center(button('terminal'))
                cfg.write_text(cfg.read_text().replace('dock_enabled = true', 'dock_enabled = false'))
                ipc.reload_config()
                wait_for(lambda: not dock(), 'reload disables dock')
                assert ipc.hit_test(x, y)['target_type'] != 'dock', 'disabled dock intercepts input'
            print(f'PASS: dock defaults, Appearance height, persistence, hover, grouped launchers, running pills, windows, fullscreen, reload ({scale}x)')
        except Exception:
            print((tmp / 'compositor.log').read_text()[-4000:])
            raise
        finally:
            for client in clients:
                stop_process(client)
            stop_process(process)
            log.close()


def context_menu():
    scale = float(os.environ.get('REDIWM_TEST_SCALE', '1'))
    with tempfile.TemporaryDirectory(prefix='rediwm-dock-menu-') as directory:
        tmp = Path(directory)
        build_client(tmp)
        env_extra = {'DBUS_SESSION_BUS_ADDRESS': '', 'DBUS_SYSTEM_BUS_ADDRESS': 'unix:path=/nonexistent',
                     'XDG_CONFIG_HOME': str(tmp / 'config'), 'XDG_DATA_HOME': str(tmp / 'data'),
                     'XDG_CACHE_HOME': str(tmp / 'cache')}
        process, log = spawn_compositor(tmp, scale=scale,
            outputs=os.environ.get('REDIWM_TEST_OUTPUTS', '1'),
            config_content='# keep this comment\n[compositor]\nxwayland = false\ndock_enabled = true\ndock_height = 96\n'
                           '[animations]\nenabled = false\n', env_extra=env_extra)
        cfg = tmp / 'rediwm-config.toml'
        clients = []
        try:
            with IPCClient(tmp) as ipc:
                ipc.wait_for('wallpaper_presented', timeout_ms=10000)
                ui = UIDriver(ipc)
                display = wait_for(lambda: next((p.name for p in tmp.glob('wayland-*')
                    if not p.name.endswith('.lock')), None), 'display')

                def names():
                    return {w['name'] for w in ui.widgets('dock') if w['name']}

                def launch(app):
                    previous = {w['id'] for w in ipc.get_windows()}
                    client = subprocess.Popen([str(tmp / 'client'), '--app-id', app],
                        env=dict(os.environ, XDG_RUNTIME_DIR=str(tmp), WAYLAND_DISPLAY=display),
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    clients.append(client)
                    win = wait_for(lambda: next((w for w in ipc.get_windows() if w['id'] not in previous), None), 'client')
                    ipc.wait_for_frame()
                    return client, win['id']

                def menu(name):
                    widget = wait_for(lambda: next((w for w in ui.widgets('dock') if w['name'] == name), None), name)
                    box = widget['global_box']
                    x = round(box['x'] + box['width'] / 2)
                    ipc.move_cursor(x, round(box['y'] + box['height'] / 2))
                    ipc.pointer_button(273, True)
                    ipc.pointer_button(273, False)
                    ipc.wait_for_frame()
                    height = 83 if name.startswith('window_') else 44
                    return x, ui.widgets('dock')[0]['global_box']['y'] - height - 4

                def key(code):
                    ipc.key(code, True)
                    ipc.key(code, False)

                first, wid = launch('dock.removed')
                second, other_id = launch('dock.removed')
                x, y = menu(f'window_{wid}')
                ipc.click_at(x + 20, y + 41)  # Separator is inert.
                assert len(ipc.get_windows()) == 2
                key(1)  # Escape
                menu(f'window_{wid}')
                ipc.click_at(5, 5)  # Outside dismisses without activating the dock.
                assert len(ipc.get_windows()) == 2
                # A running app cannot be removed from the dock (its menu is only
                # Close and Force Close), whatever the old config said.
                assert {f'window_{wid}', f'window_{other_id}'} <= names(), 'a running app left the dock'
                assert 'dock_hidden_apps' not in tomllib.loads(cfg.read_text())['compositor']
                ipc.reload_config()
                assert {f'window_{wid}', f'window_{other_id}'} <= names()

                x, y = menu('terminal')
                ipc.click_at(x + 20, y + 22)
                wait_for(lambda: 'terminal' not in names(), 'shortcut removed')
                assert tomllib.loads(cfg.read_text())['compositor']['dock_hidden_shortcuts'] == ['terminal']
                assert '# keep this comment' in cfg.read_text()

                client, close_id = launch('dock.close')
                x, y = menu(f'window_{close_id}')
                ipc.click_at(x + 20, y + 22)
                wait_for(lambda: all(w['id'] != close_id for w in ipc.get_windows()), 'Close')
                assert client.wait(timeout=5) == 0
                client, hung_id = launch('dock.hung')
                ipc.action('minimize_window', {'id': hung_id})
                client.send_signal(signal.SIGSTOP)
                menu(f'window_{hung_id}')
                key(108)
                key(108)  # Down selects Force Close, skipping the separator.
                key(28)
                wait_for(lambda: all(w['id'] != hung_id for w in ipc.get_windows()), 'Force Close')
                assert client.wait(timeout=5) == -signal.SIGKILL

                client, gone_id = launch('dock.gone')
                menu(f'window_{gone_id}')
                stop_process(client)
                wait_for(lambda: all(w['id'] != gone_id for w in ipc.get_windows()), 'menu target gone')
                ipc.wait_for_frame()
                assert process.poll() is None

                # Windows without an app ID show too.
                anonymous, anon_id = launch('')
                anonymous2, anon_id2 = launch('')
                assert {f'window_{anon_id}', f'window_{anon_id2}'} <= names()
                assert len(ipc.get_windows()) == 4
                stop_process(anonymous)
                stop_process(anonymous2)
                wait_for(lambda: len(ipc.get_windows()) == 2, 'anonymous cleanup')

                # Disabling the dock dismisses even a shortcut menu with no window target.
                menu('applications')
                cfg.write_text(cfg.read_text().replace('dock_enabled = true', 'dock_enabled = false'))
                ipc.reload_config()
                wait_for(lambda: not names(), 'disabled dock')
                key(28)
                assert tomllib.loads(cfg.read_text())['compositor']['dock_hidden_shortcuts'] == ['terminal']
                cfg.write_text(cfg.read_text().replace('dock_enabled = false', 'dock_enabled = true'))
                ipc.reload_config()
                wait_for(names, 'dock restored')
                for shortcut in ('files', 'applications', 'settings', 'trash'):
                    menu(shortcut)
                    key(103)
                    key(28)
                    wait_for(lambda: shortcut not in names(), 'shortcut removed')
                # Removing the Trash turns its Appearance switch off.
                assert tomllib.loads(cfg.read_text())['compositor']['dock_show_trash'] is False
                assert any(n.startswith('window_') for n in names()), 'running apps left the dock with its shortcuts'
                stop_process(first)
                stop_process(second)
                wait_for(lambda: not ipc.get_windows(), 'windows closed')
                wait_for(lambda: not names(), 'empty dock should be hidden')
                saved = cfg.read_text()

            for client in clients:
                stop_process(client)
            stop_process(process)
            log.close()
            process, log = spawn_compositor(tmp, scale=scale, config_content=saved, env_extra=env_extra)
            with IPCClient(tmp) as ipc:
                ipc.wait_for('wallpaper_presented', timeout_ms=10000)
                ui = UIDriver(ipc)
                display = wait_for(lambda: next((p.name for p in tmp.glob('wayland-*')
                    if not p.name.endswith('.lock')), None), 'display after restart')
                assert not names(), 'removed shortcuts returned after restart'
                client, reopened = launch('dock.removed')
                wait_for(lambda: names() == {f'window_{reopened}'}, 'running app hidden after restart')
                assert any(c['window_id'] == reopened for c in ipc.get_shell_state()['taskbars'][0]['chips'])
                cfg.write_text(cfg.read_text().replace(
                    'dock_hidden_shortcuts = ["terminal", "files", "applications", "settings"]',
                    'dock_hidden_shortcuts = []').replace('[compositor]', '[compositor]\ntaskbar_position = "top"'))
                ipc.reload_config()
                wait_for(lambda: names() == {'applications', 'files', 'terminal', 'settings', f'window_{reopened}'}, 'shortcuts restored')
                assert ui.widgets('dock')[0]['global_box']['height'] == 96, 'dock height lost after restart'
                # A dock menu stays above the dock with a top taskbar, too.
                x, y = menu('settings')
                ipc.click_at(x + 20, y + 22)
                wait_for(lambda: 'settings' not in names(), 'menu anchored to dock')
            print(f'PASS: dock context menu, Close, Force Close, shortcut removal, running apps always shown, dismissal, anonymous windows, persistence ({scale}x)')
        except Exception:
            log.flush()
            print((tmp / 'compositor.log').read_text()[-4000:])
            raise
        finally:
            for client in clients:
                stop_process(client)
            stop_process(process)
            log.close()


def pill_animation():
    scale = float(os.environ.get('REDIWM_TEST_SCALE', '1'))
    with tempfile.TemporaryDirectory(prefix='rediwm-dock-pill-') as directory:
        tmp = Path(directory)
        build_client(tmp)
        process, log = spawn_compositor(tmp, scale=scale,
            outputs=os.environ.get('REDIWM_TEST_OUTPUTS', '1'),
            config_content='[compositor]\nxwayland = false\ndock_enabled = true\n'
                           '[animations]\nenabled = true\nspeed = 1.0\nreduced_motion = "off"\n',
            env_extra={'DBUS_SESSION_BUS_ADDRESS': '', 'XDG_CONFIG_HOME': str(tmp / 'config'),
                       'XDG_DATA_HOME': str(tmp / 'data'), 'XDG_DATA_DIRS': str(tmp / 'empty'),
                       'XDG_CACHE_HOME': str(tmp / 'cache'), 'TERMINAL': 'foot'})
        clients = []
        try:
            with IPCClient(tmp) as ipc:
                ipc.wait_for('wallpaper_presented', timeout_ms=10000)
                primary = ipc.get_outputs()[0]['name']
                prefix = f'dock.{primary}.terminal.pill_'
                display = wait_for(lambda: next((p.name for p in tmp.glob('wayland-*')
                    if not p.name.endswith('.lock')), None), 'display')
                ui = UIDriver(ipc)
                clock = 1000
                ipc.action('set_anim_time', {'ms': clock})
                ipc.wait_for_frame(output=primary)

                def state(part='width'):
                    return next(a for a in ipc.action('get_animations') if a['site'] == prefix + part)

                def advance(ms):
                    nonlocal clock
                    clock += ms
                    ipc.action('set_anim_time', {'ms': clock})
                    ipc.wait_for_frame(output=primary)

                def launch(app):
                    previous = {w['id'] for w in ipc.get_windows()}
                    client = subprocess.Popen([str(tmp / 'client'), '--app-id', app],
                        env=dict(os.environ, XDG_RUNTIME_DIR=str(tmp), WAYLAND_DISPLAY=display),
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    clients.append(client)
                    win = wait_for(lambda: next((w for w in ipc.get_windows() if w['id'] not in previous), None), 'client')
                    ipc.wait_for_frame(output=primary)
                    return win['id']

                def pixels(name):
                    path = tmp / (name + '.png')
                    path.unlink(missing_ok=True)
                    ipc.screenshot(str(path))
                    widgets = ui.widgets('dock')
                    b = next(w['global_box'] for w in widgets if w['name'] == 'terminal')
                    root = widgets[0]['global_box']
                    x, y = b['x'] + b['width'] / 2, b['y'] + b['height'] + 1
                    with Image.open(path) as image:
                        return image.convert('RGB').crop(tuple(round(v * scale) for v in
                            (x - 14, y, x + 14, root['y'] + root['height'] - 2)))

                # Hover shares the dock's frame clock, reverses without jumping,
                # and exposes the enlarged icon as a clickable widget.
                def zoom_state():
                    site = f'dock.{primary}.terminal.hover_zoom'
                    return next((a for a in ipc.action('get_animations') if a['site'] == site), None)

                def terminal_box():
                    return next(w['global_box'] for w in ui.widgets('dock') if w['name'] == 'terminal')

                cfg = tmp / 'rediwm-config.toml'
                cfg.write_text(cfg.read_text().replace('[compositor]', '[compositor]\ndock_hover_zoom = 1.5'))
                ipc.reload_config()
                ipc.wait_for_frame(output=primary)
                base = terminal_box()
                x, y = round(base['x'] + base['width'] / 2), round(base['y'] + base['height'] / 2)
                ipc.move_cursor(x, y)
                assert zoom_state()['target'] == 1.5
                advance(60)
                growing_zoom = zoom_state()
                assert 1 < growing_zoom['value'] < 1.5
                ipc.move_cursor(5, 5)
                shrinking_zoom = zoom_state()
                assert shrinking_zoom['target'] == 1
                assert abs(shrinking_zoom['value'] - growing_zoom['value']) < .001
                assert abs(shrinking_zoom['velocity'] - growing_zoom['velocity']) < .001
                advance(1000)
                assert zoom_state()['value'] == 1 and zoom_state()['settled']
                ipc.move_cursor(x, y)
                advance(1000)
                expanded = terminal_box()
                assert zoom_state()['value'] == 1.5 and expanded['width'] > base['width']
                assert expanded['y'] < base['y'], 'bottom dock must grow upward'
                assert expanded['y'] + expanded['height'] == base['y'] + base['height'], 'hover moved the resting bottom edge'
                assert abs(expanded['x'] + expanded['width'] / 2 - (base['x'] + base['width'] / 2)) <= 1
                edge = (round(expanded['x'] + 1), y)
                assert edge[0] < base['x']
                ipc.move_cursor(*edge)
                assert zoom_state()['target'] == 1.5, 'expanded icon lost hover at its edge'
                assert ipc.hit_test(*edge)['target_type'] == 'dock'
                # Rebuild at an expanded edge preserves hover and input bounds.
                cfg.write_text(cfg.read_text() + '\n[theme]\ndock_radius = 17\n')
                ipc.reload_config()
                ipc.wait_for_frame(output=primary)
                assert zoom_state()['target'] == 1.5
                # An animation repaints only the cells it moves, over what was last
                # painted. From a whole repaint at rest, a settled hover must look as
                # a whole repaint of the hovered dock does (a theme change and back
                # repaints it all).
                def dock_image(name):
                    path = tmp / (name + '.png')
                    path.unlink(missing_ok=True)
                    ipc.screenshot(str(path))
                    root = ui.widgets('dock')[0]['global_box']
                    with Image.open(path) as image:
                        return image.convert('RGB').crop(tuple(round(v * scale) for v in
                            (root['x'], root['y'], root['x'] + root['width'], root['y'] + root['height'])))

                def repaint_whole():
                    for radius in (18, 17):
                        cfg.write_text(cfg.read_text().replace(f'dock_radius = {35 - radius}', f'dock_radius = {radius}'))
                        ipc.reload_config()
                        advance(1000)

                # Include a count badge in the retained/whole repaint comparison.
                zoom_windows = [launch('foot'), launch('foot')]
                ipc.move_cursor(5, 5)
                advance(1000)
                repaint_whole()
                at_rest = dock_image('at_rest')
                ipc.move_cursor(x, y)
                advance(60)
                advance(1000)
                assert zoom_state()['value'] == 1.5 and zoom_state()['settled']
                animated = dock_image('animated')
                assert ImageChops.difference(at_rest, animated).getbbox(), 'hover did not repaint'
                repaint_whole()
                assert ImageChops.difference(animated, dock_image('whole')).getbbox() is None, 'animated repaint differs from a whole one'
                for window_id in zoom_windows:
                    ipc.action('close_window', {'id': window_id})
                wait_for(lambda: not ipc.get_windows(), 'hover badge windows closed')
                advance(1000)
                cfg.write_text(cfg.read_text().replace('dock_hover_zoom = 1.5', 'dock_hover_zoom = 1.0'))
                ipc.reload_config()
                ipc.wait_for_frame(output=primary)
                assert zoom_state() is None, '1.0 must cancel hover animation'
                assert terminal_box()['width'] == base['width']
                ipc.move_cursor(5, 5)
                ipc.move_cursor(x, y)
                assert zoom_state() is None
                cfg.write_text(cfg.read_text().replace('dock_hover_zoom = 1.0', 'dock_hover_zoom = 1.5'))
                ipc.reload_config()
                ipc.wait_for_frame(output=primary)
                advance(1000)
                ipc.reset_perf()
                before_hover = ipc.get_perf()
                for _ in range(3):
                    ipc.wait_for_frame(output=primary)
                after_hover = ipc.get_perf()
                assert after_hover['anim_frames_scheduled'] == 0
                assert (after_hover['panel_allocated_bytes'] + after_hover['panel_reused_bytes'] ==
                        before_hover['panel_allocated_bytes'] + before_hover['panel_reused_bytes']), 'settled hover repaints'
                ipc.move_cursor(5, 5)
                advance(1000)
                idle = pixels('idle')
                wid = launch('foot')
                assert state()['target'] == 22 and state()['value'] == 0
                assert state()['curve'] == 'spring' and not state()['settled']
                advance(60)
                growing = state()
                assert 0 < growing['value'] < 22
                assert 0 < state('opacity')['value'] < 1
                assert ImageChops.difference(idle, pixels('growing')).getbbox(), 'animated pill did not paint'
                ipc.action('minimize_window', {'id': wid})
                ipc.wait_for_frame(output=primary)
                shrinking = state()
                assert shrinking['target'] == 10
                assert abs(shrinking['value'] - growing['value']) < 0.001
                assert abs(shrinking['velocity'] - growing['velocity']) < 0.001
                advance(60)
                before = state()
                ipc.action('restore_window', {'id': wid})
                ipc.wait_for_frame(output=primary)
                after = state()
                assert after['target'] == 22 and abs(after['value'] - before['value']) < 0.001
                assert abs(after['velocity'] - before['velocity']) < 0.001
                advance(1000)
                assert state()['settled'] and state()['value'] == 22

                other = launch('dock.pill.other')
                assert state()['target'] == 10 and state()['value'] == 22
                advance(60)
                before = state()
                assert 10 < before['value'] < 22
                cfg = tmp / 'rediwm-config.toml'
                cfg.write_text(cfg.read_text().replace('[compositor]', '[compositor]\ndock_hidden_shortcuts = ["files"]'))
                ipc.reload_config()
                ipc.wait_for_frame(output=primary)
                after = state()
                assert abs(after['value'] - before['value']) < 0.001, 'dock rebuild restarted the pill'
                assert abs(after['velocity'] - before['velocity']) < 0.001
                cfg.write_text(cfg.read_text().replace('speed = 1.0', 'speed = 0.5'))
                ipc.reload_config()
                ipc.wait_for_frame(output=primary)
                assert abs(state()['value'] - before['value']) < 0.001, 'speed reload jumped the pill'
                advance(1000)
                assert state()['value'] == 10 and state()['settled']
                cfg.write_text(cfg.read_text().replace('dock_hidden_shortcuts = ["files"]\n', ''))
                ipc.reload_config()
                ipc.wait_for_frame(output=primary)
                ipc.action('close_window', {'id': other})
                wait_for(lambda: len(ipc.get_windows()) == 1, 'other closed')
                ipc.wait_for_frame(output=primary)
                ipc.action('close_window', {'id': wid})
                wait_for(lambda: not ipc.get_windows(), 'terminal closed')
                ipc.wait_for_frame(output=primary)
                assert state()['target'] == 0 and state('opacity')['target'] == 0
                advance(60)
                assert 0 < state('opacity')['value'] < 1, 'pill disappeared without fading'
                advance(1000)
                assert state()['value'] == 0 and state('opacity')['value'] == 0
                difference = ImageChops.difference(idle, pixels('gone'))
                assert max(high for low, high in difference.getextrema()) <= 1, 'faded pill left pixels'
                ipc.reset_perf()
                for _ in range(3):
                    ipc.wait_for_frame(output=primary)
                assert ipc.get_perf()['anim_frames_scheduled'] == 0, 'pinned animation spins'

                # Turning animations off settles a transition immediately.
                wid = launch('foot')
                advance(60)
                cfg.write_text(cfg.read_text().replace('\nenabled = true\n', '\nenabled = false\n'))
                ipc.reload_config()
                ipc.wait_for_frame(output=primary)
                assert state()['value'] == 22 and state()['settled']
                ipc.action('minimize_window', {'id': wid})
                ipc.wait_for_frame(output=primary)
                assert state()['value'] == 10 and state('opacity')['value'] == 0.4

                # Reduced motion jumps width but retains the short opacity fade.
                cfg.write_text(cfg.read_text().replace('\nenabled = false\n', '\nenabled = true\n').replace('reduced_motion = "off"', 'reduced_motion = "on"'))
                ipc.reload_config()
                ipc.action('restore_window', {'id': wid})
                ipc.wait_for_frame(output=primary)
                assert state()['value'] == 22 and state()['settled']
                advance(1000)
                assert state('opacity')['settled'] and state('opacity')['value'] == 1
                b = terminal_box()
                ipc.move_cursor(round(b['x'] + b['width'] / 2), round(b['y'] + b['height'] / 2))
                assert zoom_state()['value'] == 1.5 and zoom_state()['settled'], 'reduced-motion hover did not jump'
                ipc.move_cursor(5, 5)
                assert zoom_state()['value'] == 1 and zoom_state()['settled']
                ipc.action('set_anim_time', {'ms': None})
                ipc.move_cursor(5, 5)
                ipc.wait_for_frame(output=primary)
                ipc.reset_perf()
                before = ipc.get_perf()
                for _ in range(3):
                    ipc.wait_for_frame(output=primary)
                after = ipc.get_perf()
                assert after['anim_frames_scheduled'] == 0, 'settled pills keep requesting frames'
                assert (after['panel_allocated_bytes'] + after['panel_reused_bytes'] ==
                        before['panel_allocated_bytes'] + before['panel_reused_bytes']), 'settled pills keep repainting'
            print(f'PASS: dock hover zoom, input bounds, disable, pill growth, focus, reversal, fading, rebuild, speed, reduced motion and idle ({scale}x)')
        except Exception:
            log.flush()
            print((tmp / 'compositor.log').read_text()[-4000:])
            raise
        finally:
            for client in clients:
                stop_process(client)
            stop_process(process)
            log.close()



def pinning():
    """Dragging applications from the start menu onto the dock pins them."""
    scale = float(os.environ.get('REDIWM_TEST_SCALE', '1'))
    with tempfile.TemporaryDirectory(prefix='rediwm-dock-pin-') as directory:
        tmp = Path(directory)
        build_client(tmp)
        applications = tmp / 'data' / 'applications'
        applications.mkdir(parents=True)
        for name, app_id in (('pin-one', 'dock.pin.one'), ('pin-two', 'dock.pin.two')):
            (applications / f'{name}.desktop').write_text(
                f'[Desktop Entry]\nType=Application\nName={name}\nStartupWMClass={app_id}\n'
                f'Exec={tmp / "client"} --app-id {app_id}\n')
        env_extra = {'DBUS_SESSION_BUS_ADDRESS': '', 'DBUS_SYSTEM_BUS_ADDRESS': 'unix:path=/nonexistent',
                     'XDG_CONFIG_HOME': str(tmp / 'config'), 'XDG_DATA_HOME': str(tmp / 'data'),
                     'XDG_DATA_DIRS': str(tmp / 'empty'), 'XDG_CACHE_HOME': str(tmp / 'cache'),
                     'XDG_STATE_HOME': str(tmp / 'state'), 'REDIWM_FILES_DEVICES': '0'}
        process, log = spawn_compositor(tmp, scale=scale, outputs=os.environ.get('REDIWM_TEST_OUTPUTS', '1'),
            config_content='# keep this comment\n[compositor]\nxwayland = false\ndock_enabled = true\n'
                           '[animations]\nenabled = false\n', env_extra=env_extra)
        cfg = tmp / 'rediwm-config.toml'
        clients = []
        try:
            with IPCClient(tmp) as ipc:
                ipc.wait_for('wallpaper_presented', timeout_ms=10000)
                ui = UIDriver(ipc)
                display = wait_for(lambda: next((p.name for p in tmp.glob('wayland-*')
                    if not p.name.endswith('.lock')), None), 'display')
                left, right = 272, 273

                def names():
                    return [w['name'] for w in ui.widgets('dock') if w['name']]

                def pins():
                    return tomllib.loads(cfg.read_text())['compositor'].get('dock_pinned_apps', [])

                def box(name):
                    return next(w for w in ui.widgets('dock') if w['name'] == name)['global_box']

                def centre(b):
                    return round(b['x'] + b['width'] / 2), round(b['y'] + b['height'] / 2)

                def open_menu():
                    if not ipc.get_shell_state()['start_menu']:
                        ipc.open_start_menu()
                    ipc.wait_for_panel_settled('start_menu')

                def row(label):
                    tree = ui.widgets('start_menu')
                    text = next(w for w in tree if w['role'] == 'text' and w['label'] == label)
                    x, y = centre(text['global_box'])
                    found = next(w for w in tree if w['role'] == 'row' and
                                 w['global_box']['y'] <= y < w['global_box']['y'] + w['global_box']['height'])
                    return centre(found['global_box'])

                def shot(name):
                    path = tmp / (name + '.png')
                    ipc.screenshot(str(path))
                    root = ui.widgets('dock')[0]['global_box']
                    with Image.open(path) as image:
                        return image.convert('RGB').crop(tuple(round(v * scale) for v in
                            (root['x'], root['y'], root['x'] + root['width'], root['y'] + root['height'])))

                def drag_to(label, x, y, release=True):
                    open_menu()
                    start = row(label)
                    ipc.move_cursor(*start)
                    ipc.pointer_button(left, True)
                    for step in range(1, 11):
                        ipc.move_cursor(start[0] + (x - start[0]) * step // 10, start[1] + (y - start[1]) * step // 10)
                    ipc.wait_for_frame()
                    if release:
                        ipc.pointer_button(left, False)
                        ipc.wait_for_frame()

                def launch(app):
                    previous = {w['id'] for w in ipc.get_windows()}
                    client = subprocess.Popen([str(tmp / 'client'), '--app-id', app],
                        env=dict(os.environ, XDG_RUNTIME_DIR=str(tmp), WAYLAND_DISPLAY=display),
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    clients.append(client)
                    win = wait_for(lambda: next((w for w in ipc.get_windows() if w['id'] not in previous), None), 'client')
                    ipc.wait_for_frame()
                    return client, win['id']

                wait_for(lambda: 'terminal' in names(), 'dock')
                dock = ui.widgets('dock')[0]['global_box']
                dock_point = centre(dock)
                idle = shot('idle')

                # Released away from the dock: nothing is pinned, nothing launches.
                drag_to('pin-one', 600, 100)
                assert pins() == [] and not ipc.get_windows(), 'a drop off the dock pinned or launched'
                assert ipc.get_shell_state()['start_menu'], 'a drag closed the menu'

                # Hovering the dock marks where the app would go; Escape abandons the drag.
                drag_to('pin-one', *dock_point, release=False)
                assert ImageChops.difference(idle, shot('marker')).getbbox(), 'no drop marker over the dock'
                ipc.key(1, True)
                ipc.key(1, False)
                ipc.wait_for_frame()
                assert ImageChops.difference(idle, shot('cancelled')).getbbox() is None, 'Escape left the marker'
                ipc.pointer_button(left, False)
                ipc.wait_for_frame()
                assert pins() == [] and not ipc.get_windows(), 'a cancelled drag pinned or launched'
                assert ipc.get_shell_state()['start_menu'], 'Escape closed the menu'

                # A drop pins it, saved without disturbing the config.
                drag_to('pin-one', *dock_point)
                wait_for(lambda: 'pin_pin-one.desktop' in names(), 'pinned button')
                assert pins() == ['pin-one.desktop'] and '# keep this comment' in cfg.read_text()
                assert not ipc.get_windows(), 'pinning launched the app'
                assert ImageChops.difference(idle, shot('pinned')).getbbox()
                assert names().index('pin_pin-one.desktop') == names().index('terminal') + 1
                assert ipc.get_shell_state()['start_menu']

                # Dropping on the left of a pin goes before it; pins already there are ignored.
                one = box('pin_pin-one.desktop')
                drag_to('pin-two', one['x'] + 4, centre(one)[1])
                wait_for(lambda: pins() == ['pin-two.desktop', 'pin-one.desktop'], 'drop before the pin')
                drag_to('pin-two', *dock_point)
                ipc.wait_for_frame()
                assert pins() == ['pin-two.desktop', 'pin-one.desktop']
                assert [n for n in names() if n.startswith('pin_')] == ['pin_pin-two.desktop', 'pin_pin-one.desktop']
                ipc.action('close_panel', {'panel': 'start_menu'})

                # The pin survives a reload, launches its app, and a running app shares its button.
                ipc.reload_config()
                assert [n for n in names() if n.startswith('pin_')] == ['pin_pin-two.desktop', 'pin_pin-one.desktop']

                # A pinned icon dragged along the dock moves its pin. Dropped where it
                # was, or abandoned with Escape, nothing changes and nothing launches.
                def drag_pin(name, x, y, release=True):
                    start = centre(box(name))
                    ipc.move_cursor(*start)
                    ipc.pointer_button(left, True)
                    for step in range(1, 11):
                        ipc.move_cursor(start[0] + (x - start[0]) * step // 10, start[1] + (y - start[1]) * step // 10)
                    ipc.wait_for_frame()
                    if release:
                        ipc.pointer_button(left, False)
                        ipc.wait_for_frame()

                def order():
                    return [n for n in names() if n.startswith('pin_')]

                one_name, two_name = 'pin_pin-one.desktop', 'pin_pin-two.desktop'
                before_drags = order()
                ipc.move_cursor(5, 5)
                ipc.wait_for_frame()
                resting = shot('pins-resting')
                x0, y0 = centre(box(one_name))
                drag_pin(one_name, x0 + 12, y0)
                assert pins() == ['pin-two.desktop', 'pin-one.desktop'] and not ipc.get_windows(), 'a drop in place moved or launched'
                two_box = box(two_name)
                drag_pin(one_name, two_box['x'] + 4, centre(two_box)[1], release=False)
                assert ImageChops.difference(resting, shot('pins-moving')).getbbox(), 'no marker while moving a pin'
                ipc.key(1, True)
                ipc.key(1, False)
                ipc.wait_for_frame()
                cancelled = ImageChops.difference(resting, shot('pins-cancelled')).getbbox()
                assert cancelled is None, f'Escape left the marker: {cancelled}, dock {ui.widgets("dock")[0]["global_box"]}'
                ipc.pointer_button(left, False)
                ipc.wait_for_frame()
                assert order() == before_drags and pins() == ['pin-two.desktop', 'pin-one.desktop'] and not ipc.get_windows(), 'a cancelled move changed the pins or launched'
                drag_pin(one_name, two_box['x'] + 4, centre(two_box)[1])
                wait_for(lambda: pins() == ['pin-one.desktop', 'pin-two.desktop'], 'pin moved before the other')
                wait_for(lambda: order() == [one_name, two_name], 'dock follows the moved pin')
                assert not ipc.get_windows() and '# keep this comment' in cfg.read_text(), 'moving a pin launched or disturbed the config'
                end = ui.widgets('dock')[0]['global_box']
                drag_pin(one_name, end['x'] + end['width'] - 4, centre(end)[1])
                wait_for(lambda: pins() == ['pin-two.desktop', 'pin-one.desktop'], 'pin moved to the end')
                wait_for(lambda: order() == before_drags, 'dock follows the pin moved to the end')
                assert not ipc.get_windows()
                ipc.click_at(*centre(box('pin_pin-one.desktop')))
                wait_for(lambda: len(ipc.get_windows()) == 1, 'pinned app launched')
                assert not any(n.startswith('window_') for n in names()), 'a pinned app also got a window button'
                single = count_badge(ipc, ui, 'pin_pin-one.desktop', scale, tmp / 'pin-badge-single.png')
                second, second_id = launch('dock.pin.one')
                assert not any(n.startswith('window_') for n in names())
                double = count_badge(ipc, ui, 'pin_pin-one.desktop', scale, tmp / 'pin-badge-double.png')
                assert ImageChops.difference(single, double).getbbox(), 'pinned app has no window count'
                ipc.click_at(*centre(box('pin_pin-one.desktop')))
                wait_for(lambda: len([w for w in ui.widgets('window_picker') if w['role'] == 'row']) == 2, 'pinned window picker')
                ipc.key(1, True)
                ipc.key(1, False)
                wait_for(lambda: not ui.widgets('window_picker'), 'pinned picker dismissed')
                other, other_id = launch('dock.pin.free')
                wait_for(lambda: f'window_{other_id}' in names(), 'unpinned app window')

                # A click on a row still launches, and the menu closes.
                open_menu()
                ipc.click_at(*row('pin-two'))
                wait_for(lambda: len(ipc.get_windows()) == 4, 'row click launched')
                wait_for(lambda: not ipc.get_shell_state()['start_menu'], 'row click closed the menu')

                # Unpinning keeps the windows, now as their own buttons. A running
                # pin offers Close, Force Close and Unpin.
                x, y = centre(box('pin_pin-one.desktop'))
                ipc.move_cursor(x, y)
                ipc.pointer_button(right, True)
                ipc.pointer_button(right, False)
                ipc.wait_for_frame()
                menu_top = ui.widgets('dock')[0]['global_box']['y'] - 122 - 4
                ipc.click_at(x + 20, menu_top + 6 + 2 * 39 + 16)
                wait_for(lambda: pins() == ['pin-two.desktop'], 'unpinned')
                wait_for(lambda: 'pin_pin-one.desktop' not in names(), 'pin button removed')
                assert len([n for n in names() if n.startswith('window_')]) == 3, names()
            print(f'PASS: dock pins by dragging from the start menu, marker, cancel, order, launch, merge and unpin ({scale}x)')
        except Exception:
            print((tmp / 'compositor.log').read_text()[-4000:])
            raise
        finally:
            for client in clients:
                stop_process(client)
            stop_process(process)
            log.close()


def positions():
    """Every edge, with either taskbar edge, using real pointer input."""
    scale = float(os.environ.get('REDIWM_TEST_SCALE', '1'))
    with tempfile.TemporaryDirectory(prefix='rediwm-dock-position-') as directory:
        tmp = Path(directory)
        build_client(tmp)
        # An opaque fixture exposes the exact painted edges, including the
        # few pixels that extend beyond the dock at maximum hover zoom.
        theme = tmp / 'data/icons/DockAnchorTest'
        icons = theme / '64x64/apps'
        icons.mkdir(parents=True)
        (theme / 'index.theme').write_text('[Icon Theme]\nName=DockAnchorTest\nDirectories=64x64/apps\n'
                                         '[64x64/apps]\nSize=64\nType=Fixed\nContext=Applications\n')
        Image.new('RGBA', (64, 64), (248, 16, 128, 255)).save(icons / 'rediwm-settings.png')
        Image.new('RGBA', (64, 64), (16, 224, 248, 255)).save(icons / 'transmission-artwork.png')
        applications = tmp / 'data/applications'
        applications.mkdir(parents=True)
        (applications / 'transmission-gtk.desktop').write_text(
            '[Desktop Entry]\nType=Application\nName=Transmission\n'
            'Exec=transmission-gtk %U\nIcon=transmission-artwork\n')
        env_extra = {'DBUS_SESSION_BUS_ADDRESS': '', 'DBUS_SYSTEM_BUS_ADDRESS': 'unix:path=/nonexistent',
                     'XDG_CONFIG_HOME': str(tmp / 'config'), 'XDG_DATA_HOME': str(tmp / 'data'),
                     'XDG_CACHE_HOME': str(tmp / 'cache'), 'REDIWM_ICON_THEME': 'DockAnchorTest'}
        def config(position, taskbar, size):
            return (f'[compositor]\nxwayland = false\ndock_enabled = true\ndock_position = "{position}"\n'
                    f'taskbar_position = "{taskbar}"\ndock_height = {size}\ndock_hover_zoom = 1.5\n'
                    '[animations]\nenabled = false\n')
        process, log = spawn_compositor(tmp, scale=scale, outputs=os.environ.get('REDIWM_TEST_OUTPUTS', '1'),
            config_content=config('bottom', 'bottom', 68), env_extra=env_extra)
        client = None
        overflow_clients = []
        try:
            with IPCClient(tmp) as ipc:
                ipc.wait_for('wallpaper_presented', timeout_ms=10000)
                ui = UIDriver(ipc)
                display = wait_for(lambda: next((p.name for p in tmp.glob('wayland-*')
                    if not p.name.endswith('.lock')), None), 'display')
                # Transmission uses a per-instance GTK ID, unlike its desktop
                # file and Icon= name. The dock must still show that artwork.
                app_id = 'com.transmissionbt.transmission_1000_12345'
                client = subprocess.Popen([str(tmp / 'client'), '--app-id', app_id],
                    env=dict(os.environ, XDG_RUNTIME_DIR=str(tmp), WAYLAND_DISPLAY=display),
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                wid = wait_for(lambda: next((w['id'] for w in ipc.get_windows() if w['app_id'] == app_id), None), 'position client')
                ipc.wait_for('window_geometry_settled', window_id=wid)
                cfg = tmp / 'rediwm-config.toml'
                def root():
                    return ui.widgets('dock')[0]['global_box']
                def item(name):
                    return next(w['global_box'] for w in ui.widgets('dock') if w['name'] == name)
                def center(box):
                    return round(box['x'] + box['width'] / 2), round(box['y'] + box['height'] / 2)
                def shot(name):
                    path = tmp / (name + '.png')
                    path.unlink(missing_ok=True)
                    ipc.screenshot(str(path))
                    with Image.open(path) as image:
                        return image.convert('RGB')
                def crop(image, box):
                    return image.crop(tuple(round(v * scale) for v in box))
                def running_icon_ready():
                    box = item(f'window_{wid}')
                    image = crop(shot('running-icon'), (box['x'], box['y'],
                                 box['x'] + box['width'], box['y'] + box['height']))
                    return sum(count for count, (r, g, b) in image.getcolors(image.width * image.height)
                               if r < 32 and g > 200 and b > 224) > 200 * scale * scale
                wait_for(running_icon_ready, 'running Transmission icon did not use desktop artwork')
                def icon_bounds(image, region):
                    icon = crop(image, region)
                    red, green, blue = icon.split()
                    mask = ImageChops.multiply(red.point(lambda v: 255 if v > 220 else 0),
                                              green.point(lambda v: 255 if v < 40 else 0))
                    mask = ImageChops.multiply(mask, blue.point(lambda v: 255 if 100 < v < 180 else 0))
                    return mask.getbbox()
                for taskbar in ('bottom', 'top'):
                    for position in ('top', 'left', 'right', 'bottom'):
                        vertical = position in ('left', 'right')
                        for size in (48, 96):
                            cfg.write_text(config(position, taskbar, size))
                            ipc.reload_config()
                            wait_for(lambda: ui.widgets('dock') and root()['width' if vertical else 'height'] == size, 'position reload')
                            ipc.move_cursor(5, 5)
                            ipc.wait_for_frame()
                            box = root()
                            output = next(o for o in ipc.get_outputs() if o['x'] <= box['x'] < o['x'] + o['logical_width'])
                            bar = next(b['box'] for b in ipc.get_shell_state()['taskbars'] if b['box']['x'] == output['x'])
                            x0, y0 = output['x'], output['y'] + (bar['height'] if taskbar == 'top' else 0)
                            width, height = output['logical_width'], output['logical_height'] - bar['height']
                            if vertical:
                                assert box['y'] == y0 + (height - box['height']) // 2, box
                                assert box['x'] == (x0 if position == 'left' else x0 + width - size), box
                            else:
                                assert box['x'] == x0 + (width - box['width']) // 2, box
                                assert box['y'] == (y0 if position == 'top' else y0 + height - size), box
                            buttons = [w['global_box'] for w in ui.widgets('dock') if w['name']]
                            along, cross = ('y', 'x') if vertical else ('x', 'y')
                            assert all(a[along] < b[along] and a[cross] == b[cross] for a, b in zip(buttons, buttons[1:])), buttons
                            for button in buttons:
                                assert button['width'] == button['height']
                                assert ipc.hit_test(*center(button))['target_type'] == 'dock'
                                for other in ipc.get_outputs():
                                    bx, by = center(button)
                                    assert ipc.hit_test(bx + other['x'] - output['x'], by + other['y'] - output['y'])['target_type'] == 'dock'
                            # Compare only the interior-side tooltip area; the
                            # hovered icon and cursor are outside this crop.
                            resting = item('settings')
                            region = (resting['x'] - resting['width'] / 2, resting['y'] - resting['height'] / 2,
                                      resting['x'] + resting['width'] * 1.5, resting['y'] + resting['height'] * 1.5)
                            wait_for(lambda: icon_bounds(shot('icon-ready'), region), 'fixture icon loaded')
                            idle = shot('idle')
                            small = icon_bounds(idle, region)
                            rested = time.monotonic()
                            ipc.move_cursor(*center(item('settings')))
                            ipc.wait_for_frame()
                            early = shot('early')
                            if position == 'top':
                                tip = (box['x'], box['y'] + box['height'] + 8, box['x'] + box['width'], box['y'] + box['height'] + 38)
                            elif position == 'bottom':
                                tip = (box['x'], box['y'] - 38, box['x'] + box['width'], box['y'] - 8)
                            elif position == 'left':
                                tip = (box['x'] + box['width'] + 8, box['y'], x0 + width, box['y'] + box['height'])
                            else:
                                tip = (x0, box['y'], box['x'] - 8, box['y'] + box['height'])
                            # The title shows only after the pointer has rested on the icon.
                            assert not ImageChops.difference(crop(idle, tip), crop(early, tip)).getbbox(), f'{position} tooltip shown without a delay'
                            wait_for(lambda: ImageChops.difference(crop(idle, tip), crop(shot('hovered'), tip)).getbbox(), f'{position} tooltip missing', timeout=4)
                            print(f'{taskbar}/{position}/{size}: tooltip after {time.monotonic() - rested:.2f}s')
                            assert time.monotonic() - rested >= 1.4, f'{position} tooltip shown before its delay'
                            # A hovered icon is enlarged in either orientation.
                            assert item('settings')['width'] > buttons[-1]['width'], 'hover zoom missing'
                            large = icon_bounds(shot('anchored'), region)
                            assert large and large[2] - large[0] > small[2] - small[0], (small, large)
                            fixed = {'left': 0, 'top': 1, 'right': 2, 'bottom': 3}[position]
                            assert abs(large[fixed] - small[fixed]) <= 1, (position, small, large)
                            expected = round(36 * size / 68) * 1.5 * scale
                            assert abs(large[2] - large[0] - expected) <= 2, (position, large, expected)
                            assert abs(large[3] - large[1] - expected) <= 2, (position, large, expected)
                            # The part beyond the background remains a hover target.
                            expanded = item('settings')
                            ex, ey = center(expanded)
                            if position == 'bottom': ey = box['y'] - 1
                            elif position == 'top': ey = box['y'] + box['height']
                            elif position == 'right': ex = box['x'] - 1
                            else: ex = box['x'] + box['width']
                            ipc.move_cursor(ex, ey)
                            assert ipc.hit_test(ex, ey)['target_type'] == 'dock', (position, ex, ey)
                            ipc.move_cursor(5, 5)
                            ipc.wait_for_frame()
                            # Running-window buttons still minimize and restore.
                            window_box = item(f'window_{wid}')
                            cx, cy = center(window_box)
                            thickness = max(2, 4 * size / 68)
                            indicator_cross = (size - round(58 * size / 68) - thickness
                                               if position in ('top', 'left') else round(58 * size / 68))
                            if vertical:
                                indicator = (box['x'] + indicator_cross, cy - 12 * size / 68,
                                             box['x'] + indicator_cross + thickness, cy + 12 * size / 68)
                            else:
                                indicator = (cx - 12 * size / 68, box['y'] + indicator_cross,
                                             cx + 12 * size / 68, box['y'] + indicator_cross + thickness)
                            active = crop(shot('active'), indicator)
                            ipc.click_at(*center(item(f'window_{wid}')))
                            wait_for(lambda: next(w for w in ipc.get_windows() if w['id'] == wid)['is_minimized'], 'side dock minimize')
                            ipc.move_cursor(5, 5)
                            ipc.wait_for_frame()
                            minimized = crop(shot('minimized'), indicator)
                            assert ImageChops.difference(active, minimized).getbbox(), f'{position} running indicator missing'
                            ipc.click_at(*center(item(f'window_{wid}')))
                            wait_for(lambda: not next(w for w in ipc.get_windows() if w['id'] == wid)['is_minimized'], 'side dock restore')
                            ipc.action('fullscreen_window', {'id': wid})
                            wait_for(lambda: not ui.widgets('dock'), 'fullscreen hides positioned dock')
                            ipc.action('fullscreen_window', {'id': wid})
                            wait_for(lambda: ui.widgets('dock'), 'positioned dock restored after fullscreen')
                            # Remove Settings by clicking the actual inward menu.
                            px, py = center(item('settings'))
                            ipc.move_cursor(px, py)
                            ipc.pointer_button(273, True)
                            ipc.pointer_button(273, False)
                            ipc.wait_for_frame()
                            if position == 'top':
                                mx, my = px, box['y'] + box['height'] + 4
                            elif position == 'bottom':
                                mx, my = px, box['y'] - 48
                            elif position == 'left':
                                mx, my = box['x'] + box['width'] + 4, py
                            else:
                                mx, my = box['x'] - 220, py
                            mx = min(max(mx, x0), x0 + width - 216)
                            my = min(max(my, y0), y0 + height - 44)
                            ipc.click_at(mx + 30, my + 22)
                            wait_for(lambda: not any(w['name'] == 'settings' for w in ui.widgets('dock')), f'{position} menu not usable')
                            assert tomllib.loads(cfg.read_text())['compositor']['dock_hidden_shortcuts'] == ['settings']
                # Restart preserves a side dock without an Appearance window.
                cfg.write_text(config('right', 'top', 96))
                ipc.reload_config()
                wait_for(lambda: root()['width'] == 96, 'overflow dock')
                capacity = (height - round(12 * 96 / 68) * 2 - 16) // round(56 * 96 / 68) - 5  # fixed items, the Trash included
                for index in range(capacity + 1):
                    overflow_clients.append(subprocess.Popen([str(tmp / 'client'), '--app-id', f'dock.side.overflow{index}'],
                        env=dict(os.environ, XDG_RUNTIME_DIR=str(tmp), WAYLAND_DISPLAY=display),
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
                wait_for(lambda: len(ipc.get_windows()) == capacity + 2, 'vertical overflow clients')
                def shown():
                    return {w['name'] for w in ui.widgets('dock') if (w['name'] or '').startswith('window_')}
                wait_for(lambda: len(shown()) == capacity, 'vertical dock capacity')
                first = shown()
                ipc.move_cursor(*center(item('terminal')))
                ipc.scroll(0, -120)
                try:
                    wait_for(lambda: shown() != first, 'vertical overflow scroll', timeout=2)
                except AssertionError:
                    ipc.scroll(0, 120)
                    wait_for(lambda: shown() != first, 'vertical overflow windows unreachable')
                box = root()
                assert box['y'] >= y0 and box['y'] + box['height'] <= y0 + height, box
            stop_process(process)
            log.close()
            process, log = spawn_compositor(tmp, scale=scale, outputs=os.environ.get('REDIWM_TEST_OUTPUTS', '1'),
                config_content=cfg.read_text(), env_extra=env_extra)
            with IPCClient(tmp) as ipc:
                ui = UIDriver(ipc)
                wait_for(lambda: ui.widgets('dock'), 'side dock after restart')
                box = ui.widgets('dock')[0]['global_box']
                assert box['width'] == 96 and box['height'] > box['width'], box
            print(f'PASS: dock four edges, both taskbar edges, size, input, hover, tooltips, menus, fullscreen, vertical overflow and restart ({scale}x)')
        finally:
            for overflow_client in overflow_clients:
                stop_process(overflow_client)
            if client:
                stop_process(client)
            stop_process(process)
            log.close()

if __name__ == '__main__':
    import sys
    if '--positions-only' not in sys.argv:
        run()
        context_menu()
        pill_animation()
        pinning()
    positions()

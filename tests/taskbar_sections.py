#!/usr/bin/env python3
"""Taskbar sections, live settings, input, legacy config and persistence."""
import os
from pathlib import Path
import subprocess
import tempfile
import tomllib
from PIL import Image, ImageChops

from desktop_zoom import build_client, wait_for
from ipc_client import IPCClient, spawn_compositor, stop_process
from ui_driver import UIDriver


def check_desktop_mode_menu(ipc, cfg):
    for edge in ('top', 'bottom'):
        cfg.write_text('[compositor]\nxwayland = false\ndesktop_mode = "canvas"\n'
                       f'taskbar_position = "{edge}"\n'
                       'taskbar_items = ["left:start","left:windows","center:desktop_mode",'
                       '"right:tray","right:battery","~right:wifi","right:volume","right:clock"]\n'
                       '[animations]\nenabled = false\n')
        ipc.reload_config()
        def mode_item():
            return next((w for w in ipc.get_widget_tree('taskbar')['widgets']
                         if w['name'] == 'desktop_mode'), None)
        b = wait_for(mode_item, 'desktop mode item')['global_box']
        x, y = round(b['x'] + b['width'] / 2), round(b['y'] + b['height'] / 2)
        def open_menu():
            ipc.click_at(x, y, button=0x111)
            ipc.wait_for_frame()
        def check_mode(mode):
            assert mode_item()['label'] == mode
            assert (ipc.get_workspaces()[0]['name'] == 'Canvas') == (mode == 'Canvas')
            assert tomllib.loads(cfg.read_text())['compositor']['desktop_mode'] == mode.lower()

        open_menu()
        ipc.key_press('Escape')
        check_mode('Canvas')
        open_menu()
        # Canvas, Workspaces and Scrolling, in that order from the top.
        def row_y(index):
            return b['y'] + b['height'] + 26 + 34 * index if edge == 'top' else b['y'] - 26 - 34 * (2 - index)
        ipc.click_at(x, row_y(1))
        check_mode('Workspaces')
        open_menu()
        ipc.click_at(x, row_y(1))
        check_mode('Workspaces')  # choosing the checked row is idempotent
        open_menu()
        ipc.click_at(x, row_y(2))
        check_mode('Scrolling')
        assert ipc.get_workspaces()[0]['layout'] == 'scrolling', ipc.get_workspaces()
        open_menu()
        ipc.key_press('Down')
        ipc.key_press('Return')
        check_mode('Canvas')


def run():
    scale = float(os.environ.get('REDIWM_TEST_SCALE', '1'))
    with tempfile.TemporaryDirectory(prefix='rediwm-taskbar-sections-') as directory:
        tmp = Path(directory)
        build_client(tmp)
        env_extra = {'DBUS_SESSION_BUS_ADDRESS': '', 'DBUS_SYSTEM_BUS_ADDRESS': 'unix:path=/nonexistent',
                     'XDG_CONFIG_HOME': str(tmp / 'config'), 'XDG_DATA_HOME': str(tmp / 'data'),
                     'XDG_CACHE_HOME': str(tmp / 'cache')}
        original = '# preserve me\n[compositor]\nxwayland = false\n[animations]\nenabled = false\n'
        process, log = spawn_compositor(tmp, scale=scale, outputs=os.environ.get('REDIWM_TEST_OUTPUTS', '1'),
                                        config_content=original, env_extra=env_extra)
        clients = []
        cfg = tmp / 'rediwm-config.toml'
        try:
            with IPCClient(tmp) as ipc:
                ipc.wait_for('wallpaper_presented', timeout_ms=10000)
                ui = UIDriver(ipc)
                display = wait_for(lambda: next((p.name for p in tmp.glob('wayland-*') if not p.name.endswith('.lock')), None), 'display')
                for index in range(2):
                    clients.append(subprocess.Popen([str(tmp / 'client'), '--app-id', f'taskbar.section.{index}'],
                        env=dict(os.environ, XDG_RUNTIME_DIR=str(tmp), WAYLAND_DISPLAY=display),
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
                wait_for(lambda: len(ipc.get_windows()) == 2, 'windows')
                ipc.wait_for_frame()
                def bar():
                    return ui.widgets('taskbar')
                def box(name):
                    return next(w['global_box'] for w in bar() if w['name'] == name)
                def center(b):
                    return round(b['x'] + b['width'] / 2), round(b['y'] + b['height'] / 2)
                def chips():
                    return [w['global_box'] for w in bar() if w['role'] == 'chip']
                def check_bounds():
                    root = bar()[0]['global_box']
                    items = [w['global_box'] for w in bar()[1:] if w['visible']]
                    items.sort(key=lambda b: b['x'])
                    for b in items:
                        assert root['x'] <= b['x'] and b['x'] + b['width'] <= root['x'] + root['width'], (root, b)
                        assert ipc.hit_test(*center(b))['target_type'] == 'taskbar', b
                    for a, b in zip(items, items[1:]):
                        assert a['x'] + a['width'] <= b['x'] + 1, (a, b)
                root = bar()[0]['global_box']
                row = chips()
                assert 0 <= row[0]['x'] - (box('start')['x'] + box('start')['width']) <= 32, row
                assert box('start')['x'] < row[0]['x'] < box('clock')['x']
                check_bounds()
                assert not any(w['name'] == 'power' for w in bar()), 'Power defaults off'
                assert not any(w['name'] in ('tray/1', 'wired') for w in bar()), 'Wi-Fi and Ethernet follow the hardware: none here'
                ipc.action('open_appearance')
                ipc.wait_for_panel_settled('control_center')
                def clock_image(name):
                    image_path = tmp / f'clock-{name}.png'
                    ipc.screenshot(str(image_path))
                    b = box('clock')
                    right = b['x'] + b['width']
                    with Image.open(image_path) as image:
                        return image.convert('RGB').crop(tuple(round(v * scale) for v in
                            (right - 180, b['y'], right + 2, b['y'] + b['height'])))
                def style_toggle(name):
                    toggle = ui.scroll_into_view(name)
                    ipc.click_at(*center(toggle['global_box']))
                    ipc.wait_for_panel_settled('control_center')
                    ipc.wait_for_frame()
                assert not ui.scroll_into_view('clock_bold')['on']
                assert not ui.scroll_into_view('clock_italic')['on']
                for name, label in (('clock_bold', 'bold'), ('clock_italic', 'bold-italic'),
                                    ('clock_bold', 'italic'), ('clock_italic', 'regular-again')):
                    before = clock_image('before-' + label)
                    style_toggle(name)
                    after = clock_image(label)
                    assert ImageChops.difference(before, after).getbbox(), f'clock style did not repaint: {label}'
                    check_bounds()
                style_toggle('clock_bold')
                style_toggle('clock_italic')
                saved_theme = tomllib.loads(cfg.read_text())['theme']
                assert saved_theme['clock_bold'] and saved_theme['clock_italic']
                zones = ('left', 'center', 'right')
                def zone_of(name):
                    row = ui.scroll_into_view(f'taskbar_{name}_row')['global_box']
                    for zone, label in enumerate(zones):
                        well = ui.find(f'taskbar_zone_{label}')['global_box']
                        if well['y'] <= row['y'] and row['y'] + row['height'] <= well['y'] + well['height']:
                            return zone
                for name, expected in (('start', 0), ('windows', 0), ('capture', 2), ('tray', 2), ('clock', 2), ('power', 2), ('wifi', 2), ('wired', 2)):
                    assert zone_of(name) == expected, name
                # Each row's Left/Center/Right buttons move the item like a drop.
                for zone, fraction in ((0, 1 / 6), (1, 0.5), (2, 5 / 6)):
                    segmented = ui.scroll_into_view('taskbar_wired_section')['global_box']
                    ipc.click_at(int(segmented['x'] + segmented['width'] * fraction), int(segmented['y'] + segmented['height'] / 2))
                    ipc.wait_for_panel_settled('control_center')
                    assert zone_of('wired') == zone, f'wired moved to {zones[zone]} by its buttons'
                    assert f'{zones[zone]}:wired' in [entry.lstrip('-~') for entry in tomllib.loads(cfg.read_text())['compositor']['taskbar_items']]
                for name in ('wifi', 'wired'):
                    assert not ui.scroll_into_view(f'taskbar_{name}_visible')['on'], f'{name} is off without its hardware'
                toggle = ui.scroll_into_view('taskbar_capture_visible')
                assert toggle['on'], 'Screen capture defaults on'
                ipc.click_at(*center(toggle['global_box']))
                ipc.wait_for_panel_settled('control_center')
                assert '-right:capture' in tomllib.loads(cfg.read_text())['compositor']['taskbar_items']
                assert 'not recommended' in ui.find('taskbar_capture_notice')['label']
                # Power is opt-in, opens the existing modal, and can be hidden live.
                toggle = ui.scroll_into_view('taskbar_power_visible')
                ipc.click_at(*center(toggle['global_box']))
                wait_for(lambda: any(w['name'] == 'power' for w in bar()), 'Power enabled')
                assert box('power')['x'] > box('clock')['x']
                check_bounds()
                ipc.click_at(*center(box('power')))
                ipc.wait_for('power_menu_opened')
                assert len([w for w in ui.widgets('power_menu') if w['role'] == 'row']) == 5
                ipc.key(1, True)
                ipc.key(1, False)
                ipc.wait_for('power_menu_closed')
                toggle = ui.scroll_into_view('taskbar_power_visible')
                ipc.click_at(*center(toggle['global_box']))
                wait_for(lambda: not any(w['name'] == 'power' for w in bar()), 'Power hidden')
                toggle = ui.scroll_into_view('taskbar_power_visible')
                ipc.click_at(*center(toggle['global_box']))
                wait_for(lambda: any(w['name'] == 'power' for w in bar()), 'Power restored')
                def well_end(zone):
                    tree = ui.widgets()
                    well = next(w for w in tree if w['name'] == f'taskbar_zone_{zones[zone]}')['box']
                    rows = [w for w in tree if (w.get('name') or '').startswith('taskbar_') and w['name'].endswith('_row')
                            and well['y'] <= w['box']['y'] and w['box']['y'] + w['box']['height'] <= well['y'] + well['height']]
                    return max(rows, key=lambda w: w['box']['y'])['name'] if rows else f'taskbar_zone_{zones[zone]}'
                def drop_y(well):
                    return max(0, min(ipc.get_outputs()[0]['logical_height'] - 1, well['y'] + well['height'] - 3))
                def reachable(well):
                    return well['y'] <= drop_y(well) < well['y'] + well['height']
                # Drag fixed controls and both primary groups into every section.
                for name in ('clock', 'wifi', 'wired', 'volume', 'start', 'windows', 'tray', 'power', 'capture'):
                    for zone in (0, 1, 2):
                        if zone_of(name) == zone:
                            continue
                        # Synthetic input stays on-screen, so a well too far
                        # from the row to show with it is reached in hops: drag
                        # the row to the farthest visible row toward it first.
                        # A full well can be taller than the viewport: its end
                        # (last row) is what the drop aims at.
                        for _ in range(6):
                            ui.scroll_into_view(well_end(zone))
                            row = ui.scroll_into_view(f'taskbar_{name}_row')
                            assert row['visible'] and not row['clipped'], row
                            well = ui.find(f'taskbar_zone_{zones[zone]}')['global_box']
                            if reachable(well):
                                break
                            up = well['y'] < row['global_box']['y']
                            others = [w['global_box'] for w in ui.widgets() if (w.get('name') or '').startswith('taskbar_') and w['name'].endswith('_row')
                                      and w['name'] != f'taskbar_{name}_row' and w['visible'] and not w.get('clipped')
                                      and (w['global_box']['y'] < row['global_box']['y']) == up]
                            assert others, f'no visible row to hop {name} toward {zones[zone]}'
                            stop = min(others, key=lambda b: b['y']) if up else max(others, key=lambda b: b['y'])
                            before_hop = cfg.read_text()
                            ipc.move_cursor(*center(row['global_box']))
                            ipc.pointer_button(0x110, True)
                            ipc.move_cursor(*center(stop))
                            ipc.pointer_button(0x110, False)
                            wait_for(lambda: cfg.read_text() != before_hop, 'hop saved')
                            ipc.wait_for_frame()
                            ipc.wait_for_panel_settled('control_center')
                        ipc.move_cursor(*center(row['global_box']))
                        ipc.pointer_button(0x110, True)
                        # Rows reflow live under the pointer: re-aim until the well holds still.
                        aimed = None
                        for _ in range(4):
                            well = ui.find(f'taskbar_zone_{zones[zone]}')['global_box']
                            if well == aimed:
                                break
                            # The drag grab follows the pointer outside the
                            # viewport, but synthetic input must stay on-screen.
                            y = drop_y(well)
                            assert reachable(well), well
                            ipc.move_cursor(round(well['x'] + well['width'] / 2), y)
                            aimed = well
                        ipc.pointer_button(0x110, False)
                        wait_for(lambda: any(entry.lstrip('-~') == f'{zones[zone]}:{name}'
                            for entry in tomllib.loads(cfg.read_text())['compositor']['taskbar_items']), 'section saved')
                        ipc.wait_for_frame()
                        ipc.wait_for_panel_settled('control_center')
                        assert zone_of(name) == zone, name
                        check_bounds()
                # Drag and keyboard order within a section.
                before = tomllib.loads(cfg.read_text())['compositor']['taskbar_items']
                handle = ui.scroll_into_view('taskbar_wifi_order')
                volume = ui.scroll_into_view('taskbar_volume_order')
                handle = ui.find('taskbar_wifi_order')
                fx, fy = center(handle['global_box'])
                tx, ty = center(volume['global_box'])
                assert handle['visible'] and not handle['clipped'], handle
                ipc.drag(fx, fy, tx, ty + (3 if fy < ty else -3))
                wait_for(lambda: tomllib.loads(cfg.read_text())['compositor']['taskbar_items'] != before, 'drag reorder')
                ipc.wait_for_panel_settled('control_center')
                dragged = tomllib.loads(cfg.read_text())['compositor']['taskbar_items']
                def at(entries, name): return [entry.lstrip('-~') for entry in entries].index(name)
                assert (at(dragged, 'right:wifi') > at(dragged, 'right:volume')) != (at(before, 'right:wifi') > at(before, 'right:volume')), dragged
                handle = ui.scroll_into_view('taskbar_wifi_order')
                ipc.click_at(*center(handle['global_box']))
                # Down at the end of the last section has nowhere to go: step up there.
                last = [e.lstrip('-~') for e in dragged if e.lstrip('-~').startswith('right:')][-1] == 'right:wifi'
                if last: print('wifi is last in Right: keyboard step goes up', flush=True)
                ipc.key(103 if last else 108, True)
                ipc.key(103 if last else 108, False)
                wait_for(lambda: tomllib.loads(cfg.read_text())['compositor']['taskbar_items'] != dragged, f'keyboard reorder {dragged}')
                ipc.wait_for_panel_settled('control_center')
                assert '# preserve me' in cfg.read_text()
                # Hide and restore the window group without changing windows.
                toggle = ui.scroll_into_view('taskbar_windows_visible')
                ipc.click_at(*center(toggle['global_box']))
                wait_for(lambda: not chips(), 'hidden window list')
                assert len([w for w in ipc.get_windows() if w['app_id'].startswith('taskbar.section.')]) == 2
                toggle = ui.scroll_into_view('taskbar_windows_visible')
                ipc.click_at(*center(toggle['global_box']))
                wait_for(lambda: chips(), 'window list restored')
                ipc.action('close_panel', {'panel': 'control_center'})
                ipc.wait_for_frame()
                # Start's hit target and menu follow its moved position.
                ipc.click_at(*center(box('start')))
                wait_for(lambda: ipc.get_shell_state()['start_menu'], 'moved Start button opens menu')
                menu = ipc.get_shell_state()['start_menu']['box']
                assert root['x'] <= menu['x'] and menu['x'] + menu['width'] <= root['x'] + root['width'], menu
                ipc.key(1, True)
                ipc.key(1, False)
                wait_for(lambda: not ipc.get_shell_state()['start_menu'], 'Start menu dismissed')
                saved = cfg.read_text()
                # The original status-only config still preserves order/hiding.
                cfg.write_text(original.replace('[compositor]', '[compositor]\ntaskbar_items = ["clock", "-network", "volume", "battery"]'))
                ipc.reload_config()
                wait_for(lambda: not any(w['name'] == 'tray/1' for w in bar()), 'legacy hidden network')
                assert box('clock')['x'] < box('tray/0')['x']
                assert not any(w['name'] == 'power' for w in bar()), 'legacy lists keep Power off'
                row = chips()
                assert 0 <= row[0]['x'] - (box('start')['x'] + box('start')['width']) <= 32, row
                check_desktop_mode_menu(ipc, cfg)
                cfg.write_text(saved)
            for client in clients:
                stop_process(client)
            clients.clear()
            stop_process(process)
            log.close()
            process, log = spawn_compositor(tmp, scale=scale, config_content=cfg.read_text(), env_extra=env_extra)
            with IPCClient(tmp) as ipc:
                ipc.action('open_appearance')
                ipc.wait_for_panel_settled('control_center')
                ui = UIDriver(ipc)
                assert ui.scroll_into_view('clock_bold')['on'], 'Bold clock survives restart'
                assert ui.scroll_into_view('clock_italic')['on'], 'Italic clock survives restart'
                assert any(w['name'] == 'power' for w in ui.widgets('taskbar')), 'Power survives restart'
                toggle = ui.scroll_into_view('taskbar_capture_visible')
                assert not toggle['on'], 'Hidden capture item survives restart'
                assert 'not recommended' in ui.find('taskbar_capture_notice')['label']
                for name in ('start', 'windows', 'clock', 'power', 'capture'):
                    row = ui.scroll_into_view(f'taskbar_{name}_row')['global_box']
                    well = ui.find('taskbar_zone_right')['global_box']
                    assert well['y'] <= row['y'] and row['y'] + row['height'] <= well['y'] + well['height'], name
                # Clock controls edit the selected taskbar theme independently.
                main_theme = tomllib.loads(cfg.read_text())['theme']
                cfg.write_text(cfg.read_text() + '\n[taskbar_theme]\nclock_bold = false\nclock_italic = false\n')
                ipc.reload_config()
                ipc.wait_for_panel_settled('control_center')
                assert not ui.scroll_into_view('clock_bold')['on']
                assert not ui.scroll_into_view('clock_italic')['on']
                style_toggle('clock_italic')
                config = tomllib.loads(cfg.read_text())
                assert config['taskbar_theme']['clock_italic']
                assert config['theme'] == main_theme, 'taskbar style changed main theme'
            print(f'PASS: taskbar sections, left default, section moves, bounds/input, visibility, Start menu, legacy config and restart ({scale}x)')
        finally:
            for client in clients:
                stop_process(client)
            stop_process(process)
            log.close()


if __name__ == '__main__':
    run()

#!/usr/bin/env python3
"""Mini Map geometry, lifetime, pointer ownership and Settings in an isolated compositor."""
import os
from pathlib import Path
import tempfile
import time
from PIL import Image, ImageChops
from ipc_client import IPCClient, spawn_compositor, stop_process


def run():
    with tempfile.TemporaryDirectory(prefix="rediwm-mini-map-") as directory:
        tmp = Path(directory)
        base = '[input]\ninvert_scroll = false\n[animations]\nenabled = false\n[compositor]\nxwayland = false\n'
        process, log = spawn_compositor(tmp, scale=os.getenv('REDIWM_TEST_SCALE', '1'),
            renderer=os.getenv('REDIWM_TEST_RENDERER', 'pixman'), config_content=base,
            env_extra={'DBUS_SESSION_BUS_ADDRESS': '', 'XDG_CACHE_HOME': str(tmp/'cache'),
                       'XDG_CONFIG_HOME': str(tmp/'config'), 'REDIWM_DESKTOP_DIR': str(tmp/'Desktop')})
        try:
            with IPCClient(tmp, timeout=20) as ipc:
                ipc.action('wait_for', {'condition': 'wallpaper_presented', 'timeout_ms': 10000})
                out = ipc.get_outputs()[0]
                w, h = out['logical_width'], out['logical_height']
                bottom = h - out['bottom_exclusion']
                scale = out['scale']
                def wait(check, label, timeout=4):
                    end = time.monotonic() + timeout
                    while time.monotonic() < end:
                        value = check()
                        if value: return value
                        time.sleep(.03)
                    raise AssertionError(label)
                def cam(): return ipc.request(raw_cmd={'version': 1, 'command': 'get_camera'})
                def navigate(x=0, y=0):
                    ipc.action('set_camera', {'x': x, 'y': y})
                    ipc.wait_for_frame()
                def hit(x, y): return ipc.hit_test(round(x), round(y))['target_type']
                def present(x, y): return hit(x, y) == 'mini_map'
                def capture(name):
                    path = tmp/(name+'.png')
                    ipc.screenshot(path=str(path))
                    return Image.open(path).convert('RGB')
                def configure(extra=''):
                    (tmp/'rediwm-config.toml').write_text(base+extra)
                    ipc.reload_config()
                    ipc.wait_for_frame()
                def map_box(position='bottom_right'):
                    probe_x = {'bottom_right': w-40, 'bottom_center': w/2, 'bottom_left': 40}[position]
                    probe_y = bottom-40
                    result = ipc.hit_test(round(probe_x), round(probe_y))
                    assert result['target_type'] == 'mini_map', result
                    return round(probe_x-result['local_x']), round(probe_y-result['local_y'])
                ipc.move_cursor(20, 20)
                empty = capture('empty')
                assert not present(w-40, bottom-40), 'map appeared at startup'
                navigate(300, 0)
                wait(lambda: present(w-40, bottom-40), 'navigation did not show map')
                x, y = map_box()
                shown = capture('shown')
                shown.save('/tmp/rediwm-mini-map-preview.png')
                crop = tuple(round(v*scale) for v in (x, y, w-16, bottom-16))
                assert ImageChops.difference(empty.crop(crop), shown.crop(crop)).getbbox(), 'map pixels missing'
                # PNG capture can take a second in Debug; restart before timing.
                navigate(300, 0)
                # Default 1.5s delay, with no hidden input region after dismissal.
                time.sleep(.65)
                assert present(w-40, bottom-40), 'default delay too short'
                wait(lambda: not present(w-40, bottom-40), 'map never hid')
                hidden = capture('hidden')
                delta = ImageChops.difference(empty.crop(crop), hidden.crop(crop))
                tolerance = 1 if os.getenv('REDIWM_TEST_RENDERER') == 'gles2' else 0
                assert max(high for low, high in delta.getextrema()) <= tolerance, ('stale map pixels', delta.getextrema())
                configure('mini_map_hide_ms = 500\n')
                navigate(0, 0)
                x, y = map_box()
                # At 100% zoom, the middle third is the current viewport.
                map_scale = min(220/(3*w), 140/(3*h))
                cx, cy = x+1.5*w*map_scale, y+1.5*h*map_scale
                ipc.move_cursor(round(cx), round(cy))
                time.sleep(.8)
                assert present(cx, cy), 'hover did not hold map open'
                before = cam()
                ipc.pointer_button(272, True)
                after = cam()
                assert (after['x'], after['y']) == (before['x'], before['y']), 'drag press jumped'
                ipc.move_cursor(round(cx+20), round(cy))
                assert abs(cam()['x'] - 20/map_scale) <= 2, cam()
                # The grab owns motion beyond the map and outlives its timeout.
                ipc.move_cursor(0, 20)
                time.sleep(.8)
                assert cam()['x'] == -cam()['max_x'], cam()
                assert present(w-40, bottom-40), 'map hid during drag'
                ipc.pointer_button(272, False)
                wait(lambda: not present(w-40, bottom-40), 'release outside did not start timeout')
                # Clicking an empty cell recenters; moving no longer affects camera after release.
                navigate(0, 0)
                x, y = map_box()
                target_x = round(x+.5*w*map_scale)
                ipc.click_at(target_x, round(y+1.5*h*map_scale))
                expected_x = max(-w, (target_x-x)/map_scale - 1.5*w)
                assert abs(cam()['x'] - expected_x) <= 1, cam()
                stopped = cam()
                ipc.move_cursor(20, 20)
                assert cam()['x'] == stopped['x'], 'stale map grab'
                # Zoom changes viewport size, not the world units represented by a map pixel.
                ipc.action('set_zoom', {'percent':70})
                navigate(0,0)
                x,y=map_box()
                before=cam()
                vx=round(x+(before['x']+w+w/.7/2)*map_scale)
                vy=round(y+(before['y']+h+h/.7/2)*map_scale)
                ipc.move_cursor(vx,vy)
                ipc.pointer_button(272,True)
                assert cam()['x']==before['x'], 'zoomed drag press jumped'
                ipc.move_cursor(vx+10,vy)
                assert abs(cam()['x']-before['x']-10/map_scale)<=2, cam()
                ipc.pointer_button(272,False)
                ipc.move_cursor(20,20)
                ipc.action('set_zoom', {'percent':100})
                # Settings and hot reload preserve all positions and cancel active grabs.
                for position in ('bottom_left', 'bottom_center', 'bottom_right'):
                    configure(f'mini_map_position = "{position}"\nmini_map_hide_ms = 500\n')
                    assert not present(w-40, bottom-40), 'reload revealed map'
                    navigate(0, 0)
                    px, py = map_box(position)
                    expected = {'bottom_left': 16, 'bottom_center': (w-220)//2, 'bottom_right': w-236}[position]
                    assert abs(px-expected) <= 1, (position, px, expected)
                    ipc.move_cursor(px+20, py+20)
                    ipc.pointer_button(272, True)
                    configure('mini_map_enabled = false\n')
                    assert not present(px+20, py+20), 'disable left a hit target'
                    ipc.pointer_button(272, False)
                    stopped = cam()
                    ipc.move_cursor(20,20)
                    assert cam()['x'] == stopped['x']
                    navigate(0,0)
                    assert not present(w-40,bottom-40), 'disabled map appeared'
                configure()
                # Existing shared Settings controls, including dropdown save/reload.
                ipc.action('open_control_center')
                time.sleep(.25)
                def widgets(): return ipc.get_widget_tree('control_center')['widgets']
                def widget(name): return next(v for v in widgets() if v.get('name') == name)
                def click_widget(v):
                    b=v['global_box']
                    ipc.click_at(round(b['x']+b['width']/2), round(b['y']+b['height']/2))
                    time.sleep(.15)
                click_widget(next(v for v in widgets() if v.get('label') == 'Desktop'))
                assert widget('mini_map_enabled')['checked'] is True
                assert widget('mini_map_position')['selected_index'] == 0
                assert widget('mini_map_hide_ms')['selected_index'] == 1
                def reveal(name):
                    for _ in range(20):
                        v=widget(name)
                        if v['visible'] and not v['clipped']: return v
                        box=ipc.get_shell_state()['control_center']['box']
                        ipc.move_cursor(round(box['x']+box['width']-80), round(box['y']+box['height']/2))
                        ipc.scroll(0, 100 if v['global_box']['y'] > box['y']+box['height']/2 else -100)
                        time.sleep(.08)
                    raise AssertionError(f'cannot scroll to {name}')
                for enabled in (False, True):
                    click_widget(reveal('mini_map_enabled'))
                    assert widget('mini_map_enabled')['checked'] is enabled
                    assert widget('mini_map_position')['is_disabled'] is (not enabled)
                    assert f'mini_map_enabled = {str(enabled).lower()}' in (tmp/'rediwm-config.toml').read_text()
                for name, steps, saved in [('mini_map_position', 2, 'mini_map_position = "bottom_left"'),
                                            ('mini_map_hide_ms', 1, 'mini_map_hide_ms = 2000')]:
                    click_widget(reveal(name))
                    assert widget(name)['open']
                    for _ in range(steps): ipc.key_press('Down')
                    ipc.key_press('Return')
                    time.sleep(.15)
                    assert saved in (tmp/'rediwm-config.toml').read_text()
                ipc.action('close_panel', {'panel': 'control_center'})
                time.sleep(.2)
                navigate(0,0)
                map_box('bottom_left')
                print(f'PASS: Mini Map defaults, pixels, timeout, hover, drag, clamping, positions, disable and Settings ({scale}x)')
        except Exception:
            print((tmp/'compositor.log').read_text()[-2500:])
            raise
        finally:
            stop_process(process)
            log.close()

if __name__ == '__main__': run()

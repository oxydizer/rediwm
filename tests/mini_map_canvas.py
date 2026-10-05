#!/usr/bin/env python3
"""Resizing the canvas in Settings with a window open keeps the minimap fitted."""
import math
import os
from pathlib import Path
import subprocess
import tempfile

from PIL import Image
from desktop_zoom import build_client, wait_for
from ipc_client import IPCClient, spawn_compositor, stop_process


def run():
    with tempfile.TemporaryDirectory(prefix='rediwm-map-canvas-') as directory:
        tmp = Path(directory)
        build_client(tmp)
        proc, log = spawn_compositor(
            tmp, scale=os.getenv('REDIWM_TEST_SCALE', '1'),
            renderer=os.getenv('REDIWM_TEST_RENDERER', 'pixman'),
            config_content='[compositor]\nxwayland = false\nmini_map_hide_ms = 10000\n[animations]\nenabled = false\n',
            env_extra={'DBUS_SESSION_BUS_ADDRESS': '', 'XDG_CACHE_HOME': str(tmp/'cache'),
                       'XDG_CONFIG_HOME': str(tmp/'config'), 'REDIWM_DESKTOP_DIR': str(tmp/'Desktop')})
        client = None
        try:
            with IPCClient(tmp, timeout=20) as ipc:
                ipc.action('wait_for', {'condition': 'wallpaper_presented', 'timeout_ms': 10000})
                out = ipc.get_outputs()[0]
                w, h, scale = out['logical_width'], out['logical_height'], out['scale']
                bottom = h - out['bottom_exclusion']
                display = next(p.name for p in tmp.glob('wayland-*') if not p.name.endswith('.lock'))
                client = subprocess.Popen([str(tmp/'client')],
                    env=dict(os.environ, XDG_RUNTIME_DIR=directory, WAYLAND_DISPLAY=display),
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                wait_for(lambda: ipc.get_windows(), 'window did not map')
                wid = ipc.get_windows()[0]['id']
                ipc.action('move_window_to', {'id': wid, 'x': 50, 'y': 50})

                def camera():
                    return ipc.request(raw_cmd={'version': 1, 'command': 'get_camera'})

                def click(label, index=0):
                    widget = [v for v in ipc.get_widget_tree('control_center')['widgets']
                              if v.get('label') == label][index]
                    box = widget['global_box']
                    ipc.click_at(round(box['x']+box['width']/2), round(box['y']+box['height']/2))
                    ipc.wait_for_frame()

                counts = [3, 3]

                def resize(columns, rows):
                    ipc.action('open_control_center')
                    ipc.wait_for_frame()
                    click('Desktop')
                    for axis, count in enumerate((columns, rows)):
                        for _ in range(abs(count-counts[axis])):
                            click('←' if count < counts[axis] else '→', axis)
                        counts[axis] = count
                    ipc.action('close_panel', {'panel': 'control_center'})
                    ipc.wait_for_frame()
                    ipc.move_cursor(20, 20)
                    ipc.action('set_camera', {'x': 0, 'y': 0})
                    ipc.wait_for_frame()

                for columns, rows in ((2, 2), (1, 1), (2, 2), (3, 3), (4, 4),
                                      (5, 5), (4, 2), (1, 3), (3, 1), (3, 3)):
                    resize(columns, rows)
                    state = camera()
                    assert state['max_x'] == w*(columns-1)/2, (columns, rows, state)
                    assert state['max_y'] == h*(rows-1)/2, (columns, rows, state)
                    factor = min(220/(columns*w), 140/(rows*h))
                    mw, mh = math.ceil(columns*w*factor), math.ceil(rows*h*factor)
                    x, y = w-mw-16, bottom-mh-16
                    hit = ipc.hit_test(w-18, bottom-18)
                    assert hit['target_type'] == 'mini_map', hit
                    assert abs(w-18-hit['local_x']-x) <= 1, (columns, rows, hit, x)
                    assert abs(bottom-18-hit['local_y']-y) <= 1, (columns, rows, hit, y)
                    # At 100%, the draggable viewport must cover exactly one
                    # screen's world area, including after odd/even changes.
                    # In the 1x1 case it fills the map with no blank margin.
                    path = tmp/'map.png'
                    path.unlink(missing_ok=True)
                    ipc.screenshot(path=str(path))
                    with Image.open(path) as image:
                        crop = image.convert('RGB').crop(tuple(round(v*scale) for v in (x, y, x+mw, y+mh)))
                        pixels = crop.load()
                        red = [(px, py) for px in range(crop.width) for py in range(crop.height)
                               if pixels[px, py][0] > 80 and pixels[px, py][0] > 2*pixels[px, py][1]]
                    assert red, 'viewport marker missing'
                    actual = (min(px for px, py in red), min(py for px, py in red),
                              max(px for px, py in red)+1, max(py for px, py in red)+1)
                    expected = tuple(math.floor(v+.5)*scale for v in (
                        (columns-1)*w*factor/2, (rows-1)*h*factor/2,
                        (columns+1)*w*factor/2, (rows+1)*h*factor/2))
                    assert all(abs(a-b) <= 2 for a, b in zip(actual, expected)), (columns, rows, actual, expected)

                # Shrinking must still leave an off-canvas window reachable.
                ipc.action('move_window_to', {'id': wid, 'x': -w, 'y': -h})
                resize(1, 1)
                assert camera()['max_x'] == w and camera()['max_y'] == h, camera()
                ipc.action('set_camera', {'x': -w, 'y': -h})
                ipc.wait_for_frame()
                assert camera()['x'] == -w and camera()['y'] == -h, camera()
                print(f'PASS: live canvas resizing, minimap bounds and single-screen pixels, off-canvas reachability ({scale}x)')
        except Exception:
            print((tmp/'compositor.log').read_text()[-2500:])
            raise
        finally:
            if client is not None:
                stop_process(client)
            stop_process(proc)
            log.close()


if __name__ == '__main__':
    run()

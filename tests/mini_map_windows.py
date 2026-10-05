#!/usr/bin/env python3
"""Window outline pixels, geometry and lifetime in an isolated minimap."""
import math
import os
from pathlib import Path
import subprocess
import tempfile
from PIL import Image, ImageChops
from ipc_client import IPCClient, spawn_compositor, stop_process
from desktop_zoom import build_client, wait_for


def run():
    with tempfile.TemporaryDirectory(prefix='rediwm-map-windows-') as directory:
        tmp = Path(directory)
        build_client(tmp)
        proc, log = spawn_compositor(tmp, scale=os.getenv('REDIWM_TEST_SCALE', '1'),
            renderer=os.getenv('REDIWM_TEST_RENDERER', 'pixman'),
            config_content='[compositor]\nxwayland = false\nmini_map_hide_ms = 10000\n[animations]\nenabled = false\n',
            env_extra={'DBUS_SESSION_BUS_ADDRESS': '', 'XDG_CACHE_HOME': str(tmp/'cache'),
                       'XDG_CONFIG_HOME': str(tmp/'config'), 'REDIWM_DESKTOP_DIR': str(tmp/'Desktop')})
        clients = []
        try:
            with IPCClient(tmp, timeout=20) as ipc:
                ipc.action('wait_for', {'condition': 'wallpaper_presented', 'timeout_ms': 10000})
                out = ipc.get_outputs()[0]
                w, h, scale = out['logical_width'], out['logical_height'], out['scale']
                factor = min(220/(3*w), 140/(3*h))
                mw, mh = math.ceil(3*w*factor), math.ceil(3*h*factor)
                mx, my = w-mw-16, h-out['bottom_exclusion']-mh-16
                ipc.action('set_camera', {'x': 0, 'y': 0})
                ipc.move_cursor(mx+2, my+2)  # Keep the map visible during screenshots.
                ipc.wait_for_frame()

                def capture():
                    ipc.wait_for_frame()
                    (tmp/'shot.png').unlink(missing_ok=True)
                    ipc.screenshot(path=str(tmp/'shot.png'))
                    with Image.open(tmp/'shot.png') as image:
                        return image.convert('RGB').crop(tuple(round(v*scale) for v in (mx, my, mx+mw, my+mh)))

                empty = capture()
                display = next(p.name for p in tmp.glob('wayland-*') if not p.name.endswith('.lock'))
                env = dict(os.environ, XDG_RUNTIME_DIR=str(tmp), WAYLAND_DISPLAY=display)
                for n in range(2):
                    clients.append(subprocess.Popen([str(tmp/'client'), '--app-id', f'map-test-{n}'],
                        env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
                    wait_for(lambda: len(ipc.get_windows()) == n+1, 'window did not map')
                windows = sorted(ipc.get_windows(), key=lambda item: item['app_id'])
                ids = [item['id'] for item in windows]

                def place(wid, x, y, width, height):
                    ipc.action('set_window_size', {'id': wid, 'width': width, 'height': height})
                    wait_for(lambda: ipc.get_window_debug(wid)['client_box']['width'] == width, 'resize not committed')
                    ipc.action('move_window_to', {'id': wid, 'x': x, 'y': y})
                    ipc.action('set_camera', {'x': 0, 'y': 0})
                    ipc.move_cursor(mx+2, my+2)
                    ipc.wait_for_frame()

                def outline(wid):
                    debug = ipc.get_window_debug(wid)
                    box = debug['chrome_box']
                    zoom = debug['zoom_percent']/100
                    # Match rounding to logical scene rectangles, then device pixels.
                    x0 = math.floor((box['x']+w)*factor+.5)
                    y0 = math.floor((box['y']+h)*factor+.5)
                    x1 = math.floor((box['x']+w+box['width']*zoom)*factor+.5)
                    y1 = math.floor((box['y']+h+box['height']*zoom)*factor+.5)
                    return x0, y0, x1, y1

                def check_edges(image, wid, check_interior=True):
                    x0, y0, x1, y1 = outline(wid)
                    delta = ImageChops.difference(empty, image)
                    for x, y in (((x0+x1)/2, y0), ((x0+x1)/2, y1-1),
                                 (x0, (y0+y1)/2), (x1-1, (y0+y1)/2)):
                        px, py = round(x*scale), round(y*scale)
                        patch = delta.crop((px-1, py-1, px+2, py+2))
                        assert max(high for low, high in patch.getextrema()) > 40, ('missing outline edge', wid, x, y)
                    if check_interior:
                        px, py = round((x0+x1)/2*scale), round((y0+y1)/2*scale)
                        assert max(delta.getpixel((px, py))) <= 2, 'outline unexpectedly fills window interior'

                place(ids[0], -200, -180, 320, 180)
                place(ids[1], round(w*.8), -220, 480, 260)
                shown = capture()
                shown.save("/tmp/rediwm-map-windows.png")
                for wid in ids: check_edges(shown, wid)
                # Outline pixels remain minimap input, including click-and-drag.
                x0, y0, x1, y1 = outline(ids[0])
                assert ipc.hit_test(mx+x0, my+y0)['target_type'] == 'mini_map'
                ipc.move_cursor(mx+x0, my+y0)
                ipc.pointer_button(272, True)
                before = ipc.request(raw_cmd={'version': 1, 'command': 'get_camera'})
                ipc.move_cursor(mx+x0+5, my+y0)
                assert ipc.request(raw_cmd={'version': 1, 'command': 'get_camera'})['x'] > before['x'], 'outline intercepted map drag'
                ipc.pointer_button(272, False)
                place(ids[0], -120, -140, 420, 220)
                moved = capture()
                check_edges(moved, ids[0])
                assert ImageChops.difference(shown, moved).getbbox(), 'move/resize left stale outline'
                # Camera zoom changes the viewport, not window world extents.
                for percent in (70, 100):
                    ipc.action('set_zoom', {'percent': percent})
                    camera_changed = capture()
                    # The viewport tint moves across the interiors; only the
                    # window outlines should stay at their original bounds.
                    for wid in ids: check_edges(camera_changed, wid, check_interior=False)
                ipc.set_zoom(ids[0], 70)
                place(ids[0], -120, -140, 420, 220)
                check_edges(capture(), ids[0])
                for wid in ids: ipc.minimize(wid)
                hidden = capture()
                assert max(high for low, high in ImageChops.difference(empty, hidden).getextrema()) <= 2, 'minimized outlines remain'
                ipc.restore(ids[0])
                place(ids[0], -120, -140, 420, 220)
                check_edges(capture(), ids[0])
                for client in clients: stop_process(client)
                wait_for(lambda: not ipc.get_windows(), 'closed windows remain')
                closed = capture()
                assert max(high for low, high in ImageChops.difference(empty, closed).getextrema()) <= 2, 'closed outlines remain'
                print(f'PASS: Mini Map window positions, sizes, zoom, drag, minimize, restore and close ({scale}x)')
        except Exception:
            print((tmp/'compositor.log').read_text()[-2500:])
            raise
        finally:
            for client in clients: stop_process(client)
            stop_process(proc)
            log.close()


if __name__ == '__main__': run()

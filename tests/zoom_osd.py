#!/usr/bin/env python3
"""Camera zoom uses the shared OSD, stays <=100%, and never takes input."""
import os
from pathlib import Path
import tempfile
import time

from PIL import Image, ImageChops
from ipc_client import IPCClient, spawn_compositor, stop_process


def run():
    with tempfile.TemporaryDirectory(prefix='rediwm-zoom-osd-') as directory:
        tmp = Path(directory)
        scale = float(os.getenv('REDIWM_TEST_SCALE', '1'))
        proc, log = spawn_compositor(tmp, scale=str(scale),
            renderer=os.getenv('REDIWM_TEST_RENDERER', 'pixman'),
            config_content='''[compositor]
xwayland = false
mini_map_enabled = false
zoom_steps = [1.5, 1.0, 0.85, 0.70, 0.55]
camera_zoom_max = 2.0
[desktop]
enabled = false
[animations]
enabled = false
[input]
invert_scroll = false
''', env_extra={'DBUS_SESSION_BUS_ADDRESS': '',
                'XDG_CONFIG_HOME': str(tmp/'config'), 'XDG_CACHE_HOME': str(tmp/'cache')})
        try:
            with IPCClient(tmp) as ipc:
                ipc.wait_for('wallpaper_presented', timeout_ms=10000)
                output = ipc.get_outputs()[0]
                w, h = output['logical_width'], output['logical_height']
                x = (w - 320)//2
                y = h - output['bottom_exclusion'] - 80
                box = tuple(round(v*scale) for v in (x, y, x+320, y+60))
                ipc.move_cursor(10, 10)

                def capture():
                    ipc.wait_for_frame()
                    (tmp/'shot.png').unlink(missing_ok=True)
                    ipc.screenshot(path=str(tmp/'shot.png'))
                    with Image.open(tmp/'shot.png') as image:
                        return image.convert('RGB').crop(box)

                def check_level(percent):
                    assert ipc.action('get_camera')['zoom_percent'] == percent
                    shot = capture()
                    row = [shot.getpixel((px, round(30*scale)))
                           for px in range(round(54*scale), round(236*scale))]
                    red = sum(r > 170 and r > g*2 and r > b*2 for r, g, b in row)
                    assert abs(red - 182*scale*percent/100) <= 3, (percent, red)
                    label = shot.crop(tuple(round(v*scale) for v in (248, 14, 308, 46)))
                    assert sum(min(label.getpixel((px, py))) > 180
                               for py in range(label.height) for px in range(label.width)) > 20*scale, 'zoom percentage missing'
                    assert ipc.get_input_state() == focus, 'zoom OSD changed input focus'
                    assert ipc.hit_test(x+160, y+30)['target_type'] == beneath, 'OSD intercepted input'
                    if preview := os.getenv('REDIWM_OSD_PREVIEW'):
                        folder = Path(preview)
                        folder.mkdir(parents=True, exist_ok=True)
                        shot.save(folder/f'zoom-{percent}-{scale}.png')
                    return shot

                baseline = capture()
                focus = ipc.get_input_state()
                beneath = ipc.hit_test(x+160, y+30)['target_type']
                ipc.action('set_zoom', {'percent': 55})
                check_level(55)
                ipc.key(125, True)
                ipc.key(56, True)
                try:
                    for percent in (70, 85, 100, 100, 100):
                        ipc.action('scroll', {'dx': 0, 'dy': -40})
                        # Modifier state is expected to change while held.
                        focus = ipc.get_input_state()
                        check_level(percent)
                finally:
                    ipc.key(56, False)
                    ipc.key(125, False)
                focus = ipc.get_input_state()
                ipc.action('pinch', {'phase': 'begin', 'fingers': 2})
                ipc.action('pinch', {'phase': 'update', 'scale': 3.0})
                live = next(a for a in ipc.action('get_animations') if a['site'] == 'camera.zoom')
                assert live['value'] == 1, live
                ipc.action('pinch', {'phase': 'end'})
                check_level(100)
                time.sleep(1.5)
                assert ImageChops.difference(baseline, capture()).getbbox() is None, 'zoom OSD did not fade out'
                print(f'PASS: zoom OSD pixels, percentage, input, timeout and 100% cap ({scale}x)')
        except Exception:
            print((tmp/'compositor.log').read_text()[-2500:])
            raise
        finally:
            stop_process(proc)
            log.close()


if __name__ == '__main__':
    run()

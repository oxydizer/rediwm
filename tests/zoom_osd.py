#!/usr/bin/env python3
"""Camera and window zoom overlays show their levels and let input pass through."""
import os
from pathlib import Path
import subprocess
import tempfile
import time

from PIL import Image, ImageChops
from desktop_zoom import build_client
from ipc_client import IPCClient, spawn_compositor, stop_process


def check_window_zoom(ipc, tmp, scale):
    build_client(tmp)
    display = next(p.name for p in tmp.glob('wayland-*') if not p.name.endswith('.lock'))
    client = subprocess.Popen([str(tmp/'client')],
        env=dict(os.environ, XDG_RUNTIME_DIR=str(tmp), WAYLAND_DISPLAY=display),
        stdout=subprocess.DEVNULL)
    try:
        ipc.wait_for('window_mapped', app_id='rediwm.zoom-fixture')
        window, = ipc.get_windows()
        wid = window['id']
        ipc.action('set_window_zoom', {'id': wid, 'percent': 100})
        ipc.action('move_window_to', {'id': wid, 'x': 240, 'y': 180})
        ipc.wait_for('window_geometry_settled', window_id=wid)
        ipc.move_cursor(440, 370)

        def capture(box):
            ipc.wait_for_frame()
            path = tmp/'window-zoom.png'
            path.unlink(missing_ok=True)
            ipc.screenshot(path=str(path))
            with Image.open(path) as image:
                return image.convert('RGB').crop(box)

        def step(percent, camera_percent):
            ipc.key(56, True)
            try:
                ipc.action('scroll', {'dx': 0, 'dy': 40})
            finally:
                ipc.key(56, False)
            ipc.wait_for_frame()
            ipc.wait_for('window_geometry_settled', window_id=wid)
            window, = ipc.get_windows()
            assert window['zoom_percent'] == percent, window
            camera = ipc.action('get_camera')
            assert camera['zoom_percent'] == camera_percent, camera
            frame = ipc.get_window_debug(wid)['chrome_box']
            z = camera_percent / 100
            center = (frame['x'] - camera['x'] + frame['width'] * percent / 200) * z
            top = (frame['y'] - camera['y']) * z
            box = tuple(round(v * scale) for v in (center-44, top-46, center+44, top-3))
            shot = capture(box)
            beneath = ipc.hit_test(round(center), round(top-24))
            time.sleep(1.4)
            faded = capture(box)
            assert ipc.hit_test(round(center), round(top-24)) == beneath, 'window zoom OSD intercepted input'
            bounds = ImageChops.difference(shot, faded).getbbox()
            assert bounds is not None, 'window zoom OSD missing or failed to fade'
            expected = (8, 6, 80, 38)
            assert all(abs(actual - want * scale) <= 2 for actual, want in zip(bounds, expected)), bounds
            label = shot.crop(tuple(round(v * scale) for v in (19, 12, 69, 32)))
            return label.point(lambda value: 255 if value > 180 else 0).convert('L')

        label_85 = step(85, 100)
        ipc.move_cursor(0, 0)
        ipc.action('set_zoom', {'percent': 70})
        ipc.move_cursor(320, 270)
        label_70 = step(70, 70)
        assert label_85.getbbox() and label_70.getbbox(), 'window zoom percentage missing'
        assert ImageChops.difference(label_85, label_70).getbbox(), 'window zoom percentage stayed the same'
        print(f'PASS: window zoom OSD placement, fixed size, input and timeout ({scale}x)')
    finally:
        stop_process(client)


def run():
    with tempfile.TemporaryDirectory(prefix='rediwm-zoom-osd-') as directory:
        tmp = Path(directory)
        scale = float(os.getenv('REDIWM_TEST_SCALE', '1'))
        proc, log = spawn_compositor(tmp, scale=str(scale),
            renderer=os.getenv('REDIWM_TEST_RENDERER', 'gles2'),
            config_content='''[compositor]
xwayland = false
mini_map_enabled = false
focus_zoom = "keep"
zoom_steps = [1.5, 1.0, 0.85, 0.70, 0.55]
camera_zoom_max = 2.0
[desktop]
enabled = false
[animations]
enabled = false
[input]
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
                check_window_zoom(ipc, tmp, scale)
        except Exception:
            print((tmp/'compositor.log').read_text()[-2500:])
            raise
        finally:
            stop_process(proc)
            log.close()


if __name__ == '__main__':
    run()

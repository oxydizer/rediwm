#!/usr/bin/env python3
"""Panel-only opacity and frame-paced, minimized live previews; no host access."""
import math
import os
from pathlib import Path
import subprocess
import tempfile
import time
from PIL import Image
from desktop_zoom import build_client, wait_for
from ipc_client import IPCClient, spawn_compositor, stop_process


def circular_geometry(output, taskbar):
    scale = output['scale']
    width = output['logical_width']
    usable_height = taskbar['box']['y']
    diameter = min(720, width - 32, usable_height - 32)
    center_x = ((width - diameter) // 2 + diameter / 2) * scale
    center_y = ((usable_height - diameter) // 2 + diameter / 2) * scale
    return center_x, center_y, diameter * .18 * scale, (diameter / 2 - 36) * scale


def assert_circular_arc(image, output, taskbar):
    """The selected arc follows a circle even between the former polygon vertices."""
    center_x, center_y, _, radius = circular_geometry(output, taskbar)
    errors = []
    for x in range(math.ceil(center_x - radius * .45), math.floor(center_x + radius * .45)):
        expected = center_y - math.sqrt(radius ** 2 - (x + .5 - center_x) ** 2)
        outline = [y for y in range(math.floor(expected) - 2, math.ceil(expected) + 7)
                   if (lambda c: c[0] > 220 and 15 < c[1] < 65 and 35 < c[2] < 95)(image.getpixel((x, y)))]
        assert outline, ('missing circular outer edge', x, expected)
        errors.append(min(outline) + .5 - expected)
    # Allow the antialiasing threshold and pixel-center quantization, but not
    # the 2–4px chord sag of the previous seven-segment outer arc.
    assert errors and max(abs(error) for error in errors) <= 1.5, ('faceted circular edge', min(errors), max(errors))


def run(scale, style='linear'):
    with tempfile.TemporaryDirectory(prefix='rediwm-switcher-live-') as directory:
        tmp = Path(directory)
        build_client(tmp)
        wallpaper = tmp / 'wallpaper.png'
        Image.new('RGB', (32, 32), (20, 24, 30)).save(wallpaper)
        proc, log = spawn_compositor(tmp, scale=scale, renderer=os.environ.get('REDIWM_TEST_RENDERER', 'gles2'), config_content=f'[compositor]\nwallpaper = "{wallpaper}"\nswitcher_style = "{style}"\n')
        clients = []
        try:
            with IPCClient(tmp) as ipc:
                ipc.wait_for('wallpaper_presented', timeout_ms=10000)
                display = next(p.name for p in tmp.glob('wayland-*') if not p.name.endswith('.lock'))
                colors = tmp / 'color'
                colors.write_text('ff2255dd 400 260')
                with (tmp / 'client.log').open('w') as out:
                    clients.append(subprocess.Popen([str(tmp / 'client'), '--title', 'Live preview'], env=dict(os.environ, XDG_RUNTIME_DIR=str(tmp), WAYLAND_DISPLAY=display, REDIWM_TEST_LIVE_FILE=str(colors)), stdout=out, stderr=out))
                wait_for(lambda: ipc.get_windows(), 'client map')
                wid = ipc.get_windows()[0]['id']
                ipc.action('minimize_window', {'id': wid})
                time.sleep(.1)
                def capture(name):
                    path = tmp / (name + '.png')
                    ipc.screenshot(path=str(path))
                    wait_for(path.exists, 'capture')
                    image = Image.open(path).convert('RGB')
                    if dest := os.environ.get('REDIWM_SWITCHER_PREVIEW'):
                        Path(dest).mkdir(parents=True, exist_ok=True)
                        image.save(Path(dest) / f'{style}-{name}-{scale}.png')
                    return image
                backdrop = capture('backdrop')
                ipc.key(29, True)
                ipc.key_down_up(15)
                time.sleep(.25)
                opaque = capture('opaque')
                if style == 'circular':
                    assert_circular_arc(opaque, ipc.get_outputs()[0], ipc.get_shell_state()['taskbars'][0])
                red = [(x, y) for y in range(opaque.height) for x in range(opaque.width)
                       if (lambda c: c[0] > 220 and 15 < c[1] < 65 and 35 < c[2] < 95)(opaque.getpixel((x, y)))]
                assert red, 'missing outline'
                left, right = min(x for x, y in red), max(x for x, y in red)
                top, bottom = min(y for x, y in red), max(y for x, y in red)
                center = ((left + right) // 2, (top + bottom) // 2)
                sample = (center[0], int(bottom + 75 * float(scale)))
                def near(a, b): return all(abs(x - y) <= 3 for x, y in zip(a, b))
                # A minimized client must still receive callbacks through its preview.
                colors.write_text('ff22cc66 400 260')
                time.sleep(.25)
                live = capture('live')
                assert near(live.getpixel(center), (34, 204, 102)), live.getpixel(center)
                assert near(opaque.getpixel(center), (34, 85, 221)), opaque.getpixel(center)
                assert ipc.get_windows()[0]['is_minimized'], 'preview restored client'
                for opacity in (0.5, 0.0, 1.0) if style == 'linear' else ():
                    (tmp / 'rediwm-config.toml').write_text(f'[compositor]\nwallpaper = "{wallpaper}"\nswitcher_style = "{style}"\nswitcher_opacity = {opacity}\n')
                    ipc.reload_config()
                    time.sleep(.15)
                    image = capture(f'opacity-{opacity}')
                    expected = tuple(round(a * opacity + b * (1 - opacity)) for a, b in zip(opaque.getpixel(sample), backdrop.getpixel(sample)))
                    assert near(image.getpixel(sample), expected), (opacity, image.getpixel(sample), expected)
                    assert near(image.getpixel(center), live.getpixel(center)), 'opacity changed app preview'
                    label = image.crop((left + 10, int(bottom + 16 * float(scale)), right - 10, int(bottom + 62 * float(scale))))
                    assert sum(all(c > 140 for c in label.getpixel((x, y))) for y in range(label.height) for x in range(label.width)) > 30, 'label disappeared'
                colors.write_text('ffcc9922 200 400')
                time.sleep(.25)
                resized = capture('resized')
                assert near(resized.getpixel(center), (204, 153, 34)), resized.getpixel(center)
                if style == 'linear':
                    assert not near(resized.getpixel((int(center[0] + 70 * float(scale)), center[1])), (204, 153, 34)), 'preview aspect ratio did not update'
                ipc.key_down_up(1)
                ipc.key(29, False)
                time.sleep(.2)
                count = (tmp / 'client.log').read_text().count('frame ')
                time.sleep(.2)
                assert (tmp / 'client.log').read_text().count('frame ') == count, 'hidden minimized preview kept requesting frames'
                assert proc.poll() is None
                print(f'PASS live switcher style={style} scale={scale}')
        except Exception:
            print((tmp / 'compositor.log').read_text()[-4000:])
            raise
        finally:
            for client in clients: stop_process(client)
            stop_process(proc)
            log.close()


def run_radial_framing(scale):
    """Each sector retains the source's top; tall windows crop at the hub."""
    with tempfile.TemporaryDirectory(prefix='rediwm-switcher-radial-') as directory:
        tmp = Path(directory)
        build_client(tmp)
        wallpaper = tmp / 'wallpaper.png'
        Image.new('RGB', (32, 32), (20, 24, 30)).save(wallpaper)
        proc, log = spawn_compositor(tmp, scale=scale,
            renderer=os.environ.get('REDIWM_TEST_RENDERER', 'gles2'),
            config_content=f'[compositor]\nwallpaper = "{wallpaper}"\nswitcher_style = "circular"\n')
        clients = []
        try:
            with IPCClient(tmp) as ipc:
                ipc.wait_for('wallpaper_presented', timeout_ms=10000)
                display = next(p.name for p in tmp.glob('wayland-*') if not p.name.endswith('.lock'))
                pattern = tmp / 'pattern'
                # A zero live color asks the existing fixture for red above its
                # midpoint and blue below. No production test hook is needed.
                pattern.write_text('0 200 1000')
                for i in range(4):
                    clients.append(subprocess.Popen([str(tmp / 'client'), '--title', f'Radial {i}',
                        '--app-id', f'rediwm.radial-fixture.{i}'],
                        env=dict(os.environ, XDG_RUNTIME_DIR=str(tmp), WAYLAND_DISPLAY=display,
                                 REDIWM_TEST_LIVE_FILE=str(pattern), REDIWM_TEST_NO_CHILD='1'),
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
                    wait_for(lambda: len(ipc.get_windows()) == i + 1, 'radial client map')
                for window in ipc.get_windows():
                    ipc.action('minimize_window', {'id': window['id']})
                wait_for(lambda: all(w['is_minimized'] for w in ipc.get_windows()), 'radial clients minimized')
                ipc.key(29, True)
                ipc.key_down_up(15)

                def capture(name):
                    time.sleep(.25)
                    path = tmp / f'{name}.png'
                    ipc.screenshot(path=str(path))
                    wait_for(path.exists, 'radial capture')
                    image = Image.open(path).convert('RGB')
                    if dest := os.environ.get('REDIWM_SWITCHER_PREVIEW'):
                        Path(dest).mkdir(parents=True, exist_ok=True)
                        image.save(Path(dest) / f'circular-{name}-{scale}.png')
                    return image

                output = ipc.get_outputs()[0]
                taskbar = ipc.get_shell_state()['taskbars'][0]
                cx, cy, inner, outer = circular_geometry(output, taskbar)
                inset = 6 * output['scale']

                def check_radial_colors(image, inner_color):
                    for dx, dy in ((0, -1), (1, 0), (0, 1), (-1, 0)):
                        for radius, expected in ((outer - inset, (255, 0, 0)),
                                                 (inner + inset, inner_color)):
                            point = (round(cx + dx * radius), round(cy + dy * radius))
                            actual = image.getpixel(point)
                            assert all(abs(a - b) <= 3 for a, b in zip(actual, expected)), (
                                'source top/bottom framing', (dx, dy), radius, actual, expected)

                # Tall source bottoms must disappear behind the center, leaving
                # the red upper half visible throughout all four radial views.
                tall = capture('tall-top')
                check_radial_colors(tall, (255, 0, 0))
                assert_circular_arc(tall, output, taskbar)
                # A shorter source reaches its blue lower half near the hub.
                # This also checks orientation at right, bottom and left, where
                # upright rectangular crops cannot keep the source top outside.
                pattern.write_text('0 400 240')
                check_radial_colors(capture('short-top'), (0, 0, 255))
                # Hover previews a window in the hub without changing the
                # keyboard selection. The caret travels around the inner rim.
                ipc.move_cursor(1, 1)
                baseline = capture('hover-baseline')
                density = output['scale']
                hub_size = int((inner / density / .18) * .36 - 16)
                orbit = (hub_size / 2 - 16 * min(1, hub_size / 210)) * density
                hub_text = (round(cx - 42 * density), round(cy - 25 * density),
                            round(cx + 42 * density), round(cy + 42 * density))
                def accent_near(image, x, y):
                    patch = image.crop((round(x - 14 * density), round(y - 14 * density),
                                        round(x + 14 * density), round(y + 14 * density)))
                    return sum(r > 220 and 15 < g < 65 and 35 < b < 95
                               for r, g, b in patch.getdata())
                hovered_hub = None
                for name, dx, dy in (('right', 1, 0), ('bottom', 0, 1), ('left', -1, 0)):
                    radius = (inner + outer) / 2
                    ipc.move_cursor(round((cx + dx * radius) / density), round((cy + dy * radius) / density))
                    time.sleep(.3)
                    image = capture(f'hover-{name}')
                    assert accent_near(image, cx + dx * orbit, cy + dy * orbit) > 10, 'caret did not orbit toward hover'
                    assert accent_near(image, cx, cy - orbit) == 0, 'caret stayed above hub'
                    assert image.crop(hub_text).tobytes() != baseline.crop(hub_text).tobytes(), 'hub kept selected title'
                    if name == 'right': hovered_hub = image.crop(hub_text).tobytes()
                ipc.move_cursor(1, 1)
                time.sleep(.3)
                restored = capture('hover-restored')
                assert restored.tobytes() == baseline.tobytes(), 'hover did not restore selection or settle'
                ipc.key_down_up(15)  # The former right-hand sector is now selected.
                selected = capture('hover-selected')
                assert selected.crop(hub_text).tobytes() == hovered_hub, 'hover title differs from selected title'
                assert all(w['is_minimized'] for w in ipc.get_windows()), 'radial preview restored a client'
                ipc.key_down_up(1)
                ipc.key(29, False)
                assert proc.poll() is None
                print(f'PASS radial switcher framing scale={scale}')
        except Exception:
            print((tmp / 'compositor.log').read_text()[-4000:])
            raise
        finally:
            for client in clients: stop_process(client)
            stop_process(proc)
            log.close()


if __name__ == '__main__':
    for style in ('linear', 'circular'):
        for scale in ('1', '1.5'): run(scale, style)
    for scale in ('1', '1.5'): run_radial_framing(scale)

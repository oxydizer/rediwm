#!/usr/bin/env python3
"""Panel-only opacity and frame-paced, minimized live previews; no host access."""
import os
from pathlib import Path
import subprocess
import tempfile
import time
from PIL import Image
from desktop_zoom import build_client, wait_for
from ipc_client import IPCClient, spawn_compositor, stop_process


def run(scale):
    with tempfile.TemporaryDirectory(prefix='rediwm-switcher-live-') as directory:
        tmp = Path(directory)
        build_client(tmp)
        proc, log = spawn_compositor(tmp, scale=scale, renderer=os.environ.get('REDIWM_TEST_RENDERER', 'pixman'))
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
                        image.save(Path(dest) / f'{name}-{scale}.png')
                    return image
                backdrop = capture('backdrop')
                ipc.key(29, True)
                ipc.key_down_up(15)
                time.sleep(.25)
                opaque = capture('opaque')
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
                for opacity in (0.5, 0.0, 1.0):
                    (tmp / 'rediwm-config.toml').write_text(f'[compositor]\nswitcher_opacity = {opacity}\n')
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
                assert not near(resized.getpixel((int(center[0] + 70 * float(scale)), center[1])), (204, 153, 34)), 'preview aspect ratio did not update'
                ipc.key_down_up(1)
                ipc.key(29, False)
                time.sleep(.2)
                count = (tmp / 'client.log').read_text().count('frame ')
                time.sleep(.2)
                assert (tmp / 'client.log').read_text().count('frame ') == count, 'hidden minimized preview kept requesting frames'
                assert proc.poll() is None
                print(f'PASS live switcher scale={scale}')
        except Exception:
            print((tmp / 'compositor.log').read_text()[-4000:])
            raise
        finally:
            for client in clients: stop_process(client)
            stop_process(proc)
            log.close()


if __name__ == '__main__':
    for scale in ('1', '1.5'): run(scale)

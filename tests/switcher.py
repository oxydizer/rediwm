#!/usr/bin/env python3
"""Alt/Ctrl+Tab MRU carousel, input ownership and pixels on an isolated compositor."""
import os
from pathlib import Path
import subprocess
import tempfile
import time
from PIL import Image
from desktop_zoom import build_client, wait_for
from ipc_client import IPCClient, spawn_compositor, stop_process


def run(scale, modifier=56):
    with tempfile.TemporaryDirectory(prefix='rediwm-switcher-') as directory:
        tmp = Path(directory)
        build_client(tmp)
        proc, log = spawn_compositor(tmp, scale=scale, renderer=os.environ.get('REDIWM_TEST_RENDERER', 'pixman'), config_content=f'[compositor]\nswitcher_opacity = {os.environ.get("REDIWM_TEST_SWITCHER_OPACITY", "1.0")}\n[input]\nkey_repeat_delay = 200\nkey_repeat_rate = 5\n[keybinds]\n\"alt+tab\" = \"focus_next\"\n\"alt+shift+tab\" = \"focus_prev\"\n')
        clients = []
        try:
            with IPCClient(tmp) as ipc:
                ipc.wait_for('wallpaper_presented', timeout_ms=10000)
                display = next(p.name for p in tmp.glob('wayland-*') if not p.name.endswith('.lock'))
                for i in range(7):
                    with (tmp / f'client-{i}.log').open('w') as out:
                        clients.append(subprocess.Popen([str(tmp / 'client'), '--title', f'Window {i}', '--app-id', 'org.gnome.Nautilus'], env=dict(os.environ, XDG_RUNTIME_DIR=str(tmp), WAYLAND_DISPLAY=display), stdout=out, stderr=out))
                    wait_for(lambda: len(ipc.get_windows()) == i + 1, 'map fixture')
                ids = [w['id'] for w in ipc.get_windows()]
                def focused():
                    return next(w['id'] for w in ipc.get_windows() if w['is_focused'])
                initial = focused()
                # Query order is not assumed: explicitly establish a known MRU stack.
                for wid in ids:
                    ipc.action('focus_window', {'id': wid})
                initial = ids[-1]
                def tab(reverse=False):
                    if reverse: ipc.key(42, True)
                    ipc.key_down_up(15)
                    if reverse: ipc.key(42, False)
                def capture(name):
                    time.sleep(.23)
                    path = tmp / (name + '.png')
                    ipc.screenshot(path=str(path))
                    wait_for(path.exists, 'capture')
                    image = Image.open(path).convert('RGB')
                    dest = os.environ.get('REDIWM_SWITCHER_PREVIEW')
                    if dest:
                        Path(dest).mkdir(parents=True, exist_ok=True)
                        image.save(Path(dest) / f'{name}-{scale}.png')
                    return image
                ipc.key(modifier, True)
                tab()
                assert focused() == initial, 'preview must not change focus'
                camera = ipc.get_state()['camera']
                ipc.key(125, True)  # KEY_LEFTMETA: with the Alt modifier, the pan trigger; held to confirm the switcher blocks it
                ipc.move_cursor(1000, 500)
                assert ipc.get_state()['camera'] == camera, 'Super motion panned during switching'
                ipc.key(125, False)
                first = capture('first')
                tab()
                second = capture('second')
                # Red selection frame stays at exactly the same screen coordinates.
                def red_pixels(im):
                    return {(x, y) for y in range(im.height) for x in range(im.width)
                            if (lambda c: c[0] > 220 and 15 < c[1] < 65 and 35 < c[2] < 95)(im.getpixel((x, y)))}
                red = red_pixels(first)
                assert len(red) > 200, 'selection outline is visible'
                assert red == red_pixels(second), 'center highlight moved'
                assert first.tobytes() != second.tobytes(), 'row did not scroll'
                # Text beneath every fully visible preview must survive GPU
                # compositing as well as movement, not just the red outline.
                left = min(x for x, y in red)
                right = max(x for x, y in red)
                bottom = max(y for x, y in red)
                density = float(scale)
                for offset in range(-2, 3):
                    x0 = int(left + (12 + offset * 244) * density)
                    x1 = int(right + (-12 + offset * 244) * density)
                    if x0 < 32 * density or x1 > second.width - 32 * density: continue
                    label = second.crop((x0, int(bottom + 16 * density), x1, int(bottom + 62 * density)))
                    assert sum(all(c > 140 for c in label.getpixel((x, y))) for y in range(label.height) for x in range(label.width)) > 30, 'missing carousel label'

                ipc.key(modifier, False)
                wait_for(lambda: focused() == ids[-3], 'release Alt activates selection')
                ipc.key(modifier, True)
                tab()
                ipc.key_down_up(1)
                ipc.key(modifier, False)
                assert focused() == ids[-3], 'Escape must preserve focus'
                ipc.key(modifier, True)
                tab(reverse=True)
                ipc.key(modifier, False)
                wait_for(lambda: focused() == ids[0], 'reverse wraps to oldest window')
                # Completing a whole lap preserves focus and terminates normally.
                ipc.key(modifier, True)
                for _ in ids: tab()
                ipc.key(modifier, False)
                assert focused() == ids[0]
                ipc.key(modifier, True)
                tab()
                stop_process(clients.pop())
                wait_for(lambda: len(ipc.get_windows()) == 6, 'client teardown')
                ipc.key(modifier, False)
                assert proc.poll() is None
                for i in range(6):
                    contents = (tmp / f'client-{i}.log').read_text()
                    assert 'key 15 ' not in contents and 'key 1 ' not in contents, 'switcher keys leaked to client'
                # Held Tab repeats; its release stops the timer before acceptance.
                ipc.action('focus_window', {'id': ipc.get_windows()[0]['id']})
                repeat_ids = [w['id'] for w in ipc.get_windows()]
                for wid in repeat_ids: ipc.action('focus_window', {'id': wid})
                before = focused()
                ipc.key(modifier, True)
                ipc.key(15, True)
                time.sleep(.28)
                ipc.key(15, False)
                ipc.key(modifier, False)
                assert focused() not in (before, repeat_ids[-2]), 'held Tab failed to repeat'
                accepted = focused()
                time.sleep(.25)
                assert focused() == accepted, 'repeat continued after release'
                ipc.key(modifier, True)
                tab()
                ipc.pointer_button(0x110, True)
                ipc.pointer_button(0x110, False)
                ipc.key(modifier, False)
                assert focused() == accepted, 'dismissal must preserve focus'
                while len(clients) > 1:
                    stop_process(clients.pop())
                wait_for(lambda: len(ipc.get_windows()) == 1, 'one remaining window')
                sole = ipc.get_windows()[0]['id']
                ipc.action('minimize_window', {'id': sole})
                ipc.key(modifier, True)
                tab()
                ipc.key(modifier, False)
                wait_for(lambda: focused() == sole, 'restore minimized window')
                assert not ipc.get_windows()[0]['is_minimized']
                stop_process(clients.pop())
                wait_for(lambda: not ipc.get_windows(), 'last window closed')
                ipc.key(modifier, True)
                tab()
                ipc.key(modifier, False)
                assert proc.poll() is None, 'empty carousel crashed'
                print(f'PASS switcher scale={scale} modifier={modifier}')
        except Exception:
            print((tmp / "compositor.log").read_text()[-6000:])
            raise
        finally:
            for client in clients: stop_process(client)
            stop_process(proc)
            log.close()


if __name__ == '__main__':
    for modifier in (56, 29):
        for scale in ('1', '1.5'): run(scale, modifier)

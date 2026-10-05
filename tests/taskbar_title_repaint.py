#!/usr/bin/env python3
"""Taskbar chips re-raster only when their own pixels change; no host access.

A window title update (a terminal spinner, a browser tab counter) used to
re-raster every chip. Checks the raster counts and that the skipped chips'
pixels really are unchanged, plus the kernel uevent socket behind the battery
indicator.
"""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile
import time

from PIL import Image, ImageChops

from desktop_zoom import build_client, wait_for
from ipc_client import IPCClient, spawn_compositor, stop_process


def uevent_sockets(pid):
    """Kernel uevent (protocol 15) sockets bound to group 1 by `pid`'s port."""
    rows = Path('/proc/net/netlink').read_text().splitlines()[1:]
    return [r for r in rows if r.split()[1] == '15' and r.split()[2] == str(pid) and int(r.split()[3], 16) & 1]


def run(scale):
    with tempfile.TemporaryDirectory(prefix='rediwm-title-repaint-') as directory:
        tmp = Path(directory)
        build_client(tmp)
        proc, log = spawn_compositor(tmp, scale=scale, renderer=os.environ.get('REDIWM_TEST_RENDERER', 'pixman'))
        clients = []
        try:
            with IPCClient(tmp) as ipc:
                ipc.wait_for('wallpaper_presented', timeout_ms=10000)
                assert uevent_sockets(proc.pid), 'no power_supply uevent socket'
                display = next(p.name for p in tmp.glob('wayland-*') if not p.name.endswith('.lock'))
                env = dict(os.environ, XDG_RUNTIME_DIR=str(tmp), WAYLAND_DISPLAY=display)
                live = tmp / 'live'
                live.write_text('ff2255dd 400 260 alpha 0')
                with (tmp / 'client.log').open('w') as out:
                    # `alpha` commits every frame and takes its title from the file.
                    clients.append(subprocess.Popen([str(tmp / 'client'), '--title', 'alpha'], env=dict(env, REDIWM_TEST_LIVE_FILE=str(live)), stdout=out, stderr=out))
                    wait_for(lambda: len(ipc.get_windows()) == 1, 'alpha map')
                    clients.append(subprocess.Popen([str(tmp / 'client'), '--title', 'beta'], env=env, stdout=out, stderr=out))
                    wait_for(lambda: len(ipc.get_windows()) == 2, 'beta map')
                windows = {w['title']: w['id'] for w in ipc.get_windows()}
                alpha, beta = windows['alpha 0'], windows['beta']
                time.sleep(1)  # FLIP and focus animations settle

                bar = ipc.get_shell_state()['taskbars'][0]
                chips = {c['window_id']: c['box'] for c in bar['chips']}
                factor = float(scale)

                def shot(name):
                    path = tmp / f'{name}.png'
                    ipc.screenshot(path=str(path), output=bar['output'])
                    wait_for(path.exists, 'capture')
                    return Image.open(path).convert('RGB')

                def chip(image, wid):
                    b = chips[wid]
                    return image.crop((round(b['x'] * factor), round(b['y'] * factor),
                                       round((b['x'] + b['width']) * factor), round((b['y'] + b['height']) * factor)))

                def changed(a, b, wid):
                    return ImageChops.difference(chip(a, wid), chip(b, wid)).getbbox() is not None

                def chip_paints(action, settle):
                    ipc.reset_perf()
                    action()
                    settle()
                    time.sleep(.3)
                    return ipc.get_perf()['taskbar_chip_paints']

                def retitle(title):
                    live.write_text(f'ff2255dd 400 260 {title}')
                    return lambda: wait_for(lambda: any(w['title'] == title for w in ipc.get_windows()), f'title {title}')

                before = shot('before')
                # An unchanged bar with a client committing every frame paints nothing.
                idle = chip_paints(lambda: None, lambda: time.sleep(1))
                assert idle == 0, f'idle chip paints: {idle}'

                settle = retitle('alpha 1')
                paints = chip_paints(lambda: None, settle)
                after_title = shot('after-title')
                assert paints == 1, f'title change painted {paints} chips'
                assert changed(before, after_title, alpha), 'retitled chip kept its old pixels'
                assert not changed(before, after_title, beta), 'untouched chip changed'

                paints = chip_paints(lambda: ipc.focus_window(alpha), lambda: time.sleep(.2))
                after_focus = shot('after-focus')
                assert paints == 2, f'focus change painted {paints} chips'
                assert changed(after_title, after_focus, alpha) and changed(after_title, after_focus, beta), 'focus change skipped a chip'

                settle = retitle('alpha 2')
                paints = chip_paints(lambda: None, settle)
                after_active = shot('after-active-title')
                assert paints == 1, f'active title change painted {paints} chips'
                assert changed(after_focus, after_active, alpha), 'active chip kept its old title'
                assert not changed(after_focus, after_active, beta), 'inactive chip changed'
                print(f'PASS scale {scale}: title and focus changes re-raster only affected chips')
        finally:
            for client in clients:
                client.kill()
            stop_process(proc)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--scale', action='append')
    for scale in parser.parse_args().scale or ['1', '1.5']:
        run(scale)

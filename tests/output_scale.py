#!/usr/bin/env python3
"""Mixed output density, real client buffers, shell rasters, reload and override."""
import os
from pathlib import Path
import subprocess
import tempfile

from PIL import Image

from desktop_zoom import ROOT, wait_for
from ipc_client import IPCClient, spawn_compositor, stop_process


def build_client(tmp):
    protocols = Path(subprocess.check_output(
        ['pkg-config', '--variable=pkgdatadir', 'wayland-protocols'], text=True).strip())
    sources = []
    for name, path in [
        ('xdg-shell', 'stable/xdg-shell/xdg-shell.xml'),
        ('fractional-scale', 'staging/fractional-scale/fractional-scale-v1.xml'),
        ('viewporter', 'stable/viewporter/viewporter.xml'),
        ('xdg-decoration', 'unstable/xdg-decoration/xdg-decoration-unstable-v1.xml'),
    ]:
        source = tmp / f'{name}-protocol.c'
        subprocess.run(['wayland-scanner', 'client-header', str(protocols / path),
                        str(tmp / f'{name}-client-protocol.h')], check=True)
        subprocess.run(['wayland-scanner', 'private-code', str(protocols / path), str(source)], check=True)
        sources.append(str(source))
    subprocess.run(['cc', '-Wall', '-Wextra', '-Werror', f'-I{tmp}',
                    str(ROOT / 'tests/output_scale_client.c'), *sources,
                    '-lwayland-client', '-o', str(tmp / 'scale-client')], check=True)


def config(scale):
    return f'''[compositor]
xwayland = false
[[outputs]]
name = "HEADLESS-1"
scale = 1
[[outputs]]
name = "HEADLESS-2"
scale = {scale}
'''


def run_case(binary, override='auto'):
    with tempfile.TemporaryDirectory(prefix='rediwm-output-scale-') as directory:
        tmp = Path(directory)
        renderer = os.environ.get('REDIWM_TEST_RENDERER', 'pixman')
        compositor, log = spawn_compositor(tmp, scale=override, outputs='2', config_content=config(1.5),
                                           renderer=renderer,
                                           env_extra={'XDG_CACHE_HOME': str(tmp / 'cache')})
        client = None
        client_log = None
        try:
            socket = wait_for(lambda: next(tmp.glob('rediwm-*.sock'), None), 'IPC unavailable')
            with IPCClient(socket) as ipc:
                outputs = wait_for(lambda: ipc.get_outputs() if len(ipc.get_outputs()) == 2 else None, 'outputs absent')
                outputs.sort(key=lambda out: out['name'])
                expected = [1, 1.5] if override == 'auto' else [float(override)] * 2
                assert [o['scale'] for o in outputs] == expected, outputs
                # A scale-only config must not pin both outputs to (0, 0).
                left, right = sorted(outputs, key=lambda out: out['x'])
                assert right['x'] == left['x'] + left['logical_width'], outputs
                def capture_output(out):
                    current = next(o for o in ipc.get_outputs() if o['name'] == out['name'])
                    path = tmp / 'output.png'
                    path.unlink(missing_ok=True)
                    ipc.screenshot(path=str(path), output=out['name'])
                    with Image.open(path) as image:
                        assert image.size == (current['buffer_width'], current['buffer_height'])

                for out in outputs:
                    if renderer == 'pixman':
                        bar = ipc.dump_buffer('taskbar', output=out['name'])
                        assert bar['scale'] == out['scale'], bar.keys()
                        assert bar['width'] == out['buffer_width'], (bar['width'], out)
                    else:
                        # GLES2 releases CPU scene buffers after texture upload.
                        # Inspect the rendered output instead of DumpBuffer.
                        capture_output(out)
                if override != 'auto':
                    print(f'output-scale: global override passed ({override}x)')
                    return
                display = next(p.name for p in tmp.glob('wayland-*') if not p.name.endswith('.lock'))
                client_log = (tmp / 'client.log').open('w')
                client = subprocess.Popen([str(binary)], env=dict(os.environ, XDG_RUNTIME_DIR=str(tmp),
                                          WAYLAND_DISPLAY=display), stdout=client_log, stderr=client_log)
                window = wait_for(lambda: next((w for w in ipc.get_windows() if w['app_id'] == 'rediwm-scale-test'), None),
                                  'client not mapped')
                wid = window['id']

                def move_and_check(out, scale):
                    # Camera world coordinates are exposed separately from layout coordinates.
                    ipc.action('move_window_to', {'id': wid, 'x': out['x'] + 80, 'y': out['y'] + 80})
                    if renderer == 'pixman':
                        wait_for(lambda: ipc.dump_buffer('titlebar', window_id=wid)['scale'] == scale,
                                 f'chrome did not switch to {scale}')
                    expected_draw = f'draw {round(scale * 120)} {round(400 * scale)} {round(260 * scale)}'
                    wait_for(lambda: (tmp / 'client.log').read_text().strip().splitlines()[-1:] == [expected_draw],
                             f'client did not receive {scale} scale')
                    wait_for(lambda: (ipc.get_window_debug(wid)['buffer_width'],
                                      ipc.get_window_debug(wid)['buffer_height']) ==
                             (round(400 * scale), round(260 * scale)), 'client buffer size mismatch')
                    if renderer != 'pixman':
                        capture_output(out)

                # Reset camera ensures MoveWindowTo uses the layout's coordinate system.
                ipc.action('set_camera', {'x': 0, 'y': 0})
                move_and_check(outputs[0], 1)
                move_and_check(outputs[1], 1.5)
                move_and_check(outputs[0], 1)
                move_and_check(outputs[1], 1.5)
                (tmp / 'rediwm-config.toml').write_text(config(1.25))
                ipc.reload_config()
                wait_for(lambda: next(o for o in ipc.get_outputs() if o['name'] == outputs[1]['name'])['scale'] == 1.25,
                         'live scale reload failed')
                move_and_check(outputs[1], 1.25)
                if renderer == 'pixman':
                    bar = ipc.dump_buffer('taskbar', output=outputs[1]['name'])
                    assert bar['scale'] == 1.25 and bar['width'] == 1600, bar.keys()
                # Output-local panels also use fractional buffer density.
                ipc.move_cursor(outputs[1]['x'] + 50, outputs[1]['y'] + 50)
                for panel, open_panel in [('start_menu', ipc.open_start_menu),
                                          ('control_center', ipc.open_control_center),
                                          ('power_menu', ipc.open_power_menu)]:
                    open_panel()
                    if renderer == 'pixman':
                        raster = ipc.dump_buffer(panel, output=outputs[1]['name'])
                        assert raster['scale'] == 1.25 and raster['width'] > 0
                    else:
                        capture_output(outputs[1])
                    ipc.close_panel(panel)

                # Reload a changed scale while blanked, then wake without
                # discarding either display's logical dimensions or density.
                ipc.action('set_idle_config', {'enabled': True, 'blank_after_seconds': 1})
                ipc.action('advance_idle_time', {'seconds': 2})
                wait_for(lambda: all(not o['enabled'] for o in ipc.get_outputs()), 'outputs did not blank')
                (tmp / 'rediwm-config.toml').write_text(config(1.5))
                ipc.reload_config()
                ipc.move_cursor(outputs[1]['x'] + 60, outputs[1]['y'] + 60)
                wait_for(lambda: all(o['enabled'] for o in ipc.get_outputs()), 'outputs did not wake')
                move_and_check(outputs[1], 1.5)
                (tmp / 'rediwm-config.toml').write_text(config(1.25))
                ipc.reload_config()
                move_and_check(outputs[1], 1.25)
                # Invalid configuration keeps the last working output state.
                (tmp / 'rediwm-config.toml').write_text(config('nan'))
                ipc.reload_config()
                assert next(o for o in ipc.get_outputs() if o['name'] == outputs[1]['name'])['scale'] == 1.25
                # Removing the override restores safe headless auto scaling.
                (tmp / 'rediwm-config.toml').write_text(config('"auto"'))
                ipc.reload_config()
                move_and_check(outputs[1], 1)
                # Explicit positions can now change live, and removing them
                # restores automatic placement without restarting outputs.
                (tmp / 'rediwm-config.toml').write_text(config(1) + 'x = -1280\ny = -100\n')
                ipc.reload_config()
                moved = next(o for o in ipc.get_outputs() if o['name'] == outputs[1]['name'])
                assert (moved['x'], moved['y']) == (-1280, -100), moved
                (tmp / 'rediwm-config.toml').write_text(config(1))
                ipc.reload_config()
                left, right = sorted(ipc.get_outputs(), key=lambda out: out['x'])
                assert right['x'] == left['x'] + left['logical_width']
        except Exception:
            print((tmp / 'compositor.log').read_text()[-10000:])
            if client_log:
                print((tmp / 'client.log').read_text())
            raise
        finally:
            if client:
                stop_process(client)
            if client_log:
                client_log.close()
            stop_process(compositor)
            log.close()
    print(f'output-scale: mixed density, client notifications, buffers and reload passed ({override}, {renderer})')


if __name__ == '__main__':
    with tempfile.TemporaryDirectory(prefix='rediwm-output-scale-build-') as directory:
        tmp = Path(directory)
        build_client(tmp)
        run_case(tmp / 'scale-client')
        run_case(tmp / 'scale-client', '2')

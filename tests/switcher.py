#!/usr/bin/env python3
"""Linear/circular Alt/Ctrl+Tab MRU switching and pixels on an isolated compositor."""
import os
from pathlib import Path
import subprocess
import tempfile
import time
from PIL import Image
from desktop_zoom import build_client, wait_for
from ipc_client import IPCClient, spawn_compositor, stop_process


def run(scale, modifier=56, style='linear'):
    with tempfile.TemporaryDirectory(prefix='rediwm-switcher-') as directory:
        tmp = Path(directory)
        build_client(tmp)
        wallpaper = tmp / 'wallpaper.png'
        Image.new('RGB', (32, 32), (20, 24, 30)).save(wallpaper)
        def config(layout):
            return f'[compositor]\nwallpaper = "{wallpaper}"\nswitcher_style = "{layout}"\nswitcher_opacity = {os.environ.get("REDIWM_TEST_SWITCHER_OPACITY", "1.0")}\n[input]\nkey_repeat_delay = 200\nkey_repeat_rate = 5\n[keybinds]\n"alt+tab" = "focus_next"\n"alt+shift+tab" = "focus_prev"\n'
        proc, log = spawn_compositor(tmp, scale=scale, renderer=os.environ.get('REDIWM_TEST_RENDERER', 'gles2'), config_content=config(style))
        clients = []
        try:
            with IPCClient(tmp) as ipc:
                ipc.wait_for('wallpaper_presented', timeout_ms=10000)
                display = next(p.name for p in tmp.glob('wayland-*') if not p.name.endswith('.lock'))
                for i in range(7):
                    # One shared app: for circular this keeps every window in a
                    # single group, so Tab/Shift+Tab exhausting that group's
                    # members reduces to the same flat MRU sequence linear uses.
                    # Grouping's own stacking/expand/cross-group behavior is
                    # covered separately by run_group_cycle.
                    app_id = 'org.gnome.Nautilus'
                    with (tmp / f'client-{i}.log').open('w') as out:
                        clients.append(subprocess.Popen([str(tmp / 'client'), '--title', f'Window {i}', '--app-id', app_id], env=dict(os.environ, XDG_RUNTIME_DIR=str(tmp), WAYLAND_DISPLAY=display), stdout=out, stderr=out))
                    wait_for(lambda: len(ipc.get_windows()) == i + 1, 'map fixture')
                by_title = {w['title']: w['id'] for w in ipc.get_windows()}
                ids = [by_title[f'Window {i}'] for i in range(7)]
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
                    path.unlink(missing_ok=True)
                    ipc.screenshot(path=str(path))
                    wait_for(path.exists, 'capture')
                    image = Image.open(path).convert('RGB')
                    dest = os.environ.get('REDIWM_SWITCHER_PREVIEW')
                    if dest:
                        Path(dest).mkdir(parents=True, exist_ok=True)
                        image.save(Path(dest) / f'{style}-{name}-{scale}.png')
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
                # Switching within the same app leaves the selection frame in
                # place, while showing the selected window's title/preview.
                def red_pixels(im):
                    return {(x, y) for y in range(im.height) for x in range(im.width)
                            if (lambda c: c[0] > 220 and 15 < c[1] < 65 and 35 < c[2] < 95)(im.getpixel((x, y)))}
                red = red_pixels(first)
                assert len(red) > 200, 'selection outline is visible'
                assert red == red_pixels(second), 'center highlight moved'
                assert first.tobytes() != second.tobytes(), 'selected window did not change'
                # Text beneath every fully visible preview must survive GPU
                # compositing as well as movement, not just the red outline.
                left = min(x for x, y in red)
                right = max(x for x, y in red)
                bottom = max(y for x, y in red)
                density = float(scale)
                for offset in range(-2, 3) if style == 'linear' else ():
                    x0 = int(left + (12 + offset * 244) * density)
                    x1 = int(right + (-12 + offset * 244) * density)
                    if x0 < 32 * density or x1 > second.width - 32 * density: continue
                    label = second.crop((x0, int(bottom + 16 * density), x1, int(bottom + 62 * density)))
                    assert sum(all(c > 140 for c in label.getpixel((x, y))) for y in range(label.height) for x in range(label.width)) > 30, 'missing carousel label'

                ipc.key(modifier, False)
                wait_for(lambda: focused() == ids[-3], 'release Alt activates selection')
                if style == 'circular':
                    # Reload must actually select another renderer and allow
                    # switching back without restarting the compositor.
                    def reload_capture(layout):
                        (tmp / 'rediwm-config.toml').write_text(config(layout))
                        ipc.reload_config()
                        ipc.key(modifier, True)
                        tab()
                        shot = capture(f'reload-{layout}')
                        ipc.key_down_up(1)
                        ipc.key(modifier, False)
                        assert focused() == ids[-3], 'reload preview changed focus'
                        return red_pixels(shot)
                    circular_outline = reload_capture('circular')
                    ipc.key(modifier, True)
                    tab()
                    (tmp / 'rediwm-config.toml').write_text(config('linear'))
                    ipc.reload_config()
                    ipc.wait_for_frame()
                    ipc.key(modifier, False)
                    assert focused() == ids[-3], 'changing style accepted a stale selection'
                    linear_outline = reload_capture('linear')
                    assert len(linear_outline) > 200
                    assert circular_outline != linear_outline, 'switcher_style reload did not change layout'
                    assert reload_capture('circular') == circular_outline, 'circular layout did not survive reload'
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
                # Closing or minimizing the focused window hands the keyboard
                # to the previously focused one, without workspaces too.
                def keyboard_window():
                    return next((w['id'] for w in ipc.get_windows() if w['is_focused']), None)
                by_title = {w['title']: w['id'] for w in ipc.get_windows()}
                live = [by_title[f'Window {i}'] for i in range(len(clients))]
                for wid in live: ipc.action('focus_window', {'id': wid})
                stop_process(clients.pop())
                wait_for(lambda: len(ipc.get_windows()) == len(live) - 1, 'focused client teardown')
                wait_for(lambda: keyboard_window() == live[-2], 'closing the focused window refocuses the previous one')
                ipc.minimize(live[-2])
                wait_for(lambda: keyboard_window() == live[-3], 'minimizing the focused window refocuses the previous one')
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
                print(f'PASS switcher style={style} scale={scale} modifier={modifier}')
        except Exception:
            print((tmp / "compositor.log").read_text()[-6000:])
            raise
        finally:
            for client in clients: stop_process(client)
            stop_process(proc)
            log.close()


def run_group_cycle(scale):
    """A multi-window app's circular sector stacks its windows; Tab exhausts
    that app's own windows (most recent first) before moving to the next
    app, Shift+Tab mirrors it, and the stack fans open while selected."""
    with tempfile.TemporaryDirectory(prefix='rediwm-switcher-group-') as directory:
        tmp = Path(directory)
        build_client(tmp)
        wallpaper = tmp / 'wallpaper.png'
        Image.new('RGB', (32, 32), (20, 24, 30)).save(wallpaper)
        proc, log = spawn_compositor(tmp, scale=scale, renderer=os.environ.get('REDIWM_TEST_RENDERER', 'gles2'), config_content=f'[compositor]\nwallpaper = "{wallpaper}"\nswitcher_style = "circular"\n')
        clients = []
        try:
            with IPCClient(tmp) as ipc:
                ipc.wait_for('wallpaper_presented', timeout_ms=10000)
                display = next(p.name for p in tmp.glob('wayland-*') if not p.name.endswith('.lock'))
                # alpha1..alpha4 share one app; Beta and Gamma are each alone.
                specs = [('Alpha 1', 'org.rediwm.group.alpha'), ('Alpha 2', 'org.rediwm.group.alpha'),
                         ('Alpha 3', 'org.rediwm.group.alpha'), ('Alpha 4', 'org.rediwm.group.alpha'),
                         ('Beta', 'org.rediwm.group.beta'), ('Gamma', 'org.rediwm.group.gamma')]
                for i, (title, app_id) in enumerate(specs):
                    clients.append(subprocess.Popen([str(tmp / 'client'), '--title', title, '--app-id', app_id],
                        env=dict(os.environ, XDG_RUNTIME_DIR=str(tmp), WAYLAND_DISPLAY=display), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
                    wait_for(lambda: len(ipc.get_windows()) == i + 1, 'map group-cycle fixture')
                by_title = {w['title']: w['id'] for w in ipc.get_windows()}
                ids = [by_title[t] for t, _ in specs]  # alpha1, alpha2, alpha3, alpha4, beta, gamma

                def establish_mru():
                    # Focusing in this order leaves Gamma most recent, Beta
                    # next, then Alpha 4..1 (Alpha 4 the most recently used
                    # of the group): cards = [gamma, beta, a4, a3, a2, a1].
                    for wid in ids:
                        ipc.action('focus_window', {'id': wid})

                def focused():
                    return ipc.get_focused_window()['id']

                def gesture(steps, reverse=False):
                    establish_mru()
                    ipc.key(56, True)
                    if reverse: ipc.key(42, True)
                    for _ in range(steps): ipc.key_down_up(15)
                    if reverse: ipc.key(42, False)
                    ipc.key(56, False)
                    return focused()

                # Forward: leave Gamma's and Beta's singleton groups, then walk
                # the Alpha group newest-to-oldest before completing the lap.
                assert gesture(1) == ids[4], 'first Tab leaves the starting (singleton) group'
                assert gesture(2) == ids[3], 'second Tab enters the app group at its most recent window'
                assert gesture(3) == ids[2], 'third Tab stays inside the app'
                assert gesture(4) == ids[1], 'fourth Tab is still inside the app'
                assert gesture(5) == ids[0], "fifth Tab reaches the app's last window before leaving it"
                assert gesture(6) == ids[5], 'sixth Tab leaves the exhausted group and completes the lap'
                # Reverse is the exact mirror.
                assert gesture(1, reverse=True) == ids[0], 'Shift+Tab enters the previous group at its last window'
                assert gesture(4, reverse=True) == ids[3], 'reverse cycling mirrors forward order inside the group'

                # The stack fans open only while its group holds the
                # selection: a screenshot grabbed on the first frame after
                # entering it must still be mid-animation, and a later one
                # must have stopped changing.
                establish_mru()
                ipc.key(56, True)
                ipc.key_down_up(15)  # Beta
                ipc.key_down_up(15)  # Alpha 4: enters the stacked group
                path = tmp / 'expand.png'
                def shot(name):
                    path.unlink(missing_ok=True)
                    ipc.screenshot(path=str(path))
                    wait_for(path.exists, 'capture')
                    image = Image.open(path).convert('RGB')
                    if dest := os.environ.get('REDIWM_SWITCHER_PREVIEW'):
                        Path(dest).mkdir(parents=True, exist_ok=True)
                        image.save(Path(dest) / f'group-cycle-{name}-{scale}.png')
                    return image
                ipc.wait_for_frame()
                fast = shot('fast')
                time.sleep(0.4)
                settled = shot('settled')
                time.sleep(0.2)
                settled_again = shot('settled-again')
                ipc.key_down_up(1)  # Escape: close without accepting a selection
                ipc.key(56, False)
                assert fast.tobytes() != settled.tobytes(), 'stack did not animate open'
                assert settled.tobytes() == settled_again.tobytes(), 'stack kept animating after it should have settled'
                assert focused() == ids[5], 'Escape must preserve focus'
                assert proc.poll() is None
                print(f'PASS circular switcher group cycling scale={scale}')
        except Exception:
            print((tmp / 'compositor.log').read_text()[-6000:])
            raise
        finally:
            for client in clients: stop_process(client)
            stop_process(proc)
            log.close()


def run_pagination(scale):
    """More app groups than visible sectors must not truncate the MRU list."""
    with tempfile.TemporaryDirectory(prefix='rediwm-switcher-pages-') as directory:
        tmp = Path(directory)
        build_client(tmp)
        wallpaper = tmp / 'wallpaper.png'
        Image.new('RGB', (32, 32), (20, 24, 30)).save(wallpaper)
        proc, log = spawn_compositor(tmp, scale=scale, config_content=f'[compositor]\nwallpaper = "{wallpaper}"\nswitcher_style = "circular"\n')
        clients = []
        try:
            with IPCClient(tmp) as ipc:
                ipc.wait_for('wallpaper_presented', timeout_ms=10000)
                display = next(p.name for p in tmp.glob('wayland-*') if not p.name.endswith('.lock'))
                ids = []
                for i in range(10):
                    title = f'Group {i}'
                    clients.append(subprocess.Popen([str(tmp / 'client'), '--title', title, '--app-id', f'org.rediwm.switcher.group{i}'], env=dict(os.environ, XDG_RUNTIME_DIR=str(tmp), WAYLAND_DISPLAY=display), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
                    wait_for(lambda: len(ipc.get_windows()) == i + 1, 'map group')
                    windows = ipc.get_windows()
                    ids.append(next(w['id'] for w in windows if w['title'] == title))
                for steps in range(1, len(ids) + 1):
                    for wid in ids:
                        ipc.action('focus_window', {'id': wid})
                    ipc.key(29, True)
                    for _ in range(steps):
                        ipc.key_down_up(15)
                    assert ipc.get_focused_window()['id'] == ids[-1], 'paged preview changed focus'
                    if steps == 9:
                        time.sleep(.25)
                        path = tmp / 'last-page.png'
                        ipc.screenshot(path=str(path))
                        wait_for(path.exists, 'capture last page')
                        image = Image.open(path).convert('RGB')
                        assert sum(r > 220 and 15 < g < 65 and 35 < b < 95 for r, g, b in image.getdata()) > 200, 'selected group outside visible page'
                        if dest := os.environ.get('REDIWM_SWITCHER_PREVIEW'):
                            Path(dest).mkdir(parents=True, exist_ok=True)
                            image.save(Path(dest) / f'circular-last-page-{scale}.png')
                    ipc.key(29, False)
                    expected = ids[(len(ids) - 1 - steps) % len(ids)]
                    wait_for(lambda: ipc.get_focused_window()['id'] == expected, 'every paged group remains selectable')
                assert proc.poll() is None
                print(f'PASS circular switcher pagination scale={scale}')
        except Exception:
            print((tmp / 'compositor.log').read_text()[-6000:])
            raise
        finally:
            for client in clients: stop_process(client)
            stop_process(proc)
            log.close()


if __name__ == '__main__':
    for style in ('linear', 'circular'):
        for modifier in (56, 29):
            for scale in ('1', '1.5'): run(scale, modifier, style)
    for scale in ('1', '1.5'): run_pagination(scale)
    for scale in ('1', '1.5'): run_group_cycle(scale)

#!/usr/bin/env python3
"""Laptop controls and OSDs on owned headless outputs/private PipeWire devices.
Requires Pillow, pipewire, pipewire-pulse, pactl, pw-metadata. No host hardware.
"""
from pathlib import Path
import json
import os
import shutil
import subprocess
import tempfile
import time
from contextlib import contextmanager
from PIL import Image, ImageChops
from ipc_client import IPCClient, spawn_compositor, stop_process


def wait(check, message, timeout=5):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = check()
        if value:
            return value
        time.sleep(.025)
    raise AssertionError(message)


@contextmanager
def private_audio(tmp):
    runtime = tmp / 'audio'
    runtime.mkdir(mode=0o700)
    env = dict(os.environ, XDG_RUNTIME_DIR=str(runtime), PIPEWIRE_RUNTIME_DIR=str(runtime),
               PULSE_SERVER='unix:' + str(runtime / 'pulse/native'),
               DBUS_SESSION_BUS_ADDRESS='unix:path=' + str(runtime / 'no-bus'))
    config = runtime / 'pipewire.conf'
    config.write_text(Path('/usr/share/pipewire/pipewire.conf').read_text() +
                      '\ncontext.objects = [ { factory = metadata args = { metadata.name = default } } ]\n')
    procs = []
    with (runtime / 'log').open('w') as log:
        def pactl(*args):
            return subprocess.check_output(['pactl', *args], env=env, text=True).strip()
        try:
            for args in (['pipewire', '-c', str(config)], ['pipewire-pulse']):
                procs.append(subprocess.Popen(args, env=env, stdout=log, stderr=log))
            wait(lambda: subprocess.run(['pactl', 'info'], env=env, capture_output=True).returncode == 0, 'private audio startup')
            pactl('load-module', 'module-null-sink', 'sink_name=osd_test')
            pactl('load-module', 'module-remap-source', 'source_name=osd_mic', 'master=osd_test.monitor')
            for key, name in [('sink', 'osd_test'), ('source', 'osd_mic')]:
                subprocess.run(['pw-metadata', '0', 'default.audio.' + key, json.dumps({'name': name}), 'Spa:String:JSON'], env=env, check=True, capture_output=True)
            wait(lambda: 'Default Sink: osd_test' in pactl('info'), 'private default sink')
            pactl('set-sink-volume', 'osd_test', '50%')
            pactl('set-sink-mute', 'osd_test', '0')
            pactl('set-source-mute', 'osd_mic', '0')
            yield env, pactl
        finally:
            for p in reversed(procs):
                stop_process(p)


def run(scale):
    with tempfile.TemporaryDirectory(prefix='rediwm-hardware-test-') as directory:
        tmp = Path(directory)
        with private_audio(tmp) as (audio_env, pactl):
            bin_dir = tmp / 'bin'
            bin_dir.mkdir()
            helper = bin_dir / 'brightnessctl'
            helper.write_text('''#!/usr/bin/env python3
import os, sys, time
from pathlib import Path
root = Path(os.environ['OSD_TEST_DIR'])
with (root / 'brightness-calls').open('a') as f: f.write(sys.argv[-1] + '\\n')
mode = (root / 'helper-mode').read_text() if (root / 'helper-mode').exists() else ''
if mode == 'hang': time.sleep(10)
if mode == 'fail': sys.exit(1)
time.sleep(.06)
print('fixture,backlight,700,70%,1000')
''')
            helper.chmod(0o755)
            env = {key: audio_env[key] for key in ('PIPEWIRE_RUNTIME_DIR', 'PULSE_SERVER', 'DBUS_SESSION_BUS_ADDRESS')}
            env.update(PATH=str(bin_dir) + os.pathsep + os.environ['PATH'], OSD_TEST_DIR=str(tmp))
            config = '[keybinds]\n"F12" = "quit"\n"super+space" = "toggle_start_menu"\n'
            process, log = spawn_compositor(tmp, scale=scale, outputs='2' if scale == '1.5' else '1', config_content=config, env_extra=env)
            try:
                with IPCClient(tmp) as client:
                    client.wait_for('wallpaper_presented', timeout_ms=10000)
                    def audio():
                        return client.action('get_audio_state')
                    def capture(name, output=None):
                        client.wait_for_frame(timeout_ms=2000)
                        path = tmp / (name + '.png')
                        client.screenshot(path=str(path), output=output)
                        wait(path.exists, 'screenshot ' + name)
                        image = Image.open(path).convert('RGB')
                        if os.environ.get('REDIWM_OSD_PREVIEW'):
                            dest = Path(os.environ['REDIWM_OSD_PREVIEW'])
                            dest.mkdir(parents=True, exist_ok=True)
                            image.save(dest / (name + '-' + scale + '.png'))
                        return image
                    def lower(image):
                        w, h = image.size
                        return image.crop((w//2-int(190*float(scale)), h-int(195*float(scale)), w//2+int(190*float(scale)), h-int(70*float(scale))))
                    def red_count(image):
                        pixels = lower(image).tobytes()
                        return sum(r > 170 and r > g * 2 and r > b * 2 for r, g, b in zip(pixels[0::3], pixels[1::3], pixels[2::3]))
                    wait(lambda: abs(audio()['master_volume'] - .5) < .002, 'audio initialized')
                    baseline = capture('baseline')
                    client.key_press('XF86AudioRaiseVolume')
                    wait(lambda: abs(audio()['master_volume'] - .55) < .002, 'volume up')
                    volume = capture('volume')
                    assert red_count(volume) > 500 * float(scale)**2, 'volume level bar missing'
                    focus = client.get_input_state()
                    client.key_press('XF86AudioMute')
                    wait(lambda: audio()['master_muted'], 'speaker mute')
                    muted = capture('speaker-muted')
                    assert red_count(muted) < 50 * float(scale)**2, 'muted volume bar must be empty'
                    assert client.get_input_state() == focus, 'OSD changed input focus/state'
                    client.key_press('XF86AudioMute')
                    wait(lambda: not audio()['master_muted'], 'speaker unmute')
                    client.key_press('XF86AudioMicMute')
                    wait(lambda: pactl('get-source-mute', 'osd_mic') == 'Mute: yes', 'mic mute')
                    time.sleep(.08)
                    mic = capture('mic-muted')
                    assert 10 * float(scale)**2 < red_count(mic) < 120 * float(scale)**2, 'mic mute status dot missing'
                    client.key_press('XF86AudioMicMute')
                    wait(lambda: pactl('get-source-mute', 'osd_mic') == 'Mute: no', 'mic unmute')
                    client.key_down_up(58)
                    caps_on = capture('caps-on')
                    client.key_down_up(58)
                    caps_off = capture('caps-off')
                    assert ImageChops.difference(lower(caps_on), lower(caps_off)).getbbox(), 'caps on/off did not change'
                    assert red_count(caps_on) < 50, 'caps indicator should be white'
                    time.sleep(1.5)
                    hidden = capture('hidden')
                    assert ImageChops.difference(lower(baseline), lower(hidden)).getbbox() is None, 'OSD did not disappear'
                    client.key_press('XF86MonBrightnessUp')
                    wait(lambda: (tmp / 'brightness-calls').exists(), 'brightness helper started')
                    time.sleep(.15)
                    brightness = capture('brightness')
                    assert red_count(brightness) > red_count(volume), 'confirmed 70% brightness bar missing'
                    outputs = sorted(client.get_outputs(), key=lambda o: o['x'])
                    if len(outputs) > 1:
                        left, right = outputs
                        client.move_cursor(60, 60, output=right['name'])
                        client.key_press('XF86MonBrightnessUp')
                        time.sleep(.15)
                        assert red_count(capture('active-right', right['name'])) > 500
                        assert red_count(capture('inactive-left', left['name'])) < 50
                        client.move_cursor(60, 60, output=left['name'])
                    # Hold-to-repeat, cancellation on release, and volume cap.
                    client.key(115, True)
                    time.sleep(.85)
                    client.key(115, False)
                    wait(lambda: audio()['master_volume'] > .65, 'volume repeat')
                    time.sleep(.1)
                    released = audio()['master_volume']
                    time.sleep(.25)
                    assert audio()['master_volume'] == released, 'repeat continued after release'
                    pactl('set-sink-volume', 'osd_test', '10%')
                    wait(lambda: abs(audio()['master_volume'] - .1) < .002, 'reset volume')
                    for _ in range(10):
                        client.key_down_up(115)
                    wait(lambda: abs(audio()['master_volume'] - .6) < .002, 'rapid volume steps lost')
                    # Rapid mute presses must be discrete even when held.
                    client.key(113, True)
                    wait(lambda: audio()['master_muted'], 'held mute')
                    time.sleep(.7)
                    assert audio()['master_muted'], 'mute repeated while held'
                    client.key(113, False)
                    client.key(125, True)
                    client.key_down_up(57)
                    client.key(125, False)
                    client.wait_for('menu_opened', timeout_ms=5000)
                    client.key_press('XF86AudioMute')
                    wait(lambda: not audio()['master_muted'], 'media keys while menu is open')
                    client.key_press('Escape')
                    # A visible OSD follows external changes too.
                    client.key_press('XF86AudioRaiseVolume')
                    wait(lambda: abs(audio()['master_volume'] - .65) < .002, 'volume before external adjustment')
                    pactl('set-sink-volume', 'osd_test', '25%')
                    wait(lambda: abs(audio()['master_volume'] - .25) < .002, 'external adjustment')
                    assert red_count(capture('external-volume')) < red_count(volume) * .6
                    # Failed helpers never invent a level, and hung helpers do
                    # not block IPC or keep queueing indefinitely.
                    time.sleep(1.5)
                    (tmp / 'helper-mode').write_text('fail')
                    client.key_press('XF86MonBrightnessDown')
                    time.sleep(.2)
                    failed = capture('brightness-failed')
                    assert red_count(failed) < 50, 'failed brightness command showed a success OSD'
                    (tmp / 'helper-mode').write_text('hang')
                    client.key_press('XF86MonBrightnessUp')
                    start = time.monotonic()
                    client.get_version()
                    assert time.monotonic() - start < .5, 'brightness blocked IPC'
                    time.sleep(2.2)
                    (tmp / 'helper-mode').unlink()
                    client.key_press('XF86MonBrightnessUp')
                    time.sleep(.2)
                    assert red_count(capture('brightness-recovered')) > 500, 'helper did not recover after timeout'
                    (tmp / 'helper-mode').write_text('hang')
                    client.key_press('XF86MonBrightnessUp')
                    time.sleep(.1)
                    try:
                        client.key(88, True)  # F12: teardown with an OSD and child alive.
                    except EOFError:
                        pass  # Quit can close IPC before its reply is flushed.
                    assert process.wait(timeout=3) == 0
            finally:
                stop_process(process)
                log.close()
            contents = (tmp / 'compositor.log').read_text()
            assert 'panic:' not in contents, contents
    print('PASS: hardware keys, confirmed OSD pixels, repeats, menu routing, helper failures; scale=' + scale)


if __name__ == '__main__':
    for tool in ['pipewire', 'pipewire-pulse', 'pactl', 'pw-metadata']:
        assert shutil.which(tool), tool + ' is required'
    run('1')
    run('1.5')

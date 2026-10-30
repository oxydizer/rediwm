#!/usr/bin/env python3
"""Power-source policies and Settings against fake sysfs, backlights and D-Bus."""
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time

from ipc_client import IPCClient, spawn_compositor, stop_process
from ui_driver import UIDriver
from power_profiles import FAKE_PPD, wait_for
from power import FAKE_LOGIND

CONFIG = '''[compositor]
xwayland = false
lock_on_suspend = false
[keybinds]
"F9" = "brightness_up"
[power]
enabled = true
power_saver_percent = 15
charge_limit = 80
[power.plugged_in]
mode = "balanced"
brightness = 80
blank_after_seconds = 0
suspend_after_seconds = 0
[power.on_battery]
mode = "power_saver"
brightness = 45
keyboard_brightness = 0
blank_after_seconds = 0
suspend_after_seconds = 0
'''


def records(path):
    return [json.loads(line) for line in path.read_text().splitlines() if line.startswith('{')]


def start_daemon(code, path):
    stream = path.open('w')
    proc = subprocess.Popen([sys.executable, '-c', code], stdin=subprocess.PIPE, stdout=stream, text=True)
    wait_for(lambda: 'ready' in path.read_text(), 'private daemon ready')
    return proc, stream


def run(scale):
    with tempfile.TemporaryDirectory(prefix='rediwm-power-settings-') as directory:
        root = Path(directory)
        battery = root / 'power_supply' / 'BAT0'
        adapter = root / 'power_supply' / 'AC'
        battery.mkdir(parents=True)
        adapter.mkdir()
        (battery / 'scope').write_text('System\n')
        (battery / 'type').write_text('Battery\n')
        (battery / 'charge_control_end_threshold').write_text('100\n')
        (adapter / 'scope').write_text('System\n')
        event_path = root / 'power-events'

        def supply(plugged, percent=80, status=None, emit=True):
            status = status or ('Not charging' if plugged else 'Discharging')
            (battery / 'uevent').write_text(f'POWER_SUPPLY_TYPE=Battery\nPOWER_SUPPLY_CAPACITY={percent}\nPOWER_SUPPLY_STATUS={status}\n')
            (adapter / 'uevent').write_text(f'POWER_SUPPLY_TYPE=Mains\nPOWER_SUPPLY_ONLINE={int(plugged)}\n')
            if emit:
                with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as client:
                    client.sendto(b'change@/devices/power_supply/AC\0SUBSYSTEM=power_supply\0', str(event_path))

        supply(True, emit=False)
        hook = root / 'battery.so'
        subprocess.run(['cc', '-shared', '-fPIC', '-Wall', '-Wextra', '-Werror', str(Path(__file__).with_name('battery_hook.c')), '-ldl', '-o', str(hook)], check=True)
        helpers = root / 'bin'
        helpers.mkdir()
        brightness = helpers / 'brightnessctl'
        brightness.write_text('''#!/usr/bin/env python3
import os, sys, json
from pathlib import Path
root = Path(os.environ['POWER_FIXTURE'])
kind = 'leds' if '--class=leds' in sys.argv else 'backlight'
path = root / kind
value = int(path.read_text()) if path.exists() else 60
if sys.argv[-2] == 'set':
    arg = sys.argv[-1]
    if arg.endswith('%+'): value = min(100, value + int(arg[:-2]))
    elif arg.endswith('%-'): value = max(1, value - int(arg[:-2]))
    else: value = int(arg.rstrip('%'))
    path.write_text(str(value))
    with (root / 'brightness-calls').open('a') as log: log.write(json.dumps({'kind':kind,'value':value}) + '\\n')
print(f'fixture,{kind},{value},{value}%,100')
''')
        brightness.chmod(0o755)
        for tool in ('systemctl', 'loginctl'):
            path = helpers / tool
            path.write_text('#!/bin/sh\nexit 1\n')
            path.chmod(0o755)
        pp_log, login_log = root / 'profiles.log', root / 'logind.log'
        delay_file = root / 'profile-delay'
        delay_file.write_text('0')
        pp_code = FAKE_PPD.replace('import json, os, sys, warnings', 'import json, os, sys, warnings, time').replace(
            '    state["active"] = profile\n',
            f'    time.sleep(float(open({str(delay_file)!r}).read()))\n    state["active"] = profile\n')
        pp, pp_stream = start_daemon(pp_code, pp_log)
        logind, logind_stream = start_daemon(FAKE_LOGIND, login_log)
        proc, stream = spawn_compositor(root, scale=scale, renderer=os.environ.get('REDIWM_TEST_RENDERER', 'gles2'), config_content=CONFIG, env_extra={
            'LD_PRELOAD': str(hook), 'REDIWM_TEST_BATTERY_DIR': str(battery.parent),
            'REDIWM_TEST_BATTERY_SOCKET': str(event_path), 'POWER_FIXTURE': str(root),
            'PATH': str(helpers) + os.pathsep + os.environ['PATH'],
            'DBUS_SYSTEM_BUS_ADDRESS': os.environ['DBUS_SESSION_BUS_ADDRESS'],
        })
        try:
            with IPCClient(root, timeout=15) as ipc:
                exercise(ipc, root, supply, pp, logind, pp_log, login_log, event_path, battery, scale)
        finally:
            stop_process(proc)
            stream.close()
            for daemon, file in ((pp, pp_stream), (logind, logind_stream)):
                stop_process(daemon)
                file.close()


def exercise(ipc, root, supply, pp, logind, pp_log, login_log, event_path, battery, scale):
    ipc.wait_for('wallpaper_presented', timeout_ms=10000)
    wait_for(lambda: (root / 'backlight').exists() and (root / 'backlight').read_text() == '80', 'startup brightness')
    wait_for(event_path.exists, 'power event transport')
    assert (battery / 'charge_control_end_threshold').read_text().strip() == '80'

    def level(value):
        wait_for(lambda: (root / 'backlight').read_text() == str(value), f'brightness {value}')

    def sets():
        return [r['set'] for r in records(pp_log) if 'set' in r]

    rapid_reversal(root, supply, pp_log)

    supply(False)
    level(45)
    wait_for(lambda: sets() and sets()[-1] == 'power-saver', 'battery power mode')
    wait_for(lambda: (root / 'leds').exists() and (root / 'leds').read_text() == '0', 'keyboard backlight off')
    # Manual changes survive repeated battery events and unrelated reloads.
    ipc.key_down_up(67)
    level(50)
    supply(False, 79)
    (root / 'rediwm-config.toml').write_text(CONFIG + '\n# unrelated edit\n')
    time.sleep(.3)
    level(50)
    # Resume on the same source must preserve the manual brightness.
    logind.stdin.write(json.dumps({'action':'signal','name':'PrepareForSleep','value':False}) + '\n')
    logind.stdin.flush()
    time.sleep(.2)
    level(50)
    supply(True, 100, 'Full')
    level(80)
    wait_for(lambda: sets()[-1] == 'balanced', 'plugged mode')
    count = len(sets())
    supply(True, 100, 'Not charging')
    time.sleep(.2)
    assert len(sets()) == count, 'charge-state update reapplied mode'
    # A read failure is not an unplug or a missing system battery.
    (root / 'power_supply' / 'AC' / 'uevent').unlink()
    with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as client:
        client.sendto(b'change@/devices/power_supply/AC\0SUBSYSTEM=power_supply\0', str(event_path))
    time.sleep(.2)
    level(80)
    supply(True)
    # Low battery restores the mode only while it still owns the change.
    cfg = CONFIG.replace('mode = "power_saver"', 'mode = "balanced"')
    (root / 'rediwm-config.toml').write_text(cfg)
    supply(False, 10)
    level(45)
    wait_for(lambda: sets()[-1] == 'power-saver', 'low battery mode')
    supply(False, 30)
    wait_for(lambda: sets()[-1] == 'balanced', 'restore automatically selected saver')
    supply(False, 10)
    wait_for(lambda: sets()[-1] == 'power-saver', 'second low-battery episode')
    pp.stdin.write(json.dumps({'action':'external','profile':'performance'}) + '\n')
    pp.stdin.flush()
    time.sleep(.2)
    before = len(sets())
    supply(False, 30)
    time.sleep(.2)
    assert len(sets()) == before, 'recovery overwrote manual performance mode'
    # Settings edits persist, and editing an inactive source has no side effects.
    ipc.open_control_center()
    ui = UIDriver(ipc)
    ui.wait_settled('control_center')
    ui.click(ui.find('power', panel='control_center'))
    ui.wait_settled('control_center')
    assert ui.find('power_brightness')['selected_index'] == 45
    ui.click(ui.find('power_source'), fraction=.2)
    ui.wait_settled('control_center')
    assert ui.find('power_brightness')['selected_index'] == 80
    ui.click(ui.find('power_brightness'))
    ipc.key_down_up(102)
    ipc.key_down_up(108)
    ipc.key_down_up(28)
    wait_for(lambda: 'brightness = 1' in (root / 'rediwm-config.toml').read_text(), 'saved inactive brightness')
    level(45)
    out = Path(os.environ.get('REDIWM_POWER_PREVIEW', '/tmp/rediwm-power-preview'))
    out.mkdir(exist_ok=True)
    screenshot = out / f'power-{scale}.png'
    screenshot.unlink(missing_ok=True)
    ipc.screenshot(str(screenshot))
    # Dimming restores the pre-idle level on activity.
    ipc.key_down_up(1)
    dim_cfg = cfg.replace('brightness = 45', 'brightness = 75\ndim_after_seconds = 1\ndim_brightness = 20')
    (root / 'rediwm-config.toml').write_text(dim_cfg)
    level(75)
    ipc.key_down_up(1)
    level(20)
    ipc.key_down_up(1)
    level(75)
    # A critical action happens once per discharge episode.
    critical_cfg = cfg.replace('power_saver_percent = 15', 'power_saver_percent = 15\ncritical_percent = 5\ncritical_action = "sleep"')
    (root / 'rediwm-config.toml').write_text(critical_cfg)
    time.sleep(.2)
    supply(False, 4)
    wait_for(lambda: any(r.get('method') == 'SuspendWithFlags' for r in records(login_log)), 'critical battery sleep')
    before_sleep = len([r for r in records(login_log) if r.get('method') == 'SuspendWithFlags'])
    supply(False, 3)
    time.sleep(.2)
    assert len([r for r in records(login_log) if r.get('method') == 'SuspendWithFlags']) == before_sleep
    supply(False, 30)
    # Independent sleep deadline works with blanking disabled.
    cfg = cfg.replace('suspend_after_seconds = 0', 'suspend_after_seconds = 2') + '\n[idle]\nenabled = true\n'
    (root / 'rediwm-config.toml').write_text(cfg)
    wait_for(lambda: len([r for r in records(login_log) if r.get('method') == 'SuspendWithFlags']) > before_sleep, 'automatic sleep', timeout=8)
    actions = [r for r in records(login_log) if r.get('method') == 'SuspendWithFlags']
    assert len(actions) == before_sleep + 1, actions
    time.sleep(.3)
    assert len([r for r in records(login_log) if r.get('method') == 'SuspendWithFlags']) == before_sleep + 1
    recover_without_service(ipc, root, supply, pp, pp_log)
    print(f'PASS power settings scale={scale}: plug/unplug, charge status, overrides, low battery, keyboard, persistence, automatic sleep')


def rapid_reversal(root, supply, pp_log):
    delay_file = root / 'profile-delay'
    delay_file.write_text('0.4')
    supply(False)
    wait_for(lambda: any(r.get('set') == 'power-saver' for r in records(pp_log)), 'delayed saver request')
    # The daemon still reports Balanced while the first Set is in flight.
    supply(True)
    wait_for(lambda: [r['set'] for r in records(pp_log) if 'set' in r][-1] == 'balanced', 'reversed source request')
    active = subprocess.check_output(['busctl', '--address=' + os.environ['DBUS_SESSION_BUS_ADDRESS'],
        'get-property', 'org.freedesktop.UPower.PowerProfiles', '/org/freedesktop/UPower/PowerProfiles',
        'org.freedesktop.UPower.PowerProfiles', 'ActiveProfile'], text=True)
    assert '"balanced"' in active, active
    delay_file.write_text('0')


def recover_without_service(ipc, root, supply, pp, pp_log):
    ui = UIDriver(ipc)
    cfg = CONFIG.replace('mode = "balanced"', 'mode = "unchanged"').replace('mode = "power_saver"', 'mode = "unchanged"')
    (root / 'rediwm-config.toml').write_text(cfg)
    stop_process(pp)
    wait_for(lambda: not any(str(w.get('label') or '').startswith('Current power mode:') for w in ui.widgets()), 'power service disappeared')
    supply(False, 4)
    wait_for(lambda: any(str(w.get('label') or '').startswith('4%') for w in ui.widgets()), 'offline low battery processed')
    supply(False, 40)
    wait_for(lambda: any(str(w.get('label') or '').startswith('40%') for w in ui.widgets()), 'offline recovery processed')
    replacement, stream = start_daemon(FAKE_PPD, pp_log)
    try:
        wait_for(lambda: any(str(w.get('label') or '') == 'Current power mode: Balanced' for w in ui.widgets()), 'power service returned')
        assert not [r for r in records(pp_log) if 'set' in r], 'recovery left a stale Power Saver request'
    finally:
        stop_process(replacement)
        stream.close()


if __name__ == '__main__':
    if not os.environ.get('REDIWM_POWER_SETTINGS_PRIVATE_BUS'):
        os.execvpe('dbus-run-session', ['dbus-run-session', '--', sys.executable, __file__, *sys.argv[1:]], {**os.environ, 'REDIWM_POWER_SETTINGS_PRIVATE_BUS':'1'})
    run(os.environ.get('REDIWM_TEST_SCALE', '1'))

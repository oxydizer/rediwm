#!/usr/bin/env python3
"""Settings → Network against the fake NetworkManager (tests/nm_fake.py); never touches host networking."""
import json
import os
from pathlib import Path
import select
import queue
import subprocess
import sys
import tempfile
import threading
import time

from ipc_client import IPCClient, spawn_compositor, stop_process
from power_profiles import wait_for, read_line
from ui_driver import UIDriver

HERE = Path(__file__).resolve().parent


def start_fake():
    process = subprocess.Popen([sys.executable, str(HERE / 'nm_fake.py')], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
    assert select.select([process.stdout], [], [], 5)[0]
    assert process.stdout.readline().strip() == 'ready'
    return process


class Page:
    """The compositor, its Settings window and the fake NetworkManager."""

    def __init__(self, ipc, fake):
        self.ipc, self.fake, self.ui, self.events = ipc, fake, UIDriver(ipc), []
        # Lines can arrive together; a thread keeps them from hiding in a buffer.
        self.lines = queue.Queue()
        threading.Thread(target=self.pump, daemon=True).start()

    def pump(self):
        for line in self.fake.stdout:
            self.lines.put(json.loads(line))

    def labels(self):
        return [w['label'] for w in self.ui.widgets() if w.get('label')]

    def find(self, name):
        return self.ui.find(name, panel='control_center')

    def has(self, name):
        return any(w.get('name') == name for w in self.ui.widgets())

    def command(self, **values):
        self.fake.stdin.write(json.dumps(values) + '\n')
        self.fake.stdin.flush()
        while True:
            line = self.lines.get(timeout=5)
            if line == {'done': True}:
                return
            self.events.append(line)

    def drain(self, wait=0.0):
        try:
            while True:
                self.events.append(self.lines.get(timeout=wait) if wait else self.lines.get_nowait())
        except queue.Empty:
            pass

    def event(self, key, timeout=5):
        """The next fake event that has `key`."""
        deadline = time.monotonic() + timeout
        while True:
            self.drain()
            for i, line in enumerate(self.events):
                if key in line:
                    return self.events.pop(i)
            assert time.monotonic() < deadline, f'no {key} event; saw {self.events}'
            time.sleep(.05)

    def no_event(self, key):
        self.drain(.5)
        assert not any(key in line for line in self.events), self.events

    def click(self, name):
        wait_for(lambda: self.has(name) and not self.find(name)['is_disabled'], name + ' enabled')
        if not name.startswith('wifi_'):
            self.ui.click(self.ui.scroll_into_view(name, panel='control_center'), panel='control_center')
            self.ui.wait_settled('control_center')
            return
        for _ in range(14):
            widget = self.find(name)
            if widget['visible'] and not widget['clipped']:
                self.ui.click(widget, panel='control_center')
                self.ui.wait_settled('control_center')
                return
            # The Wi-Fi list scrolls inside the page, which scrolls too.
            outer = next(w for w in self.ui.widgets() if w['role'] == 'scroll_container')
            inner = self.find('wifi_networks') if name.startswith('wifi_') and self.has('wifi_networks') else None
            viewport = inner if inner and inner['visible'] and not inner['clipped'] else outer
            box = viewport['global_box']
            self.ipc.move_cursor(box['x'] + box['width'] - 8, box['y'] + box['height'] // 2)
            self.ipc.scroll(0, -120 if widget['box']['y'] > viewport['box']['y'] else 120)
            self.ui.wait_settled('control_center')
        raise AssertionError('could not reveal ' + name)

    def key(self, code):
        for pressed in (True, False):
            self.ipc.action('key', {'keycode': code, 'pressed': pressed})
        time.sleep(.12)

    def choose(self, name, steps):
        """Open a dropdown and move `steps` entries down (negative: up) with the keyboard."""
        self.click(name)
        for _ in range(abs(steps)):
            self.key(108 if steps > 0 else 103)
        self.key(28)
        self.ui.wait_settled('control_center')

    def clear(self, name):
        self.click(name)
        self.key(107)  # End
        for _ in range(60):
            self.key(14)

    def type_into(self, name, text):
        self.click(name)
        self.ipc.type_text(text)
        self.ui.wait_settled('control_center')

    def open_network(self):
        self.ipc.open_control_center()
        self.ui.wait_settled('control_center')
        self.ui.click('network', panel='control_center')


def details(page):
    page.open_network()
    wait_for(lambda: '192.168.1.100/24' in page.labels(), 'Ethernet IPv4 address with its prefix')
    page.ui.wait_settled('control_center')
    shown = page.labels()
    for want in ('2001:db8::2a/64', 'fe80::1', '2001:db8::53', 'lan', '3C:EC:EF:12:34:56', '1.1.1.1, 1.0.0.1'):
        assert want in shown, (want, shown)
    wait_for(lambda: 'IPv4 Automatic · IPv6 Automatic' in page.labels(), 'Ethernet profile methods')
    print('Ethernet shows IPv4, IPv6, search domains and the profile methods', flush=True)

    page.ui.click(page.find('wifi_network_0'), panel='control_center')
    page.ui.wait_settled('control_center')
    wait_for(lambda: '10.0.0.23/24' in page.labels(), 'Wi-Fi IPv4 address')
    shown = page.labels()
    for want in ('WPA2/WPA3 Personal', '90%', '5 GHz · channel 36', '866 Mbps', '11:22:33:44:55:01', '10.0.0.1',
                 'fe80::a8bb:ccff:fedd:ee01/64', 'AA:BB:CC:DD:EE:01'):
        assert want in shown, (want, shown)
    assert not page.has('network_unlock'), 'policy allows changes: nothing to unlock'
    print('Wi-Fi details: security, signal, band, link speed, access point and addresses', flush=True)


def edits(page):
    # Auto-connect is one quick toggle; the rest of the profile must survive it.
    page.click('wifi_autoconnect')
    event = page.event('update')
    assert event['update'].endswith('/Settings/1') and event['settings']['connection']['autoconnect'] is False, event
    assert event['settings']['802-11-wireless-security']['key-mgmt'] == 'wpa-psk', 'secret settings were dropped'
    assert event['settings']['802-11-wireless']['ssid'] == list(b'REDI_Home')
    page.click('wifi_autoconnect')
    assert page.event('update')['settings']['connection']['autoconnect'] is True
    print('Auto-connect toggles in place and keeps the rest of the profile', flush=True)

    page.click('wifi_edit')
    wait_for(lambda: page.has('edit_v4_method'), 'editor opens with the profile')
    page.choose('edit_v4_method', 1)  # Manual
    wait_for(lambda: page.has('edit_v4_address'), 'manual IPv4 fields')
    # A bad prefix is refused before anything is sent.
    page.type_into('edit_v4_address', '10.0.0.77')
    page.type_into('edit_v4_prefix', '99')
    page.click('edit_save')
    wait_for(lambda: 'Enter an IPv4 prefix length from 1 to 32.' in page.labels(), 'prefix validation message')
    page.no_event('update')
    page.click('edit_v4_prefix')
    for _ in range(2):
        page.key(14)  # backspace
    page.type_into('edit_v4_prefix', '24')
    page.type_into('edit_v4_gateway', '10.0.0.1')
    page.choose('edit_dns_mode', 1)  # Custom
    page.type_into('edit_dns', '1.1.1.1, 2606:4700:4700::1111')
    page.type_into('edit_mtu', '1400')
    page.choose('edit_metered', 1)  # Yes
    page.click('edit_save')
    event = page.event('update')
    settings = event['settings']
    assert settings['ipv4']['method'] == 'manual', settings['ipv4']
    assert settings['ipv4']['address-data'] == [{'address': '10.0.0.77', 'prefix': 24}], settings['ipv4']
    assert settings['ipv4']['gateway'] == '10.0.0.1' and settings['ipv4']['ignore-auto-dns'] is True
    assert settings['ipv4']['dns'] == [int.from_bytes(bytes([1, 1, 1, 1]), sys.byteorder)], settings['ipv4']
    assert settings['ipv6']['dns'] == [list(bytes.fromhex('26064700470000000000000000001111'))], settings['ipv6']
    assert settings['ipv6']['method'] == 'auto' and settings['connection']['metered'] == 1, settings
    assert settings['802-11-wireless']['mtu'] == 1400 and settings['802-11-wireless']['ssid'] == list(b'REDI_Home')
    assert settings['802-11-wireless-security']['key-mgmt'] == 'wpa-psk'
    activated = page.event('activate')
    assert activated['activate'].endswith('/Settings/1') and activated['device'].endswith('/Devices/1'), activated
    wait_for(lambda: 'Saved.' in page.labels(), 'saved message')
    print('Editor saves manual IPv4, custom DNS, MTU and metered, then reapplies the connection', flush=True)
    shot = Path('/tmp/rediwm-network-editor.png')
    shot.unlink(missing_ok=True)
    page.ipc.screenshot(str(shot))

    page.click('edit_forget')
    assert page.find('edit_forget')['label'] == 'Confirm forget'
    page.no_event('delete')
    page.click('edit_forget')
    assert page.event('delete')['delete'].endswith('/Settings/1')
    wait_for(lambda: not page.has('edit_card'), 'editor closes after forgetting')
    print('Forget asks twice, then deletes the profile', flush=True)


def locked(page):
    page.open_network()
    wait_for(lambda: page.has('network_unlock'), 'Unlock prompt when polkit wants authentication')
    assert 'Unlock to change connection settings.' in page.labels()
    page.ui.click(page.find('wifi_network_0'), panel='control_center')
    page.ui.wait_settled('control_center')
    assert page.find('wifi_forget')['is_disabled'] and page.find('wifi_autoconnect')['is_disabled']
    page.click('network_unlock')
    while not page.event('interactive')['interactive']:
        pass  # the quiet check made when the page opened came first
    wait_for(lambda: not page.has('network_unlock'), 'Unlock goes away once authorised')
    wait_for(lambda: not page.find('wifi_forget')['is_disabled'], 'actions enable after unlocking')
    print('Unlock asks polkit with interaction and enables the actions', flush=True)


def vpn(page):
    page.open_network()
    wait_for(lambda: 'Work VPN' in page.labels() and 'wg0' in page.labels(), 'VPN and WireGuard profiles are listed')
    assert 'Studio_5G' not in [w['label'] for w in page.ui.widgets() if (w.get('name') or '').startswith('vpn_')], 'Wi-Fi profiles are not VPNs'
    states = [w['label'] for w in page.ui.widgets() if w.get('label') in ('Connected', 'Not connected')]
    assert page.find('vpn_toggle_0')['label'] == 'Disconnect' and page.find('vpn_toggle_1')['label'] == 'Connect', 'one VPN is up, one is not'
    page.click('vpn_toggle_1')  # connect wg0
    event = page.event('activate')
    assert event['activate'].endswith('/Settings/5') and event['device'] == '/', event
    wait_for(lambda: page.find('vpn_toggle_1')['label'] == 'Disconnect', 'wg0 shows connected')
    page.click('vpn_toggle_0')  # disconnect the OpenVPN one
    page.event('deactivate')
    wait_for(lambda: page.find('vpn_toggle_0')['label'] == 'Connect', 'Work VPN shows disconnected')
    print('VPN list, connect and disconnect', flush=True)
    page.click('vpn_remove_0')
    assert page.find('vpn_remove_0')['label'] == 'Confirm remove'
    page.no_event('delete')
    page.click('vpn_remove_0')
    assert page.event('delete')['delete'].endswith('/Settings/4')
    wait_for(lambda: 'Work VPN' not in page.labels(), 'removed VPN leaves the list')
    print('Remove asks twice, then deletes the VPN profile', flush=True)


def proxy(page, tmp):
    keyfile = tmp / 'config' / 'glib-2.0' / 'settings' / 'keyfile'

    def stored():
        import configparser
        parser = configparser.ConfigParser(interpolation=None)
        parser.optionxform = str
        parser.read(keyfile)
        return parser

    def spawn_env():
        received, probe = tmp / 'child-env.json', tmp / 'env.py'
        received.unlink(missing_ok=True)
        probe.write_text('import os, json, sys\nfrom pathlib import Path\n'
                         'Path(sys.argv[1]).write_text(json.dumps({k: v for k, v in os.environ.items() if "proxy" in k.lower()}))\n')
        page.ipc.action('spawn', {'argv': [sys.executable, str(probe), str(received)]})
        wait_for(received.exists, 'app environment')
        time.sleep(.1)
        return json.loads(received.read_text())

    page.open_network()
    wait_for(lambda: page.has('proxy_mode'), 'proxy card')
    page.choose('proxy_mode', 1)  # Manual
    wait_for(lambda: page.has('proxy_http_host'), 'manual proxy fields')
    page.type_into('proxy_http_host', 'proxy.test')
    page.clear('proxy_http_port')
    page.type_into('proxy_http_port', '99999')
    page.click('proxy_apply')
    wait_for(lambda: 'Check the HTTP proxy host and port (1–65535).' in page.labels(), 'port validation')
    assert not keyfile.exists() or stored().get('system/proxy', 'mode', fallback="'none'") == "'none'", 'nothing is stored for a bad value'
    page.clear('proxy_http_port')  # the schema fills in 8080
    page.type_into('proxy_http_port', '3128')
    page.type_into('proxy_socks_host', '127.0.0.1')
    page.type_into('proxy_socks_port', '1080')
    page.clear('proxy_ignore')
    page.type_into('proxy_ignore', 'localhost, 10.0.0.0/8')
    page.click('proxy_apply')
    wait_for(lambda: any('Applied.' in label for label in page.labels()), 'applied message: ' + repr([l for l in page.labels() if 'proxy' in l.lower() or 'Check' in l or 'Enter' in l or 'port' in l.lower()]))
    wait_for(lambda: keyfile.exists() and stored().get('system/proxy', 'mode', fallback='') == "'manual'", 'GSettings mode', timeout=10)
    config = stored()
    assert config.get('system/proxy/http', 'host') == "'proxy.test'" and config.get('system/proxy/http', 'port') == '3128', dict(config['system/proxy/http'])
    assert config.get('system/proxy/socks', 'host') == "'127.0.0.1'" and config.get('system/proxy/socks', 'port') == '1080'
    assert config.get('system/proxy', 'ignore-hosts') == "['localhost', '10.0.0.0/8']", config.get('system/proxy', 'ignore-hosts')
    env = spawn_env()
    assert env.get('http_proxy') == 'http://proxy.test:3128' and env.get('HTTP_PROXY') == env['http_proxy'], env
    assert env.get('all_proxy') == 'socks5h://127.0.0.1:1080' and env.get('no_proxy') == 'localhost,10.0.0.0/8', env
    assert 'https_proxy' not in env, env
    print('Manual proxy is stored in GSettings and exported to apps started afterwards', flush=True)

    page.choose('proxy_mode', 1)  # Automatic
    wait_for(lambda: page.has('proxy_pac'), 'PAC field')
    page.type_into('proxy_pac', 'wpad.local/wpad.dat')
    page.click('proxy_apply')
    wait_for(lambda: 'Enter an http://, https:// or file:// address.' in page.labels(), 'PAC validation')
    page.clear('proxy_pac')
    page.type_into('proxy_pac', 'http://wpad.test/wpad.dat')
    page.click('proxy_apply')
    wait_for(lambda: stored().get('system/proxy', 'mode', fallback='') == "'auto'", 'automatic mode stored', timeout=10)
    assert stored().get('system/proxy', 'autoconfig-url') == "'http://wpad.test/wpad.dat'"
    assert 'http_proxy' not in spawn_env(), 'a script cannot be exported as a variable'
    print('Automatic proxy stores its script address and exports nothing', flush=True)

    page.choose('proxy_mode', -2)  # Automatic -> Off
    page.click('proxy_apply')
    wait_for(lambda: stored().get('system/proxy', 'mode', fallback='') == "'none'", 'proxy off stored', timeout=10)
    assert not spawn_env()
    print('Off stores none and stops exporting', flush=True)


def run(scenario, scale=1):
    fake = start_fake()
    with tempfile.TemporaryDirectory(prefix='rediwm-network-') as directory:
        tmp = Path(directory)
        process, log = spawn_compositor(tmp, scale=scale, renderer=os.environ.get('REDIWM_TEST_RENDERER', 'gles2'), config_content='[compositor]\nxwayland = false\n', env_extra={
            'DBUS_SYSTEM_BUS_ADDRESS': os.environ['DBUS_SESSION_BUS_ADDRESS'], 'DBUS_SESSION_BUS_ADDRESS': '', 'XDG_CACHE_HOME': str(tmp),
            'PIPEWIRE_RUNTIME_DIR': str(tmp), 'PULSE_SERVER': 'unix:/nonexistent-rediwm-test-pulse',
            # GSettings writes go to a file in the scratch directory, never the user's dconf.
            'GSETTINGS_BACKEND': 'keyfile', 'XDG_CONFIG_HOME': str(tmp / 'config'),
        })
        try:
            with IPCClient(tmp, timeout=15) as ipc:
                page = Page(ipc, fake)
                if scenario == 'vpn':
                    vpn(page)
                elif scenario == 'proxy':
                    proxy(page, tmp)
                elif scenario == 'locked':
                    page.command(polkit='challenge')
                    locked(page)
                else:
                    details(page)
                    shot = Path('/tmp/rediwm-network-details.png')
                    shot.unlink(missing_ok=True)
                    ipc.screenshot(str(shot))
                    edits(page)
        except BaseException:
            log.flush()
            print(Path(log.name).read_text()[-6000:] if hasattr(log, 'name') else 'no log', file=sys.stderr)
            raise
        finally:
            stop_process(process)
            fake.kill()
            fake.wait()


if __name__ == '__main__':
    run('open')
    run('locked')
    run('vpn')
    if subprocess.run(['gsettings', 'list-schemas'], capture_output=True, text=True).stdout.count('org.gnome.system.proxy'):
        run('proxy')
    else:
        print('SKIP: proxy needs the org.gnome.system.proxy schemas')
    print('PASS Network settings: details, editing, forgetting and unlock')

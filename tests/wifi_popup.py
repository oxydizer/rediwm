#!/usr/bin/env python3
"""Wi-Fi menu against a private NetworkManager fixture; never changes host networking."""
import json
import os
from pathlib import Path
import select
import subprocess
import sys
import tempfile
import time

from PIL import Image

from ipc_client import IPCClient, spawn_compositor, stop_process
from power_profiles import wait_for, read_line
from ui_driver import UIDriver

FAKE = r"""
import json, sys, warnings
warnings.simplefilter('ignore', DeprecationWarning)
from gi.repository import Gio, GLib
NM = 'org.freedesktop.NetworkManager'
ROOT = '/org/freedesktop/NetworkManager'
OBJECTS_ROOT = '/org/freedesktop'
DEV = ROOT + '/Devices/1'
AP = ROOT + '/AccessPoint/'
SAVED = ROOT + '/Settings/1'
ETH = ROOT + '/Devices/2'
IP4 = ROOT + '/IP4Config/2'
conn = Gio.bus_get_sync(Gio.BusType.SESSION)
v = GLib.Variant
state = {'enabled': True, 'hardware': True, 'active': 1, 'fail': False, 'device': True, 'many': False, 'updated': False, 'last_scan': -1, 'hold_scan': True, 'ethernet': True, 'eth_state': 100, 'carrier': True, 'managed': True, 'eth_profile': True, 'eth_fail': False, 'hold_eth': False, 'connectivity': 4}
names = ['REDI_Home', 'Studio_5G', 'Cafe_WiFi', 'Linksys_7432', 'OfficeNet', 'MySpectrum']
def objects():
    count = state.get('count', 35 if state['many'] else 6)
    result = {ROOT: {NM: {'WirelessEnabled': v('b', state['enabled']), 'WirelessHardwareEnabled': v('b', state['hardware']), 'State': v('u', 70), 'Connectivity': v('u', state['connectivity'])}}, SAVED: {NM+'.Settings.Connection': {}}}
    if state['ethernet']:
        result[ETH] = {NM+'.Device': {'Interface': v('s','enp4s0'), 'Driver': v('s','r8169'), 'Managed': v('b',state['managed']), 'State': v('u',state['eth_state']), 'Ip4Config': v('o',IP4), 'AvailableConnections': v('ao',[ROOT+'/Settings/2'] if state['eth_profile'] else [])}, NM+'.Device.Wired': {'Carrier': v('b',state['carrier']), 'Speed': v('u',2500), 'HwAddress': v('s','3C:EC:EF:12:34:56')}}
        result[IP4] = {NM+'.IP4Config': {'AddressData': v('aa{sv}',[{'address':v('s','192.168.1.100'),'prefix':v('u',24)}]), 'Gateway': v('s','192.168.1.1'), 'NameserverData': v('aa{sv}',[{'address':v('s','1.1.1.1')},{'address':v('s','1.0.0.1')}])}}
    if not state['device']: return result
    result[DEV] = {NM+'.Device': {'State': v('u', 100 if state['active'] else 30)}, NM+'.Device.Wireless': {'LastScan': v('x', state['last_scan']), 'ActiveAccessPoint': v('o', AP+str(state['active']) if state['active'] else '/'), 'AccessPoints': v('ao', [AP+str(i+1) for i in range(count)])}}
    for i in range(count):
        result[AP+str(i+1)] = {NM+'.AccessPoint': {'Ssid': v('ay', list((names[i] if i < 6 else 'Network_'+str(i)).encode())), 'Strength': v('y', state.get('strength') if state.get('strength') is not None else max(10, 95-i*8)), 'Flags': v('u', 0 if i==2 else 1), 'WpaFlags': v('u', 0), 'RsnFlags': v('u', 0 if i==2 else 0x100)}}
    return result

def changed():
    conn.emit_signal(None, ROOT, 'org.freedesktop.DBus.Properties', 'PropertiesChanged', v('(sa{sv}as)', (NM, {'WirelessEnabled': v('b', state['enabled'])}, [])))
    conn.flush_sync()

def completed():
    state['last_scan'] += 1
    conn.emit_signal(None, DEV, 'org.freedesktop.DBus.Properties', 'PropertiesChanged', v('(sa{sv}as)', (NM+'.Device.Wireless', {'LastScan': v('x', state['last_scan'])}, [])))
    conn.flush_sync()
    return False

def method(c,sender,path,iface,name,params,inv):
    if name == 'Disconnect' or (name in ('ActivateConnection','AddAndActivateConnection') and params.unpack()[1] == ETH):
        on = name != 'Disconnect'
        if on:
            settings, device, specific = params.unpack()
            assert device == ETH and specific == '/'
            if name == 'ActivateConnection': assert settings == '/'
            else:
                assert settings == {'connection': {'id':'enp4s0','type':'802-3-ethernet','interface-name':'enp4s0'}, '802-3-ethernet': {}, 'ipv4': {'method':'auto'}, 'ipv6': {'method':'auto'}}
        print(json.dumps({'ethernet':on,'new':name=='AddAndActivateConnection'}),flush=True)
        if state['eth_fail']:
            inv.return_dbus_error(NM+'.PermissionDenied','Fixture rejected Ethernet request')
            return
        state['eth_state'] = (40 if state['hold_eth'] else 100) if on else 30
        inv.return_value(v('(oo)', (ROOT+'/Settings/2',ROOT+'/ActiveConnection/2')) if name=='AddAndActivateConnection' else v('(o)', (ROOT+'/ActiveConnection/2',)) if on else v('()',()))
        changed()
    elif name == 'GetManagedObjects': inv.return_value(v('(a{oa{sa{sv}}})', (objects(),)))
    elif name == 'GetSettings': inv.return_value(v('(a{sa{sv}})', ({'802-11-wireless': {'ssid': v('ay', list(b'Studio_5G'))}, '802-11-wireless-security': {'key-mgmt': v('s','wpa-psk'), 'psk-flags': v('u', 1)}, 'connection': {'id': v('s', 'Saved profile'), 'autoconnect': v('b', False)}, 'ipv4': {'method': v('s', 'manual'), 'addresses': v('aau', [[0x0a000005,24,0x0a000001]]), 'dns': v('au',[0x01010101])}},)))
    elif name == 'Update':
        settings=params.unpack()[0]
        assert settings['connection']=={'id':'Saved profile','autoconnect':False}
        assert settings['ipv4']=={'method':'manual','addresses':[[0x0a000005,24,0x0a000001]],'dns':[0x01010101]}
        assert settings['802-11-wireless-security']=={'key-mgmt':'wpa-psk','psk':'test-password','psk-flags':0}
        state['updated']=True
        inv.return_value(v('()',()))
    elif name == 'RequestScan':
        inv.return_value(v('()', ()))
        if not state['hold_scan']: GLib.timeout_add(1500, completed)
    elif name in ('AddAndActivateConnection', 'ActivateConnection'):
        args=params.unpack()
        if name == 'AddAndActivateConnection':
            settings,device,ap=args
            wifi=settings['802-11-wireless']
            # Only a test credential is allowed; never print its value.
            sec=settings.get('802-11-wireless-security', {})
            assert sec.get('psk', 'test-password') == 'test-password', sec
            print(json.dumps({'join': bytes(wifi['ssid']).decode(), 'hidden': wifi['hidden'], 'auto': settings['connection']['autoconnect'], 'security': sec.get('key-mgmt','open')}), flush=True)
        else:
            saved,device,ap=args
            assert saved == SAVED
            print(json.dumps({'activate': 'saved', **({'updated':True} if state['updated'] else {})}),flush=True)
        assert device == DEV
        if state['fail']:
            inv.return_dbus_error(NM+'.PermissionDenied', 'Fixture rejected connection')
            return
        state['active'] = int(ap.rsplit('/',1)[-1]) if ap != '/' else 0
        inv.return_value(v('(oo)', (SAVED, ROOT+'/ActiveConnection/1')) if name=='AddAndActivateConnection' else v('(o)', (ROOT+'/ActiveConnection/1',)))
        changed()

def get_prop(c,sender,path,iface,prop): return v('b', state['enabled'])
def set_prop(c,sender,path,iface,prop,value):
    state['enabled']=value.unpack()
    print(json.dumps({'enabled':state['enabled']}),flush=True)
    changed()
    return True

def register(path,xml):
    node=Gio.DBusNodeInfo.new_for_xml('<node>'+xml+'</node>')
    for iface in node.interfaces: conn.register_object(path,iface,method,get_prop,set_prop)
register(OBJECTS_ROOT, '<interface name="org.freedesktop.DBus.ObjectManager"><method name="GetManagedObjects"><arg direction="out" type="a{oa{sa{sv}}}"/></method></interface>')
register(ROOT, '''<interface name="org.freedesktop.NetworkManager"><property name="WirelessEnabled" type="b" access="readwrite"/>
<method name="AddAndActivateConnection"><arg direction="in" type="a{sa{sv}}"/><arg direction="in" type="o"/><arg direction="in" type="o"/><arg direction="out" type="o"/><arg direction="out" type="o"/></method>
<method name="ActivateConnection"><arg direction="in" type="o"/><arg direction="in" type="o"/><arg direction="in" type="o"/><arg direction="out" type="o"/></method></interface>''')
register(ETH, '<interface name="'+NM+'.Device"><method name="Disconnect"/></interface>')
register(DEV, '<interface name="'+NM+'.Device.Wireless"><method name="RequestScan"><arg direction="in" type="a{sv}"/></method></interface>')
register(SAVED, '<interface name="'+NM+'.Settings.Connection"><method name="GetSettings"><arg direction="out" type="a{sa{sv}}"/></method><method name="Update"><arg direction="in" type="a{sa{sv}}"/></method></interface>')
def command(channel,cond):
    req=json.loads(sys.stdin.readline())
    state.update(req)
    if req.get('complete_scan'): completed()
    if 'device' in req:
        # Device hotplug is announced from ObjectManager's parent path.
        if state['device']:
            conn.emit_signal(None, OBJECTS_ROOT, 'org.freedesktop.DBus.ObjectManager', 'InterfacesAdded', v('(oa{sa{sv}})', (DEV, objects()[DEV])))
        else:
            conn.emit_signal(None, OBJECTS_ROOT, 'org.freedesktop.DBus.ObjectManager', 'InterfacesRemoved', v('(oas)', (DEV, [NM+'.Device', NM+'.Device.Wireless'])))
        conn.flush_sync()
    else:
        changed()
    print(json.dumps({'done': True}),flush=True)
    return True
GLib.io_add_watch(sys.stdin.fileno(), GLib.IO_IN, command)
Gio.bus_own_name_on_connection(conn,NM,Gio.BusNameOwnerFlags.NONE,lambda *_: print('ready',flush=True),None)
GLib.MainLoop().run()
"""


def start_fake():
    process = subprocess.Popen([sys.executable, '-c', FAKE], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
    assert select.select([process.stdout], [], [], 5)[0]
    assert process.stdout.readline().strip() == 'ready'
    return process


def run(scale):
    fake = start_fake()
    with tempfile.TemporaryDirectory(prefix='rediwm-wifi-') as directory:
        tmp = Path(directory)
        process, log = spawn_compositor(tmp, scale=scale, renderer=os.environ.get('REDIWM_TEST_RENDERER', 'pixman'), config_content='[compositor]\nxwayland = false\n', env_extra={
            'DBUS_SYSTEM_BUS_ADDRESS': os.environ['DBUS_SESSION_BUS_ADDRESS'], 'DBUS_SESSION_BUS_ADDRESS': '', 'XDG_CACHE_HOME': str(tmp),
        })
        try:
            with IPCClient(tmp, timeout=15) as ipc:
                ipc.wait_for('wallpaper_presented', timeout_ms=10000)
                bar = ipc.get_shell_state()['taskbars'][0]
                boxes = {item['name']: item['box'] for item in bar['right_items']}
                def center(box): return box['x']+box['width']//2, box['y']+box['height']//2
                anchor = center(boxes['network'])
                factor = min(1, (bar['box']['width']-24)/420)
                point = (anchor[0], bar['box']['y']-40)
                def settle():
                    ipc.wait_for_frame()
                    time.sleep(.25) # panel animation, not network state polling
                def origin():
                    hit = ipc.hit_test(*point)
                    assert hit['target_type'] == 'wifi_popup', hit
                    return point[0]-hit['local_x'], point[1]-hit['local_y']
                def at(x,y):
                    ox,oy=origin()
                    return round(ox+x*factor),round(oy+y*factor)
                def click(x,y): ipc.click_at(*at(x,y)); settle()
                def locate(widget):
                    for y in range(75, int((bar['box']['y']-24)/factor)-64, 10):
                        point=at(120,y)
                        if ipc.hit_test(*point).get('widget')==widget: return point
                    raise AssertionError(f'{widget} is not visible')
                def open_menu(): ipc.click_at(*anchor); settle()
                def close(): ipc.key_down_up(1); settle()
                def command(**values):
                    fake.stdin.write(json.dumps(values)+'\n');fake.stdin.flush()
                    assert read_line(fake)=={'done':True}
                    settle()
                def screenshot(name):
                    target=Path('/tmp')/f'rediwm-wifi-{name}-{scale}-{os.environ.get("REDIWM_TEST_RENDERER", "pixman")}.png'
                    target.unlink(missing_ok=True)
                    ipc.screenshot(str(target))
                open_menu()
                wait_for(lambda: ipc.hit_test(*at(100,100)).get('widget')=='row','network rows')
                def sonar_image():
                    x,y=at(262,3)
                    raster=float(scale)
                    target=tmp/'sonar.png'
                    target.unlink(missing_ok=True)
                    ipc.screenshot(str(target))
                    with Image.open(target) as image:
                        return image.convert('RGB').crop((round(x*raster),round(y*raster),round((x+60*factor)*raster),round((y+60*factor)*raster)))
                def sonar_pixels(): return list(sonar_image().getdata())
                def has_sonar():
                    return any(red > green+35 for red,green,blue in sonar_pixels())
                assert has_sonar(), 'scan acceptance hid the sonar before completion'
                first=sonar_pixels()
                time.sleep(.2) # sample a different sweep phase
                assert sonar_pixels()!=first, 'sonar sweep did not animate'
                screenshot('searching')
                command(hold_scan=False, complete_scan=True)
                def sonar_settled():
                    first = sonar_pixels()
                    time.sleep(.15)
                    return sonar_pixels() == first
                wait_for(sonar_settled, 'scan completion stops sweep')
                assert has_sonar(), 'completed scan lost its signal map'
                assert ipc.hit_test(*at(100,100)).get('widget')=='row', 'search hid existing networks'
                screenshot('list')
                # A real signal update moves the same echo radially; the centre
                # beacon and faint rings are excluded from this pixel check.
                def echo_distance():
                    image = sonar_image()
                    distances = []
                    for y in range(image.height):
                        for x in range(image.width):
                            red, green, blue = image.getpixel((x,y))
                            distance = ((x+.5-image.width/2)**2+(y+.5-image.height/2)**2)**.5 / (float(scale)*factor)
                            if red > green+120 and distance > 5:
                                distances.append(distance)
                    assert distances, 'network echo missing'
                    return sum(distances)/len(distances)
                command(count=1, strength=10)
                weak = echo_distance()
                command(strength=95)
                assert echo_distance() < weak-8, 'stronger signal did not move towards centre'
                command(count=6, strength=None)
                strongest = sonar_pixels()
                command(count=35, active=35)
                assert sonar_pixels() == strongest, 'weaker networks changed the six strongest echoes'
                command(count=6, active=1)
                # Opening focuses the first network: Down/Enter opens the
                # second (saved, secured) network without toggling the radio.
                close();open_menu()
                ipc.key_down_up(108);ipc.key_down_up(28);settle()
                assert locate('password')
                assert not select.select([fake.stdout], [], [], .1)[0], 'opening toggled Wi-Fi'
                close();open_menu()
                # Unsaved secured row expands inline; invalid input never submits.
                click(100,70+3*64+25)
                assert locate('password')
                ipc.type_text('short'); ipc.key_down_up(28);settle()
                assert not select.select([fake.stdout], [], [], .1)[0], 'invalid password submitted'
                ipc.key(29, True);ipc.key_down_up(22);ipc.key(29, False) # Ctrl+U
                ipc.type_text('test-password');settle()
                screenshot('password')
                ipc.key_down_up(28)
                assert read_line(fake)=={'join':'Linksys_7432','hidden':False,'auto':True,'security':'wpa-psk'}
                settle()
                # Saved credentials activate the existing profile.
                close();open_menu();click(100,70+2*64+25);ipc.key_down_up(28)
                assert read_line(fake)=={'activate':'saved'}
                settle()
                # Editing saved credentials preserves custom IP/DNS settings.
                command(active=1)
                close();open_menu();click(100,70+64+25)
                ipc.type_text('test-password');ipc.key_down_up(28)
                assert read_line(fake)=={'activate':'saved','updated':True}
                settle()
                # An open network sends no security settings; auto-join is editable.
                close();open_menu();click(100,70+2*64+25)
                ipc.key(42,True);ipc.key_down_up(15);ipc.key(42,False)
                ipc.key_down_up(57) # disable auto-join
                ipc.key_down_up(15);ipc.key_down_up(28)
                assert read_line(fake)=={'join':'Cafe_WiFi','hidden':False,'auto':False,'security':'open'}
                settle()
                # Off/on is confirmed by the service, and closes the form.
                click(369,36)
                assert read_line(fake)=={'enabled':False}
                settle();screenshot('off')
                assert not has_sonar(), 'disabled radio still shows a signal map'
                # With no network list, opening still focuses the radio toggle.
                close();open_menu();ipc.key_down_up(28)
                assert read_line(fake)=={'enabled':True}
                settle()
                # Hidden form, keyboard entry, security, auto-join and error path.
                close();open_menu()
                ipc.key(42,True);ipc.key_down_up(15);ipc.key_down_up(15);ipc.key_down_up(15);ipc.key(42,False) # past toggle and settings to hidden action
                ipc.key_down_up(28);settle()
                ipc.type_text('Hidden test');ipc.key_down_up(15) # security
                ipc.key_down_up(15) # password
                ipc.type_text('test-password');settle()
                screenshot('hidden')
                command(fail=True)
                ipc.key_down_up(28)
                assert read_line(fake)=={'join':'Hidden test','hidden':True,'auto':True,'security':'wpa-psk'}
                settle();screenshot('error')
                # Dismissals, radio block, adapter removal, service loss/restart.
                close();open_menu();ipc.click_at(*center(boxes['clock']));settle()
                assert ipc.hit_test(*point)['target_type']!='wifi_popup'
                open_menu();command(hardware=False);screenshot('blocked')
                command(hardware=True,device=False);screenshot('no-adapter')
                assert ipc.hit_test(*at(100,100)).get('widget') != 'row', 'removed adapter still shown'
                command(device=True,many=True,count=35);screenshot('many')
                wait_for(lambda: ipc.hit_test(*at(100,100)).get('widget')=='row','adapter added')
                ipc.move_cursor(*at(100,150));ipc.scroll(0,1000);settle();screenshot('scrolled')
                fake.terminate();fake.wait(timeout=5);settle();screenshot('unavailable')
                fake=start_fake();settle()
                wait_for(lambda: ipc.hit_test(*at(100,100)).get('widget')=='row','service restart')
                ipc.click_at(20,20);settle()
                assert ipc.hit_test(*point)['target_type']!='wifi_popup'
                open_menu()
                # The footer opens the same Network page and retires the popup.
                ipc.key(42, True); ipc.key_down_up(15); ipc.key_down_up(15); ipc.key(42, False)
                ipc.key_down_up(28)
                UIDriver(ipc).wait_settled('control_center')
                assert ipc.get_shell_state()['control_center']['category'] == 'network'
                window = next(w for w in ipc.get_windows() if w['app_id'] == 'rediwm-settings')
                ipc.close_window(window['id'])
                UIDriver(ipc).wait_absent('control_center')
                open_menu()
                (tmp/'rediwm-config.toml').write_text('[compositor]\nxwayland = false\ntaskbar_items = ["battery", "volume", "-network", "clock"]\n')
                wait_for(lambda: ipc.hit_test(*point)['target_type']!='wifi_popup','hidden anchor closes menu')
                print(f'PASS Wi-Fi menu: forms, joins, saved credentials, radio, lifecycle, scale={scale}')
        except Exception:
            print((tmp/'compositor.log').read_text()[-7000:])
            raise
        finally:
            stop_process(process);log.close();fake.terminate();fake.wait(timeout=5)

def settings(scale):
    fake = start_fake()
    with tempfile.TemporaryDirectory(prefix='rediwm-network-settings-') as directory:
        tmp = Path(directory)
        process, log = spawn_compositor(tmp, scale=scale, renderer=os.environ.get('REDIWM_TEST_RENDERER', 'pixman'), config_content='[compositor]\nxwayland = false\n', env_extra={
            'DBUS_SYSTEM_BUS_ADDRESS': os.environ['DBUS_SESSION_BUS_ADDRESS'], 'DBUS_SESSION_BUS_ADDRESS': '', 'XDG_CACHE_HOME': str(tmp),
            'PIPEWIRE_RUNTIME_DIR': str(tmp), 'PULSE_SERVER': 'unix:/nonexistent-rediwm-test-pulse',
        })
        try:
            with IPCClient(tmp, timeout=15) as ipc:
                ui = UIDriver(ipc)
                def labels(): return [w['label'] for w in ui.widgets() if w.get('label')]
                def find(name): return ui.find(name, panel='control_center')
                def click(name):
                    for _ in range(12):
                        widget = find(name)
                        if widget['visible'] and not widget['clipped']:
                            ui.click(widget, panel='control_center')
                            ui.wait_settled('control_center')
                            return
                        outer = next(w for w in ui.widgets() if w['role'] == 'scroll_container')
                        viewport = find('wifi_networks') if name.startswith('wifi_') and name not in ('wifi_enabled', 'wifi_scan') else outer
                        if not viewport['visible'] or viewport['clipped']:
                            widget, viewport = viewport, outer
                        box = viewport['global_box']
                        ipc.move_cursor(box['x'] + box['width']//2, box['y'] + box['height']//2)
                        ipc.scroll(0, -120 if widget['box']['y'] > viewport['box']['y'] else 120)
                        ui.wait_settled('control_center')
                    raise AssertionError(f'could not reveal {name}')
                def command(**values):
                    fake.stdin.write(json.dumps(values)+'\n'); fake.stdin.flush()
                    assert read_line(fake) == {'done': True}
                def ready(): return not find('ethernet_enabled')['is_disabled']
                ipc.open_control_center()
                ui.wait_settled('control_center')
                ui.click('network', panel='control_center')
                wait_for(lambda: '192.168.1.100' in labels(), 'Ethernet address')
                ui.wait_settled('control_center')
                body_width = ipc.get_shell_state()['control_center']['box']['width']
                axis = 'x' if body_width >= 1000 else 'y'
                assert find('ethernet_card')['box'][axis] < find('wifi_card')['box'][axis]
                assert '2.5 Gbps' in labels() and '1.1.1.1, 1.0.0.1' in labels()
                assert 'REDI_Home' in labels() and "You're online." in labels()
                assert find('ethernet_enabled')['on'] and find('wifi_enabled')['on']
                screenshot = Path(f'/tmp/rediwm-network-settings-{scale}.png')
                screenshot.unlink(missing_ok=True)
                ipc.screenshot(str(screenshot))
                click('ethernet_copy_0')
                click('ethernet_enabled')
                assert read_line(fake) == {'ethernet': False, 'new': False}
                wait_for(lambda: not find('ethernet_enabled')['on'] and ready(), 'Ethernet disconnected')
                assert '192.168.1.100' not in labels()
                command(hold_eth=True)
                click('ethernet_enabled')
                assert read_line(fake) == {'ethernet': True, 'new': False}
                wait_for(lambda: 'Connecting Ethernet…' in labels(), 'Ethernet activation accepted')
                assert find('ethernet_enabled')['is_disabled']
                command(eth_state=100, hold_eth=False)
                wait_for(lambda: ready() and find('ethernet_enabled')['on'], 'Ethernet activated')
                command(eth_fail=True)
                click('ethernet_enabled')
                assert read_line(fake) == {'ethernet': False, 'new': False}
                wait_for(lambda: any('Ethernet request failed' in label for label in labels()), 'Ethernet permission error')
                assert find('ethernet_enabled')['on'], 'failed request changed the displayed state'
                command(eth_fail=False, eth_state=30, eth_profile=False)
                wait_for(lambda: not find('ethernet_enabled')['on'], 'Ethernet reset')
                click('ethernet_enabled')
                assert read_line(fake) == {'ethernet': True, 'new': True}
                wait_for(lambda: ready() and find('ethernet_enabled')['on'], 'new wired DHCP profile')
                command(carrier=False, eth_state=20, connectivity=3)
                wait_for(lambda: 'Cable unplugged' in labels(), 'cable removal')
                assert find('ethernet_enabled')['is_disabled'] and 'Limited access' in labels()
                command(carrier=True, eth_state=100, connectivity=2)
                wait_for(lambda: 'Sign-in required' in labels(), 'captive portal state')
                command(connectivity=4, complete_scan=True)
                # Open, saved and password-protected joins use the same backend
                # as the popup. A live update must preserve the draft and focus.
                click('wifi_network_2')
                click('wifi_join')
                assert read_line(fake) == {'join': 'Cafe_WiFi', 'hidden': False, 'auto': True, 'security': 'open'}
                wait_for(lambda: 'Connecting…' not in labels(), 'open Wi-Fi join')
                # Find rows by their displayed SSID, since connected rows sort first.
                def network_row(ssid):
                    widgets = ui.widgets()
                    label = next(w for w in widgets if w['label'] == ssid)
                    return next(w['name'] for w in widgets if w['role'] == 'row' and w['name'].startswith('wifi_network_') and w['box']['y'] <= label['box']['y'] < w['box']['y'] + w['box']['height'])
                click(network_row('Studio_5G'))
                click('wifi_join')
                assert read_line(fake) == {'activate': 'saved'}
                wait_for(lambda: 'Connecting…' not in labels(), 'saved Wi-Fi join')
                click(network_row('REDI_Home'))
                ipc.type_text('test-')
                command(strength=85)
                wait_for(lambda: find('wifi_password')['is_focused'], 'password focus after refresh')
                ipc.type_text('password')
                assert 'test-password' not in json.dumps(ipc.get_widget_tree('control_center'))
                click('wifi_reveal')
                assert 'test-password' not in json.dumps(ipc.get_widget_tree('control_center'))
                click('wifi_join')
                assert read_line(fake) == {'join': 'REDI_Home', 'hidden': False, 'auto': True, 'security': 'wpa-psk'}
                wait_for(lambda: 'Connecting…' not in labels(), 'password Wi-Fi join')
                command(fail=True)
                click('wifi_hidden')
                ipc.type_text('Hidden test')
                click('wifi_password')
                ipc.type_text('test-password')
                click('wifi_autojoin')
                click('wifi_join')
                assert read_line(fake) == {'join': 'Hidden test', 'hidden': True, 'auto': False, 'security': 'wpa-psk'}
                wait_for(lambda: any('Wi-Fi request failed' in label for label in labels()), 'hidden join error')
                command(fail=False)
                click('wifi_cancel')
                click('wifi_enabled')
                assert read_line(fake) == {'enabled': False}
                wait_for(lambda: 'Wi-Fi is turned off' in labels(), 'radio off')
                click('wifi_enabled')
                assert read_line(fake) == {'enabled': True}
                wait_for(lambda: 'REDI_Home' in labels(), 'radio on')
                command(ethernet=False, device=False)
                wait_for(lambda: 'No wired adapter found' in labels() and 'No Wi-Fi adapter found' in labels(), 'adapter removal')
                assert find('ethernet_enabled')['is_disabled'] and find('wifi_enabled')['is_disabled']
                command(ethernet=True, device=True)
                wait_for(lambda: ready() and 'REDI_Home' in labels(), 'adapter hotplug')
                window = next(w for w in ipc.get_windows() if w['app_id'] == 'rediwm-settings')
                ipc.action('set_window_size', {'id': window['id'], 'width': 760, 'height': 640})
                ui.wait_settled('control_center')
                assert find('ethernet_card')['box']['y'] < find('wifi_card')['box']['y'], 'narrow layout did not stack'
                fake.terminate(); fake.wait(timeout=5)
                wait_for(lambda: 'NetworkManager is unavailable' in labels(), 'service loss')
                fake = start_fake()
                wait_for(lambda: 'REDI_Home' in labels(), 'service restart')
                ipc.close_window(window['id'])
                ui.wait_absent('control_center')
                assert process.poll() is None
                print(f'PASS Network settings: layout, Ethernet details/activation/errors, Wi-Fi forms/joins/radio, service lifecycle, scale={scale}')
        except Exception:
            print((tmp/'compositor.log').read_text()[-7000:])
            raise
        finally:
            stop_process(process); log.close(); fake.terminate(); fake.wait(timeout=5)

if __name__=='__main__':
    if not os.environ.get('REDIWM_WIFI_PRIVATE_BUS'):
        os.execvpe('dbus-run-session',['dbus-run-session','--',sys.executable,__file__,*sys.argv[1:]],{**os.environ,'REDIWM_WIFI_PRIVATE_BUS':'1'})
    os.umask(0o077)
    scale = next((arg for arg in sys.argv[1:] if not arg.startswith('--')), '1')
    if '--settings-only' not in sys.argv: run(scale)
    settings(scale)

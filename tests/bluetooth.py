#!/usr/bin/env python3
"""Bluetooth Settings against private BlueZ; never accesses host Bluetooth."""
import json
import os
from pathlib import Path
import select
import subprocess
import sys
import tempfile

from PIL import Image
from ipc_client import IPCClient, IPCError, spawn_compositor, stop_process
from power_profiles import wait_for, read_line
from ui_driver import UIDriver

FAKE = r'''
import json, sys
from gi.repository import Gio, GLib
conn = Gio.bus_get_sync(Gio.BusType.SESSION)
v = GLib.Variant
A = '/org/bluez/hci0'
D = A + '/dev_11_22_33_44_55_66'
K = A + '/dev_AA_BB_CC_DD_EE_FF'
state = {'powered': True, 'scanning': False, 'paired': False, 'connected': True, 'trusted': True, 'blocked': False, 'battery': 80, 'removed': False, 'adapter': True, 'mode': 'confirm', 'fail': False, 'events': []}
agent = None
pending = None

def objects():
    if not state['adapter']: return {}
    result = {A: {'org.bluez.Adapter1': {'Alias': v('s','Test Bluetooth'), 'Powered': v('b',state['powered']), 'Discovering': v('b',state['scanning'])}}}
    if not state['removed']:
        result[D] = {'org.bluez.Device1': {'Alias': v('s','WH-1000XM5'), 'Adapter': v('o',A), 'Address': v('s','11:22:33:44:55:66'), 'Icon': v('s','audio-headphones'), 'Paired': v('b',True), 'Connected': v('b',state['connected']), 'Trusted': v('b',state['trusted']), 'Blocked': v('b',state['blocked']), 'RSSI': v('n',-42), 'UUIDs': v('as',['0000110b-0000-1000-8000-00805f9b34fb','0000111e-0000-1000-8000-00805f9b34fb'])}}
        if state['battery'] is not None: result[D]['org.bluez.Battery1'] = {'Percentage': v('y',state['battery'])}
    if state['scanning'] or state['paired']:
        result[K] = {'org.bluez.Device1': {'Alias': v('s','Keychron K2'), 'Adapter': v('o',A), 'Address': v('s','AA:BB:CC:DD:EE:FF'), 'Icon': v('s','input-keyboard'), 'Paired': v('b',state['paired']), 'Connected': v('b',state.get('key_connected',False)), 'Trusted': v('b',False), 'UUIDs': v('as',['00001812-0000-1000-8000-00805f9b34fb'])}}
    return result

def changed():
    conn.emit_signal(None,A,'org.freedesktop.DBus.Properties','PropertiesChanged',v('(sa{sv}as)',('org.bluez.Adapter1',{},[])))
    conn.flush_sync()

def pair_done(connection, result, inv):
    global pending
    try:
        answer = connection.call_finish(result).unpack()
        if state['mode'] == 'pin': assert answer == ('1234',), answer
        if state['mode'] == 'passkey': assert answer == (123456,), answer
        state['paired'] = True
        inv.return_value(v('()',()))
    except GLib.Error:
        inv.return_dbus_error('org.bluez.Error.AuthenticationRejected','Rejected')
    pending = None
    changed()

def method(c, sender, path, iface, name, params, inv):
    global agent, pending
    if name == 'GetManagedObjects': inv.return_value(v('(a{oa{sa{sv}}})',(objects(),))); return
    state['events'].append(name)
    if state['fail'] and name != 'RegisterAgent': inv.return_dbus_error('org.bluez.Error.NotAuthorized','Permission denied'); return
    if name == 'RegisterAgent':
        agent = (sender, params.unpack()[0]);state['agent'] = agent
    elif name == 'Set':
        _, key, value = params.unpack()
        state[{'Powered':'powered','Trusted':'trusted','Blocked':'blocked'}[key]] = value
    elif name == 'StartDiscovery': state['scanning'] = True
    elif name == 'StopDiscovery': state['scanning'] = False
    elif name in ('Connect','Disconnect'):
        state['connected' if path == D else 'key_connected'] = name == 'Connect'
    elif name == 'RemoveDevice': state['removed'] = True
    elif name == 'Pair':
        pending = inv
        mode = state['mode']
        member, args, reply = ('RequestConfirmation',v('(ou)',(path,123456)),v('()',()).get_type()) if mode == 'confirm' else ('RequestPinCode',v('(o)',(path,)),v('(s)',('',)).get_type()) if mode == 'pin' else ('RequestPasskey',v('(o)',(path,)),v('(u)',(0,)).get_type())
        conn.call(agent[0],agent[1],'org.bluez.Agent1',member,args,reply,Gio.DBusCallFlags.NONE,20000,None,pair_done,inv)
        return
    elif name == 'CancelPairing': pass
    inv.return_value(v('()',()))
    changed()

refs=[]
def register(path, xml):
    info=Gio.DBusNodeInfo.new_for_xml('<node>'+xml+'</node>');refs.append(info)
    for iface in info.interfaces: conn.register_object(path,iface,method,None,None)
register('/', '<interface name="org.freedesktop.DBus.ObjectManager"><method name="GetManagedObjects"><arg direction="out" type="a{oa{sa{sv}}}"/></method></interface>')
register('/org/bluez','<interface name="org.bluez.AgentManager1"><method name="RegisterAgent"><arg type="o" direction="in"/><arg type="s" direction="in"/></method></interface>')
register(A, '<interface name="org.bluez.Adapter1"><method name="StartDiscovery"/><method name="StopDiscovery"/><method name="RemoveDevice"><arg type="o" direction="in"/></method></interface>')
for path in (A,D,K):
    register(path,'<interface name="org.freedesktop.DBus.Properties"><method name="Set"><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="v" direction="in"/></method></interface>')
for path in (D,K):
    register(path,'<interface name="org.bluez.Device1">'+''.join('<method name="'+name+'"/>' for name in ('Connect','Disconnect','Pair','CancelPairing'))+'</interface>')

def command(fd, condition):
    values=json.loads(sys.stdin.readline())
    if values.pop('inspect',False): print(json.dumps(state),flush=True)
    else:
        state.update(values);changed();print(json.dumps({'done':True}),flush=True)
    return True
GLib.io_add_watch(sys.stdin,GLib.IO_IN,command)
Gio.bus_own_name_on_connection(conn,'org.bluez',Gio.BusNameOwnerFlags.NONE,lambda *_:print('ready',flush=True),None)
GLib.MainLoop().run()
'''


def start_fake():
    fake = subprocess.Popen([sys.executable, '-c', FAKE], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
    assert select.select([fake.stdout], [], [], 5)[0]
    assert fake.stdout.readline().strip() == 'ready'
    return fake


def run(scale):
    fake = start_fake()
    with tempfile.TemporaryDirectory(prefix='rediwm-bluetooth-') as directory:
        tmp = Path(directory)
        process, log = spawn_compositor(tmp, scale=scale, renderer=os.environ.get('REDIWM_TEST_RENDERER','pixman'), config_content='[compositor]\nxwayland = false\n', env_extra={
            'DBUS_SYSTEM_BUS_ADDRESS': os.environ['DBUS_SESSION_BUS_ADDRESS'], 'DBUS_SESSION_BUS_ADDRESS': '',
            'XDG_CACHE_HOME': str(tmp), 'PIPEWIRE_RUNTIME_DIR': str(tmp), 'PULSE_SERVER': 'unix:/nonexistent-rediwm-test-pulse',
        })
        try:
            with IPCClient(tmp, timeout=15) as ipc:
                ui = UIDriver(ipc)
                def find(name): return ui.find(name, panel='control_center')
                def click(name):
                    wait_for(lambda:not find(name)['is_disabled'], name+' enabled')
                    ui.click(ui.scroll_into_view(name, panel='control_center'), panel='control_center')
                    ui.wait_settled('control_center')
                def labels(): return [w.get('label') for w in ui.widgets('control_center')]
                def fixture(**values):
                    fake.stdin.write(json.dumps(values)+'\n');fake.stdin.flush()
                    return read_line(fake)
                def state(): return fixture(inspect=True)
                def wait_label(value): wait_for(lambda:value in labels(), value)
                def capture(name):
                    if dest := os.environ.get('REDIWM_SETTINGS_PREVIEW'):
                        Path(dest).mkdir(parents=True,exist_ok=True)
                        path=tmp/(name+'.png')
                        ipc.screenshot(str(path))
                        with Image.open(path) as image: image.save(Path(dest)/(name+'-'+scale+'.png'))
                def choose(label):
                    title = find(label)
                    row = next(w for w in ui.widgets('control_center') if w['role']=='row' and w['box']['y'] <= title['box']['y'] < w['box']['y']+w['box']['height'] and w['name'] and w['name'].startswith('bluetooth_device_'))
                    click(row['name'])
                def type_field(name, value):
                    click(name);ipc.type_text(value);ui.wait_settled('control_center')
                ipc.open_control_center();ui.wait_settled('control_center')
                assert 'RegisterAgent' not in state()['events'], 'Bluetooth should be lazy'
                click('bluetooth');wait_label('WH-1000XM5')
                choose('WH-1000XM5')
                wait_label('Audio (A2DP) · High quality audio')
                assert find('bluetooth_battery')['role']=='battery'
                capture('bluetooth')
                click('bluetooth_connect');wait_for(lambda:not state()['connected'],'disconnect')
                click('bluetooth_connect');wait_for(lambda:state()['connected'],'connect')
                click('bluetooth_trusted');wait_for(lambda:not state()['trusted'],'trust')
                fixture(battery=None)
                wait_for(lambda:not any(w['name']=='bluetooth_battery' for w in ui.widgets()),'optional battery')
                fixture(battery=8);wait_for(lambda:any(w['name']=='bluetooth_battery' for w in ui.widgets()),'live battery')
                type_field('bluetooth_search','does not exist');wait_label('No matching devices')
                ipc.key(29,True);ipc.key_down_up(30);ipc.key(29,False);ipc.key_down_up(14);ui.wait_settled('control_center')
                wait_label('WH-1000XM5')
                click('bluetooth_scan');wait_label('Keychron K2');choose('Keychron K2')
                click('bluetooth_connect');wait_label('Does this code match the code on your device?')
                wait_label('123456');capture('bluetooth-pairing')
                click('bluetooth_pair_cancel');wait_for(lambda:not state()['paired'],'cancel pairing')
                wait_for(lambda:any(w['name']=='bluetooth_connect' and not w['is_disabled'] for w in ui.widgets()),'pair reset')
                click('bluetooth_connect');wait_label('Does this code match the code on your device?')
                click('bluetooth_pair_accept');wait_for(lambda:state()['paired'],'confirmation pairing')
                fixture(paired=False,mode='pin');wait_label('Pair Device');click('bluetooth_connect');wait_label("Enter the device's PIN")
                type_field('bluetooth_pin','1234');ipc.key_down_up(28)
                wait_for(lambda:state()['paired'] and state().get('key_connected'),'PIN pairing and connect')
                click('general');wait_for(lambda:not state()['scanning'],'stop discovery on leave')
                click('bluetooth');wait_label('Keychron K2');choose('Keychron K2')
                fixture(paired=False,mode='passkey')
                # Restart discovery so this unpaired device stays listed.
                click('bluetooth_scan');wait_label('Keychron K2');choose('Keychron K2');click('bluetooth_connect')
                wait_label("Enter the device's six-digit passkey");type_field('bluetooth_pin','123456');click('bluetooth_pair_accept')
                wait_for(lambda:state()['paired'],'passkey pairing')
                choose('WH-1000XM5');fixture(fail=True)
                click('bluetooth_connect');wait_label('Permission denied');assert state()['connected']
                fixture(fail=False)
                click('bluetooth_forget');wait_label('Forget this device? Pair it again to reconnect.')
                click('bluetooth_forget_cancel');assert not state()['removed']
                click('bluetooth_forget');click('bluetooth_forget_confirm');wait_for(lambda:state()['removed'],'forget')
                click('bluetooth_enabled');wait_for(lambda:not state()['powered'],'radio off')
                click('bluetooth_enabled');wait_for(lambda:state()['powered'],'radio on')
                fixture(adapter=False);wait_label('No Bluetooth adapter found')
                fixture(adapter=True);wait_label('Keychron K2')
                window=next(w for w in ipc.get_windows() if w.get('app_id')=='rediwm-settings')
                ipc.action('set_window_size',{'id':window['id'],'width':620,'height':580});ui.wait_settled('control_center')
                assert find('bluetooth_scan')['visible'] and not find('bluetooth_scan')['clipped']
                capture('bluetooth-narrow')
                ipc.action('set_window_size',{'id':window['id'],'width':1120,'height':580});ui.wait_settled('control_center')
                fake.terminate();fake.wait(timeout=5);wait_label('Bluetooth service is unavailable')
                fake=start_fake();wait_label('WH-1000XM5')
                choose('WH-1000XM5');capture('bluetooth-restarted')
                click('bluetooth_scan');wait_for(lambda:state()['scanning'],'discovery restarted')
                window=next(w for w in ipc.get_windows() if w.get('app_id')=='rediwm-settings')
                ipc.close_window(window['id']);ui.wait_absent('control_center')
                wait_for(lambda:not state()['scanning'],'stop discovery on close')
                ipc.open_control_center();ui.wait_settled('control_center');click('bluetooth');wait_label('WH-1000XM5')
                sender,path=state()['agent']
                spoof=subprocess.run(['busctl','--address='+os.environ['DBUS_SESSION_BUS_ADDRESS'],'call',sender,path,'org.bluez.Agent1','Cancel'],capture_output=True,text=True)
                assert spoof.returncode != 0 and 'Unexpected sender' in spoof.stderr, spoof
                click('bluetooth_scan');wait_label('Keychron K2');choose('Keychron K2');click('bluetooth_connect')
                wait_label('Does this code match the code on your device?')
                ipc.key(29,True);ipc.key(56,True);ipc.key(38,True)
                wait_for(lambda:not state()['scanning'] and 'CancelPairing' in state()['events'],'lock cancels discovery and pairing')
                try: ipc.get_shell_state()
                except IPCError as error: assert 'SessionLocked' in str(error)
                else: raise AssertionError('lock accepted settings IPC')
            stop_process(process)
            contents=(tmp/'compositor.log').read_text() if (tmp/'compositor.log').exists() else ''
            assert 'memory address' not in contents and ' leaked:' not in contents, contents[-2000:]
            print('Bluetooth settings passed at scale',scale)
        except Exception:
            log.flush()
            Path('/tmp/rediwm-bluetooth-compositor.log').write_text((tmp/'compositor.log').read_text())
            raise
        finally:
            stop_process(process);log.close();fake.terminate();fake.wait(timeout=5)


if __name__=='__main__':
    if not os.environ.get('REDIWM_BLUETOOTH_PRIVATE_BUS'):
        os.execvpe('dbus-run-session',['dbus-run-session','--',sys.executable,__file__,*sys.argv[1:]],{**os.environ,'REDIWM_BLUETOOTH_PRIVATE_BUS':'1'})
    os.umask(0o077)
    run(os.environ.get('REDIWM_TEST_SCALE','1'))

#!/usr/bin/env python3
"""A fake NetworkManager on the session bus for the Network settings tests.

Run as a subprocess: it prints one JSON line per event the compositor causes
(updates, deletes, activations) and takes JSON commands on stdin, answering each
with {"done": true}. Never talks to the host's NetworkManager.
"""
import json
import sys
import warnings
warnings.simplefilter('ignore', DeprecationWarning)
from gi.repository import Gio, GLib

NM = 'org.freedesktop.NetworkManager'
ROOT = '/org/freedesktop/NetworkManager'
OBJECTS_ROOT = '/org/freedesktop'
SETTINGS = ROOT + '/Settings'
CONN = NM + '.Settings.Connection'
WIFI = ROOT + '/Devices/1'
ETH = ROOT + '/Devices/2'
AP = ROOT + '/AccessPoint/'
v = GLib.Variant
bus = Gio.bus_get_sync(Gio.BusType.SESSION)


def ip(a, b, c, d):
    """An IPv4 address as NetworkManager's `dns` property carries it: network byte order."""
    return int.from_bytes(bytes([a, b, c, d]), sys.byteorder)


def settings(kind, name, **extra):
    """a{sa{sv}} for a saved profile."""
    out = {'connection': {'id': v('s', name), 'type': v('s', kind), 'autoconnect': v('b', True)},
           'ipv4': {'method': v('s', 'auto')}, 'ipv6': {'method': v('s', 'auto')}}
    if kind == '802-11-wireless':
        out['802-11-wireless'] = {'ssid': v('ay', list(name.encode()))}
        out['802-11-wireless-security'] = {'key-mgmt': v('s', 'wpa-psk'), 'psk-flags': v('u', 0)}
    if kind == '802-3-ethernet':
        out['802-3-ethernet'] = {}
    if kind == 'vpn':
        out['vpn'] = {'service-type': v('s', 'org.freedesktop.NetworkManager.openvpn')}
    if kind == 'wireguard':
        out['wireguard'] = {'listen-port': v('u', 0)}
    for section, props in extra.items():
        out.setdefault(section.replace('_', '-'), {}).update(props)
    return out


state = {
    'enabled': True, 'hardware': True, 'global_state': 70, 'connectivity': 4,
    'wifi_active': 1, 'eth_state': 100, 'vpn_active': [4],
    # polkit answer to CheckAuthorization: 'yes', 'challenge' (needs interaction) or 'no'
    'polkit': 'yes', 'polkit_grant': True,
    'profiles': {
        SETTINGS + '/1': v('a{sa{sv}}', settings('802-11-wireless', 'REDI_Home')),
        SETTINGS + '/2': v('a{sa{sv}}', settings('802-3-ethernet', 'Wired connection 1')),
        SETTINGS + '/3': v('a{sa{sv}}', settings('802-11-wireless', 'Studio_5G')),
        SETTINGS + '/4': v('a{sa{sv}}', settings('vpn', 'Work VPN')),
        SETTINGS + '/5': v('a{sa{sv}}', settings('wireguard', 'wg0')),
    },
}
names = ['REDI_Home', 'Studio_5G', 'Cafe_WiFi']
freq = [5180, 2437, 5955]


def array_of_dicts(items):
    return v('aa{sv}', [{k: val for k, val in item.items()} for item in items])


def objects():
    result = {ROOT: {NM: {'WirelessEnabled': v('b', state['enabled']), 'WirelessHardwareEnabled': v('b', state['hardware']),
                          'State': v('u', state['global_state']), 'Connectivity': v('u', state['connectivity'])}}}
    for path in state['profiles']:
        result[path] = {CONN: {}}
    result[ETH] = {NM + '.Device': {'Interface': v('s', 'enp4s0'), 'Driver': v('s', 'r8169'), 'Managed': v('b', True), 'State': v('u', state['eth_state']),
                                    'Ip4Config': v('o', ROOT + '/IP4Config/2'), 'Ip6Config': v('o', ROOT + '/IP6Config/2'),
                                    'ActiveConnection': v('o', ROOT + '/ActiveConnection/2'),
                                    'AvailableConnections': v('ao', [SETTINGS + '/2'])},
                   NM + '.Device.Wired': {'Carrier': v('b', True), 'Speed': v('u', 2500), 'HwAddress': v('s', '3C:EC:EF:12:34:56')}}
    result[ROOT + '/IP4Config/2'] = {NM + '.IP4Config': {
        'AddressData': array_of_dicts([{'address': v('s', '192.168.1.100'), 'prefix': v('u', 24)}]), 'Gateway': v('s', '192.168.1.1'),
        'NameserverData': array_of_dicts([{'address': v('s', '1.1.1.1')}, {'address': v('s', '1.0.0.1')}]), 'Searches': v('as', ['lan'])}}
    result[ROOT + '/IP6Config/2'] = {NM + '.IP6Config': {
        'AddressData': array_of_dicts([{'address': v('s', '2001:db8::2a'), 'prefix': v('u', 64)}]), 'Gateway': v('s', 'fe80::1'),
        'Nameservers': v('aay', [list(bytes.fromhex('20010db8000000000000000000000053'))])}}
    result[ROOT + '/ActiveConnection/2'] = {NM + '.Connection.Active': {'Id': v('s', 'Wired connection 1'), 'Type': v('s', '802-3-ethernet'),
                                                                        'Connection': v('o', SETTINGS + '/2'), 'State': v('u', 2)}}
    active = state['wifi_active']
    result[WIFI] = {NM + '.Device': {'Interface': v('s', 'wlan0'), 'State': v('u', 100 if active else 30), 'Ip4Config': v('o', ROOT + '/IP4Config/1'),
                                     'Ip6Config': v('o', ROOT + '/IP6Config/1'), 'ActiveConnection': v('o', ROOT + '/ActiveConnection/1' if active else '/'),
                                     'HwAddress': v('s', 'AA:BB:CC:DD:EE:01')},
                    NM + '.Device.Wireless': {'LastScan': v('x', 1), 'Bitrate': v('u', 866000), 'HwAddress': v('s', 'AA:BB:CC:DD:EE:01'),
                                              'ActiveAccessPoint': v('o', AP + str(active) if active else '/'),
                                              'AccessPoints': v('ao', [AP + str(i + 1) for i in range(len(names))])}}
    result[ROOT + '/IP4Config/1'] = {NM + '.IP4Config': {
        'AddressData': array_of_dicts([{'address': v('s', '10.0.0.23'), 'prefix': v('u', 24)}]), 'Gateway': v('s', '10.0.0.1'),
        'NameserverData': array_of_dicts([{'address': v('s', '10.0.0.1')}])}}
    result[ROOT + '/IP6Config/1'] = {NM + '.IP6Config': {
        'AddressData': array_of_dicts([{'address': v('s', 'fe80::a8bb:ccff:fedd:ee01'), 'prefix': v('u', 64)}])}}
    result[ROOT + '/ActiveConnection/1'] = {NM + '.Connection.Active': {'Id': v('s', 'REDI_Home'), 'Type': v('s', '802-11-wireless'),
                                                                        'Connection': v('o', SETTINGS + '/1'), 'State': v('u', 2)}}
    for n in state['vpn_active']:
        result[ROOT + '/ActiveConnection/%d' % n] = {NM + '.Connection.Active': {
            'Id': v('s', 'Work VPN' if n == 4 else 'wg0'), 'Type': v('s', 'vpn' if n == 4 else 'wireguard'),
            'Connection': v('o', SETTINGS + '/%d' % n), 'State': v('u', 2)}}
    for i, name in enumerate(names):
        result[AP + str(i + 1)] = {NM + '.AccessPoint': {'Ssid': v('ay', list(name.encode())), 'Strength': v('y', 90 - i * 20), 'Flags': v('u', 1),
                                                         'WpaFlags': v('u', 0), 'RsnFlags': v('u', 0x100), 'Frequency': v('u', freq[i]),
                                                         'HwAddress': v('s', '11:22:33:44:55:0%d' % (i + 1))}}
    return result


def emit(path, iface, member, params):
    bus.emit_signal(None, path, iface, member, params)
    bus.flush_sync()


def changed():
    emit(ROOT, 'org.freedesktop.DBus.Properties', 'PropertiesChanged', v('(sa{sv}as)', (NM, {'WirelessEnabled': v('b', state['enabled'])}, [])))


def event(**values):
    print(json.dumps(values), flush=True)


def plain(value):
    """JSON-friendly copy of an unpacked value."""
    if isinstance(value, dict):
        return {k: plain(x) for k, x in value.items()}
    if isinstance(value, (list, tuple)):
        return [plain(x) for x in value]
    if isinstance(value, bytes):
        return list(value)
    return value


def method(c, sender, path, iface, name, params, inv):
    if name == 'GetManagedObjects':
        inv.return_value(v('(a{oa{sa{sv}}})', (objects(),)))
    elif name == 'GetSettings':
        inv.return_value(GLib.Variant.new_tuple(state['profiles'][path]))
    else:
        handler = HANDLERS.get(name)
        if handler is None:
            inv.return_dbus_error(NM + '.Failed', 'fake has no ' + name)
        else:
            handler(path, params, inv)


HANDLERS = {}
PROFILE_XML = ('<interface name="%s"><method name="GetSettings"><arg direction="out" type="a{sa{sv}}"/></method>'
               '<method name="Update"><arg direction="in" type="a{sa{sv}}"/></method><method name="Delete"/></interface>' % CONN)


def update(path, params, inv):
    state['profiles'][path] = params.get_child_value(0)
    event(update=path, settings=plain(state['profiles'][path].unpack()))
    inv.return_value(v('()', ()))
    emit(path, CONN, 'Updated', None)


def delete(path, params, inv):
    state['profiles'].pop(path, None)
    event(delete=path)
    inv.return_value(v('()', ()))
    emit(OBJECTS_ROOT, 'org.freedesktop.DBus.ObjectManager', 'InterfacesRemoved', v('(oas)', (path, [CONN])))


def activate(path, params, inv):
    profile, device, specific = params.unpack()
    event(activate=profile, device=device, specific=specific)
    if device == '/':  # a VPN needs no adapter
        n = int(profile.rsplit('/', 1)[-1])
        if n not in state['vpn_active']:
            state['vpn_active'].append(n)
        inv.return_value(v('(o)', (ROOT + '/ActiveConnection/%d' % n,)))
    else:
        inv.return_value(v('(o)', (ROOT + '/ActiveConnection/1',)))
    changed()


def deactivate(path, params, inv):
    event(deactivate=params.unpack()[0])
    n = int(params.unpack()[0].rsplit('/', 1)[-1])
    if n in state['vpn_active']:
        state['vpn_active'].remove(n)
    inv.return_value(v('()', ()))
    changed()


def disconnect(path, params, inv):
    event(disconnect=path)
    if path == WIFI:
        state['wifi_active'] = 0
    inv.return_value(v('()', ()))
    changed()


def check_authorization(path, params, inv):
    interactive = bool(params.unpack()[3] & 1)
    event(polkit=params.unpack()[1], interactive=interactive)
    answer = state['polkit']
    if answer == 'challenge' and interactive:
        granted = state['polkit_grant']
        if granted:
            state['polkit'] = 'yes'
        inv.return_value(v('((bba{ss}))', ((granted, not granted, {}),)))
    else:
        inv.return_value(v('((bba{ss}))', ((answer == 'yes', answer == 'challenge', {}),)))


HANDLERS.update({'DeactivateConnection': deactivate, 'Update': update, 'Delete': delete, 'ActivateConnection': activate, 'Disconnect': disconnect, 'CheckAuthorization': check_authorization})


def register(path, xml):
    node = Gio.DBusNodeInfo.new_for_xml('<node>' + xml + '</node>')
    for info in node.interfaces:
        bus.register_object(path, info, method, lambda *a: v('b', state['enabled']), lambda *a: True)


def command(channel, cond):
    request = json.loads(sys.stdin.readline())
    COMMANDS(request)
    changed()
    event(done=True)
    return True


def default_commands(request):
    state.update(request)


COMMANDS = default_commands


def start():
    register(OBJECTS_ROOT, '<interface name="org.freedesktop.DBus.ObjectManager"><method name="GetManagedObjects"><arg direction="out" type="a{oa{sa{sv}}}"/></method></interface>')
    for path in list(state['profiles']):
        register(path, PROFILE_XML)
    register(ROOT, '<interface name="%s"><property name="WirelessEnabled" type="b" access="readwrite"/><method name="ActivateConnection"><arg direction="in" type="o"/><arg direction="in" type="o"/><arg direction="in" type="o"/><arg direction="out" type="o"/></method><method name="DeactivateConnection"><arg direction="in" type="o"/></method></interface>' % NM)
    register(WIFI, '<interface name="%s.Device.Wireless"><method name="RequestScan"><arg direction="in" type="a{sv}"/></method></interface>' % NM)
    register(WIFI, '<interface name="%s.Device"><method name="Disconnect"/></interface>' % NM)
    register(ETH, '<interface name="%s.Device"><method name="Disconnect"/></interface>' % NM)
    register('/org/freedesktop/PolicyKit1/Authority', '<interface name="org.freedesktop.PolicyKit1.Authority"><method name="CheckAuthorization">'
             '<arg direction="in" type="(sa{sv})"/><arg direction="in" type="s"/><arg direction="in" type="a{ss}"/><arg direction="in" type="u"/><arg direction="in" type="s"/>'
             '<arg direction="out" type="(bba{ss})"/></method></interface>')
    Gio.bus_own_name_on_connection(bus, 'org.freedesktop.PolicyKit1', Gio.BusNameOwnerFlags.NONE, None, None)
    GLib.io_add_watch(sys.stdin.fileno(), GLib.IO_IN, command)
    Gio.bus_own_name_on_connection(bus, NM, Gio.BusNameOwnerFlags.NONE, lambda *_: print('ready', flush=True), None)
    GLib.MainLoop().run()


if __name__ == '__main__':
    start()

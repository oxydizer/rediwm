#!/usr/bin/env python3
"""Real SNI/DBusMenu traffic and taskbar input on an isolated session bus."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

from ipc_client import IPCClient, ROOT, spawn_compositor, stop_process

NAME = 'org.rediwm.TestTray'
ITEM = '/CustomTray'
IFACE = 'org.kde.StatusNotifierItem'
WATCHER = 'org.kde.StatusNotifierWatcher'
MENU = 'com.canonical.dbusmenu'


def service(event_path):
    import gi
    from gi.repository import Gio, GLib
    conn = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    state = {'status': 'Active', 'red': True, 'menu': False, 'label': '_Open', 'delay': False}
    events = open(event_path, 'a', buffering=1)
    xml = f'''<node><interface name="{IFACE}">
      <property name="Status" type="s" access="read"/>
      <property name="IconName" type="s" access="read"/>
      <property name="IconPixmap" type="a(iiay)" access="read"/>
      <property name="Menu" type="o" access="read"/>
      <property name="ItemIsMenu" type="b" access="read"/>
      <method name="Activate"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
      <method name="SecondaryActivate"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
      <method name="ContextMenu"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
      <method name="Scroll"><arg type="i" direction="in"/><arg type="s" direction="in"/></method>
      <method name="Change"><arg type="s" direction="in"/></method>
    </interface><interface name="{MENU}">
      <method name="AboutToShow"><arg type="i" direction="in"/><arg type="b" direction="out"/></method>
      <method name="GetLayout"><arg type="i" direction="in"/><arg type="i" direction="in"/><arg type="as" direction="in"/><arg type="u" direction="out"/><arg type="(ia{{sv}}av)" direction="out"/></method>
      <method name="Event"><arg type="i" direction="in"/><arg type="s" direction="in"/><arg type="v" direction="in"/><arg type="u" direction="in"/></method>
    </interface></node>'''
    info = Gio.DBusNodeInfo.new_for_xml(xml)

    def prop(_conn, sender, path, interface, name):
        return {
            'Status': GLib.Variant('s', state['status']),
            'IconName': GLib.Variant('s', ''),
            'IconPixmap': GLib.Variant('a(iiay)', [(16, 16, bytes([128, 255, 0, 0] if state['red'] else [255, 0, 255, 0]) * 256)]),
            'Menu': GLib.Variant('o', '/' if state.get('fallback') else '/Menu'),
            'ItemIsMenu': GLib.Variant('b', state['menu']),
        }[name]

    def row(id, label='', **props):
        values = {'label': GLib.Variant('s', label)}
        values.update({k.replace('_', '-'): GLib.Variant('b' if isinstance(v, bool) else 'i' if isinstance(v, int) else 's', v) for k, v in props.items()})
        return GLib.Variant('(ia{sv}av)', (id, values, []))

    def method(_conn, sender, path, interface, member, params, inv):
        args = params.unpack()
        if member == 'Change':
            change = args[0]
            if change in ('Active', 'Passive', 'NeedsAttention'):
                state['status'] = change
            elif change == 'green': state['red'] = False
            elif change == 'menu': state['menu'] = True
            elif change == 'fallback': state['fallback'] = True
            elif change == 'delay': state['delay'] = True
            elif change == 'exported': state['fallback'] = False
            elif change == 'rename': state['label'] = '_Renamed'
            if change == 'rename':
                conn.emit_signal(None, '/Menu', MENU, 'LayoutUpdated', GLib.Variant('(ui)', (2, 0)))
            else:
                conn.emit_signal(None, ITEM, IFACE, 'NewIcon', None)
        elif member == 'GetLayout':
            children = [row(10, '_Child')] if args[0] == 5 else [
                row(1, state['label']), row(2, '_Disabled', enabled=False),
                row(3, '_Hidden', visible=False), row(4, 'Checked', toggle_type='checkmark', toggle_state=1),
                row(7, type='separator'), row(5, '_More', children_display='submenu')]
            result = GLib.Variant('(u(ia{sv}av))', (1, (args[0], {}, children)))
            if state['delay']:
                GLib.timeout_add(300, lambda: (inv.return_value(result), False)[1])
            else: inv.return_value(result)
            return
        elif member == 'AboutToShow':
            events.write(f'AboutToShow {args[0]}\n')
            inv.return_value(GLib.Variant('(b)', (True,)))
            return
        else:
            events.write(member + ' ' + str(args) + '\n')
        inv.return_value(GLib.Variant('()', ()))

    conn.register_object(ITEM, info.interfaces[0], method, prop, None)
    conn.register_object('/StatusNotifierItem', info.interfaces[0], method, prop, None)
    conn.register_object('/Menu', info.interfaces[1], method, None, None)
    conn.call_sync('org.freedesktop.DBus', '/org/freedesktop/DBus', 'org.freedesktop.DBus', 'RequestName', GLib.Variant('(su)', (NAME, 4)), None, Gio.DBusCallFlags.NONE, 3000, None)

    def appeared(conn, name, owner):
        conn.call_sync(WATCHER, '/StatusNotifierWatcher', WATCHER, 'RegisterStatusNotifierItem', GLib.Variant('(s)', (ITEM,)), None, Gio.DBusCallFlags.NONE, 3000, None)
        print('READY', flush=True)
    Gio.bus_watch_name_on_connection(conn, WATCHER, Gio.BusNameWatcherFlags.NONE, appeared, None)
    GLib.MainLoop().run()


def wait(fn, description):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        value = fn()
        if value: return value
        time.sleep(.05)
    raise AssertionError(description)


def test(scale):
    from PIL import Image
    with tempfile.TemporaryDirectory(prefix='rediwm-tray-') as d:
        runtime = Path(d)
        events = runtime / 'events'
        # Start before the watcher to verify discovery when it appears.
        fixture = subprocess.Popen([sys.executable, __file__, '--service', str(events)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        proc, log = spawn_compositor(runtime, outputs='1', scale=scale, renderer=os.environ.get('REDIWM_TEST_RENDERER', 'pixman'),
            env_extra={'WLR_RENDERER_ALLOW_SOFTWARE': '1', 'REDIWM_FORCE_DBUS': '1', 'PULSE_SERVER': 'unix:/nonexistent/rediwm-test-audio'})
        try:
            with IPCClient(runtime) as ipc:
                ipc.wait_for('wallpaper_presented', timeout_ms=10000)
                def bar(): return ipc.get_shell_state()['taskbars'][0]
                def icons(): return bar()['app_tray']
                def menu(): return bar()['tray_menu']
                def change(value):
                    subprocess.run(['busctl', '--user', 'call', NAME, ITEM, IFACE, 'Change', 's', value], check=True, capture_output=True)
                def has_event(s): return events.exists() and s in events.read_text()
                def click_icon(button=0x110):
                    b = icons()[0]['box']
                    ipc.click_at(b['x'] + b['width']//2, b['y'] + b['height']//2, button)
                def menu_row(n):
                    b = wait(menu, 'menu is visible')
                    ipc.click_at(b['x'] + 90, b['y'] + 8 + n * 30 + 15)
                wait(lambda: len(icons()) == 1, 'application registered in taskbar')
                b = icons()[0]['box']
                assert b['x'] + b['width'] <= min(i['box']['x'] for i in bar()['right_items'] if i['box'])
                click_icon()
                wait(lambda: has_event('Activate '), 'left click activates app')
                click_icon(0x112)
                wait(lambda: has_event('SecondaryActivate '), 'middle click activates secondary action')
                ipc.move_cursor(b['x'] + 10, b['y'] + 10)
                ipc.scroll(0, 30)
                wait(lambda: has_event('Scroll '), 'scroll forwarded')
                click_icon(0x111)
                wait(menu, 'right click opens exported context menu')
                assert menu()['height'] == 166, 'hidden entries excluded'
                if os.environ.get('REDIWM_TRAY_PREVIEW'):
                    ipc.screenshot(os.environ['REDIWM_TRAY_PREVIEW'] + '-' + scale + '.png')
                menu_row(1)
                assert menu(), 'disabled row must leave menu open'
                assert not has_event('Event '), events.read_text()
                menu_row(2)
                wait(lambda: has_event("Event (4, 'clicked'"), 'checked action delivered')
                assert menu() is None
                click_icon(0x111)
                menu_row(4)
                wait(lambda: has_event('AboutToShow 5'), 'submenu about-to-show')
                wait(lambda: menu() and menu()['height'] == 76, 'submenu layout')
                menu_row(1)
                wait(lambda: has_event("Event (10, 'clicked'"), 'submenu action delivered')
                click_icon(0x111)
                wait(menu, 'menu reopen')
                change('rename')
                time.sleep(.15)
                ipc.key_press('Escape')
                wait(lambda: menu() is None, 'Escape dismisses menu')
                change('menu')
                time.sleep(.15)
                click_icon()
                wait(menu, 'ItemIsMenu opens on left click')
                ipc.click_at(5, 5)
                wait(lambda: menu() is None, 'outside click dismisses menu')
                change('Passive')
                wait(lambda: len(icons()) == 0, 'passive icon hidden')
                change('Active')
                wait(lambda: len(icons()) == 1, 'active icon restored')
                change('green')
                time.sleep(.15)
                shot = runtime / 'tray.png'
                ipc.screenshot(str(shot))
                image = Image.open(shot).convert('RGB')
                b = icons()[0]['box']
                px = image.getpixel((round((b['x'] + b['width']/2) * float(scale)), round((b['y'] + b['height']/2) * float(scale))))
                assert px[1] > 240 and px[0] < 15, px
                change('fallback')
                time.sleep(.15)
                click_icon(0x111)
                wait(lambda: has_event('ContextMenu '), 'fallback context menu call')
                # Service-name registrations use /StatusNotifierItem. Duplicates
                # must resolve to the same owner/path even through an alias.
                for _ in range(2):
                    subprocess.run(['busctl', '--user', 'call', WATCHER, '/StatusNotifierWatcher', WATCHER, 'RegisterStatusNotifierItem', 's', NAME], check=True, capture_output=True)
                wait(lambda: len(icons()) == 2, 'service-name item registered once')
                props = subprocess.run(['busctl', '--user', 'get-property', WATCHER, '/StatusNotifierWatcher', WATCHER, 'RegisteredStatusNotifierItems'], check=True, capture_output=True, text=True)
                assert props.stdout.startswith('as 2 '), props.stdout
                # An existing watcher must be reused by a second host.
                second = runtime / 'second'
                second.mkdir()
                other, other_log = spawn_compositor(second, outputs='1', scale=scale,
                    renderer=os.environ.get('REDIWM_TEST_RENDERER', 'pixman'),
                    env_extra={'WLR_RENDERER_ALLOW_SOFTWARE': '1', 'REDIWM_FORCE_DBUS': '1', 'PULSE_SERVER': 'unix:/nonexistent/rediwm-test-audio'})
                try:
                    with IPCClient(second) as other_ipc:
                        wait(lambda: len(other_ipc.get_shell_state()['taskbars'][0]['app_tray']) == 2,
                             'second host discovers existing watcher items')
                finally:
                    stop_process(other)
                    other_log.close()
                change('exported')
                change('delay')
                time.sleep(.15)
                click_icon(0x111)
                ipc.click_at(5, 5)
                time.sleep(.4)
                assert menu() is None, 'late layout reply must not reopen dismissed menu'
                click_icon(0x111)
                stop_process(fixture)
                wait(lambda: len(icons()) == 0, 'exited app removed')
                assert menu() is None, 'exit during menu request closes it'
                assert proc.poll() is None
                print(f'tray scale {scale}: PASS')
        except Exception:
            print((runtime / 'compositor.log').read_text()[-12000:], file=sys.stderr)
            raise
        finally:
            stop_process(fixture)
            stop_process(proc)
            log.close()


if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == '--service':
        service(sys.argv[2])
    elif '--private' not in sys.argv:
        raise SystemExit(subprocess.call(['dbus-run-session', '--', sys.executable, __file__, '--private']))
    else:
        for scale in ('1', '1.5'): test(scale)

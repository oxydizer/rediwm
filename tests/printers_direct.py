#!/usr/bin/env python3
"""Direct libcups against private scripted schedulers, never the host CUPS.

The native API checks exercise actual libcups HTTP/IPP and authentication. The
UI check runs the real Settings page with no cups-pk-helper on its private
system bus: administration then goes through the rediwm-cups helper process,
which must be the only process that maps libcups.
"""
import base64
import ctypes
import json
import os
from pathlib import Path
import select
import socketserver
import struct
import subprocess
import sys
import tempfile
import time

from printers import (SetupScheduler, CUPS_CONNECT_HOOK, request_attributes,
                      attribute, cups_ready, IPCClient, UIDriver, spawn_compositor,
                      stop_process, wait_for)


class DirectHandler(socketserver.StreamRequestHandler):
    def handle(self):
        try:
            line = self.rfile.readline().decode().split()
            if not line:
                return
            method, path = line[:2]
            headers = {}
            while True:
                line = self.rfile.readline()
                if line in (b'\r\n', b'\n', b''):
                    break
                key, value = line.decode().split(':', 1)
                headers[key.lower()] = value.strip()
            protected = path.startswith('/admin')
            # Inventory GET/POST remains available to the independent reader.
            if self.server.auth and protected and headers.get('authorization') != 'Basic ' + base64.b64encode(b'fixture-admin:fixture-secret').decode():
                self.server.challenges += 1
                self.wfile.write(b'HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Basic realm="private fixture"\r\nContent-Length: 0\r\nConnection: close\r\n\r\n')
                return
            if headers.get('expect', '').lower() == '100-continue':
                self.wfile.write(b'HTTP/1.1 100 Continue\r\n\r\n')
                self.wfile.flush()
            if method == 'GET':
                name = path.rsplit('/', 1)[-1].removesuffix('.ppd')
                if name not in self.server.state()['queues']:
                    status, response = 404, b''
                else:
                    status, ipp = self.server.reply(0x400f, {'_request_id': 1, 'printer-uri': 'ipp://localhost/printers/' + name})
                    response = ipp[ipp.index(b'*PPD-Adobe'):]
                    # libcups' PPD parser expects these required headers.
                    response = response.replace(b'*OpenGroup:', b'*FormatVersion: "4.3"\n*FileVersion: "1.0"\n*LanguageVersion: English\n*LanguageEncoding: ISOLatin1\n*PCFileName: "FIXTURE.PPD"\n*Manufacturer: "Fixture"\n*Product: "(Fixture)"\n*ModelName: "Fixture"\n*NickName: "Fixture"\n*PSVersion: "(3010) 0"\n*OpenGroup:', 1)
            else:
                if headers.get('transfer-encoding') == 'chunked':
                    chunks = []
                    while True:
                        size = int(self.rfile.readline().strip(), 16)
                        if not size:
                            self.rfile.readline()
                            break
                        chunks.append(self.rfile.read(size))
                        self.rfile.read(2)
                    body = b''.join(chunks)
                else:
                    body = self.rfile.read(int(headers.get('content-length', '0')))
                fields = request_attributes(body)
                fields['_request_id'] = struct.unpack_from('!I', body, 4)[0]
                operation = struct.unpack_from('!H', body, 2)[0]
                if self.server.stall and path.startswith('/admin'):
                    self.server.release.wait(30)
                status, response = self.server.reply(operation, fields)
            self.wfile.write(f'HTTP/1.1 {status} Fixture\r\nContent-Type: application/ipp\r\nContent-Length: {len(response)}\r\nConnection: close\r\n\r\n'.encode() + response)
        except (BrokenPipeError, ConnectionResetError, TimeoutError):
            pass


class DirectScheduler(SetupScheduler):
    def __init__(self, path, state):
        self.auth = False
        self.challenges = 0
        self.stall = False
        self.deny = None
        self.class_member = False
        super().__init__(path, state)
        self.RequestHandlerClass = DirectHandler

    def reply(self, operation, fields):
        state = self.state()
        name = fields.get('printer-uri', '').rsplit('/', 1)[-1]
        status = 0
        if operation == self.deny:
            status = 0x403
        elif operation == 0x000b and name not in state['queues']:
            status = 0x406
        elif operation in (0x4003, 0x4004, 0x400a, 0x10, 0x11, 0x4008, 0x4009):
            with self.lock:
                self.events.append((operation, dict(fields)))
                if operation == 0x4004:
                    state['queues'].pop(name, None)
                elif operation == 0x400a:
                    state['default'] = name
                else:
                    queue = state['queues'].setdefault(name, {'uri': '', 'options': {}, 'enabled': False, 'accepting': False})
                    if operation == 0x4003:
                        if 'device-uri' in fields: queue['uri'] = fields['device-uri']
                        if 'printer-info' in fields: queue['info'] = fields['printer-info']
                        for key, value in fields.items():
                            if key.endswith('-default'):
                                if value is None: queue['options'].pop(key[:-8], None)
                                else: queue['options'][key[:-8]] = value
                        document = fields.get('_document', b'')
                        if document:
                            for line in document.decode().splitlines():
                                if line.startswith('*Default'):
                                    key, value = line[8:].split(':', 1)
                                    queue['options'][key] = value.strip()
                    elif operation in (0x10, 0x11): queue['enabled'] = operation == 0x11
                    elif operation in (0x4008, 0x4009): queue['accepting'] = operation == 0x4008
                self.state_path.write_text(json.dumps(state))
        else:
            if operation not in (0x400b, 0x4005):
                return super().reply(operation, fields)
        response = struct.pack('!BBHI', 2, 0, status, fields['_request_id'])
        response += b'\x01' + attribute(0x47, 'attributes-charset', 'utf-8') + attribute(0x48, 'attributes-natural-language', 'en')
        if operation == 0x4005 and self.class_member:
            response += b'\x04' + attribute(0x42, 'printer-name', 'FixtureClass') + attribute(0x42, 'member-names', 'Label_Test')
        if operation == 0x400b and not status:
            for uri in ('usb://Fixture/Label?serial=direct', 'file:/tmp/forbidden'):
                response += b'\x04' + attribute(0x45, 'device-uri', uri)
                response += attribute(0x41, 'device-info', 'Direct fixture')
                response += attribute(0x41, 'device-make-and-model', 'Fixture Label')
                response += attribute(0x41, 'device-id', 'MFG:Fixture;MDL:Label;')
                response += attribute(0x44, 'device-class', 'direct')
        return 200, response + b'\x03'


def fixture(tmp):
    state = tmp / 'queues.json'
    state.write_text(json.dumps({'queues': {'Label_Test': {'uri': 'usb://Fixture/Label?serial=existing', 'enabled': False, 'accepting': False, 'info': 'Fixture', 'options': {}}}, 'default': 'Label_Test'}))
    source = tmp / 'connect.c'
    source.write_text(CUPS_CONNECT_HOOK)
    hook = tmp / 'connect.so'
    subprocess.run(['cc', '-shared', '-fPIC', '-o', str(hook), str(source), '-ldl'], check=True)
    return DirectScheduler(tmp / 'cups.sock', state), hook


def native_child(library):
    lib = ctypes.CDLL(library)
    ptr = ctypes.c_void_p
    lib.rediwm_cups_create.restype = ptr
    for name in ('destroy', 'fd', 'state', 'result', 'cancel', 'finish'):
        getattr(lib, 'rediwm_cups_' + name).argtypes = [ptr]
    lib.rediwm_cups_submit.argtypes = [ptr, ctypes.c_char_p, ctypes.c_int, ctypes.POINTER(ctypes.c_char_p), ctypes.c_int]
    lib.rediwm_cups_credentials.argtypes = [ptr, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_ulong]
    worker = lib.rediwm_cups_create()
    assert worker
    try:
        def command(method, args=(), reset=1, auth=False):
            argv = (ctypes.c_char_p * len(args))(*(x.encode() for x in args))
            assert lib.rediwm_cups_submit(worker, method.encode(), len(args), argv, reset) == 0
            fd = lib.rediwm_cups_fd(worker)
            challenges = 0
            while True:
                assert select.select([fd], [], [], 25)[0], (method, 'no worker result')
                os.read(fd, 8)
                state = lib.rediwm_cups_state(worker)
                if state == 1:
                    challenges += 1
                    assert auth, method
                    password = b'wrong' if challenges == 1 or mode == 'bad-auth' else b'fixture-secret'
                    lib.rediwm_cups_credentials(worker, b'fixture-admin', password, len(password))
                elif state == 2:
                    result = lib.rediwm_cups_result(worker)
                    lib.rediwm_cups_finish(worker)
                    return result
        mode = sys.argv[3]
        if mode == 'class':
            assert command('PrinterRename', ['Label_Test', 'ClassBlocked']) == 5
        elif mode == 'denied':
            assert command('PrinterSetInfo', ['Label_Test', 'Must not change']) != 0
        elif mode == 'partial':
            assert command('PrinterRename', ['Label_Test', 'Partial']) == 4
        elif mode == 'active-jobs':
            assert command('PrinterRename', ['Label_Test', 'Blocked']) != 0
        elif mode == 'bad-auth':
            assert command('PrinterSetInfo', ['Label_Test', 'Must not change'], auth=True) != 0
        elif mode == 'auth':
            assert command('PrinterSetInfo', ['Label_Test', 'Authenticated'], auth=True) == 0
        elif mode == 'cancel':
            argv = (ctypes.c_char_p * 2)(b'Label_Test', b'cancelled')
            assert lib.rediwm_cups_submit(worker, b'PrinterSetInfo', 2, argv, 1) == 0
            assert select.select([lib.rediwm_cups_fd(worker)], [], [], 5)[0]
            os.read(lib.rediwm_cups_fd(worker), 8)
            assert lib.rediwm_cups_state(worker) == 1
            start = time.monotonic()
            lib.rediwm_cups_destroy(worker)
            worker = None
            assert time.monotonic() - start < 1
        elif mode == 'deadline':
            start = time.monotonic()
            assert command('PrinterSetInfo', ['Label_Test', 'Uncertain']) != 0
            assert 18 < time.monotonic() - start < 24, 'CUPS I/O must have an absolute deadline'
        elif mode == 'stall':
            argv = (ctypes.c_char_p * 2)(b'Label_Test', b'stalled')
            assert lib.rediwm_cups_submit(worker, b'PrinterSetInfo', 2, argv, 1) == 0
            time.sleep(.3)
            start = time.monotonic()
            lib.rediwm_cups_destroy(worker)
            worker = None
            assert time.monotonic() - start < 2
        else:
            assert command('DevicesGet') == 0
            assert command('PrinterAdd', ['Direct', 'usb://Fixture/Label?serial=direct', 'raw', 'Direct fixture', '']) == 0
            assert command('PrinterAdd', ['Direct', 'usb://Fixture/other', 'raw', 'Collision', '']) != 0
            for method, args in (
                ('PrinterSetEnabled', ['Direct', 'true']),
                ('PrinterSetAcceptJobs', ['Direct', 'true', '']),
                ('PrinterSetDefault', ['Direct']),
                ('PrinterSetInfo', ['Direct', 'Renamed description']),
                ('PrinterSetDevice', ['Direct', 'socket://127.0.0.1:9100']),
                ('PrinterAddOptionDefault', ['Direct', 'printer-resolution', '203dpi']),
                ('PrinterDeleteOptionDefault', ['Direct', 'printer-resolution']),
                ('PrinterAddOption', ['Direct', 'Darkness', '12']),
                ('PrinterRename', ['Direct', 'Cloned']),
                ('PrinterDelete', ['Cloned']),
            ):
                assert command(method, args) == 0, method
                if method == 'PrinterAddOption':
                    state = json.loads((Path(os.environ['HOME']) / 'queues.json').read_text())
                    assert state['queues']['Direct']['options']['Darkness'] == '12'
                if method == 'PrinterRename':
                    state = json.loads((Path(os.environ['HOME']) / 'queues.json').read_text())
                    assert 'Direct' not in state['queues']
                    assert state['default'] == 'Cloned'
                    assert state['queues']['Cloned']['options']['Darkness'] == '12'
    finally:
        if worker: lib.rediwm_cups_destroy(worker)


def native_tests():
    with tempfile.TemporaryDirectory(prefix='rediwm-direct-native-') as directory:
        tmp = Path(directory)
        scheduler, hook = fixture(tmp)
        lib = tmp / 'direct.so'
        subprocess.run(['cc', '-shared', '-fPIC', '-g', '-Wno-deprecated-declarations', '-o', str(lib), 'src/printing/direct.c', '-lcups', '-lpthread'], check=True)
        env = {**os.environ, 'HOME': str(tmp), 'LD_PRELOAD': str(hook), 'PRINTER_FIXTURE_CUPS_SOCKET': str(tmp / 'cups.sock'), 'CUPS_USER': 'fixture-admin'}
        try:
            for mode in ('operations', 'auth', 'bad-auth', 'cancel', 'denied', 'class', 'active-jobs', 'partial', 'stall', 'deadline'):
                scheduler.auth = mode in ('auth', 'bad-auth', 'cancel')
                scheduler.deny = 0x4003 if mode == 'denied' else 0x4004 if mode == 'partial' else None
                scheduler.active_job = mode == 'active-jobs'
                scheduler.class_member = mode == 'class'
                scheduler.stall = mode in ('stall', 'deadline')
                subprocess.run([sys.executable, __file__, '--native-child', str(lib), mode], env=env, check=True, timeout=60)
            assert 'Cloned' not in scheduler.state()['queues']
            assert 'Partial' in scheduler.state()['queues']
            assert 'Blocked' not in scheduler.state()['queues']
            assert 'ClassBlocked' not in scheduler.state()['queues']
            assert scheduler.state()['queues']['Label_Test']['info'] == 'Authenticated'
        finally:
            scheduler.release.set()
            scheduler.close()
    print('Direct libcups operations, authentication retry and cancellation passed', flush=True)


def helper_pids(compositor, zombies=False):
    """rediwm-cups children of the compositor; a zombie counts only if asked."""
    found = []
    for entry in Path('/proc').iterdir():
        if not entry.name.isdigit():
            continue
        try:
            stat = entry.joinpath('stat').read_text()
        except OSError:
            continue
        comm = stat[stat.index('(') + 1:stat.rindex(')')]
        fields = stat[stat.rindex(')') + 2:].split()
        if comm == 'rediwm-cups' and int(fields[1]) == compositor and (zombies or fields[0] != 'Z'):
            found.append(int(entry.name))
    return found


def mapped(pid, library):
    return library in Path(f'/proc/{pid}/maps').read_text()


def linked(program, library):
    return library in subprocess.run(['ldd', str(program)], capture_output=True, text=True, check=True).stdout


def ui_test(scale):
    with tempfile.TemporaryDirectory(prefix='rediwm-direct-ui-') as directory:
        tmp = Path(directory)
        scheduler, hook = fixture(tmp)
        bus = subprocess.Popen(['dbus-daemon', '--session', '--nofork', '--print-address=1'], stdout=subprocess.PIPE, text=True)
        process = log = None
        try:
            assert select.select([bus.stdout], [], [], 10)[0]
            address = bus.stdout.readline().strip()
            process, log = spawn_compositor(tmp, scale=scale, config_content='[compositor]\nxwayland = false\n', env_extra={
                'CUPS_SERVER': '/run/cups/cups.sock', 'CUPS_ENCRYPTION': 'Never',
                'LD_PRELOAD': str(hook), 'PRINTER_FIXTURE_CUPS_SOCKET': str(tmp / 'cups.sock'),
                'HOME': str(tmp), 'XDG_CONFIG_HOME': str(tmp / 'config'), 'XDG_DATA_HOME': str(tmp / 'data'), 'XDG_CACHE_HOME': str(tmp / 'cache'),
                'DBUS_SESSION_BUS_ADDRESS': '', 'DBUS_SYSTEM_BUS_ADDRESS': address,
                'PIPEWIRE_RUNTIME_DIR': str(tmp), 'PULSE_SERVER': 'unix:/nonexistent-rediwm-printers-test-pulse',
            })
            with IPCClient(tmp, timeout=15) as ipc:
                ui = UIDriver(ipc)
                def click(name):
                    wait_for(lambda: not ui.find(name, panel='control_center')['is_disabled'], name, timeout=15)
                    ui.click(ui.scroll_into_view(name, panel='control_center'), panel='control_center')
                    ui.wait_settled('control_center')
                ipc.open_control_center()
                ui.wait_settled('control_center')
                click('printers')
                wait_for(lambda: cups_ready(ui), 'direct page loaded', timeout=15)
                assert not helper_pids(process.pid), 'a read-only page must not start the administration helper'
                click('printers_resume')
                wait_for(lambda: scheduler.state()['queues']['Label_Test']['enabled'], 'helper-absent resume')
                wait_for(lambda: cups_ready(ui), 'refresh after resume')
                helpers = helper_pids(process.pid)
                assert len(helpers) == 1, helpers
                # The helper is non-dumpable, so its maps are not readable: check the link.
                assert linked('zig-out/bin/rediwm-cups', 'libcups') and not linked('zig-out/bin/rediwm', 'libcups')
                for library in ('libcups', 'libgnutls', 'libnettle', 'libp11-kit'):
                    assert not mapped(process.pid, library), f'the compositor must not map {library}'
                scheduler.auth = True
                click('printers_manage')
                click('printers_accepting')
                wait_for(lambda: any(w.get('name') == 'printers_auth_password' for w in ui.widgets()), 'CUPS password UI')
                click('printers_auth_user')
                ipc.key(29, True); ipc.key_press('a'); ipc.key(29, False)
                ipc.type_text('fixture-admin')
                click('printers_auth_password')
                ipc.type_text('fixture-secret')
                assert 'fixture-secret' not in json.dumps(ui.widgets()), 'secret must not be exposed by widget inspection'
                click('printers_auth_submit')
                wait_for(lambda: scheduler.state()['queues']['Label_Test']['accepting'], 'authenticated administration')
                wait_for(lambda: cups_ready(ui), 'inventory refresh')
                click('printers_accepting')
                wait_for(lambda: any(w.get('name') == 'printers_auth_password' for w in ui.widgets()), 'new operation must request fresh credentials')
                click('printers_auth_cancel')
                wait_for(lambda: not any(w.get('name') == 'printers_auth_password' for w in ui.widgets()), 'cancel clears prompt')
                # The helper dying while a password prompt is outstanding fails that
                # request and leaves the page usable: the next one starts a new helper.
                click('printers_accepting')
                wait_for(lambda: any(w.get('name') == 'printers_auth_password' for w in ui.widgets()), 'prompt before the helper dies')
                helpers = helper_pids(process.pid)
                assert len(helpers) == 1, helpers
                os.kill(helpers[0], 9)
                wait_for(lambda: not any(w.get('name') == 'printers_auth_password' for w in ui.widgets()), 'helper death ends the prompt')
                wait_for(lambda: not helper_pids(process.pid, zombies=True), 'dead helper is reaped', timeout=5)
                # Hide while a second prompt is outstanding; the new helper's request
                # ends promptly with the page.
                click('printers_accepting')
                wait_for(lambda: any(w.get('name') == 'printers_auth_password' for w in ui.widgets()), 'hide challenge')
                start = time.monotonic()
                click('general')
                assert time.monotonic() - start < 3
                wait_for(lambda: not helper_pids(process.pid, zombies=True), 'hiding the page ends the helper', timeout=5)
                assert scheduler.state()['queues']['Label_Test']['accepting']
                scheduler.auth = False
                click('printers')
                wait_for(lambda: cups_ready(ui), 'reopened direct page')
                click('printers_add')
                click('printers_discover')
                wait_for(lambda: any(w.get('name') == 'printers_device_0' for w in ui.widgets()), 'direct discovery')
                assert not any(w.get('name') == 'printers_device_1' for w in ui.widgets()), 'unsafe backend URI must be filtered'
                # The helper dying between requests is invisible: the next one starts a new helper.
                helpers = helper_pids(process.pid)
                assert len(helpers) == 1, helpers
                os.kill(helpers[0], 9)
                wait_for(lambda: not helper_pids(process.pid, zombies=True), 'killed helper is reaped', timeout=5)
                click('printers_device_0')
                click('printers_name')
                ipc.key(29, True); ipc.key_press('a'); ipc.key(29, False)
                ipc.type_text('Ui_Direct')
                click('printers_create')
                wait_for(lambda: scheduler.state()['queues'].get('Ui_Direct', {}).get('accepting'), 'direct add/enable/accept chain')
                created = scheduler.state()['queues']['Ui_Direct']
                assert created['enabled'] and created['uri'] == 'usb://Fixture/Label?serial=direct'
                assert not scheduler.printed, 'administration must not print a document'
                wait_for(lambda: cups_ready(ui), 'direct add refreshed')
                # The helper's three threads (poll loop, CUPS worker, I/O watchdog) must
                # sleep without timed wakes at idle.
                helpers = helper_pids(process.pid)
                assert len(helpers) == 1, helpers
                def counters():
                    result = {}
                    for task in Path(f'/proc/{helpers[0]}/task').iterdir():
                        try:
                            if task.joinpath('comm').read_text().strip() not in ('rediwm-cups', 'rediwm-cups-io'): continue
                            fields = dict(line.split(':', 1) for line in task.joinpath('status').read_text().splitlines())
                            result[task.name] = int(fields['voluntary_ctxt_switches'])
                        except FileNotFoundError: pass
                    return result
                time.sleep(.3)
                before = counters()
                time.sleep(.6)
                assert len(before) == 3 and counters() == before, 'native administration must not poll at idle'
        finally:
            if process: stop_process(process)
            if log: log.close()
            bus.terminate(); bus.wait(timeout=5)
            scheduler.close()
    print('Helper-absent Settings and secure CUPS challenge lifecycle passed at scale', scale, flush=True)


if __name__ == '__main__':
    os.umask(0o077)
    if len(sys.argv) > 1 and sys.argv[1] == '--native-child':
        native_child(sys.argv[2])
    else:
        native_tests()
        ui_test(os.environ.get('REDIWM_TEST_SCALE', '1'))

#!/usr/bin/env python3
"""Creates a private dbus-run-session; build.zig supplies a test-only service."""
import concurrent.futures
import json
import os
import select
import subprocess
import sys
import time
import socket
import struct
import tempfile

NAME = 'org.rediwm.Test'
PATH = '/org/rediwm/Test'


def call(member, signature=None, *args, check=True):
    cmd = ['busctl', '--user', '--timeout=3', 'call', NAME, PATH, NAME, member]
    if signature is not None:
        cmd += [signature, *args]
    return subprocess.run(cmd, capture_output=True, text=True, timeout=5, check=check)


def receive_exact(peer, n):
    result = b''
    while len(result) < n:
        chunk = peer.recv(n - len(result))
        assert chunk, 'unexpected EOF'
        result += chunk
    return result


def receive_message(peer):
    header = receive_exact(peer, 16)
    endian = '<' if header[0] == ord('l') else '>'
    body, serial, fields = struct.unpack_from(endian + 'III', header, 4)
    return serial, header + receive_exact(peer, ((fields + 7) & ~7) + body)


def fake_peers(binary):
    """Adversarial local endpoints: authentication and framing, no bus involved."""
    for scenario in ('reject', 'auth_timeout', 'auth_overlong', 'oversized',
                     'truncated', 'bad_padding', 'fragmented_big_endian', 'abstract'):
        with tempfile.TemporaryDirectory(prefix='rediwm-dbus-') as directory:
            endpoint = directory + '/bus'
            address = 'unix:path=' + endpoint
            if scenario == 'abstract':
                endpoint = '\0' + directory
                address = 'unix:abstract=' + directory
            with socket.socket(socket.AF_UNIX) as listener:
                listener.bind(endpoint)
                listener.listen(1)
                listener.settimeout(4)
                env = dict(os.environ, DBUS_SESSION_BUS_ADDRESS=
                           'unix:path=' + directory + '/absent;' + address)
                child = subprocess.Popen([binary], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                try:
                    peer, _ = listener.accept()
                    with peer:
                        peer.settimeout(4)
                        auth = b''
                        while not auth.endswith(b'\r\n'):
                            auth += peer.recv(1)
                        assert auth == b'\0AUTH EXTERNAL ' + str(os.getuid()).encode().hex().encode() + b'\r\n'
                        if scenario == 'reject':
                            peer.sendall(b'REJECTED EXTERNAL\r\n')
                        elif scenario == 'auth_timeout':
                            assert child.wait(timeout=4) != 0
                        elif scenario == 'auth_overlong':
                            peer.sendall(b'X' * 1024)
                        else:
                            for byte in b'OK ' + b'0' * 32 + b'\r\n':
                                peer.sendall(bytes([byte]))
                                time.sleep(.001)
                            assert receive_exact(peer, 7) == b'BEGIN\r\n'
                            serial, hello = receive_message(peer)
                            assert b'Hello\0' in hello
                            if scenario == 'oversized':
                                peer.sendall(struct.pack('<BBBBIII', ord('l'), 2, 0, 1, 0xffffffff, 1, 0))
                            elif scenario == 'truncated':
                                peer.sendall(b'l\2\0\1')
                            else:
                                # Independently encode a big-endian Hello reply.
                                fields = b'\5\1u\0' + struct.pack('>I', serial)
                                fields += b'\10\1g\0\1s\0'
                                # Include the bus driver's sender header.
                                fields += b'\0' + b'\7\1s\0' + struct.pack('>I', 20) + b'org.freedesktop.DBus\0'
                                body = struct.pack('>I', 6) + b':1.999\0'
                                header = struct.pack('>BBBBIII', ord('B'), 2, 0, 1, len(body), 1, len(fields)) + fields
                                message = header + b'\0' * (-len(header) % 8) + body
                                if scenario == 'bad_padding':
                                    message = message[:len(header)] + b'\1' + message[len(header) + 1:]
                                    peer.sendall(message)
                                else:
                                    for byte in message:
                                        peer.sendall(bytes([byte]))
                                        time.sleep(.001)
                                    _, request = receive_message(peer)
                                    assert b'RequestName\0' in request, request
                    stdout, stderr = child.communicate(timeout=4)
                    assert child.returncode != 0, scenario
                    assert b'panic' not in stderr and b'Segmentation' not in stderr, (scenario, stderr)
                finally:
                    if child.poll() is None:
                        child.kill()
                    child.communicate(timeout=3)
    print('D-Bus: rejected/stalled auth, malformed/oversized/truncated frames and fragmented big-endian replies passed')


FAKE_SYSTEMD = r'''
import json
import warnings
warnings.simplefilter('ignore', DeprecationWarning)  # register_object's closure-less form
from gi.repository import Gio, GLib
XML = ('<node><interface name="org.freedesktop.systemd1.Manager"><method name="SetEnvironment">'
       '<arg type="as" direction="in"/></method></interface></node>')
conn = Gio.bus_get_sync(Gio.BusType.SESSION)
def call(c, sender, path, iface, method, params, invocation):
    print(json.dumps(params.unpack()[0]), flush=True)
    invocation.return_value(None)
conn.register_object('/org/freedesktop/systemd1', Gio.DBusNodeInfo.new_for_xml(XML).interfaces[0], call, None, None)
Gio.bus_own_name_on_connection(conn, 'org.freedesktop.systemd1', Gio.BusNameOwnerFlags.NONE,
                               lambda *_: print('ready', flush=True), None)
GLib.MainLoop().run()
'''


def read_line(proc, timeout=5):
    assert select.select([proc.stdout], [], [], timeout)[0], 'no output from fake systemd'
    return proc.stdout.readline().strip()


def activation_env(binary):
    """session/activation.zig's publish, which once queued its call and dropped it unsent."""
    # A private bus has no systemd user manager: the bus's own activation
    # environment still accepts, so the publish succeeds and logs the refusal.
    lone = subprocess.run([binary, '--activation-env'], capture_output=True, text=True, timeout=15)
    assert lone.returncode == 0, lone
    assert 'SetEnvironment refused' in lone.stderr, lone.stderr
    fake = subprocess.Popen([sys.executable, '-c', FAKE_SYSTEMD], stdout=subprocess.PIPE, text=True)
    try:
        assert read_line(fake) == 'ready'
        both = subprocess.run([binary, '--activation-env'], capture_output=True, text=True, timeout=15)
        assert both.returncode == 0 and 'refused' not in both.stderr, both
        assert json.loads(read_line(fake)) == ['REDIWM_TEST_ACTIVATION=one', 'WAYLAND_DISPLAY=wayland-test']
    finally:
        fake.terminate()
        fake.wait(timeout=3)
    print('D-Bus: activation environment reaches the bus and systemd, with each refusal logged')


def main():
    # Always re-exec onto a fresh bus, even when invoked directly.
    if '--private' not in sys.argv:
        raise SystemExit(subprocess.call(['dbus-run-session', '--', sys.executable,
                                         __file__, sys.argv[1], '--private']))
    fake_peers(sys.argv[1])
    activation_env(sys.argv[1])
    # Exercise openSystem without ever opening the host system bus.
    service = subprocess.Popen([sys.argv[1], '--system'],
                               env=dict(os.environ, DBUS_SYSTEM_BUS_ADDRESS=os.environ['DBUS_SESSION_BUS_ADDRESS']),
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    monitor = None
    try:
        deadline = time.monotonic() + 5
        while True:
            assert service.poll() is None, service.communicate()
            result = call('Stats', check=False)
            if result.returncode == 0 and result.stdout.strip() == 'u 2':
                break
            assert time.monotonic() < deadline, result.stderr
            time.sleep(.02)
        echo = call('Echo', 's', 'hello café').stdout.strip()
        assert echo in ('s "hello café"', 's "hello caf\\303\\251"'), repr(echo)
        for member in ('Delayed', 'DelayedFail'):
            started = time.monotonic()
            result = call(member, check=False)
            assert time.monotonic() - started >= .9, result
            if member == 'Delayed':
                assert result.returncode == 0, result
            else:
                assert result.returncode != 0 and 'delayed failure' in result.stderr, result
        # Exercise many serials and clients, including messages larger than read chunks.
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            results = list(pool.map(lambda i: call('Echo', 's', f'message {i}').stdout.strip(), range(40)))
        assert results == [f's "message {i}"' for i in range(40)]
        large = 'x' * 100000
        assert call('Echo', 's', large).stdout.strip() == f's "{large}"'
        failed = call('Fail', check=False)
        assert failed.returncode != 0 and 'expected failure' in failed.stderr, failed
        unknown = call('Absent', check=False)
        assert unknown.returncode != 0 and 'No matching method' in unknown.stderr, unknown
        invalid = call('Echo', 'u', '5', check=False)
        assert invalid.returncode != 0 and 'BadSignature' in invalid.stderr, invalid
        # An independent libdbus caller as well as sd-bus (busctl).
        result = subprocess.run(['dbus-send', '--session', '--print-reply', '--dest=' + NAME,
                                 PATH, NAME + '.Echo', 'string:from dbus-send'],
                                check=True, text=True, capture_output=True, timeout=5)
        assert 'from dbus-send' in result.stdout
        monitor = subprocess.Popen(['dbus-monitor', '--session',
                                    "type='signal',interface='org.rediwm.Test',member='Changed'"],
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        # Wait for monitor's NameAcquired before emitting (no registration race).
        poller = select.poll()
        poller.register(monitor.stdout, select.POLLIN)
        assert poller.poll(3000), 'monitor not ready'
        time.sleep(.05)
        call('Emit')
        time.sleep(.05)
        monitor.terminate()
        output, _ = monitor.communicate(timeout=3)
        assert 'member=Changed' in output and 'changed' in output, output
        monitor = None

        # Verify incoming signal dispatch received the emitted signal
        deadline = time.monotonic() + 3
        while True:
            res = call('Signals', check=False)
            if res.returncode == 0 and res.stdout.strip() == 'u 1':
                break
            assert time.monotonic() < deadline, res.stderr
            time.sleep(.02)

        # External signal from dbus-send also dispatches to subscription
        subprocess.run(['dbus-send', '--session', '--type=signal', PATH,
                        NAME + '.Changed', 'string:changed'], check=True, timeout=5)
        deadline = time.monotonic() + 3
        while True:
            res = call('Signals', check=False)
            if res.returncode == 0 and res.stdout.strip() == 'u 2':
                break
            assert time.monotonic() < deadline, res.stderr
            time.sleep(.02)

        # Unsubscribe stops further signal delivery
        call('Unsub')
        time.sleep(.02)
        call('Emit')
        time.sleep(.05)
        assert call('Signals').stdout.strip() == 'u 2'

        # Quit is explicitly one-way. Its handler deliberately sends no reply.
        subprocess.run(['dbus-send', '--session', '--type=method_call', '--dest=' + NAME,
                        PATH, NAME + '.Quit'], check=True, timeout=5)
        assert service.wait(timeout=5) == 0, service.communicate()
        print('D-Bus: Hello, name ownership, client calls, timeouts, concurrent/large calls, replies, errors, signals and subscriptions passed')
    finally:
        if monitor is not None:
            monitor.terminate()
            monitor.communicate(timeout=3)
        if service.poll() is None:
            service.terminate()
        service.communicate(timeout=3)


if __name__ == '__main__':
    main()

#!/usr/bin/env python3
"""Supervisor readiness/teardown tests against the rediwm-session binary.

Never contacts either host bus: the system bus address points nowhere, so
publication stays disabled. Publication leases are unit-tested in
src/session/publication.zig; tests/session_bus.py covers real bus calls.
Usage: session_services.py <rediwm-session binary>
"""
import os
from pathlib import Path
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest

SUPERVISOR = Path(sys.argv.pop(1) if len(sys.argv) > 1 else Path(__file__).resolve().parents[1] / 'zig-out/bin/rediwm-session')


class SupervisorTests(unittest.TestCase):
    def start(self, directory, script):
        tmp = Path(directory)
        shutil.copy2(SUPERVISOR, tmp / 'rediwm-session')
        fake = tmp / 'rediwm'
        fake.write_text('#!/usr/bin/env python3\n' + script)
        fake.chmod(0o700)
        home = tmp / 'home'
        home.mkdir()
        env = {**os.environ, 'HOME': str(home), 'DBUS_SYSTEM_BUS_ADDRESS': 'unix:path=/nonexistent/rediwm-test-bus'}
        env.pop('XDG_STATE_HOME', None)
        return subprocess.Popen([str(tmp / 'rediwm-session')], env=env), home / '.local/state/rediwm/session.log'

    def run_fake(self, script):
        with tempfile.TemporaryDirectory(prefix='rediwm-supervisor-') as directory:
            proc, log = self.start(directory, script)
            code = proc.wait(timeout=30)
            self.assertEqual(code, 0, log.read_text() if log.exists() else '')
            return log.read_text()

    def test_delayed_readiness_and_multiple_handshakes(self):
        self.run_fake('''import json, os, socket, time
s = socket.socket(fileno=int(os.environ['REDIWM_SESSION_FD']))
time.sleep(.1)
for display in ('wayland-7', 'wayland-8'):
    s.send(json.dumps({'WAYLAND_DISPLAY': display}).encode())
    assert s.recv(32) == b'ready'
''')

    def test_crash_between_readiness_and_ack_still_restarts(self):
        log = self.run_fake('''import os, signal, socket
from pathlib import Path
counter = Path(__file__ + '.count')
attempt = int(counter.read_text()) + 1 if counter.exists() else 1
counter.write_text(str(attempt))
s = socket.socket(fileno=int(os.environ['REDIWM_SESSION_FD']))
s.send(b'{"WAYLAND_DISPLAY":"wayland-test"}')
if attempt < 3:
    os.kill(os.getpid(), signal.SIGABRT)
assert s.recv(32) == b'ready'
''')
        self.assertEqual(log.count('rediwm-session: restart'), 2, log)

    def test_invalid_readiness_still_releases_direct_launches(self):
        self.run_fake('''import os, socket
s = socket.socket(fileno=int(os.environ['REDIWM_SESSION_FD']))
s.send(b'not json')
assert s.recv(32) == b'ready'
''')

    def test_owned_descendants_die_on_compositor_exit(self):
        with tempfile.TemporaryDirectory() as directory:
            pidpath = Path(directory) / 'pid'
            self.run_fake(f'''import subprocess
p = subprocess.Popen(['/bin/sleep', '60'], start_new_session=True)
open({str(pidpath)!r}, 'w').write(str(p.pid))
''')
            self.assert_dead(int(pidpath.read_text()))

    def test_logout_signal_stops_the_session(self):
        with tempfile.TemporaryDirectory(prefix='rediwm-supervisor-') as directory:
            marker = Path(directory) / 'acked'
            proc, log = self.start(directory, f'''import os, socket, subprocess, time
s = socket.socket(fileno=int(os.environ['REDIWM_SESSION_FD']))
s.send(b'{{"WAYLAND_DISPLAY":"wayland-test"}}')
assert s.recv(32) == b'ready'
helper = subprocess.Popen(['/bin/sleep', '60'])
open({str(marker)!r}, 'w').write(f'{{os.getpid()}} {{helper.pid}}')
time.sleep(60)
''')
            deadline = time.monotonic() + 10
            while not marker.exists() or not marker.read_text():
                self.assertLess(time.monotonic(), deadline, 'fake compositor never acknowledged')
                time.sleep(.05)
            started = time.monotonic()
            proc.send_signal(signal.SIGTERM)
            self.assertEqual(proc.wait(timeout=10), 0, log.read_text())
            self.assertLess(time.monotonic() - started, 3, 'teardown should end once the tree exits')
            for pid in map(int, marker.read_text().split()):
                self.assert_dead(pid)

    def assert_dead(self, pid):
        try:
            fd = os.pidfd_open(pid)
        except ProcessLookupError:
            return
        try:
            self.assertTrue(select.select([fd], [], [], 2)[0], f'owned process {pid} survived')
        finally:
            os.close(fd)


if __name__ == '__main__':
    unittest.main()

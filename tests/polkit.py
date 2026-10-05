#!/usr/bin/env python3
"""Stage 2: real agent transport, fake polkit/logind on a fresh private bus."""
import os
import pwd
import select
import subprocess
import sys
import warnings
import socket
import struct
import tempfile
import threading
import pty
import termios
import signal
import time

if __name__ == '__main__' and '--private' not in sys.argv:
    raise SystemExit(subprocess.call(['dbus-run-session', '--', sys.executable,
                                     __file__, sys.argv[1], '--private']))

warnings.simplefilter('ignore', DeprecationWarning)
from gi.repository import Gio, GLib

AUTH = 'org.freedesktop.PolicyKit1'
AUTH_PATH = '/org/freedesktop/PolicyKit1/Authority'
AUTH_IFACE = AUTH + '.Authority'
AGENT_PATH = '/org/freedesktop/PolicyKit1/AuthenticationAgent'
AGENT_IFACE = AUTH + '.AuthenticationAgent'
BUS = 'org.freedesktop.DBus'
BUS_PATH = '/org/freedesktop/DBus'
events = []
loop = GLib.MainLoop()


def connection():
    return Gio.DBusConnection.new_for_address_sync(
        os.environ['DBUS_SESSION_BUS_ADDRESS'],
        Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION,
        None, None)


def call(conn, name, path, iface, member, signature='()', args=()):
    return conn.call_sync(name, path, iface, member, GLib.Variant(signature, args),
                          None, Gio.DBusCallFlags.NONE, 3000, None)


def own(conn, name):
    assert call(conn, BUS, BUS_PATH, BUS, 'RequestName', '(su)', (name, 4)).unpack() == (1,)


def event(value):
    events.append(value)
    loop.quit()


def wait_event(member, after=0):
    expired = False

    def timeout():
        nonlocal expired
        expired = True
        loop.quit()
        return False

    timer = GLib.timeout_add(5000, timeout)
    try:
        while not expired:
            found = [e for e in events[after:] if e['method'] == member]
            if found:
                return found[-1]
            loop.run()
        raise AssertionError(f'timed out waiting for {member}: {events[after:]}')
    finally:
        if not expired:
            GLib.source_remove(timer)


class Authority:
    def __init__(self, refuse=False, hold=False):
        self.conn = connection()
        self.refuse = refuse
        self.hold = hold
        self.pending = []
        xml = '''<node><interface name="org.freedesktop.PolicyKit1.Authority">
          <method name="RegisterAuthenticationAgent"><arg type="(sa{sv})" direction="in"/>
            <arg type="s" direction="in"/><arg type="s" direction="in"/></method>
          <method name="UnregisterAuthenticationAgent"><arg type="(sa{sv})" direction="in"/>
            <arg type="s" direction="in"/></method>
        </interface></node>'''
        self.conn.register_object(AUTH_PATH, Gio.DBusNodeInfo.new_for_xml(xml).interfaces[0], self.method, None, None)
        own(self.conn, AUTH)

    def method(self, conn, sender, path, iface, method, params, invocation):
        event({'method': method, 'sender': sender, 'args': params.unpack()})
        if method == 'RegisterAuthenticationAgent' and self.hold:
            self.pending.append(invocation)
        elif method == 'RegisterAuthenticationAgent' and self.refuse:
            invocation.return_dbus_error(AUTH + '.Error.Failed', 'An authentication agent already exists')
        else:
            invocation.return_value(None)

    def close(self):
        self.conn.close_sync(None)
        self.pending.clear()


class Logind:
    def __init__(self):
        self.conn = connection()
        xml = '''<node><interface name="org.freedesktop.login1.Manager">
          <method name="GetSessionByPID"><arg type="u" direction="in"/><arg type="o" direction="out"/></method>
        </interface></node>'''
        self.conn.register_object('/org/freedesktop/login1', Gio.DBusNodeInfo.new_for_xml(xml).interfaces[0], self.method, None, None)
        xml = '''<node><interface name="org.freedesktop.DBus.Properties">
          <method name="Get"><arg type="s" direction="in"/><arg type="s" direction="in"/>
            <arg type="v" direction="out"/></method></interface></node>'''
        self.conn.register_object('/org/freedesktop/login1/session/_37', Gio.DBusNodeInfo.new_for_xml(xml).interfaces[0], self.method, None, None)
        own(self.conn, 'org.freedesktop.login1')

    def method(self, conn, sender, path, iface, method, params, invocation):
        event({'method': method, 'args': params.unpack()})
        if method == 'GetSessionByPID':
            invocation.return_value(GLib.Variant('(o)', ('/org/freedesktop/login1/session/_37',)))
        else:
            invocation.return_value(GLib.Variant('(v)', (GLib.Variant('s', '7'),)))


def spawn(mode=None, terminal_fd=None, **overrides):
    env = dict(os.environ, DBUS_SYSTEM_BUS_ADDRESS=os.environ['DBUS_SESSION_BUS_ADDRESS'],
               WLR_BACKENDS='headless', REDIWM_FORCE_POLKIT='1', XDG_SESSION_ID='test-session', LC_ALL='C', USER='not-the-logged-in-user')
    for key, value in overrides.items():
        if value is None:
            env.pop(key, None)
        else:
            env[key] = value
    # An external setsid avoids Python preexec_fn in a multithreaded fixture.
    command = (['setsid', '--ctty'] if terminal_fd is not None else []) + [sys.argv[1]] + ([mode] if mode else [])
    return subprocess.Popen(command, env=env,
                            stdin=subprocess.PIPE if terminal_fd is None else terminal_fd,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)


def status(child, expected):
    assert select.select([child.stdout], [], [], 5)[0], f'no agent status: {expected}'
    assert child.stdout.readline().decode().strip() == expected


def stop(child):
    if child.stdin and not child.stdin.closed:
        child.stdin.close()
    assert child.wait(timeout=5) == 0, child.stderr.read().decode()
    logs = child.stderr.read().decode()
    assert 'SECRET_COOKIE' not in logs and 'PRIVATE_DETAIL' not in logs, logs
    return logs


def expect_error(conn, name, member, signature, args, error):
    try:
        call(conn, name, AGENT_PATH, AGENT_IFACE, member, signature, args)
    except GLib.Error as err:
        assert Gio.DBusError.get_remote_error(err) == error, err
    else:
        raise AssertionError(f'{member} unexpectedly succeeded')


BEGIN_SIGNATURE = '(sssa{ss}sa(sa{sv}))'


def begin_args(identities=None):
    return ('org.test.action', 'Authenticate', 'dialog-password', {'private': 'PRIVATE_DETAIL'},
            'SECRET_COOKIE', identities if identities is not None else
            [('unix-user', {'uid': GLib.Variant('u', os.getuid())})])


class HelperSocket:
    """Independent wire peer. Assert the registering PID also opens the socket."""
    def __init__(self, directory, scenario):
        self.path = directory + '/helper'
        self.scenario = scenario
        self.pid = None
        self.error = None
        self.prompt_count = 0
        self.listener = socket.socket(socket.AF_UNIX)
        self.listener.bind(self.path)
        self.listener.listen(1)
        self.listener.settimeout(5)
        self.thread = threading.Thread(target=self.run, daemon=True)
        self.thread.start()

    def run(self):
        try:
            for _ in range(3 if self.scenario == 'failure' else 1):
                peer, _ = self.listener.accept()
                with peer:
                    peer.settimeout(5)
                    pid, uid, _ = struct.unpack('3i', peer.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))
                    assert pid == self.pid and uid == os.getuid(), (pid, self.pid, uid)
                    with peer.makefile('rb', buffering=0) as stream:
                        assert stream.readline() == pwd.getpwuid(os.getuid()).pw_name.encode() + b'\n'
                        assert stream.readline() == b'SECRET_COOKIE\n'
                        if self.scenario == 'malformed':
                            peer.sendall(b'UNEXPECTED\n')
                            return
                        if self.scenario == 'oversized':
                            peer.sendall(b'x' * 9000 + b'\n')
                            return
                        if self.scenario == 'truncated':
                            peer.sendall(b'PAM_PROMPT_ECHO_OFF unfinished')
                            return
                        if self.scenario == 'hold':
                            peer.sendall(b'PAM_PROMPT_ECHO_OFF Password: \n')
                            assert stream.read(1) == b'', 'cancel did not close helper'
                            return
                        # Split escape and command boundaries, then coalesce lines.
                        for part in (b'PAM_TEXT_', b'INFO first\\nsecond\nPAM_PROMPT_ECHO_', b'OFF Pass\\', b'167ord: \\303\\251\n'):
                            peer.sendall(part)
                        self.prompt_count += 1
                        assert stream.readline() == b'test-response\n'
                        if self.scenario == 'multiple':
                            peer.sendall(b'PAM_ERROR_MSG Try another factor\nPAM_PROMPT_ECHO_ON Code: \n')
                            assert stream.readline() == b'test-response\n'
                        peer.sendall(b'FAILURE\n' if self.scenario == 'failure' else b'SUCCESS\n')
        except Exception as err:
            self.error = err
        finally:
            self.listener.close()

    def finish(self):
        self.thread.join(timeout=6)
        assert not self.thread.is_alive(), 'helper thread did not stop'
        assert self.error is None, repr(self.error)


def helper_conversations(authority, observer):
    for scenario in ('success', 'multiple', 'failure', 'malformed', 'oversized', 'truncated', 'hold', 'disconnect'):
        with tempfile.TemporaryDirectory(prefix='rediwm-polkit-') as directory:
            holding = scenario in ('hold', 'disconnect')
            peer = HelperSocket(directory, 'hold' if holding else scenario)
            child = spawn(mode='--hold' if holding else '--simulate', REDIWM_POLKIT_HELPER_SOCKET=peer.path)
            peer.pid = child.pid
            try:
                start = len(events)
                registration = wait_event('RegisterAuthenticationAgent', start)
                name = registration['sender']
                status(child, 'registered')
                if holding:
                    def completed(conn, result):
                        try:
                            conn.call_finish(result)
                            error = None
                        except GLib.Error as err:
                            error = Gio.DBusError.get_remote_error(err)
                        event({'method': 'BeginDone', 'error': error})
                    authority.conn.call(name, AGENT_PATH, AGENT_IFACE, 'BeginAuthentication',
                                        GLib.Variant(BEGIN_SIGNATURE, begin_args()), None,
                                        Gio.DBusCallFlags.NONE, 5000, None, completed)
                    status(child, 'prompt')
                    if scenario == 'disconnect':
                        child.stdin.write(b'd')
                        assert wait_event('BeginDone', start)['error'] == BUS + '.Error.NoReply'
                    else:
                        # Wrong-cookie cancellation must leave the real request active.
                        call(authority.conn, name, AGENT_PATH, AGENT_IFACE, 'CancelAuthentication', '(s)', ('wrong-cookie',))
                        expect_error(authority.conn, name, 'BeginAuthentication', BEGIN_SIGNATURE, begin_args(), AUTH + '.Error.Cancelled')
                        call(authority.conn, name, AGENT_PATH, AGENT_IFACE, 'CancelAuthentication', '(s)', ('SECRET_COOKIE',))
                        assert wait_event('BeginDone', start)['error'] == AUTH + '.Error.Cancelled'
                elif scenario in ('success', 'multiple'):
                    identities = [('unix-group', {'gid': GLib.Variant('u', os.getgid())})] if scenario == 'success' else None
                    assert call(authority.conn, name, AGENT_PATH, AGENT_IFACE, 'BeginAuthentication', BEGIN_SIGNATURE, begin_args(identities)).unpack() == ()
                    status(child, 'info')
                    status(child, 'prompt')
                    if scenario == 'multiple':
                        status(child, 'error-message')
                        status(child, 'prompt')
                    status(child, 'success')
                else:
                    expect_error(authority.conn, name, 'BeginAuthentication', BEGIN_SIGNATURE, begin_args(), AUTH + '.Error.Cancelled')
                    if scenario == 'failure':
                        for attempt in range(3):
                            status(child, 'info')
                            status(child, 'prompt')
                            status(child, 'error-message' if attempt < 2 else 'failure')
                    else:
                        status(child, 'transport-error')
                peer.finish()
                logs = stop(child)
                assert 'test-response' not in logs
            finally:
                if child.poll() is None:
                    child.kill()
                    child.wait(timeout=3)
    # No identities, wrong variant type, or a missing helper cancels promptly.
    with tempfile.TemporaryDirectory(prefix='rediwm-polkit-') as directory:
        start = len(events)
        child = spawn(mode='--simulate', REDIWM_POLKIT_HELPER_SOCKET=directory + '/absent')
        try:
            name = wait_event('RegisterAuthenticationAgent', start)['sender']
            status(child, 'registered')
            for identities in ([], [('unix-user', {'uid': GLib.Variant('s', 'not-a-uid')})], None):
                expect_error(authority.conn, name, 'BeginAuthentication', BEGIN_SIGNATURE, begin_args(identities), AUTH + '.Error.Cancelled')
            stop(child)
        finally:
            if child.poll() is None:
                child.kill()
                child.wait(timeout=3)
    print('Polkit: helper peer PID, split/coalesced messages, prompts, success/failure, cancellation, EOF, malformed input and missing helper passed')


def terminal_conversations(authority):
    for cancel in (False, True):
        with tempfile.TemporaryDirectory(prefix='rediwm-polkit-tty-') as directory:
            peer = HelperSocket(directory, 'hold' if cancel else 'success')
            master, slave = pty.openpty()
            original = termios.tcgetattr(slave)
            start = len(events)
            child = spawn(mode='--terminal', terminal_fd=slave, REDIWM_POLKIT_HELPER_SOCKET=peer.path)
            peer.pid = child.pid
            try:
                name = wait_event('RegisterAuthenticationAgent', start)['sender']
                status(child, 'registered')
                def completed(conn, result):
                    try:
                        conn.call_finish(result)
                        error = None
                    except GLib.Error as err:
                        error = Gio.DBusError.get_remote_error(err)
                    event({'method': 'TerminalDone', 'error': error})
                authority.conn.call(name, AGENT_PATH, AGENT_IFACE, 'BeginAuthentication',
                                    GLib.Variant(BEGIN_SIGNATURE, begin_args()), None,
                                    Gio.DBusCallFlags.NONE, 5000, None, completed)
                output = b''
                deadline = time.monotonic() + 5
                while b'Password:' not in output:
                    remaining = deadline - time.monotonic()
                    assert remaining > 0 and select.select([master], [], [], remaining)[0], output
                    output += os.read(master, 4096)
                assert not termios.tcgetattr(slave)[3] & termios.ECHO
                if cancel:
                    child.send_signal(signal.SIGTERM)
                else:
                    os.write(master, b'test-response\n')
                assert wait_event('TerminalDone', start)['error'] == (AUTH + '.Error.Cancelled' if cancel else None)
                peer.finish()
                logs = stop(child)
                # Child has exited; drain the finite amount of remaining tty output.
                while select.select([master], [], [], 0)[0]:
                    output += os.read(master, 4096)
                assert termios.tcgetattr(slave) == original
                assert b'test-response' not in output and 'test-response' not in logs
            finally:
                if child.poll() is None:
                    child.kill()
                    child.wait(timeout=3)
                os.close(master)
                os.close(slave)
    print('Polkit: manual terminal driver hides input and restores terminal on success and cancellation')


class ScriptedHelper:
    """Each connection has an expected cookie and terminal behavior."""
    def __init__(self, directory, script):
        self.path = directory + '/helper'
        self.script = script
        self.error = None
        self.accepted = []
        self.listener = socket.socket(socket.AF_UNIX)
        self.listener.bind(self.path)
        self.listener.listen(16)
        self.listener.settimeout(5)
        self.thread = threading.Thread(target=self.run, daemon=True)
        self.thread.start()

    def run(self):
        try:
            for cookie, outcome in self.script:
                peer, _ = self.listener.accept()
                with peer:
                    peer.settimeout(5)
                    with peer.makefile('rb', buffering=0) as stream:
                        assert stream.readline() == pwd.getpwuid(os.getuid()).pw_name.encode() + b'\n'
                        assert stream.readline() == cookie.encode() + b'\n'
                        self.accepted.append(cookie)
                        if outcome == 'eof':
                            continue
                        peer.sendall(b'PAM_PROMPT_ECHO_OFF Password:\n')
                        if outcome == 'cancel':
                            assert stream.read(1) == b'', 'suspension/cancel did not close helper'
                        else:
                            assert stream.readline() == b'test-response\n'
                            peer.sendall(outcome.encode() + b'\n')
        except Exception as err:
            self.error = err
        finally:
            self.listener.close()

    def finish(self):
        self.thread.join(timeout=6)
        assert not self.thread.is_alive(), 'scripted helper did not finish'
        assert self.error is None, repr(self.error)


def queue_conversations(authority):
    for scenario in ('initially-locked', 'queue-lock-retry', 'locked-cancel', 'disconnect', 'authority-loss', 'shutdown', 'eof', 'missing'):
        with tempfile.TemporaryDirectory(prefix='rediwm-polkit-queue-') as directory:
            script = {
                'initially-locked': [('A', 'SUCCESS')],
                'queue-lock-retry': [('A', 'cancel'), ('A', 'FAILURE'), ('A', 'SUCCESS'), ('C', 'cancel')],
                'locked-cancel': [('A', 'cancel'), ('B', 'SUCCESS'), ('C', 'cancel')],
                'shutdown': [('A', 'cancel')],
                'disconnect': [('A', 'cancel')],
                'authority-loss': [('A', 'cancel')],
                'eof': [('A', 'eof'), ('B', 'cancel')],
                'missing': [],
            }[scenario]
            helper = ScriptedHelper(directory, script) if script else None
            start = len(events)
            child = spawn(mode='--hold', REDIWM_POLKIT_HELPER_SOCKET=directory + '/helper')
            try:
                name = wait_event('RegisterAuthenticationAgent', start)['sender']
                status(child, 'registered')
                def args(cookie):
                    data = list(begin_args()); data[4] = cookie
                    data[0] = 'org.test.' + cookie
                    data[1] = 'Authenticate ' + cookie
                    return tuple(data)
                def begin(cookie):
                    def completed(conn, result):
                        error = None
                        try: conn.call_finish(result)
                        except GLib.Error as err: error = Gio.DBusError.get_remote_error(err)
                        event({'method': 'QueueDone-' + cookie, 'error': error})
                    authority.conn.call(name, AGENT_PATH, AGENT_IFACE, 'BeginAuthentication',
                        GLib.Variant(BEGIN_SIGNATURE, args(cookie)), None, Gio.DBusCallFlags.NONE, 10000, None, completed)
                    authority.conn.flush_sync(None)
                def done(cookie, expected=AUTH + '.Error.Cancelled'):
                    assert wait_event('QueueDone-' + cookie, start)['error'] == expected
                    assert len([e for e in events[start:] if e['method'] == 'QueueDone-' + cookie]) == 1
                def cancel(cookie):
                    call(authority.conn, name, AGENT_PATH, AGENT_IFACE, 'CancelAuthentication', '(s)', (cookie,))
                def command(value, expected=None):
                    child.stdin.write(value.encode())
                    if expected: status(child, expected)
                def barrier():
                    # Same authority connection: acknowledgement orders all preceding Begins.
                    cancel('unknown-cookie')

                if scenario == 'initially-locked':
                    command('p'); status(child, 'cancelled'); status(child, 'paused')
                    begin('A'); begin('B'); barrier(); command('s', 'state 2 0 1')
                    assert helper.accepted == []
                    cancel('B'); done('B')
                    command('r', 'resumed'); status(child, 'prompt')
                    command('a'); done('A', None); status(child, 'success')
                    command('s', 'state 0 0 0')
                elif scenario == 'missing':
                    begin('A'); begin('B'); done('A'); done('B')
                    status(child, 'transport-error'); status(child, 'transport-error')
                elif scenario == 'eof':
                    begin('A'); begin('B'); done('A')
                    status(child, 'transport-error'); status(child, 'prompt')
                    cancel('B'); done('B'); status(child, 'cancelled')
                else:
                    begin('A'); status(child, 'prompt')
                    begin('B'); begin('C'); barrier()
                    command('s', 'state 2 1 0')
                    expect_error(authority.conn, name, 'BeginAuthentication', BEGIN_SIGNATURE, args('C'), AUTH + '.Error.Cancelled')
                    if scenario == 'locked-cancel':
                        command('p'); status(child, 'cancelled'); status(child, 'paused')
                        cancel('A'); done('A'); status(child, 'cancelled')
                        command('s', 'state 2 0 1')
                        command('r', 'resumed'); status(child, 'prompt')
                        command('a'); done('B', None); status(child, 'success'); status(child, 'prompt')
                        cancel('C'); done('C'); status(child, 'cancelled')
                    elif scenario == 'queue-lock-retry':
                        cancel('B'); done('B')
                        command('p'); status(child, 'cancelled'); status(child, 'paused')
                        begin('D'); barrier(); command('s', 'state 2 1 1')
                        assert helper.accepted == ['A'], helper.accepted
                        cancel('D'); done('D')
                        command('r', 'resumed'); status(child, 'prompt')
                        command('s', 'state 1 1 0')
                        command('a'); status(child, 'error-message'); status(child, 'prompt')
                        command('s', 'state 1 2 0')
                        command('a'); done('A', None); status(child, 'success'); status(child, 'prompt')
                        cancel('C'); done('C'); status(child, 'cancelled')
                        command('s', 'state 0 0 0')
                    else:
                        # The queue is bounded at 16 waiting requests.
                        for i in range(14): begin('Q' + str(i))
                        barrier(); command('s', 'state 16 1 0')
                        expect_error(authority.conn, name, 'BeginAuthentication', BEGIN_SIGNATURE, args('overflow'), AUTH + '.Error.Cancelled')
                        if scenario == 'shutdown':
                            child.stdin.close(); expected = AUTH + '.Error.Cancelled'
                        elif scenario == 'disconnect':
                            command('d'); expected = BUS + '.Error.NoReply'
                        else:
                            call(authority.conn, BUS, BUS_PATH, BUS, 'ReleaseName', '(s)', (AUTH,))
                            expected = AUTH + '.Error.Cancelled'
                        for cookie in ['A', 'B', 'C'] + ['Q' + str(i) for i in range(14)]: done(cookie, expected)
                        status(child, 'cancelled')
                        if scenario != 'shutdown': command('s', 'state 0 0 0')
                if helper: helper.finish()
                stop(child)
                if scenario == 'authority-loss': own(authority.conn, AUTH)
            finally:
                if child.poll() is None:
                    child.kill(); child.wait(timeout=3)
    print('Polkit: FIFO queue, queued cancellation, duplicate/capacity rejection, lock suspension/resume, retries, EOF/spawn failure, bus/authority loss passed')


def config_conversations(authority):
    with tempfile.TemporaryDirectory(prefix='rediwm-polkit-config-') as directory:
        os.mkdir(directory + '/next')
        old = ScriptedHelper(directory, [('A', 'FAILURE'), ('A', 'SUCCESS'), ('B', 'SUCCESS')])
        new = ScriptedHelper(directory + '/next', [('C', 'SUCCESS')])
        start = len(events)
        child = spawn(mode='--hold', REDIWM_POLKIT_HELPER_SOCKET=old.path, REDIWM_TEST_NEXT_HELPER_SOCKET=new.path)
        try:
            name = wait_event('RegisterAuthenticationAgent', start)['sender']; status(child, 'registered')
            def begin(cookie):
                args = list(begin_args()); args[4] = cookie
                def complete(conn, result):
                    try: conn.call_finish(result); error = None
                    except GLib.Error as err: error = Gio.DBusError.get_remote_error(err)
                    event({'method': 'ConfigDone-' + cookie, 'error': error})
                authority.conn.call(name, AGENT_PATH, AGENT_IFACE, 'BeginAuthentication', GLib.Variant(BEGIN_SIGNATURE, tuple(args)), None, Gio.DBusCallFlags.NONE, 10000, None, complete)
                authority.conn.flush_sync(None)
            def done(cookie): assert wait_event('ConfigDone-' + cookie, start)['error'] is None
            begin('A'); status(child, 'prompt'); begin('B')
            call(authority.conn, name, AGENT_PATH, AGENT_IFACE, 'CancelAuthentication', '(s)', ('unknown',))
            child.stdin.write(b't'); status(child, 'configured')
            child.stdin.write(b'a'); status(child, 'error-message'); status(child, 'prompt')
            child.stdin.write(b'a'); done('A'); status(child, 'success'); status(child, 'prompt')
            child.stdin.write(b'a'); done('B'); status(child, 'success')
            old.finish()
            begin('C'); status(child, 'prompt')
            child.stdin.write(b'x'); status(child, 'configured')
            expect_error(authority.conn, name, 'BeginAuthentication', BEGIN_SIGNATURE, begin_args(), AUTH + '.Error.Cancelled')
            assert not any(e['method'] == 'UnregisterAuthenticationAgent' and e['sender'] == name for e in events[start:])
            mark = len(events)
            child.stdin.write(b'a'); done('C'); status(child, 'success'); new.finish()
            assert wait_event('UnregisterAuthenticationAgent', mark)['sender'] == name
            mark = len(events)
            child.stdin.write(b'e'); status(child, 'configured')
            wait_event('RegisterAuthenticationAgent', mark); status(child, 'registered')
            stop(child)
        finally:
            if child.poll() is None: child.kill(); child.wait(timeout=3)
    print('Polkit: config snapshots preserve active/queued/retry paths; disable drains/unregisters; re-enable registers passed')


def main():
    # Gate runs before openSystem: even a broken address must be harmless.
    for force in (None, '0', 'false'):
        child = spawn(REDIWM_FORCE_POLKIT=force, DBUS_SYSTEM_BUS_ADDRESS='unix:path=/nonexistent/polkit-test')
        assert child.wait(timeout=5) == 0
    authority = Authority()
    observer = connection()
    child = None
    logind = None
    try:
        start = len(events)
        child = spawn()
        registration = wait_event('RegisterAuthenticationAgent', start)
        assert registration['args'] == (('unix-session', {'session-id': 'test-session'}), 'C', AGENT_PATH)
        status(child, 'registered')
        name = registration['sender']
        names = call(observer, BUS, BUS_PATH, BUS, 'ListNames').unpack()[0]
        for owned in names:
            if owned.startswith(':') or owned == BUS:
                continue
            pid = call(observer, BUS, BUS_PATH, BUS, 'GetConnectionUnixProcessID', '(s)', (owned,)).unpack()[0]
            assert pid != child.pid, f'agent unexpectedly owns {owned}'
        begin = ('org.test.action', 'Authenticate', 'dialog-password', {'private': 'PRIVATE_DETAIL'},
                 'SECRET_COOKIE', [('unix-user', {'uid': GLib.Variant('u', os.getuid())})])
        signature = '(sssa{ss}sa(sa{sv}))'
        expect_error(authority.conn, name, 'BeginAuthentication', signature, begin, AUTH + '.Error.Cancelled')
        expect_error(observer, name, 'BeginAuthentication', signature, begin, BUS + '.Error.AccessDenied')
        expect_error(observer, name, 'CancelAuthentication', '(s)', ('SECRET_COOKIE',), BUS + '.Error.AccessDenied')
        expect_error(authority.conn, name, 'BeginAuthentication', '(s)', ('invalid',), BUS + '.Error.InvalidArgs')
        assert call(authority.conn, name, AGENT_PATH, AGENT_IFACE, 'CancelAuthentication', '(s)', ('SECRET_COOKIE',)).unpack() == ()

        # A new daemon gets a registration on the same agent connection.
        start = len(events)
        authority.close()
        authority = Authority()
        assert wait_event('RegisterAuthenticationAgent', start)['sender'] == name
        status(child, 'registered')
        # Losing the well-known name revokes the old owner's authority even
        # when that process keeps its connection alive.
        old = authority
        assert call(old.conn, BUS, BUS_PATH, BUS, 'ReleaseName', '(s)', (AUTH,)).unpack() == (1,)
        start = len(events)
        authority = Authority()
        wait_event('RegisterAuthenticationAgent', start)
        status(child, 'registered')
        expect_error(old.conn, name, 'CancelAuthentication', '(s)', ('SECRET_COOKIE',), BUS + '.Error.AccessDenied')
        old.close()
        start = len(events)
        child.stdin.close()
        unregister = wait_event('UnregisterAuthenticationAgent', start)
        assert unregister['args'] == (('unix-session', {'session-id': 'test-session'}), AGENT_PATH)
        stop(child)
        child = None

        # With neither an environment session nor logind, report failure and
        # stay alive; do not register against a guessed session.
        child = spawn(XDG_SESSION_ID=None)
        status(child, 'unavailable')
        assert child.poll() is None
        stop(child)
        child = None

        # Missing session id resolves through logind, not the object-path suffix.
        logind = Logind()
        start = len(events)
        child = spawn(XDG_SESSION_ID=None)
        registration = wait_event('RegisterAuthenticationAgent', start)
        assert registration['args'][0] == ('unix-session', {'session-id': '7'})
        assert wait_event('GetSessionByPID', start)['args'] == (child.pid,)
        assert wait_event('Get', start)['args'] == ('org.freedesktop.login1.Session', 'Id')
        status(child, 'registered')
        stop(child)
        child = None

        # Refusal is degraded/nonfatal, and does not unregister another agent.
        authority.refuse = True
        start = len(events)
        child = spawn()
        wait_event('RegisterAuthenticationAgent', start)
        status(child, 'unavailable')
        assert child.poll() is None
        stop(child)
        child = None

        # Restart while RegisterAuthenticationAgent is still pending.
        authority.refuse = False
        authority.hold = True
        start = len(events)
        child = spawn()
        wait_event('RegisterAuthenticationAgent', start)
        authority.close()
        start = len(events)
        authority = Authority()
        wait_event('RegisterAuthenticationAgent', start)
        status(child, 'registered')
        stop(child)
        child = None
        helper_conversations(authority, observer)
        terminal_conversations(authority)
        queue_conversations(authority)
        config_conversations(authority)
        print('Polkit: startup isolation, registration, logind fallback, sender validation, cancellation, refusal, restart and unregister passed')
    finally:
        if child is not None and child.poll() is None:
            child.kill()
            child.wait(timeout=3)
        authority.close()
        observer.close_sync(None)
        if logind:
            logind.conn.close_sync(None)


if __name__ == '__main__':
    main()

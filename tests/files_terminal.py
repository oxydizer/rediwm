#!/usr/bin/env python3
"""Isolated PTY/shell coordination and the real Files terminal drawer.

No production test hooks: the engine fixture calls the same C API as Files,
and the UI suite uses normal Wayland input, screenshots and /proc evidence.
"""
import ctypes as C
import os
from pathlib import Path
import select
import shlex
import shutil
import subprocess
import tempfile
import time

from ipc_client import IPCClient, ROOT, spawn_compositor, stop_process
from files_browser import wait_for

MAGIC = 0x46543031
VTERM_HASH = 'N-V-__8AAFwIBQAS1j3S14ozuJ18ebNtLQ-c5Kl6W4J7PoJt'
BIN = Path(os.environ.get('REDIWM_TEST_BIN', ROOT / 'zig-out/bin')).resolve()


class Status(C.Structure):
    _fields_ = [('magic', C.c_uint32), ('flags', C.c_uint32),
                ('serial', C.c_uint64), ('error', C.c_int32),
                ('jobs', C.c_int32), ('path', C.c_char * 4096)]


def build_engine(tmp):
    vterm = ROOT / 'zig-pkg' / VTERM_HASH
    out = tmp / 'engine.so'
    subprocess.run(['cc', '-shared', '-fPIC', '-O2', '-std=c99',
                    '-I' + str(vterm / 'include'), '-I' + str(vterm / 'src'),
                    str(ROOT / 'src/files/terminal/engine.c'),
                    *[str(p) for p in sorted((vterm / 'src').glob('*.c'))],
                    '-lxkbcommon', '-lutil', '-o', str(out)], check=True)
    lib = C.CDLL(str(out))
    signatures = {
        'ft_new': ([C.c_int, C.c_int], C.c_void_p),
        'ft_free': ([C.c_void_p], None),
        'ft_start': ([C.c_void_p, C.c_char_p, C.c_char_p, C.c_char_p, C.c_bool], C.c_int),
        'ft_pty': ([C.c_void_p], C.c_int), 'ft_channel': ([C.c_void_p], C.c_int),
        'ft_exit_fd': ([C.c_void_p], C.c_int),
        'ft_wants_write': ([C.c_void_p], C.c_bool),
        'ft_wants_request': ([C.c_void_p], C.c_bool),
        'ft_io': ([C.c_void_p, C.c_bool, C.c_bool, C.c_bool, C.c_bool], None),
        'ft_follow': ([C.c_void_p, C.c_char_p], C.c_int),
        'ft_status': ([C.c_void_p], C.POINTER(Status)),
        'ft_close': ([C.c_void_p, C.c_bool], None),
        'ft_running': ([C.c_void_p], C.c_bool),
        'ft_exited': ([C.c_void_p], C.c_bool),
        'ft_exit_status': ([C.c_void_p], C.c_int),
        'ft_history_bytes': ([C.c_void_p], C.c_size_t),
        'ft_paste': ([C.c_void_p, C.c_char_p, C.c_size_t], C.c_bool),
    }
    for name, (args, result) in signatures.items():
        fn = getattr(lib, name)
        fn.argtypes, fn.restype = args, result
    return lib


class Engine:
    def __init__(self, lib, directory):
        self.lib, self.handle = lib, lib.ft_new(12, 80)
        assert self.handle
        helper = BIN / 'rediwm-files-terminal'
        plugin = BIN.parent / 'lib/rediwm/files-bash.so'
        assert lib.ft_start(self.handle, os.fsencode(helper), os.fsencode(plugin),
                            os.fsencode(directory), False) == 0

    def pump(self, timeout=.05):
        poll = select.poll()
        fds = [self.lib.ft_pty(self.handle), self.lib.ft_channel(self.handle),
               self.lib.ft_exit_fd(self.handle)]
        for i, fd in enumerate(fds):
            if fd >= 0:
                output = (i == 0 and self.lib.ft_wants_write(self.handle)) or (
                    i == 1 and self.lib.ft_wants_request(self.handle))
                poll.register(fd, select.POLLIN | (select.POLLOUT if output else 0))
        events = dict(poll.poll(round(timeout * 1000)))
        self.lib.ft_io(self.handle, bool(events.get(fds[0], 0) & (
            select.POLLIN | select.POLLHUP | select.POLLERR)),
            bool(events.get(fds[0], 0) & select.POLLOUT),
            fds[1] in events, fds[2] in events)

    def wait(self, pred, description, timeout=5):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            self.pump()
            if pred():
                return
        s = self.status()
        raise AssertionError((description, s.magic, s.flags, s.serial, s.path))

    def status(self):
        return self.lib.ft_status(self.handle).contents

    def send(self, text):
        os.write(self.lib.ft_pty(self.handle), text if isinstance(text, bytes) else text.encode())

    def follow(self, path):
        assert self.lib.ft_follow(self.handle, os.fsencode(path)) == 0

    def free(self):
        self.lib.ft_close(self.handle, False)
        try:
            self.wait(lambda: self.lib.ft_exited(self.handle), 'owned shell reaped', timeout=1)
        except AssertionError:
            self.lib.ft_close(self.handle, True)
            self.wait(lambda: self.lib.ft_exited(self.handle), 'owned shell killed and reaped')
        finally:
            self.lib.ft_free(self.handle)


def engine_tests(tmp, home):
    lib = build_engine(tmp)
    weird = home / "spaces ' quotes \" $()\n新"
    weird.mkdir()
    another = home / 'latest'
    another.mkdir()
    e = Engine(lib, home)
    try:
        e.wait(lambda: e.status().magic == MAGIC and e.status().flags == 1, 'empty Bash prompt')
        e.follow(weird)
        e.wait(lambda: e.status().serial == 1 and e.status().path == os.fsencode(weird), 'path transported as data')
        e.send('printf partial')
        e.wait(lambda: e.status().flags == 2, 'partly typed command')
        e.follow(home)
        for _ in range(4):
            e.pump()
        assert e.status().serial == 1 and e.status().path == os.fsencode(weird)
        e.send(b'\x15')  # Ctrl+U clears the line without executing it.
        e.wait(lambda: e.status().serial == 2, 'following after line cleared')
        e.send('sleep .4\n')
        e.wait(lambda: e.status().flags == 4, 'running command')
        e.follow(weird)
        e.follow(home)
        e.follow(another)
        e.wait(lambda: e.status().serial == 5 and e.status().path == os.fsencode(another), 'latest request wins after command')
        e.send('printf keep')
        e.wait(lambda: e.status().flags == 2, 'partial input before inaccessible folder')
        gone = home / 'gone'
        gone.mkdir()
        e.follow(gone)
        gone.rmdir()
        e.send(b'\x15')
        e.wait(lambda: e.status().serial == 6 and e.status().flags & 8, 'failed cd acknowledged')
        assert e.status().path == os.fsencode(another)
        e.send('bash --noprofile --norc\n')
        e.wait(lambda: e.status().flags == 4, 'nested shell suspends following')
        e.follow(home)
        for _ in range(4):
            e.pump()
        assert e.status().serial == 6
        e.send('exit\n')
        e.wait(lambda: e.status().serial == 7 and e.status().path == os.fsencode(home), 'following resumes in owned shell')
        e.send('sleep 30 &\n')
        e.wait(lambda: e.status().jobs > 0 and e.status().flags == 1, 'background jobs reported')
        # A raw reader exercises queued writes, EAGAIN and partial PTY writes.
        ready, pasted = home / 'paste-ready', home / 'pasted'
        script = ('import os,termios,tty; old=termios.tcgetattr(0); tty.setraw(0); '
                  f'open({str(ready)!r},"w").close(); '
                  f'f=open({str(pasted)!r},"wb"); '
                  'left=200000\ntry:\n while left:\n  b=os.read(0,min(left,8192)); f.write(b); left-=len(b)\n'
                  'finally:\n f.close(); termios.tcsetattr(0,termios.TCSANOW,old)')
        e.send('python3 -c ' + shlex.quote(script) + '\n')
        e.wait(lambda: ready.exists(), 'raw reader ready')
        payload = b'x' * 200000
        assert lib.ft_paste(e.handle, payload, len(payload))
        e.wait(lambda: pasted.exists() and pasted.stat().st_size == len(payload), 'partial writes preserve paste', timeout=10)
        assert pasted.read_bytes() == payload
        e.wait(lambda: e.status().flags == 1, 'prompt after raw reader')
        bash_paste = b'true # ' + b'x' * 200000
        assert lib.ft_paste(e.handle, bash_paste, len(bash_paste))
        e.wait(lambda: not lib.ft_wants_write(e.handle), 'large Bash paste drains', timeout=10)
        e.send('\n')
        e.wait(lambda: e.status().flags == 1, 'large paste preserves Readline responsiveness', timeout=10)
        if Path('/usr/bin/vim').exists():
            vim_file, vim_ready = home / 'vim.txt', home / 'vim-ready'
            e.send('vim -Nu NONE -i NONE -n -c ' + shlex.quote(
                'call writefile(["ready"], "' + str(vim_ready) + '")') + ' ' + shlex.quote(str(vim_file)) + '\n')
            e.wait(lambda: vim_ready.exists(), 'vim alternate screen')
            e.send(b'ihello terminal\x1b:wq\n')
            e.wait(lambda: vim_file.exists(), 'vim accepts keyboard input')
            e.wait(lambda: e.status().flags == 1, 'vim restores shell screen')
            assert vim_file.read_text() == 'hello terminal\n'
        if Path('/usr/bin/top').exists():
            e.send('top -d .1 -n 2\n')
            e.wait(lambda: e.status().flags == 4, 'top fullscreen')
            e.wait(lambda: e.status().flags == 1, 'top completes fullscreen updates')
        e.send("printf '\\033]52;c;YmFk\\007'; seq 1 100000\n")
        e.wait(lambda: e.status().flags == 4, 'continuous output starts')
        e.wait(lambda: e.status().flags == 1, 'continuous output finishes', timeout=10)
        assert lib.ft_history_bytes(e.handle) <= 8 * 1024 * 1024
        e.send('exit 7\n')
        e.wait(lambda: lib.ft_exited(e.handle), 'shell exit')
        assert lib.ft_exit_status(e.handle) == 7
    finally:
        e.free()
    before = len(list(Path('/proc/self/fd').iterdir()))
    failed = lib.ft_new(4, 20)
    assert failed
    assert lib.ft_start(failed, b'/nonexistent-files-terminal-helper', b'', os.fsencode(home), False) == -1
    lib.ft_free(failed)
    assert len(list(Path('/proc/self/fd').iterdir())) == before, 'failed launch leaked descriptors'
    if shutil.which('fish'):
        selected = os.environ['SHELL']
        os.environ['SHELL'] = shutil.which('fish')
        unsupported = Engine(lib, home)
        os.environ['SHELL'] = selected
        try:
            unsupported.wait(lambda: lib.ft_channel(unsupported.handle) < 0, 'unsupported integration closes its channel')
            fish_dir = home / 'fish-dir'
            unsupported.send('pwd > ' + shlex.quote(str(fish_dir)) + '\n')
            unsupported.wait(lambda: fish_dir.exists(), 'Fish starts and accepts input')
            assert fish_dir.read_text().strip() == str(home)
        finally:
            unsupported.free()
    print('PTY: Unicode paths, partial/busy prompts, coalescing, failed cd, nested shells, jobs, paste writes, vim/top, bounds, launch failure, Fish and exit', flush=True)


def task_switches(pid):
    total = 0
    for task in Path(f'/proc/{pid}/task').glob('*/status'):
        for line in task.read_text().splitlines():
            if line.startswith(('voluntary_ctxt_switches:', 'nonvoluntary_ctxt_switches:')):
                total += int(line.split()[-1])
    return total


def scope_test(home, env):
    # The helper's native placement path talks only to this private fake user
    # manager. Assert scope placement completes before any app code executes.
    script = r'''
import os, subprocess, sys, warnings
warnings.simplefilter('ignore', DeprecationWarning)
from gi.repository import Gio, GLib
helper, home = sys.argv[1:]
loop = GLib.MainLoop()
conn = Gio.bus_get_sync(Gio.BusType.SESSION)
conn.call_sync('org.freedesktop.DBus', '/org/freedesktop/DBus', 'org.freedesktop.DBus', 'RequestName',
               GLib.Variant('(su)', ('org.freedesktop.systemd1', 0)), None, Gio.DBusCallFlags.NONE, 3000, None)
xml = """<node><interface name='org.freedesktop.systemd1.Manager'>
<method name='StartTransientUnit'><arg type='s' direction='in'/><arg type='s' direction='in'/>
<arg type='a(sv)' direction='in'/><arg type='a(sa(sv))' direction='in'/>
<arg type='o' direction='out'/></method></interface></node>"""
node = Gio.DBusNodeInfo.new_for_xml(xml)
seen = []
def called(conn, sender, path, interface, method, parameters, invocation):
    name, mode, values, aux = parameters.unpack()
    props = dict(values)
    assert name == f'app-rediwm-files-terminal-{proc.pid}.scope', name
    assert mode == 'fail' and props['PIDs'] == [proc.pid], props
    assert props['Slice'] == 'app.slice' and props['CollectMode'] == 'inactive-or-failed', props
    open(home + '/scope-placed', 'w').close()
    seen.append(name)
    invocation.return_value(GLib.Variant('(o)', ('/org/freedesktop/systemd1/job/1',)))
conn.register_object('/org/freedesktop/systemd1', node.interfaces[0], called, None, None)
program = 'import os; assert os.path.exists("scope-placed"); open("scoped-cwd","w").write(os.getcwd())'
proc = subprocess.Popen([helper, '1', home, '--external', sys.executable, '-c', program])
def exited(pid, status):
    proc.returncode = os.waitstatus_to_exitcode(status)
    loop.quit()
GLib.child_watch_add(proc.pid, exited)
GLib.timeout_add_seconds(5, lambda: (loop.quit(), False)[1])
try:
    loop.run()
    assert proc.returncode == 0 and seen, (proc.returncode, seen)
finally:
    if proc.returncode is None:
        proc.kill(); proc.wait()
'''
    subprocess.run(['dbus-run-session', '--', 'python3', '-c', script,
                    str(BIN / 'rediwm-files-terminal'), str(home)],
                   env=env, check=True, timeout=10)
    assert (home / 'scoped-cwd').read_text() == str(home)
    print('Scope: private manager receives owned PID/app.slice before exec', flush=True)


def ui_tests(tmp, home, env):
    external_cwd, external_args = home / 'external-cwd', home / 'external-args'
    external = tmp / 'external-terminal'
    external.write_text('#!/bin/sh\npwd > "$HOME/external-cwd"\nprintf "%s\\0" "$@" > "$HOME/external-args"\n')
    external.chmod(0o755)
    applications = tmp / 'data/applications'
    applications.mkdir(parents=True, exist_ok=True)
    (applications / 'files-terminal-fixture.desktop').write_text(
        '[Desktop Entry]\nType=Application\nName=Terminal fixture\nCategories=TerminalEmulator;\n'
        f'Exec={external} --flag "two words"\n')
    comp, log = spawn_compositor(tmp, binary=BIN / 'rediwm', config_content='[compositor]\nxwayland = false\ndefault_terminal = "files-terminal-fixture.desktop"\n',
                                 scale=os.environ.get('REDIWM_TEST_SCALE', '1'), env_extra=env)
    procs = []
    logs = []
    try:
        sock = wait_for(lambda: next(tmp.glob('rediwm-*.sock'), None), 'compositor socket')
        display = next(p.name for p in tmp.glob('wayland-*') if not p.name.endswith('.lock'))
        def start():
            output = (tmp / f'files-{len(procs)}.log').open('w')
            logs.append(output)
            p = subprocess.Popen([str(BIN / 'rediwm-files'), str(home)],
                                 env=dict(env, WAYLAND_DISPLAY=display), stdout=output, stderr=output)
            procs.append(p)
            return p
        with IPCClient(sock) as ipc:
            first = start()
            window = wait_for(lambda: next((w for w in ipc.get_windows() if w['app_id'] == 'rediwm-files'), None), 'Files window')
            ident = window['id']
            ipc.focus_window(ident)
            ipc.wait_for('window_geometry_settled', window_id=ident)
            def key(code, modifiers=()):
                for modifier in modifiers:
                    ipc.key(modifier, True)
                ipc.key_down_up(code)
                for modifier in reversed(modifiers):
                    ipc.key(modifier, False)
            def command(text):
                ipc.type_text(text)
                key(28)
            def click(x, y, pressed=None):
                box = ipc.get_window_debug(ident)['client_box']
                ipc.move_cursor(round(box['x'] + x), round(box['y'] + y))
                if pressed is None:
                    ipc.pointer_button(272, True)
                    ipc.pointer_button(272, False)
                else:
                    ipc.pointer_button(272, pressed)
            # A held F4 must open once, even after the repeat delay expires.
            ipc.key(62, True)
            time.sleep(.65)
            ipc.key(62, False)
            pidfile = home / 'bash-pid'
            shell = wait_for(lambda: int(pidfile.read_text()) if pidfile.exists() else None, 'lazy shell startup')
            marker = home / 'gui-output'
            command('printf GUI > ' + shlex.quote(str(marker)))
            wait_for(lambda: marker.exists(), 'terminal receives keys after held F4')
            ipc.screenshot(path=str(tmp / 'drawer.png'))
            # F4 hides without stopping a running command; reopening retains it.
            hidden = home / 'hidden-output'
            command('sleep .2; printf survived > ' + shlex.quote(str(hidden)))
            key(62)
            wait_for(lambda: hidden.exists(), 'hidden command survives')
            key(62)
            assert Path(f'/proc/{shell}').exists()
            target = home / "folder with ' quotes"
            target.mkdir()
            # Terminal keeps Ctrl+L; explicitly focus the file list first.
            click(350, 160)
            key(38, (29,))
            ipc.type_text(str(target))
            key(28)
            wait_for(lambda: Path(f'/proc/{shell}/cwd').resolve() == target, 'Files navigation follows empty prompt')
            # Focus the terminal body and prove shell Ctrl+C reaches a command.
            box = ipc.get_window_debug(ident)['client_box']
            click(350, box['height'] - 55)
            command('sleep 30')
            key(46, (29,))
            interrupted = home / 'interrupted'
            command('printf done > ' + shlex.quote(str(interrupted)))
            wait_for(lambda: interrupted.exists(), 'Ctrl+C interrupts foreground command')
            # The external action preserves desktop-entry argv and Files' cwd.
            default_height = max(100, int((box['height'] - 26 - 112) / 3))
            top = box['height'] - 26 - default_height
            click(box['width'] - 49, top + 16)
            wait_for(lambda: external_args.exists(), 'configured external terminal')
            assert external_cwd.read_text().strip() == str(target)
            assert external_args.read_bytes() == b'--flag\0two words\0'
            assert Path(f'/proc/{shell}').exists()
            if shutil.which('wl-copy') and shutil.which('wl-paste'):
                clipboard_env = dict(env, WAYLAND_DISPLAY=display)
                pasted = home / 'clipboard-pasted'
                copy = subprocess.Popen(['wl-copy', '--foreground', '--paste-once'], stdin=subprocess.PIPE, env=clipboard_env)
                procs.append(copy)
                copy.stdin.write(('printf pasted > ' + shlex.quote(str(pasted))).encode())
                copy.stdin.close()
                # The terminal header action leaves keyboard focus in Files;
                # take the terminal again before pasting.
                click(350, box['height'] - 55)
                time.sleep(.1)  # Wayland selection offer follows wl-copy startup.
                key(47, (29, 42))  # Ctrl+Shift+V.
                copy.wait(timeout=5)
                key(28)
                wait_for(lambda: pasted.exists(), 'Wayland clipboard pasted into PTY')
                selected = home / 'selection-ready'
                command("clear; printf 'SELECTABLE\\n'; printf ready > " + shlex.quote(str(selected)))
                wait_for(lambda: selected.exists(), 'selection output ready')
                ipc.wait_for_frame()
                time.sleep(.1)
                # Default mono metrics: use stty columns if theme size changes.
                click(216.2, top + 48, True)
                click(216.2 + 80, top + 48, False)
                key(46, (29, 42))
                def has_selection():
                    return subprocess.run(['wl-paste', '--list-types'], env=clipboard_env,
                                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                          timeout=3).returncode == 0
                wait_for(has_selection, 'terminal publishes selected text')
                copied = subprocess.run(['wl-paste', '--no-newline'], env=clipboard_env, stdout=subprocess.PIPE, timeout=5, check=True).stdout
                assert copied == b'SELECTABLE', ('terminal selection', copied)
            # Resizing the shared divider changes the preferred height and persists it.
            click(400, top, True)
            click(400, top - 50, False)
            key(62)
            state = tmp / 'state/rediwm/files-view'
            wait_for(lambda: state.exists(), 'drawer height saved')
            assert state.read_bytes()[0:1] == b'4'
            # Hidden drawer is idle. Check all Files and shell threads together.
            time.sleep(.8)
            before = task_switches(first.pid) + task_switches(shell)
            time.sleep(1.1)
            after = task_switches(first.pid) + task_switches(shell)
            assert after - before < 20, ('terminal idle wakeups', after - before)
            key(62)
            ipc.minimize(ident)
            ipc.restore(ident)
            ipc.focus_window(ident)
            ipc.wait_for('window_geometry_settled', window_id=ident)
            assert Path(f'/proc/{shell}').exists(), 'minimize/restore replaced the session'
            # Switching workspaces keeps an open drawer's session alive through
            # the slide and the size changes on entering/leaving tiled mode.
            ipc.action('set_desktop_mode', {'mode': 'workspaces', 'persist': False})
            ipc.wait_for('window_geometry_settled', window_id=ident)
            current_workspace = next(w['id'] for w in ipc.get_workspaces() if w['is_focused'])
            switched = home / 'workspace-output'
            command('sleep .2; printf survived > ' + shlex.quote(str(switched)))
            ipc.action('switch_workspace', {'workspace': 9})
            wait_for(lambda: switched.exists(), 'terminal command survives workspace slide')
            ipc.action('switch_workspace', {'workspace': current_workspace})
            ipc.focus_window(ident)
            ipc.action('set_desktop_mode', {'mode': 'canvas', 'persist': False})
            ipc.wait_for('window_geometry_settled', window_id=ident)
            assert Path(f'/proc/{shell}').exists()
            # New window starts hidden and creates its own shell only on F4.
            second = start()
            wait_for(lambda: len([w for w in ipc.get_windows() if w['app_id'] == 'rediwm-files']) == 2, 'second Files window')
            second_window = next(w for w in ipc.get_windows() if w['app_id'] == 'rediwm-files' and w['id'] != ident)
            ipc.focus_window(second_window['id'])
            ipc.wait_for('window_geometry_settled', window_id=second_window['id'])
            assert not Path(f'/proc/{second.pid}/task/{second.pid}/children').read_text().strip()
            key(62)
            other_shell = wait_for(lambda: int(pidfile.read_text()) if pidfile.read_text() != str(shell) else None, 'independent terminal')
            assert other_shell != shell
            ipc.focus_window(ident)
            # An idle shell is not work: only a job asks for confirmation.
            def session_members():
                members = []
                for entry in Path('/proc').iterdir():
                    try:
                        if entry.name.isdigit() and int(entry.name) != shell and os.getsid(int(entry.name)) == shell:
                            members.append(int(entry.name))
                    except OSError:
                        pass
                return members
            assert not session_members(), 'idle shell has no other session members'
            command('sleep 60')
            wait_for(session_members, 'foreground job started')
            key(62)
            # Close confirmation also covers the hidden terminal; cancellation preserves it.
            ipc.action('close_window', {'id': ident})
            time.sleep(.15)
            assert first.poll() is None
            key(1)
            assert first.poll() is None and Path(f'/proc/{shell}').exists()
            ipc.action('close_window', {'id': ident})
            time.sleep(.15)
            key(28)
            first.wait(timeout=4)
            assert not Path(f'/proc/{shell}').exists(), 'shell reaped on close'
            assert second.poll() is None and Path(f'/proc/{other_shell}').exists()
            # Opened once and left alone: closing needs no confirmation.
            ipc.action('close_window', {'id': second_window['id']})
            second.wait(timeout=4)
            assert not Path(f'/proc/{other_shell}').exists(), 'idle shell hung up on close'
        print('Files: F4/repeat, input, copy/paste, selection, external launch, following, divider/resize, idle, workspaces, minimize, independent windows and close/cancel and idle close', flush=True)
    except Exception:
        for path in tmp.glob('*.log'):
            print(path.name, path.read_text()[-6000:])
        keep = Path('/tmp/rediwm-files-terminal-failure.png')
        if (tmp / 'drawer.png').exists():
            keep.write_bytes((tmp / 'drawer.png').read_bytes())
        raise
    finally:
        for p in reversed(procs):
            if p.poll() is None:
                stop_process(p)
        for output in logs:
            output.close()
        stop_process(comp)
        log.close()


def terminal_drop_test(tmp, home, env, list_view=False):
    source = home / ('drop-list' if list_view else 'drop-grid')
    source.mkdir()
    folder = source / "folder with ' quotes"
    folder.mkdir()
    file = source / 'file 雪 \"$()`;\\.txt'
    file.write_text('drag payload')
    output = home / (source.name + '-args')
    comp, log = spawn_compositor(tmp, binary=BIN / 'rediwm', scale=os.environ.get('REDIWM_TEST_SCALE', '1'), env_extra=env,
                                 config_content='[compositor]\nxwayland = false\ndodge_file_drags = false\n')
    proc = None
    try:
        with IPCClient(tmp).connect() as ipc:
            display = next(p.name for p in tmp.glob('wayland-*') if not p.name.endswith('.lock'))
            with (tmp / 'files.log').open('w') as files_log:
                proc = subprocess.Popen([str(BIN / 'rediwm-files'), str(source)],
                                        env=dict(env, WAYLAND_DISPLAY=display), stdout=files_log, stderr=files_log)
            window = wait_for(lambda: next((w for w in ipc.get_windows() if w['app_id'] == 'rediwm-files'), None), 'drop Files window')
            ident = window['id']
            ipc.focus_window(ident)
            ipc.wait_for('window_geometry_settled', window_id=ident)
            def key(code, modifiers=()):
                for modifier in modifiers:
                    ipc.key(modifier, True)
                ipc.key_down_up(code)
                for modifier in reversed(modifiers):
                    ipc.key(modifier, False)
            def move(x, y):
                box = ipc.get_window_debug(ident)['client_box']
                ipc.move_cursor(round(box['x'] + x), round(box['y'] + y))
            def click(x, y):
                move(x, y)
                ipc.pointer_button(272, True)
                ipc.pointer_button(272, False)
            if list_view:
                width = ipc.get_window_debug(ident)['client_box']['width']
                click(width - 232, 80)
            key(62)
            ready = home / (source.name + '-ready')
            ipc.type_text('printf ready > ' + shlex.quote(str(ready)))
            key(28)
            wait_for(lambda: ready.exists(), 'drop terminal ready')
            # Build a command before giving focus to the list. The drop must
            # insert arguments, preserve that command and return keyboard focus.
            ipc.type_text("printf '%s\\0' > " + shlex.quote(str(output)) + ' ')
            sx, sy = 250, (178 if list_view else 158)
            click(500, 300)  # Focus empty space so single-click opening cannot navigate.
            key(30, (29,))
            move(sx, sy)
            ipc.pointer_button(272, True)
            height = ipc.get_window_debug(ident)['client_box']['height']
            for step in range(1, 17):
                move(sx + 80 * step / 16, sy + (height - 55 - sy) * step / 16)
                time.sleep(.04)
            ipc.pointer_button(272, False)
            ipc.wait_for_frame()
            time.sleep(.2)  # Allow the asynchronous Wayland URI pipe to finish.
            assert not output.exists(), 'drop executed the command'
            key(28)
            expected = [os.fsencode(folder), os.fsencode(file)]
            wait_for(lambda: output.exists() and output.read_bytes().split(b'\0') == expected + [b''], 'quoted drop arguments and terminal focus')
            assert file.read_text() == 'drag payload' and folder.is_dir(), 'terminal drop changed source files'
            assert sorted(p.name for p in source.iterdir()) == sorted([file.name, folder.name])
            assert proc.poll() is None
        print(f'Files: multi-file/folder terminal drop, quoting, focus and preserved sources ({"list" if list_view else "grid"})', flush=True)
    except Exception:
        for path in tmp.glob('*.log'):
            print(path.name, path.read_text()[-6000:])
        print('Dropped arguments:', output.read_bytes() if output.exists() else None, flush=True)
        if proc is not None and comp.poll() is None:
            with IPCClient(tmp).connect() as ipc:
                ipc.screenshot(path=f'/tmp/rediwm-files-terminal-drop-failure-{os.getpid()}.png')
        raise
    finally:
        if proc is not None:
            stop_process(proc)
        stop_process(comp)
        log.close()


def run():
    os.umask(0o077)
    with tempfile.TemporaryDirectory(prefix='rediwm-files-terminal-') as directory:
        tmp = Path(directory)
        home = tmp / 'Home'
        home.mkdir()
        (home / '.bashrc').write_text("PS1='files-test:\\w$ '\nHISTFILE=/dev/null\nprintf '%s' \"$BASHPID\" > \"$HOME/bash-pid\"\n")
        env = dict(os.environ, HOME=str(home), SHELL='/bin/bash', XDG_RUNTIME_DIR=directory,
                   XDG_CONFIG_HOME=str(tmp / 'config'), XDG_STATE_HOME=str(tmp / 'state'),
                   XDG_DATA_HOME=str(tmp / 'data'), XDG_CACHE_HOME=str(tmp / 'cache'),
                   WLR_BACKENDS='headless', REDIWM_FILES_DEVICES='0', REDIWM_APP_SCOPES='0',
                   DBUS_SESSION_BUS_ADDRESS='unix:path=/nonexistent-files-test-session-bus',
                   DBUS_SYSTEM_BUS_ADDRESS='unix:path=/nonexistent-files-test-system-bus')
        env.pop('WAYLAND_DISPLAY', None)
        env.pop('REDIWM_SOCKET', None)
        original = dict(os.environ)
        os.environ.clear()
        os.environ.update(env)
        try:
            engine_tests(tmp, home)
            scope_test(home, env)
            (home / 'bash-pid').unlink(missing_ok=True)
            # Use one configuration for the compositor and Files.
            env['REDIWM_CONFIG'] = str(tmp / 'rediwm-config.toml')
            ui_tests(tmp, home, env)
            for list_view in (False, True):
                drop_tmp = tmp / ('drop-list' if list_view else 'drop-grid')
                drop_tmp.mkdir(mode=0o700)
                drop_env = dict(env, XDG_RUNTIME_DIR=str(drop_tmp), XDG_STATE_HOME=str(drop_tmp / 'state'),
                                REDIWM_CONFIG=str(drop_tmp / 'rediwm-config.toml'))
                terminal_drop_test(drop_tmp, home, drop_env, list_view)
        finally:
            os.environ.clear()
            os.environ.update(original)


if __name__ == '__main__':
    run()

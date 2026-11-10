#!/usr/bin/env python3
"""SSH metadata/helper and real Settings checks, using only generated keys.

Every file and operation uses scratch HOME/XDG directories. No host agent,
trust store or real credentials are accessed. Run under dbus-run-session.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

from ipc_client import IPCClient, ROOT, spawn_compositor, stop_process
from ui_driver import UIDriver


def wait(predicate, description, seconds=12):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        result = predicate()
        if result:
            return result
        time.sleep(.08)
    raise AssertionError(description)


def environment(root):
    env = dict(os.environ, HOME=str(root / 'home'),
               XDG_CONFIG_HOME=str(root / 'config'), XDG_DATA_HOME=str(root / 'data'),
               XDG_CACHE_HOME=str(root / 'cache'), XDG_STATE_HOME=str(root / 'state'),
               XDG_RUNTIME_DIR=str(root), SSH_AUTH_SOCK='', REDIWM_APP_SCOPES='0', GIO_USE_VFS='local',
               PULSE_SERVER='unix:/nonexistent-rediwm-keys-audio', PIPEWIRE_RUNTIME_DIR=str(root),
               DBUS_SYSTEM_BUS_ADDRESS='unix:path=/nonexistent-rediwm-keys-system-bus')
    env.pop('REDIWM_SOCKET', None)
    env.pop('WAYLAND_DISPLAY', None)
    for key in ('HOME', 'XDG_CONFIG_HOME', 'XDG_DATA_HOME', 'XDG_CACHE_HOME', 'XDG_STATE_HOME'):
        Path(env[key]).mkdir(mode=0o700, exist_ok=True)
    return env


def helper_checks(root, env, binary):
    ssh = Path(env['HOME']) / '.ssh'
    ssh.mkdir(mode=0o700)

    def generate(name, password='', algorithm='ed25519', bits=None):
        argv = ['ssh-keygen', '-q', '-t', algorithm, '-N', password, '-C', 'fixture ' + name, '-f', str(ssh / name)]
        if bits:
            argv += ['-b', str(bits)]
        subprocess.run(argv, check=True, env=env, capture_output=True)

    def invoke(action='scan', **fields):
        result = subprocess.run([str(binary), 'scan' if action == 'scan' else 'op'],
                                input=None if action == 'scan' else json.dumps(dict(action=action, **fields)).encode(),
                                capture_output=True, check=True, env=env, timeout=20)
        assert b'PRIVATE KEY' not in result.stdout
        return json.loads(result.stdout)

    def identity(reply, name):
        return next(item for item in reply['inventory']['items'] if any(Path(p['path']).name == name for p in item['locations']))

    generate('extensionless')
    generate('protected', 'old secret')
    generate('weak', algorithm='rsa', bits=1024)
    generate('ecdsa', algorithm='ecdsa', bits=256)
    subprocess.run(['ssh-keygen', '-q', '-t', 'rsa', '-b', '2048', '-m', 'PEM', '-N', '', '-f', str(ssh / 'cloud.pem')], check=True, env=env, capture_output=True)
    subprocess.run(['openssl', 'pkey', '-in', str(ssh / 'cloud.pem'), '-out', str(ssh / 'pkcs8.key')], check=True, env=env, capture_output=True)
    shutil.copyfile(ssh / 'extensionless', ssh / 'duplicate')
    (ssh / 'duplicate').chmod(0o600)
    (ssh / 'extensionless.pub').unlink()
    (ssh / 'extensionless').chmod(0o644)
    (ssh / 'link').symlink_to(ssh / 'protected')
    os.mkfifo(ssh / 'fifo', 0o600)
    (ssh / 'bad').write_text('-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA/w==\n-----END OPENSSH PRIVATE KEY-----\n')
    reply = invoke()
    assert reply['failure'] is None, reply
    assert len(reply['inventory']['items']) == 5, reply
    legacy = identity(reply, 'cloud.pem')
    assert len(legacy['locations']) == 3
    item = identity(reply, 'extensionless')
    assert len(item['locations']) == 2, item
    location = next(p for p in item['locations'] if Path(p['path']).name == 'extensionless')
    assert location['missing_public'] and location['permissions'] and not location['encrypted']
    encrypted = identity(reply, 'protected')
    assert any(p['private'] and p['encrypted'] for p in encrypted['locations'])
    # Compare every supported algorithm against OpenSSH's fingerprint oracle.
    for row in reply['inventory']['items']:
        path = next((p['path'] for p in row['locations'] if not p['private']), row['locations'][0]['path'])
        reference = subprocess.run(['ssh-keygen', '-lf', path], env=env, check=True, capture_output=True).stdout.decode()
        assert row['fingerprint'] in reference, (row, reference)
    target = dict(path=str(ssh / 'extensionless'), fingerprint=item['fingerprint'])
    assert invoke('recreate_public', **target)['failure'] is None
    assert (ssh / 'extensionless.pub').read_text().startswith('ssh-ed25519 ')
    assert invoke('recreate_public', **target)['failure'] == 'PathAlreadyExists'
    assert invoke('permissions', **target)['failure'] is None
    assert (ssh / 'extensionless').stat().st_mode & 0o777 == 0o600
    assert ssh.stat().st_mode & 0o777 == 0o700
    legacy_target = dict(path=str(ssh / 'cloud.pem'), fingerprint=legacy['fingerprint'])
    legacy_change = invoke('passphrase', new_passphrase='legacy secret', **legacy_target)
    assert legacy_change['failure'] is None, legacy_change
    assert subprocess.run(['ssh-keygen', '-y', '-P', 'legacy secret', '-f', str(ssh / 'cloud.pem')], env=env, capture_output=True).returncode == 0
    assert invoke('label', text='Work laptop', **target)['failure'] is None
    assert identity(invoke(), 'duplicate')['label'] == 'Work laptop'
    encrypted_target = dict(path=str(ssh / 'protected'), fingerprint=encrypted['fingerprint'])
    original = (ssh / 'protected').read_bytes()
    assert invoke('passphrase', old_passphrase='wrong', new_passphrase='unused', **encrypted_target)['failure'] == 'KeygenFailed'
    assert (ssh / 'protected').read_bytes() == original
    changed = invoke('passphrase', old_passphrase='old secret', new_passphrase='new secret', **encrypted_target)
    assert changed['failure'] is None, changed
    verified = subprocess.run(['ssh-keygen', '-y', '-P', 'new secret', '-f', str(ssh / 'protected')], env=env, capture_output=True)
    assert verified.returncode == 0, verified.stderr
    assert invoke('comment', old_passphrase='new secret', text='Changed comment', **encrypted_target)['failure'] is None
    assert identity(invoke(), 'protected')['comment'] == 'Changed comment'
    assert invoke('passphrase', old_passphrase='new secret', new_passphrase='', **encrypted_target)['failure'] is None
    assert not next(p for p in identity(invoke(), 'protected')['locations'] if p['private'])['encrypted']
    generated = invoke('generate', path='new-key', text='Generated key', new_passphrase='generated secret')
    assert generated['failure'] is None, generated
    assert invoke('generate', path='new-key', new_passphrase='')['failure'] == 'PathAlreadyExists'
    assert invoke('generate', path='../escape')['failure'] == 'InvalidPath'
    assert invoke('permissions', path=str(ssh / 'link'), fingerprint=encrypted['fingerprint'])['failure'] is not None
    assert invoke('trash', path=target['path'], fingerprint='SHA256:stale')['failure'] == 'FileChanged'
    # A mismatched public file remains untouched by comment/passphrase actions.
    shutil.copyfile(ssh / 'weak.pub', ssh / 'protected.pub')
    mismatch = identity(invoke(), 'protected')
    assert any(p['mismatched_public'] for p in mismatch['locations'])
    before_public = (ssh / 'protected.pub').read_bytes()
    assert invoke('comment', text='New comment', **encrypted_target)['failure'] is None
    assert (ssh / 'protected.pub').read_bytes() == before_public
    shutil.copyfile(ssh / 'extensionless.pub', ssh / 'protected.pub')
    # Trash preserves unrelated public files and other copies of the key.
    assert invoke('trash', **target)['failure'] is None
    assert not (ssh / 'extensionless').exists() and not (ssh / 'extensionless.pub').exists()
    assert (ssh / 'duplicate').exists()
    assert list((Path(env['XDG_DATA_HOME']) / 'Trash' / 'files').iterdir())
    # Leave a small, predictable fixture for the real page test.
    for entry in ssh.iterdir():
        if entry.name not in ('duplicate', 'protected', 'weak', 'weak.pub'):
            entry.unlink()
    assert not list(ssh.glob('.rediwm-keys-*'))
    print('helper: inventory, fingerprints, deduplication, unsafe files, actions and Trash passed')


def page_checks(root, env, binary):
    proc, log = spawn_compositor(root, scale=os.environ.get('REDIWM_TEST_SCALE', '1'), env_extra=env, binary=binary)
    try:
        with IPCClient(root, timeout=20) as ipc:
            ipc.wait_for('wallpaper_presented', timeout_ms=10000)
            ui = UIDriver(ipc)

            def click(name):
                ui.click(ui.scroll_into_view(name), panel='control_center')
                ui.wait_settled('control_center')

            def idle():
                return not any(w.get('name') == 'keys_status' for w in ui.widgets())

            def enter(name, value):
                click(name)
                ipc.key_down_up(107)  # End
                for _ in range(30):
                    ipc.key_down_up(14)  # Backspace
                ipc.type_text(value)

            ipc.open_control_center()
            ui.wait_settled('control_center')
            ui.click('keys', panel='control_center')
            wait(lambda: any(w.get('name') == 'keys_item_0' for w in ui.widgets()) and idle(), 'key inventory')
            if preview := os.environ.get('REDIWM_KEYS_SETTINGS_PREVIEW'):
                ui.wait_settled('control_center')
                ipc.screenshot(preview)
            click('keys_item_0')
            assert any(w.get('name') == 'keys_fingerprint' for w in ui.widgets())
            click('keys_copy')
            assert ui.find('keys_message')['label'] == 'Public key copied.'
            click('keys_edit_label')
            enter('keys_label', 'UI label')
            click('keys_submit')
            wait(lambda: idle() and any(w.get('label') == 'UI label' for w in ui.widgets()), 'label saved')
            click('keys_back')
            click('keys_new')
            enter('keys_name', 'ui-generated')
            enter('keys_comment', 'UI generated')
            click('keys_new_passphrase')
            ipc.type_text('ui secret')
            click('keys_confirm_passphrase')
            ipc.type_text('ui secret')
            # Secret widget inspection must not disclose entered text.
            assert 'ui secret' not in json.dumps(ui.widgets())
            click('keys_submit')
            key_path = Path(env['HOME']) / '.ssh' / 'ui-generated'
            wait(lambda: key_path.exists() and idle(), 'generated from Settings')
            result = subprocess.run(['ssh-keygen', '-y', '-P', 'ui secret', '-f', str(key_path)], env=env, capture_output=True)
            assert result.returncode == 0, result.stderr
            assert not any(w.get('name') == 'keys_error' for w in ui.widgets()), ui.widgets()
            # Leaving and returning starts a fresh scan and keeps the section usable.
            ui.click('general', panel='control_center')
            ui.wait_settled('control_center')
            ui.click('keys', panel='control_center')
            wait(lambda: idle() and any(w.get('label') == 'UI generated' for w in ui.widgets()), 'reopened inventory')
            click('keys_new')
            click('keys_new_passphrase')
            ipc.type_text('cancelled secret')
            ipc.key_down_up(1)  # Escape cancels and wipes the form.
            ui.wait_settled('control_center')
            assert not any(w.get('name') == 'keys_new_passphrase' for w in ui.widgets())
            window = next(w for w in ipc.get_windows() if w.get('app_id') == 'rediwm-settings')
            ipc.close_window(window['id'])
            ui.wait_absent('control_center')
    except Exception:
        log.flush()
        print(Path(log.name).read_text()[-6000:])
        raise
    finally:
        stop_process(proc)
        log.close()
    print('Settings: inventory, copy, label, secret generation, navigation and cancellation passed')


def cancellation_check(root, env, binary):
    """A noninstalled fixture proves that hiding kills a pending helper group."""
    local_bin = root / 'fixture-bin'
    local_bin.mkdir()
    shutil.copy2(binary, local_bin / 'rediwm')
    pid_file = root / 'helper-pids'
    helper = local_bin / 'rediwm-keys'
    helper.write_text('#!/bin/sh\n/bin/sleep 120 &\nprintf "%s %s\\n" "$$" "$!" > ' + str(pid_file) + '\nwait\n')
    helper.chmod(0o700)
    proc, log = spawn_compositor(root, env_extra=env, binary=local_bin / 'rediwm')
    try:
        with IPCClient(root, timeout=20) as ipc:
            ipc.open_control_center()
            ui = UIDriver(ipc)
            ui.wait_settled('control_center')
            assert not pid_file.exists(), 'hidden section started its helper'
            ui.click('keys', panel='control_center')
            wait(pid_file.exists, 'fixture helper start')
            helper_pid, descendant = map(int, pid_file.read_text().split())
            ui.click('general', panel='control_center')
            ui.wait_settled('control_center')

            def stopped(pid):
                try:
                    os.kill(pid, 0)
                    return False
                except ProcessLookupError:
                    return True

            wait(lambda: stopped(helper_pid), 'helper did not stop on hide')
            # A just-killed grandchild can briefly remain a zombie awaiting its
            # adopter; it must never remain a running sleeper after page hide.
            result = subprocess.run(['ps', '-o', 'stat=', '-p', str(descendant)], capture_output=True, text=True)
            assert not result.stdout.strip() or result.stdout.strip().startswith('Z'), result.stdout
    finally:
        stop_process(proc)
        log.close()
    print('Settings: hidden page starts nothing; hide cancels the helper and its descendants')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--helper-only', action='store_true')
    parser.add_argument('--bin-dir', type=Path, default=ROOT / 'zig-out/bin')
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='rediwm-keys-') as directory:
        root = Path(directory)
        root.chmod(0o700)
        env = environment(root)
        helper_checks(root, env, args.bin_dir / 'rediwm-keys')
        if not args.helper_only:
            page_checks(root, env, args.bin_dir / 'rediwm')
            cancellation_root = root / 'cancellation'
            cancellation_root.mkdir(mode=0o700)
            cancellation_check(cancellation_root, environment(cancellation_root), (args.bin_dir / 'rediwm').resolve())


if __name__ == '__main__':
    main()

#!/usr/bin/env python3
"""rediwm-firewall-helper against real nftables, without touching the host.

Re-runs itself in a private user, mount and network namespace (`unshare
-rmn`): the helper is namespace root and its nftables table lands in the
empty network namespace. ${sysconfdir}/rediwm and /run are scratch tmpfs;
NetworkManager's and systemd's directories are masked and nmcli, systemctl,
ufw and firewall-cmd are hidden, so nothing reaches host services. Checks our
own backend end to end: enable, rules, validation, listener verdicts, trust,
lockdown and policy changes that revert unless kept, and disable.
Usage: python3 tests/firewall_helper.py [--bin-dir zig-out/bin]
"""
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import time

HERE = Path(__file__).resolve().parent
SETUP = r'''
set -e
scratch="$1"; shift
if [ -d /etc/rediwm ]; then
    mount -t tmpfs tmpfs /etc/rediwm
else
    mkdir -p "$scratch/etc"
    mount --rbind /etc "$scratch/etc"
    mount -t tmpfs tmpfs /etc
    for entry in "$scratch"/etc/* "$scratch"/etc/.[!.]*; do [ -e "$entry" ] && ln -s "$entry" /etc/; done
    mkdir /etc/rediwm
fi
mount -t tmpfs tmpfs /run
for dir in /etc/NetworkManager /etc/systemd/system; do [ -d "$dir" ] && mount -t tmpfs tmpfs "$dir"; done
for tool in ufw nmcli systemctl firewall-cmd; do
    for dir in /usr/bin /usr/sbin /bin /sbin; do [ -e "$dir/$tool" ] && mount --bind /dev/null "$dir/$tool"; done
done
ip link set lo up 2>/dev/null || true
exec "$@"
'''


def bin_dir():
    if '--bin-dir' in sys.argv:
        return Path(sys.argv[sys.argv.index('--bin-dir') + 1]).resolve()
    return (HERE.parent / 'zig-out' / 'bin').resolve()


def reexec():
    if not shutil.which('nft') or not shutil.which('unshare'):
        print('SKIP: firewall_helper needs nft and unshare')
        sys.exit(0)
    with tempfile.TemporaryDirectory(prefix='rediwm-firewall-helper-') as scratch:
        command = ['unshare', '-rmn', 'sh', '-c', SETUP, 'setup', scratch, sys.executable, '-I', __file__, '--inside', '--bin-dir', str(bin_dir())]
        sys.exit(subprocess.run(command).returncode)


HELPER = str(bin_dir() / 'rediwm-firewall-helper')


def call(mode, request):
    result = subprocess.run([HELPER, mode], input=json.dumps(request).encode(), capture_output=True, timeout=60)
    reply = json.loads(result.stdout) if result.stdout else None
    return result.returncode, reply


def manage(request):
    code, reply = call('manage', request)
    assert reply is not None, f'{request}: no reply (exit {code})'
    assert reply['failure'] is None, f'{request}: {reply["failure"]}'
    return reply['status']


def status():
    return call('read', {'op': 'status'})[1]['status']


def nft(*args):
    return subprocess.run(['nft', *args], capture_output=True, text=True).stdout


def verdicts(s):
    return {(l['proto'], l['port']): l['verdict'] for l in s['listeners']}


def main():
    s = status()
    assert s['backend'] == 'own' and not s['running'], s
    assert s['capabilities']['edit'] and s['capabilities']['lockdown']

    # A read cannot change anything, and junk never reaches nft.
    code, _ = call('read', {'op': 'enable'})
    assert code != 0
    for bad in ({'port': '22; flush ruleset', 'proto': 'tcp'}, {'source': '1.2.3.4 } accept', 'action': 'deny'}, {'service': 'ssh', 'comment': 'x" accept'}, {}):
        code, reply = call('manage', {'op': 'add_rule', 'rule': bad})
        assert code != 0 and reply is None, bad
    assert 'rediwm' not in nft('list', 'tables')

    s = manage({'op': 'enable'})
    assert s['running'] and s['incoming'] == 'drop', s
    assert 'table inet rediwm' in nft('list', 'tables')

    listeners = []
    for family, address, port, kind in ((socket.AF_INET, '0.0.0.0', 8080, socket.SOCK_STREAM), (socket.AF_INET, '127.0.0.1', 631, socket.SOCK_STREAM), (socket.AF_INET6, '::', 22, socket.SOCK_STREAM), (socket.AF_INET, '0.0.0.0', 5353, socket.SOCK_DGRAM)):
        sock = socket.socket(family, kind)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.bind((address, port))
        if kind == socket.SOCK_STREAM:
            sock.listen()
        listeners.append(sock)
    v = verdicts(status())
    assert v == {('tcp', 8080): 'blocked', ('tcp', 631): 'local', ('tcp', 22): 'blocked', ('udp', 5353): 'blocked'}, v

    manage({'op': 'add_rule', 'rule': {'service': 'ssh', 'source': 'lan', 'comment': 'ssh'}})
    manage({'op': 'add_rule', 'rule': {'port': '8080', 'proto': 'tcp'}})
    manage({'op': 'add_rule', 'rule': {'service': 'mdns', 'scope': 'home'}})
    s = manage({'op': 'add_rule', 'rule': {'source': '203.0.113.9', 'action': 'deny'}})
    assert len(s['rules']) == 4, s['rules']
    v = verdicts(s)
    assert v[('tcp', 8080)] == 'everywhere' and v[('tcp', 22)] == 'home' and v[('udp', 5353)] == 'home', v
    table = nft('list', 'table', 'inet', 'rediwm')
    for piece in ('ip saddr 203.0.113.9 drop', 'ip saddr @lan4 tcp dport 22 accept comment "ssh"', 'tcp dport 8080 accept', 'iifname @home_ifaces udp dport 5353 accept'):
        assert piece in table, (piece, table)
    # Adding the same rule twice keeps one.
    assert len(manage({'op': 'add_rule', 'rule': {'port': '8080', 'proto': 'tcp'}})['rules']) == 4

    # Remove by the rule as the status listed it.
    rule = next(r for r in s['rules'] if r['port'] == '8080')
    s = manage({'op': 'remove_rule', 'rule': rule})
    assert all(r['port'] != '8080' for r in s['rules']) and 'dport 8080' not in nft('list', 'table', 'inet', 'rediwm')
    code, reply = call('manage', {'op': 'remove_rule', 'rule': rule})
    assert code == 3 and reply['failure'] == 'That rule is no longer there.', reply

    # Per-interface trust (no NetworkManager here) fills the home set.
    iface = next((n['iface'] for n in s['networks']), None)
    if iface:
        s = manage({'op': 'set_trust', 'iface': iface, 'trust': 'home'})
        assert any(n['iface'] == iface and n['trust'] == 'home' for n in s['networks'])
        assert f'"{iface}"' in nft('list', 'set', 'inet', 'rediwm', 'home_ifaces')

    # Lockdown and blocking outgoing undo themselves unless kept.
    s = manage({'op': 'lockdown', 'on': True, 'revert_after': 2})
    assert s['lockdown'] and s['revert_in'] > 0 and 'rediwm_lockdown' in nft('list', 'tables')
    time.sleep(3.5)
    s = status()
    assert not s['lockdown'] and s['revert_in'] == 0, s
    manage({'op': 'lockdown', 'on': True, 'revert_after': 2})
    manage({'op': 'confirm'})
    time.sleep(3)
    assert status()['lockdown']
    assert not manage({'op': 'lockdown', 'on': False})['lockdown']
    s = manage({'op': 'set_defaults', 'outgoing': 'drop', 'revert_after': 2})
    assert s['outgoing'] == 'drop' and 'policy drop' in nft('list', 'chain', 'inet', 'rediwm', 'output')
    time.sleep(3.5)
    assert status()['outgoing'] == 'accept'

    s = manage({'op': 'set_option', 'option': 'ping', 'on': False})
    assert not s['ping'] and 'icmp type echo-request drop' in nft('list', 'chain', 'inet', 'rediwm', 'input')
    s = manage({'op': 'set_option', 'option': 'logging', 'logging': 'medium'})
    assert s['logging'] == 'medium' and 'rediwm-drop' in nft('list', 'chain', 'inet', 'rediwm', 'input')
    s = manage({'op': 'set_defaults', 'incoming': 'reject'})
    assert s['incoming'] == 'reject'
    code, reply = call('read', {'op': 'blocks'})
    assert code == 0 and isinstance(reply['status']['blocks'], list)

    # The saved state is root-only, and `sync` restores the table.
    saved = Path('/etc/rediwm/firewall.json')
    assert oct(saved.stat().st_mode & 0o777) == '0o600', oct(saved.stat().st_mode)
    nft('delete', 'table', 'inet', 'rediwm')
    assert subprocess.run([HELPER, 'sync']).returncode == 0
    assert 'table inet rediwm' in nft('list', 'tables')

    s = manage({'op': 'disable'})
    assert not s['running'] and 'rediwm' not in nft('list', 'tables'), nft('list', 'tables')
    for sock in listeners:
        sock.close()
    print('PASS firewall helper: own nftables backend, validation, verdicts, trust, revert, sync')


if __name__ == '__main__':
    if '--inside' in sys.argv:
        main()
    else:
        reexec()

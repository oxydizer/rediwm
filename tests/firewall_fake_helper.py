#!/usr/bin/env python3
"""A stand-in for rediwm-firewall-helper for tests/firewall_settings.py.

Speaks the helper's JSON protocol (src/firewall/protocol.zig) over stdin and
stdout, keeps its firewall in a JSON file and appends every request to a log,
so the test can check what Settings asked for. It never touches a real
firewall. The real helper is tested against nftables in tests/firewall_helper.py.
"""
import json
import os
import sys

STATE = os.environ['FIREWALL_FAKE_STATE']
LOG = os.environ['FIREWALL_FAKE_LOG']
READ_ONLY = {'status', 'blocks'}


def default_state():
    return {
        'backend': 'own', 'running': False, 'boot': False, 'incoming': 'drop', 'outgoing': 'accept', 'forward': 'drop',
        'ping': True, 'logging': 'off', 'ssh_limit': False, 'lockdown': False, 'revert_in': 0,
        'rules': [{'service': 'ssh', 'action': 'allow', 'direction': 'in', 'proto': 'both', 'port': '', 'source': '', 'scope': 'everywhere', 'family': 'both', 'iface': '', 'comment': '', 'raw': ''}],
        'listeners': [
            {'proto': 'tcp', 'address': '0.0.0.0', 'port': 22, 'process': 'sshd', 'pid': 700, 'uid': 0, 'verdict': 'everywhere'},
            {'proto': 'tcp', 'address': '127.0.0.1', 'port': 631, 'process': 'cupsd', 'pid': 701, 'uid': 0, 'verdict': 'local'},
            {'proto': 'udp', 'address': '0.0.0.0', 'port': 21027, 'process': 'syncthing', 'pid': 900, 'uid': 1000, 'verdict': 'blocked'},
        ],
        'networks': [{'name': 'Home Wi-Fi', 'iface': 'wlan0', 'uuid': '0b6f2c55-1a4e-4c68-9d1d-2a5c4cbe1f00', 'trust': 'public', 'active': True}],
        'foreign': [{'owner': 'Docker', 'name': 'ip nat', 'rules': 4}],
    }


def load():
    try:
        with open(STATE) as f:
            return json.load(f)
    except FileNotFoundError:
        return default_state()


def status(state, blocks=False):
    rules = [dict(r, id=i) for i, r in enumerate(state['rules'])]
    caps = {k: True for k in ('edit', 'trust', 'sources', 'limit', 'reject', 'outgoing_rules', 'outgoing_policy', 'forward_policy', 'ping', 'logging', 'ssh_limit', 'boot', 'lockdown')}
    out = {k: state[k] for k in ('backend', 'running', 'boot', 'incoming', 'outgoing', 'forward', 'ping', 'logging', 'ssh_limit', 'lockdown', 'revert_in', 'listeners', 'networks', 'foreign')}
    out.update(system='linux', rules=rules, capabilities=caps, conflicts=[], installed=['own'], zone='', needs_anchor=False,
               blocks=[{'time': '2026-11-17T10:00:00', 'direction': 'in', 'proto': 'TCP', 'source': '192.0.2.5', 'port': 23, 'iface': 'wlan0'}] if blocks else [])
    return out


def same(a, b):
    keys = ('action', 'direction', 'proto', 'port', 'service', 'source', 'scope', 'family', 'iface')
    return all(a.get(k, d) == b.get(k, d) for k, d in zip(keys, ('allow', 'in', 'both', '', '', '', 'everywhere', 'both', '')))


def main():
    mode = sys.argv[1]
    request = json.loads(sys.stdin.read())
    with open(LOG, 'a') as f:
        f.write(json.dumps({'mode': mode, 'request': request}) + '\n')
    op = request['op']
    if mode != 'manage' and op not in READ_ONLY:
        print('operation needs the manage action', file=sys.stderr)
        return 1
    state = load()
    failure = None
    state['revert_in'] = 0
    if op == 'enable':
        state['running'] = True
    elif op == 'disable':
        state['running'] = False
    elif op == 'add_rule':
        rule = request['rule']
        if not any(same(r, rule) for r in state['rules']):
            state['rules'].append(rule)
    elif op == 'remove_rule':
        before = len(state['rules'])
        state['rules'] = [r for r in state['rules'] if not same(r, request['rule'])]
        if len(state['rules']) == before:
            failure = 'That rule is no longer there.'
    elif op == 'set_defaults':
        for key in ('incoming', 'outgoing', 'forward'):
            if request.get(key):
                state[key] = request[key]
    elif op == 'set_option':
        option = request['option']
        if option == 'logging':
            state['logging'] = request['logging']
        else:
            state[option] = request['on']
    elif op == 'set_trust':
        for n in state['networks']:
            if n['uuid'] == request['uuid']:
                n['trust'] = request['trust']
    elif op == 'lockdown':
        state['lockdown'] = request['on']
    if request.get('revert_after'):
        state['revert_in'] = request['revert_after']
    with open(STATE, 'w') as f:
        json.dump(state, f)
    if op == 'authorize':
        return 0
    print(json.dumps({'status': status(state, blocks=op == 'blocks'), 'failure': failure}))
    return 0 if failure is None else 3


if __name__ == '__main__':
    sys.exit(main())

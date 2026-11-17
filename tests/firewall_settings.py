#!/usr/bin/env python3
"""Settings → Network → Firewall against a fake helper; never touches a firewall.

The compositor looks for pkexec only in the system directories, so the test
re-runs itself in a private user and mount namespace (namespace root is a
subordinate uid, used only to bind-mount a fake over /usr/bin/pkexec), then
drops back to the user's own uid for the compositor. The fake pkexec runs
tests/firewall_fake_helper.py instead of the real helper and can refuse, as a
dismissed password dialog does (exit 126). Needs util-linux unshare/setpriv
and a subuid range for newuidmap.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

HERE = Path(__file__).resolve().parent


def reexec(no_policy=False):
    uid, gid = os.getuid(), os.getgid()
    sub = next((line.split(':') for line in Path('/etc/subuid').read_text().splitlines() if line.split(':')[0] in (os.environ.get('USER', ''), str(uid))), None)
    if not sub:
        print('SKIP: firewall_settings needs a /etc/subuid range for newuidmap')
        sys.exit(0)
    # Namespace root is a subordinate uid that cannot enter the user's home,
    # so the fake is staged where it can be read.
    with tempfile.TemporaryDirectory(prefix='rediwm-firewall-pkexec-') as stage:
        os.chmod(stage, 0o755)
        fake = Path(stage) / 'pkexec'
        fake.write_bytes((HERE / 'fixtures' / 'firewall_pkexec.sh').read_bytes())
        fake.chmod(0o755)
        # Settings runs pkexec only when polkit's actions name its helper.
        actions = Path(stage) / 'actions'
        actions.mkdir(mode=0o755)
        policy = actions / 'org.rediwm.firewall.policy'
        text = (HERE.parent / 'zig-out' / 'share' / 'polkit-1' / 'actions' / 'org.rediwm.firewall.policy').read_text()
        if no_policy:
            text = text.replace('/rediwm-firewall-helper<', '/some-other-helper<')
        policy.write_text(text)
        policy.chmod(0o644)
        inner = f'mount --bind {fake} /usr/bin/pkexec && mount --bind {actions} /usr/share/polkit-1/actions && exec setpriv --reuid={uid} --regid={gid} --keep-groups {sys.executable} -I {__file__} --inside' + (' --no-policy' if no_policy else '')
        command = ['unshare', '--user', '--mount', f'--map-users=0:{sub[1]}:1', f'--map-users={uid}:{uid}:1', f'--map-groups=0:{sub[1]}:1', f'--map-groups={gid}:{gid}:1', '--setuid', '0', '--setgid', '0', 'sh', '-c', inner]
        return subprocess.run(command).returncode


if '--inside' not in sys.argv:
    sys.exit(reexec() or reexec(no_policy=True))

sys.path.insert(0, str(HERE))
from ipc_client import IPCClient, spawn_compositor, stop_process  # noqa: E402
from power_profiles import wait_for as _wait_for  # noqa: E402

CURRENT = {}


def wait_for(predicate, description, *args, **kwargs):
    try:
        return _wait_for(predicate, description, *args, **kwargs)
    except AssertionError:
        if CURRENT.get('page'):
            print('page text:', CURRENT['page'].texts(), file=sys.stderr)
            print('helper requests:', CURRENT['page'].requests(), file=sys.stderr)
        raise
from ui_driver import UIDriver  # noqa: E402


class Page:
    def __init__(self, ipc, tmp):
        self.ipc, self.ui, self.tmp = ipc, UIDriver(ipc), tmp

    def widgets(self):
        return self.ui.widgets()

    def has(self, name):
        return any(w.get('name') == name for w in self.widgets())

    def find(self, name):
        return self.ui.find(name, panel='control_center')

    def label(self, name):
        return self.find(name).get('label', '')

    def texts(self):
        return ' '.join(w.get('label') or w.get('text') or '' for w in self.widgets())

    def click(self, name):
        wait_for(lambda: self.has(name) and not self.find(name)['is_disabled'], name + ' enabled')
        self.ui.click(self.ui.scroll_into_view(name, panel='control_center'), panel='control_center')
        self.ui.wait_settled('control_center')

    def key(self, code):
        for pressed in (True, False):
            self.ipc.action('key', {'keycode': code, 'pressed': pressed})
        time.sleep(.12)

    def choose(self, name, steps):
        self.click(name)
        for _ in range(abs(steps)):
            self.key(108 if steps > 0 else 103)
        self.key(28)
        self.ui.wait_settled('control_center')

    def type_into(self, name, text):
        self.click(name)
        self.ipc.type_text(text)
        self.ui.wait_settled('control_center')

    def shot(self, name):
        """FIREWALL_TEST_SHOTS=<dir> keeps screenshots for a visual check."""
        directory = os.environ.get('FIREWALL_TEST_SHOTS')
        if directory:
            self.ui.wait_settled('control_center')
            self.ipc.screenshot(str(Path(directory) / f'{name}.png'))

    def requests(self):
        log = self.tmp / 'helper.log'
        return [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []

    def wait_request(self, op, count=1, **expect):
        def found():
            hits = [r for r in self.requests() if r['request']['op'] == op and all(r['request'].get(k) == v for k, v in expect.items())]
            return hits[count - 1] if len(hits) >= count else None
        wait_for(found, f'{op} request {expect}')
        return found()

    def open_network(self):
        self.ipc.open_control_center()
        self.ui.wait_settled('control_center')
        self.ui.click('network', panel='control_center')
        self.ui.wait_settled('control_center')
        wait_for(lambda: self.has('firewall_card'), 'firewall card')


def scenario_manage(page):
    page.open_network()
    page.wait_request('status')
    wait_for(lambda: 'Unlock' in page.label('firewall_unlock'), 'unlock button')
    assert page.find('firewall_enabled')['is_disabled'], 'toggle must wait for Unlock'
    first = page.requests()[0]
    assert first['mode'] == 'read', first

    page.click('firewall_unlock')
    page.wait_request('authorize')
    wait_for(lambda: page.label('firewall_unlock') == 'Lock', 'unlocked')
    page.click('firewall_enabled')
    assert page.wait_request('enable')['mode'] == 'manage'
    wait_for(lambda: 'Protected by' in page.texts(), 'protected summary')
    page.ui.scroll_into_view('firewall_card', panel='control_center')
    page.shot('overview')

    page.click('firewall_manage')
    wait_for(lambda: page.has('firewall_rules') and page.has('firewall_listeners') and page.has('firewall_advanced'), 'sub-view')
    assert page.has('firewall_foreign') and 'Docker' in page.texts()
    page.shot('manage-top')

    # Add a port rule through the form.
    page.click('firewall_add')
    wait_for(lambda: page.has('firewall_form'), 'form')
    page.choose('firewall_form_kind', 1)
    wait_for(lambda: page.has('firewall_form_port'), 'port field')
    page.type_into('firewall_form_port', '8080')
    page.type_into('firewall_form_comment', 'dev server')
    page.shot('form')
    page.click('firewall_form_add')
    rule = page.wait_request('add_rule')['request']['rule']
    assert rule['port'] == '8080' and rule['proto'] == 'tcp' and rule['comment'] == 'dev server', rule
    wait_for(lambda: not page.has('firewall_form'), 'form closes')
    wait_for(lambda: 'Port 8080 TCP' in page.texts(), 'new rule listed')

    # Bad input stays in the form with a reason and sends nothing.
    page.click('firewall_add')
    page.choose('firewall_form_kind', 2)
    page.type_into('firewall_form_address', '300.1.1.1')
    before = len(page.requests())
    page.click('firewall_form_add')
    wait_for(lambda: 'Enter an IP address' in page.texts(), 'address error')
    assert len(page.requests()) == before
    page.click('firewall_form_cancel')

    # The exposed sshd: Block removes the rule that opens port 22, and since
    # that rule allows SSH the change waits to be kept.
    page.click('firewall_listener_block')
    removal = page.wait_request('remove_rule')['request']
    assert removal['rule']['service'] == 'ssh' and removal['revert_after'] == 20, removal
    page.click('firewall_keep')
    page.wait_request('confirm')

    # Trust, outgoing policy (reverting), logging, recent blocks.
    page.choose('firewall_trust', 1)
    trust = page.wait_request('set_trust')['request']
    assert trust['trust'] == 'home' and trust['uuid'].startswith('0b6f2c55'), trust
    page.choose('firewall_outgoing', 1)
    outgoing = page.wait_request('set_defaults')['request']
    assert outgoing['outgoing'] == 'drop' and outgoing['revert_after'] == 20, outgoing
    page.choose('firewall_logging', 1)
    assert page.wait_request('set_option')['request']['logging'] == 'low'
    page.click('firewall_blocks')
    page.wait_request('blocks')
    wait_for(lambda: '192.0.2.5' in page.texts(), 'block listed')
    page.shot('blocks')
    page.ui.scroll_into_view('firewall_listeners', panel='control_center')
    page.shot('listeners')
    page.ui.scroll_into_view('firewall_incoming', panel='control_center')
    page.shot('advanced')

    # Back to the Network page; leaving the page forgets the unlock.
    page.click('firewall_back')
    wait_for(lambda: page.has('firewall_card') and not page.has('firewall_rules'), 'network page')
    page.ui.click('general', panel='control_center')
    page.ui.wait_settled('control_center')
    page.ui.click('network', panel='control_center')
    page.ui.wait_settled('control_center')
    wait_for(lambda: page.has('firewall_unlock') and page.label('firewall_unlock') == 'Unlock', 'locked again after leaving')


def scenario_denied(page):
    # Reads need the password here (FreeBSD's polkit today): the card asks for
    # an unlock before showing anything, and never prompts by itself.
    (page.tmp / 'deny-read').write_text('1')
    page.open_network()
    wait_for(lambda: 'Unlock to view the firewall.' in page.texts(), 'unlock to view')
    assert [r['request']['op'] for r in page.requests()] == [], 'denied reads never reach the helper'
    (page.tmp / 'deny-read').unlink()
    page.click('firewall_unlock')
    page.wait_request('authorize')
    status = page.wait_request('status')
    assert status['mode'] == 'manage', status
    wait_for(lambda: page.has('firewall_manage') and not page.find('firewall_manage')['is_disabled'], 'status shown')
    # A dismissed password dialog keeps the page locked.
    page.click('firewall_unlock')
    wait_for(lambda: page.label('firewall_unlock') == 'Unlock', 'locked by the user')
    (page.tmp / 'deny-manage').write_text('1')
    page.click('firewall_unlock')
    wait_for(lambda: 'cancelled or denied' in page.texts(), 'denied message')
    assert page.label('firewall_unlock') == 'Unlock'


def scenario_no_policy(page):
    # polkit's actions name another helper: pkexec would fall back to its
    # generic action and ask for a password, so Settings runs nothing.
    page.open_network()
    wait_for(lambda: 'its polkit policy is missing' in page.texts(), 'missing policy message')
    time.sleep(1)
    assert page.requests() == [], page.requests()
    assert page.find('firewall_unlock')['is_disabled']


def run(scenario, scale='1'):
    with tempfile.TemporaryDirectory(prefix='rediwm-firewall-') as directory:
        tmp = Path(directory)
        process, log = spawn_compositor(tmp, scale=scale, config_content='[compositor]\nxwayland = false\n', env_extra={
            'XDG_CACHE_HOME': str(tmp), 'PIPEWIRE_RUNTIME_DIR': str(tmp), 'PULSE_SERVER': 'unix:/nonexistent-rediwm-test-pulse',
            'FIREWALL_FAKE_STATE': str(tmp / 'state.json'), 'FIREWALL_FAKE_LOG': str(tmp / 'helper.log'),
            'FIREWALL_FAKE_DIR': str(tmp), 'FIREWALL_FAKE_HELPER': str(HERE / 'firewall_fake_helper.py'),
        })
        try:
            with IPCClient(tmp, timeout=15) as ipc:
                page = Page(ipc, tmp)
                CURRENT['page'] = page
                scenario(page)
        except BaseException:
            log.flush()
            print(Path(log.name).read_text()[-6000:] if hasattr(log, 'name') else 'no log', file=sys.stderr)
            raise
        finally:
            stop_process(process)


if __name__ == '__main__':
    scale = os.environ.get('REDIWM_TEST_SCALE', '1')
    if '--no-policy' in sys.argv:
        run(scenario_no_policy, scale)
        print('PASS Firewall settings: no pkexec without the polkit policy')
    else:
        run(scenario_manage, scale)
        run(scenario_denied, scale)
        print('PASS Firewall settings: overview, unlock, rules, listeners, trust, revert, denied reads')

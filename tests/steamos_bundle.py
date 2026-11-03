#!/usr/bin/env python3
"""Check a built portable tree without changing the host desktop or system.
Usage: python3 tests/steamos_bundle.py /path/to/rediwm-steamos
"""
import os
from pathlib import Path
import subprocess
import sys
import tempfile

bundle = Path(sys.argv[1]).resolve()
assert not (bundle / 'bin/rediwm-transfers').exists()
assert not (bundle / 'share/wayland-sessions').exists()
for entry in (bundle / 'share/applications').glob('*.desktop'):
    assert '=/usr/local/bin/' not in entry.read_text()
assert not (bundle / 'share/applications/rediwm-transfers.desktop').exists()
for name in ('libwlroots-0.20.so', 'libwayland-client.so.0',
             'libwayland-server.so.0', 'libwayland-cursor.so.0'):
    assert (bundle / 'lib/rediwm' / name).is_file(), name
for binary in (bundle / 'bin').iterdir():
    dynamic = subprocess.check_output(['readelf', '-d', binary], text=True)
    assert 'libtorrent' not in dynamic
    assert '/work/' not in dynamic
    assert '$ORIGIN/../lib/rediwm' in dynamic
with tempfile.TemporaryDirectory(prefix='rediwm-portable-') as tmp:
    env = dict(os.environ, HOME=tmp)
    subprocess.run(['sh', bundle / 'install'], env=env, check=True)
    installed = Path(tmp) / '.local/opt/rediwm-steamos'
    # The actual loader check must also pass after relocation.
    subprocess.run(['sh', installed / 'run', '--check'], env=env,
                   stdout=subprocess.DEVNULL, check=True)
    assert list(Path(tmp).iterdir()) == [Path(tmp) / '.local']
    # An update must not silently overwrite an existing installation.
    result = subprocess.run(['sh', bundle / 'install'], env=env,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    assert result.returncode != 0
print('PASS: private libraries, omitted features, user install, relocation, overwrite refusal')

#!/usr/bin/env python3
"""Exercise the local signing CLI without exporting private material.

Author: Timur Isaev
"""
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile

binary = Path(sys.argv[1]).resolve()
root = Path(__file__).resolve().parents[3]


def call(*arguments, success=True):
    result = subprocess.run([str(binary), *map(str, arguments)], capture_output=True, text=True, check=False)
    assert (result.returncode == 0) == success, (arguments[0], result.stderr)
    return result


def payload(path):
    import base64
    return json.loads(base64.b64decode(json.loads(path.read_bytes())['payload']))


with tempfile.TemporaryDirectory(prefix='alloy-trust-cli-') as temporary:
    directory = Path(temporary) / 'development'
    call('init', directory)
    assert stat.S_IMODE(directory.stat().st_mode) == 0o700
    key_paths = list((directory / 'keys').glob('*.key'))
    assert len(key_paths) == 18
    assert all(stat.S_IMODE(path.stat().st_mode) == 0o600 and path.stat().st_size == 32 for path in key_paths)
    call('init', directory, success=False)
    call('init', root / 'runtime/trust/SHOULD-NOT-EXIST', success=False)
    assert not (root / 'runtime/trust/SHOULD-NOT-EXIST').exists()
    source = Path(temporary) / 'profile.json'
    source.write_text('{"profileId":"gp_cli","revision":1}')
    kind = 'application/vnd.alloy.game-profile+json;version=1'
    call('sign', directory, kind, source, 'profile.envelope.json')
    call('sign', directory, kind, source, 'root.json', success=False)
    assert len(payload(directory / 'targets.json')['targets']) == 1
    call('timestamp', directory)
    before = payload(directory / 'root.json')
    call('rotate', directory, 'root')
    after = payload(directory / 'root.json')
    assert after['version'] == 2 and len(json.loads((directory / 'root.json').read_bytes())['signatures']) == 4
    assert before['roles']['root'] != after['roles']['root']
    call('revoke', directory, 'profile', 'gp_cli', '1')
    key = after['roles']['profiles']['keyIds'][0]
    call('revoke', directory, 'key', key)
    revoked = payload(directory / 'revocation.json')
    assert revoked['revokedProfiles'] == [{'profileId': 'gp_cli', 'revision': 1}]
    assert revoked['revokedKeys'] == [key]
    call('revoke', directory, 'key', after['roles']['root']['keyIds'][0], success=False)
    # Permissions fail closed; do not display the file's secret content.
    os.chmod(key_paths[2], 0o644)
    # Every signer validates all keys it loads; choose a current profile key.
    profile_key = directory / 'keys' / (key.removeprefix('sha256:') + '.key')
    os.chmod(profile_key, 0o644)
    call('sign', directory, kind, source, 'bad.json', success=False)
print('CLI init/sign/timestamp/rotate/revoke, restricted permissions and rejection controls PASS')

#!/usr/bin/env python3
"""Scan first-party tracked/staged files; never print key material.

Author: Timur Isaev
"""
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[3]
ALLOWLIST = {
    # Exact pre-existing intentionally public compiler fixture files only.
    "runtime/profile-compiler/Tests/Fixtures/TEST-ONLY-key.json": "4190d8095587eb93f732d5026959546814c4c536f8bb3eb1ee4e142d1cf91ebd",
    "runtime/profile-compiler/Tests/Fixtures/TEST-ONLY-vendor-key.json": "45e211f365afceccb1349ad9ffefbf2b504756bb2684d3dd1f318ec136036cd6",
}


def suspicious(path, data):
    if path.endswith(('.key', '.p12', '.pfx')):
        return True
    if re.search(rb'-----BEGIN (?:[A-Z0-9 ]* )?PRIVATE KEY-----', data):
        return True
    return bool(re.search(rb'["\'](?:privateKey|private_key|seed)["\']\s*[:=]\s*["\'][A-Za-z0-9+/=\\]{32,}', data))


def main():
    files = subprocess.check_output([
        'git', 'ls-files', '-z', '--', '.', ':!third_party/**',
        ':!tools/toolchains/**', ':!spikes/*/work/**',
    ], cwd=ROOT).decode().split('\0')
    failures = []
    exempted = []
    for name in filter(None, files):
        path = ROOT / name
        if path.is_symlink():
            continue
        data = path.read_bytes()
        if suspicious(name, data):
            if ALLOWLIST.get(name) == hashlib.sha256(data).hexdigest():
                exempted.append(name)
            else:
                failures.append(name)
    # The negative control must exercise the detector, not only a filename rule.
    with tempfile.TemporaryDirectory(prefix='alloy-key-scan-') as temporary:
        planted = Path(temporary) / 'planted.txt'
        planted.write_text('-----BEGIN ' + 'PRIVATE KEY-----\nTEST-ONLY-PLANTED\n')
        assert suspicious(str(planted), planted.read_bytes())
        assert suspicious('unknown.json', json.dumps({'privateKey': 'A' * 44}).encode())
        assert not suspicious('public.json', json.dumps({'publicKey': 'A' * 44}).encode())
    report = {'status': 'FAIL' if failures else 'PASS', 'paths': failures,
              'existingTestOnlyFixtures': exempted, 'plantedPrivateKeyDetected': True}
    print(json.dumps(report, sort_keys=True))
    raise SystemExit(bool(failures))


if __name__ == '__main__':
    main()

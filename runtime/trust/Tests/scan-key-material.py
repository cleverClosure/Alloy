#!/usr/bin/env python3
"""Scan first-party tracked/staged files; never print key material.

Author: Timur Isaev
"""
import base64
import hashlib
import json
from pathlib import Path
import re
import secrets
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


def scan(root):
    files = subprocess.check_output([
        'git', 'ls-files', '-z', '--', '.', ':!third_party/**',
        ':!tools/toolchains/**', ':!spikes/*/work/**',
    ], cwd=root).decode().split('\0')
    failures = []
    exempted = []
    for name in filter(None, files):
        path = root / name
        if path.is_symlink():
            continue
        data = path.read_bytes()
        if suspicious(name, data):
            if ALLOWLIST.get(name) == hashlib.sha256(data).hexdigest():
                exempted.append(name)
            else:
                failures.append(name)
    return failures, exempted


def main():
    failures, exempted = scan(ROOT)
    # Exercise the same Git enumeration and detector as the real scan. A fresh
    # 32-byte signing seed stays in this disposable repository and is not committed.
    with tempfile.TemporaryDirectory(prefix='alloy-key-scan-') as temporary:
        root = Path(temporary)
        subprocess.run(['git', 'init', '--quiet', str(root)], check=True)
        (root / 'public.json').write_text(json.dumps({'publicKey': 'A' * 44}))
        subprocess.run(['git', 'add', 'public.json'], cwd=root, check=True)
        assert scan(root) == ([], [])
        seed = base64.b64encode(secrets.token_bytes(32)).decode()
        planted = root / 'planted.json'
        planted.write_text(json.dumps({'label': 'TEST-ONLY planted signing seed', 'privateKey': seed}))
        subprocess.run(['git', 'add', 'planted.json'], cwd=root, check=True)
        assert scan(root) == (['planted.json'], [])
        planted.unlink()
        subprocess.run(['git', 'add', '-u'], cwd=root, check=True)
        assert scan(root) == ([], [])
        marker = ('-----BEGIN ' + 'PRIVATE KEY-----\nTEST-ONLY-PLANTED\n').encode()
        assert suspicious('unknown.txt', marker)
    report = {'status': 'FAIL' if failures else 'PASS', 'paths': failures,
              'existingTestOnlyFixtures': exempted, 'plantedPrivateKeyDetected': True,
              'gitEnumerationControl': 'pass'}
    print(json.dumps(report, sort_keys=True))
    raise SystemExit(bool(failures))


if __name__ == '__main__':
    main()

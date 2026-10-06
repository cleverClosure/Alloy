"""Wine guest scenario construction for an explicit runtime tree. Author: Timur Isaev."""

from pathlib import Path
import struct

from .common import file_bytes, file_digest, hashed, require
from .scenario import runtime_digest, validate


def inventory(root):
    root = Path(root)
    require(root.is_dir() and not root.is_symlink(), 'wine:unsafe_runtime_root')
    files = {}
    for path in sorted(root.rglob('*')):
        require(not path.is_symlink(), 'wine:runtime_links_must_be_materialized')
        if path.is_dir():
            continue
        require(path.is_file(), 'wine:runtime_special_file')
        name = path.relative_to(root).as_posix()
        key = 'wine' if name == 'loader/wine' else 'server' if name == 'server/wineserver' else 'file-' + str(len(files))
        files[key] = {'path': name, **file_digest(path)}
    require('wine' in files and 'server' in files, 'wine:loader_or_server_missing')
    require(len(files) <= 8192, 'wine:inventory_too_large')
    return files


def architecture(subject):
    data = file_bytes(subject)
    require(data[:2] == b'MZ' and len(data) >= 64, 'wine:subject_not_pe')
    offset = struct.unpack_from('<I', data, 60)[0]
    require(offset + 6 <= len(data) and data[offset:offset + 4] == b'PE\0\0', 'wine:subject_not_pe')
    machine = struct.unpack_from('<H', data, offset + 4)[0]
    require(machine in (0x8664, 0xaa64), 'wine:unsupported_guest_architecture')
    return 'x64' if machine == 0x8664 else 'arm64'


def scenario(runtime_root, subject):
    subject = Path(subject)
    arch = architecture(subject)
    runtime = {'kind': 'wine', 'executable': 'loader/wine', 'files': inventory(runtime_root)}
    runtime['sha256'] = runtime_digest(runtime)
    environment = {'WINEPREFIX': '{work}/prefix', 'WINELOADER': '{runtime}',
        'WINESERVER': '{runtime_file:server}', 'ALLOY_RUNTIME_GENERATION': '{runtime_root}',
        'WINEDEBUG': '-all', 'WINEDLLOVERRIDES': 'xtajit64=n;mscoree,mshtml=', 'FEX_SILENTLOG': '1'}
    def step(name, phase, argv, timeout=90):
        return {'id': name, 'phase': phase, 'argv': argv, 'environment': dict(environment),
                'timeout_seconds': timeout, 'expected_exit': 0}
    steps = [step('boot', 'setup', ['{runtime}', 'wineboot', '-u'])]
    if arch == 'x64':
        require(any(item['path'] == 'dlls/libarm64ecfex/aarch64-windows/libarm64ecfex.dll'
                    for item in runtime['files'].values()), 'wine:fex_missing')
        steps.append(step('register', 'setup', ['{runtime}', 'reg', 'add',
            'HKLM\\Software\\Microsoft\\Wow64\\amd64', '/ve', '/t', 'REG_SZ', '/d', 'libarm64ecfex.dll', '/f']))
    steps.append(step('guest', 'run', ['{runtime}', '{subject}', '{control}'], 30))
    steps[-1]['environment']['WINEDEBUG'] = '-all,+module,+loaddll'
    steps.extend([step('stop-server', 'teardown', ['{runtime_file:server}', '-k'], 3),
                  step('wait-server', 'teardown', ['{runtime_file:server}', '-w'], 3)])
    steps[-2]['expected_exit'] = [0, 1]  # 1 means no server was running; -w must still succeed.
    subject_digest = file_digest(subject)['sha256']
    result = {'version': 2, 'id': 'wine-known-answer-' + arch, 'revision': 1,
        'subject': {'kind': 'wine', 'path': subject.name, 'sha256': subject_digest}, 'runtime': runtime,
        'host': {'os': 'Darwin', 'architectures': ['arm64'], 'minimum_memory_bytes': 0, 'requirements': {}},
        'inputs': {}, 'steps': steps, 'observables': [
            {'id': name, 'source': {'kind': 'stdout-json', 'step': 'guest', 'path': None, 'key': [name]},
             'comparison': {'class': 'exact', 'absolute': 0, 'relative': 0, 'direction': 'any'}, 'unit': 'integer'}
            for name in ('answer', 'sum')],
        'timing_sensitive': False, 'timeout_seconds': 180, 'retry_limit': 0,
        'context': {'game_build': subject_digest, 'profile': hashed({'wine': 'private-prefix-v1'}),
            'automation': hashed({'guest': 'known-answer-v1'}), 'cache_state': 'fresh-private-prefix',
            'privacy': 'local-only-no-accounts'}, 'legacy': None}
    return validate(result)

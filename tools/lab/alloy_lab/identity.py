"""Observed identities without machine-unique identifiers. Author: Timur Isaev."""

import os
from pathlib import Path
import platform
import subprocess
import sys

from .common import decode, file_bytes, file_digest, hashed, require, safe_file
from .scenario import runtime_digest

PACKAGE = Path(__file__).resolve().parent


def source_files():
    from .scenario import LEGACY
    return {**{path.name: path for path in sorted(PACKAGE.glob('*.py'))},
            'lab.py': PACKAGE.parent / 'lab.py', 'lab001-scenario.py': LEGACY / 'scenario.py'}


def source_identity():
    return {'id': 'alloy-lab-v2', 'sha256': hashed({name: file_digest(path) for name, path in source_files().items()})}


def archive_sources(output):
    import hashlib
    from .storage import private_directory
    target = private_directory(Path(output) / 'sources')
    inventory = {}
    for name, path in source_files().items():
        data = file_bytes(path)
        (target / name).write_bytes(data)
        inventory[name] = {'sha256': hashlib.sha256(data).hexdigest(), 'bytes': len(data)}
    return {'id': 'alloy-lab-v2', 'sha256': hashed(inventory)}


def scheduler_identity():
    return {'id': 'local-queue-v2', 'sha256': file_digest(PACKAGE / 'scheduler.py')['sha256']}


def host_identity():
    def sysctl(name):
        return subprocess.check_output(['/usr/sbin/sysctl', '-n', name], text=True, timeout=5).strip()
    require(platform.system() == 'Darwin', 'host:mac_only')
    firmware = 'unavailable'
    try:
        data = subprocess.check_output(['/usr/sbin/system_profiler', 'SPHardwareDataType', '-json'], timeout=10)
        hardware = decode(data)['SPHardwareDataType'][0]
        firmware = str(hardware.get('boot_rom_version', 'unavailable'))
    except (OSError, ValueError, KeyError, subprocess.SubprocessError):
        pass
    return {'os': platform.system(), 'os_release': platform.release(), 'os_build': sysctl('kern.osversion'),
            'architecture': platform.machine(), 'hardware_class': sysctl('hw.model'), 'firmware': firmware,
            'memory_bytes': int(sysctl('hw.memsize')), 'cpu_count': os.cpu_count() or 1, 'capabilities': {}}


def requirements_met(scenario, host):
    expected = scenario['host']
    values = {**host, **host['capabilities']}
    return (host['os'] == expected['os'] and host['architecture'] in expected['architectures'] and
            host['memory_bytes'] >= expected['minimum_memory_bytes'] and
            all(values.get(key) == value for key, value in expected['requirements'].items()))


def runtime_manifest(scenario, root):
    expected = scenario['runtime']
    observed = {'kind': expected['kind'], 'executable': expected['executable'], 'files': {}}
    for name, entry in expected['files'].items():
        observed['files'][name] = {'path': entry['path'], **file_digest(safe_file(root, entry['path']))}
    return observed


def runtime_identity(scenario, root):
    return runtime_digest(runtime_manifest(scenario, root))


def input_identities(scenario, root):
    return {name: file_digest(safe_file(root, entry['path']))['sha256'] for name, entry in scenario['inputs'].items()}

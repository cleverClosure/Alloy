"""Observed identities without machine-unique identifiers. Author: Timur Isaev."""

import os
from pathlib import Path
import platform
import subprocess
import sys

from .common import decode, file_digest, hashed, require, safe_file
from .scenario import runtime_digest

PACKAGE = Path(__file__).resolve().parent


def source_identity():
    sources = {path.name: file_digest(path) for path in sorted(PACKAGE.glob('*.py'))}
    sources['lab.py'] = file_digest(PACKAGE.parent / 'lab.py')
    return {'id': 'alloy-lab-v2', 'sha256': hashed(sources)}


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


def runtime_identity(scenario, root):
    expected = scenario['runtime']
    observed = {'kind': expected['kind'], 'executable': expected['executable'], 'files': {}}
    for name, entry in expected['files'].items():
        observed['files'][name] = {'path': entry['path'], **file_digest(safe_file(root, entry['path']))}
    return runtime_digest(observed)


def input_identities(scenario, root):
    return {name: file_digest(safe_file(root, entry['path']))['sha256'] for name, entry in scenario['inputs'].items()}

"""Shared synthetic Wine proof helpers. Author: Timur Isaev."""

import os
from pathlib import Path


def private_cleanup(root):
    # Materialized runtime directories are sealed. Only this proof's disposable copy is removed.
    for parent, directories, _ in os.walk(root):
        os.chmod(parent, 0o700)
        for name in directories:
            path = Path(parent) / name
            if not path.is_symlink():
                path.chmod(0o700)


def policy(name, cpu):
    return {"id": name, "providerDirectory": "C:\\alloy\\providers\\x86_64-windows",
            "resolved": {"ruleIds": [name], "cpuProvider": cpu, "graphicsProvider": name,
                         "syncProvider": "conservative", "dllOverrides": {"alloyblocked": "disabled"},
                         "environment": {"LANG": name}, "workingDirectory": "G:\\cwd",
                         "networkPolicy": "allow", "debugPolicy": "off", "services": {}}}



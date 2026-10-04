"""Read-only shared source identity/index/dirty-byte snapshots. Author: Timur Isaev."""
import hashlib
import os
from pathlib import Path

from fex_inventory import common


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def snapshot(sources):
    result = {}
    for name, repo in sorted(sources.items()):
        records = common.git(repo, 'status', '--porcelain=v1', '-z', '--no-renames', '--untracked-files=no', binary=True).split(b'\0')
        dirty = []
        for record in filter(None, records):
            status, relative = record[:2].decode(), record[3:].decode()
            path = repo / relative
            parts = relative.lower().split('/')
            excluded = any(part == 'd3d12' or part.startswith('vkd3d') for part in parts)
            if path.is_symlink():
                state = {'kind': 'symlink', 'target': os.readlink(path)}
            elif not path.exists():
                state = {'kind': 'absent'}
            elif excluded:
                state = {'kind': 'excluded-content-not-read'}
            else:
                common.safe_path(relative)
                common.require(path.is_file(), 'preservation:unexpected_dirty_directory')
                state = {'kind': 'regular', 'sha256': sha(path)}
            dirty.append({'status': status, 'path': relative, **state})
        index = Path(common.git(repo, 'rev-parse', '--git-path', 'index'))
        if not index.is_absolute():
            index = repo / index
        result[name] = {'head': common.git(repo, 'rev-parse', 'HEAD'), 'branch': common.git(repo, 'branch', '--show-current'), 'refs': common.git(repo, 'for-each-ref', '--format=%(refname) %(objectname)').splitlines(), 'index_sha256': sha(index), 'dirty': dirty}
    return result

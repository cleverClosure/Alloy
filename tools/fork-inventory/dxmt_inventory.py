#!/usr/bin/env python3
"""Committed patch-only DXMT inventory with an exact materialization allowlist. Author: Timur Isaev."""

import argparse
import hashlib
import os
from pathlib import Path
import re
import subprocess
import tempfile

from fex_inventory import common, ROOT

HERE = ROOT / 'spikes/GFX-001/patch-inventory'
PREFIX = 'spikes/GFX-001/instrumentation/'
require, canonical = common.require, common.canonical


def patch_paths(content):
    """Inspect headers before any target object is read; reject ambiguous formats."""
    text = content.decode('utf-8')
    paths, current, headers = [], None, set()
    for line in text.splitlines():
        if line.startswith('diff --git '):
            require(current is None or headers == {'---', '+++'}, 'patch:missing_file_headers')
            match = re.fullmatch(r'diff --git a/(\S+) b/(\S+)', line)
            require(match is not None, 'patch:ambiguous_path')
            old, new = match.groups()
            common.safe_path(old)
            common.safe_path(new)
            require(old == new, 'patch:rename_not_supported')
            require('"' not in old and old.startswith('src/d3d11/'), 'patch:outside_d3d11_allowlist')
            require(old not in paths, 'patch:duplicate_file')
            paths.append(old)
            current, headers = old, set()
        elif line.startswith(('--- ', '+++ ')):
            require(current is not None, 'patch:orphan_file_header')
            kind, value = line[:3], line[4:]
            require(kind not in headers, 'patch:duplicate_file_header')
            if value != '/dev/null':
                require(value.startswith(('a/', 'b/')), 'patch:ambiguous_path')
                path = common.safe_path(value[2:])
                require(path == current and value[:2] == ('a/' if kind == '---' else 'b/'), 'patch:header_mismatch')
            headers.add(kind)
        elif line.startswith('diff '):
            raise common.Invalid('patch:unsupported_diff_format')
        elif line.startswith(('rename ', 'copy ', 'Binary files ', 'GIT binary patch')):
            raise common.Invalid('patch:unsupported_metadata')
        elif re.match(r'(new file mode|deleted file mode|old mode|new mode) ', line):
            require(line.endswith(' 100644'), 'patch:non_regular_file')
        elif line.startswith('index '):
            require(re.fullmatch(r'index [0-9a-f]+\.\.[0-9a-f]+(?: 100644)?', line), 'patch:invalid_index_mode')
    require(bool(paths) and headers == {'---', '+++'}, 'patch:missing_file_headers')
    return sorted(paths)


def scratch_git(repo, *args, check=True):
    env = {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}
    env.update(GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null', GIT_TERMINAL_PROMPT='0', GIT_NO_LAZY_FETCH='1', LC_ALL='C')
    command = ['git', '-c', 'protocol.no_fetch.allow=never', '-c', 'core.hooksPath=/dev/null', '-c', 'submodule.recurse=false', '-c', 'fetch.recurseSubmodules=false', '-C', str(repo), *map(str, args)]
    result = subprocess.run(command, env=env, capture_output=True, timeout=90, check=False)
    require(not check or result.returncode == 0, f'scratch_git:{args[0]}:exit_{result.returncode}')
    return result


def allowed_worktree(source, target, base, allowed):
    """Private Git/index borrowing objects; only allowed regular blobs materialize."""
    common.oid(base)
    for path in allowed:
        common.safe_path(path)
    require(allowed and len(allowed) == len(set(allowed)), 'allowlist:empty_or_duplicate')
    require(common.git(source, 'cat-file', '-t', base) == 'commit', 'base:missing_commit')
    target.mkdir()
    scratch_git(target, 'init', '-q')
    objects = Path(common.git(source, 'rev-parse', '--git-path', 'objects'))
    if not objects.is_absolute():
        objects = (Path(source) / objects).resolve()
    (target / '.git/objects/info/alternates').write_text(str(objects) + '\n')
    shallow = Path(common.git(source, 'rev-parse', '--git-path', 'shallow'))
    if not shallow.is_absolute():
        shallow = Path(source) / shallow
    if shallow.exists():
        (target / '.git/shallow').write_bytes(shallow.read_bytes())
    # Validate mode/path metadata before checkout: no symlink, gitlink, or excluded blob.
    for path in allowed:
        metadata = common.git(source, 'ls-tree', base, '--', path)
        if metadata:
            mode, kind, _rest = metadata.split(None, 2)
            require(mode == '100644' and kind == 'blob', 'allowlist:non_regular_file')
    scratch_git(target, 'config', 'core.sparseCheckout', 'true')
    scratch_git(target, 'config', 'core.sparseCheckoutCone', 'false')
    (target / '.git/info/sparse-checkout').write_text(''.join('/' + path + '\n' for path in allowed))
    scratch_git(target, 'checkout', '-q', '--detach', base)
    actual = {str(path.relative_to(target)) for path in target.rglob('*') if '.git' not in path.relative_to(target).parts and (path.is_file() or path.is_symlink())}
    require(actual <= set(allowed), 'allowlist:unexpected_materialization')
    require(all(not (target / path).is_symlink() for path in actual), 'allowlist:symlink')
    return sorted(actual)


def apply_check(source, base, patches):
    allowed = sorted({path for patch in patches for path in patch_paths(patch)})
    with tempfile.TemporaryDirectory(prefix='alloy-dxmt-apply-') as temporary:
        scratch = Path(temporary)
        checkout = scratch / 'checkout'
        materialized = allowed_worktree(source, checkout, base, allowed)
        inputs = []
        for index, content in enumerate(patches):
            path = scratch / f'input-{index}.patch'
            path.write_bytes(content)
            inputs.append(path)
        result = scratch_git(checkout, 'apply', '--check', *inputs, check=False)
        return {'base': base, 'status': 'clean' if result.returncode == 0 else 'conflict', 'exit_code': result.returncode, 'allowed_paths': allowed, 'materialized_paths': materialized}


def generate(repo, root, policy):
    common.fields(policy, ('version', 'author', 'bounds', 'patches'), 'dxmt_policy')
    require(type(policy['version']) is int and policy['version'] == 1 and policy['author'] == 'Timur Isaev', 'dxmt_policy:identity')
    common.fields(policy['bounds'], ('patch_files',), 'bounds')
    require(type(policy['bounds']['patch_files']) is int and policy['bounds']['patch_files'] >= 0, 'bound:invalid_number')
    require(type(policy['patches']) is dict, 'dxmt_policy:patches')
    names = common.git(root, 'ls-files', '--', PREFIX + '*.patch').splitlines()
    require(names and set(names) == set(policy['patches']), 'patch:undocumented_or_stale_file')
    before = {'head': common.git(repo, 'rev-parse', 'HEAD'), 'branch': common.git(repo, 'branch', '--show-current'), 'refs': common.git(repo, 'for-each-ref', '--format=%(refname) %(objectname)', 'refs/heads/alloy/'), 'upstream': common.git(repo, 'rev-parse', 'refs/remotes/origin/main')}
    require(before['branch'] == 'alloy/task-11-metrics', 'dxmt:unexpected_checkout')
    branches = []
    for line in before['refs'].splitlines():
        ref, tip = line.split()
        require(tip == before['upstream'], 'dxmt:unexpected_fork_commit_requires_review')
        branches.append({'ref': ref, 'tip': tip, 'downstream_commit_count': 0})
    require(branches, 'dxmt:no_alloy_branches')
    rows = []
    for name in sorted(names):
        item = policy['patches'][name]
        common.fields(item, ('base', 'base_declaration', 'sha256', 'allowed_paths', 'annotation'), 'dxmt_patch')
        common.oid(item['base'])
        common.annotation(item['annotation'], root)
        # Read only this committed first-party patch, never a DXMT working-tree diff.
        disk = common.first_party(root, name).read_bytes()
        content = common.git(root, 'show', 'HEAD:' + name, binary=True)
        require(disk == content, 'patch:uncommitted_changes')
        require(hashlib.sha256(content).hexdigest() == item['sha256'], 'patch:bytes_changed')
        paths = patch_paths(content)
        require(paths == item['allowed_paths'], 'patch:allowlist_changed')
        declaration = item['base_declaration']
        common.fields(declaration, ('path', 'literal'), 'base_declaration')
        declared = common.first_party(root, declaration['path']).read_text()
        require(item['base'] in declaration['literal'] and declaration['literal'] in declared, 'patch:base_undeclared')
        result = apply_check(repo, item['base'], [content])
        require(result['status'] == 'clean', 'patch:base_apply_failed:' + name)
        rows.append({'patch': name, **item, 'base_apply_check': result})
    after = {'head': common.git(repo, 'rev-parse', 'HEAD'), 'branch': common.git(repo, 'branch', '--show-current'), 'refs': common.git(repo, 'for-each-ref', '--format=%(refname) %(objectname)', 'refs/heads/alloy/'), 'upstream': common.git(repo, 'rev-parse', 'refs/remotes/origin/main')}
    require(before == after, 'dxmt:references_changed_during_inventory')
    counts = {'patch_files': len(rows)}
    common.bound(counts, policy['bounds'])
    return {'version': 1, 'author': 'Timur Isaev', 'scope': 'committed first-party patch files only; live working-tree changes excluded', 'checkout': {'branch': before['branch'], 'head': before['head']}, 'branches': branches, 'counts': counts, 'bounds': policy['bounds'], 'patches': rows}


def outputs(report, directory, action, repo):
    destination = Path(directory).resolve()
    source = Path(repo).resolve()
    require(destination != source and source not in destination.parents, 'output:inside_source_repository')
    path = destination / 'inventory.json'
    require(not path.is_symlink(), 'output:symlink')
    if action == 'check':
        require(path.is_file() and path.read_text() == canonical(report), 'inventory:drift:dxmt')
    else:
        destination.mkdir(parents=True, exist_ok=True)
        path.write_text(canonical(report))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('generate', 'check'))
    parser.add_argument('--dxmt', type=Path, default=Path(os.environ.get('ALLOY_DXMT_SOURCE', ROOT / 'third_party/src/dxmt')))
    parser.add_argument('--annotations', type=Path, default=HERE / 'annotations.json')
    parser.add_argument('--output', type=Path, default=HERE)
    args = parser.parse_args()
    try:
        report = generate(args.dxmt, ROOT, common.load(args.annotations))
        outputs(report, args.output, args.action, args.dxmt)
        print(canonical({'status': 'PASS', 'fork': 'DXMT', 'counts': report['counts'], 'base_apply_checks': 'clean'}).strip())
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        parser.exit(1, f'FAIL {error}\n')


if __name__ == '__main__':
    main()

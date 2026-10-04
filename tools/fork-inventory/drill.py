#!/usr/bin/env python3
"""Isolated sparse upstream replay; no shared mutations or runtime builds. Author: Timur Isaev."""

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

import dxmt_inventory as dxmt
import preservation
from fex_inventory import common, ROOT, generate as fex_generate

URLS = {'wine': ('https://gitlab.winehq.org/wine/wine.git', 'master'), 'fex': ('https://github.com/FEX-Emu/FEX.git', 'main'), 'dxmt': ('https://github.com/3Shain/dxmt.git', 'main')}
HERE = Path(__file__).resolve().parent
require, canonical = common.require, common.canonical


def command(repo, *args, check=True, trace=False, timeout=180):
    env = {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}
    env.update(GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null', GIT_TERMINAL_PROMPT='0', GIT_NO_LAZY_FETCH='1', GIT_EDITOR='true', GIT_SEQUENCE_EDITOR='true', LC_ALL='C')
    if trace:
        env['GIT_TRACE_PACKET'] = '1'
    argv = ['git', '-c', 'protocol.version=2', '-c', 'protocol.no_fetch.allow=never', '-c', 'gc.auto=0', '-c', 'maintenance.auto=false', '-c', 'credential.helper=', '-c', 'core.hooksPath=/dev/null', '-c', 'submodule.recurse=false', '-c', 'fetch.recurseSubmodules=false', '-c', 'merge.renames=false', '-c', 'commit.gpgSign=false', '-c', 'user.name=Timur Isaev', '-c', 'user.email=timur@alloy.invalid', '-C', str(repo), *map(str, args)]
    result = subprocess.run(argv, env=env, capture_output=True, timeout=timeout, check=False)
    require(not check or result.returncode == 0, f'drill_git:{args[0]}:exit_{result.returncode}')
    return result


def text(repo, *args):
    return command(repo, *args).stdout.decode().strip()


def preflight(repo, url, branch):
    # ls-remote transfers refs/capabilities only. Never try a blob-filtered fetch
    # unless the server explicitly promises filter support first.
    result = command(repo, 'ls-remote', url, 'refs/heads/' + branch, trace=True)
    capabilities = result.stderr.decode(errors='replace')
    require(any('fetch=' in line and re.search(r'\bfilter\b', line) for line in capabilities.splitlines()), 'fetch:server_does_not_advertise_filter')
    fields = result.stdout.decode().strip().split()
    require(len(fields) == 2 and fields[1] == 'refs/heads/' + branch, 'fetch:ambiguous_upstream_tip')
    common.oid(fields[0])
    return fields[0]


def fetch_object(repo, url, oid, ref=None):
    identifiers = oid if type(oid) is list else [oid]
    require(identifiers and len(identifiers) <= 256 and (ref is None or len(identifiers) == 1), 'fetch:invalid_want_list')
    for value in identifiers:
        common.oid(value)
    targets = identifiers if ref is None else [identifiers[0] + ':' + ref]
    depth = ['--depth=1'] if ref is not None else ['--refetch']
    filtering = '--filter=blob:none' if ref is not None else '--no-filter'
    # A commit "have" cannot imply possession of its filtered-out blobs. Re-fetch
    # exactly the verified blob wants, with no negotiation or descendant closure.
    # Persistent promisor metadata uses an explicitly forbidden protocol; only
    # this explicit fetch receives an exact command-scoped URL rewrite.
    result = command(repo, '-c', 'url.' + url + '.insteadOf=no_fetch://alloy-guard', '-c', 'fetch.negotiationAlgorithm=noop', 'fetch', '--no-auto-maintenance', '--no-recurse-submodules', '--no-tags', '--no-write-fetch-head', *depth, filtering, 'upstream', *targets, check=False)
    require(result.returncode == 0, 'fetch:failed:' + result.stderr.decode(errors='replace')[-3000:].strip())
    require(b'filtering not recognized' not in result.stderr, 'fetch:filter_ignored')
    for value in identifiers:
        require(text(repo, 'cat-file', '-t', value) == ('commit' if ref else 'blob'), 'fetch:unexpected_object_type')
    require(text(repo, 'remote') == 'upstream' and text(repo, 'remote', 'get-url', 'upstream') == 'no_fetch://alloy-guard', 'fetch:lazy_network_remote')


def make_cache(directory, source):
    require(not directory.exists(), 'cache:already_exists')
    directory.mkdir(parents=True)
    command(directory, 'init', '-q')
    command(directory, 'config', 'gc.auto', '0')
    command(directory, 'config', 'maintenance.auto', 'false')
    command(directory, 'config', 'protocol.no_fetch.allow', 'never')
    command(directory, 'config', 'remote.upstream.url', 'no_fetch://alloy-guard')
    command(directory, 'config', 'remote.upstream.promisor', 'true')
    command(directory, 'config', 'remote.upstream.partialclonefilter', 'blob:none')
    objects = Path(common.git(source, 'rev-parse', '--git-path', 'objects'))
    if not objects.is_absolute():
        objects = (source / objects).resolve()
    (directory / '.git/objects/info/alternates').write_text(str(objects) + '\n')
    shallow = Path(common.git(source, 'rev-parse', '--git-path', 'shallow'))
    if not shallow.is_absolute():
        shallow = source / shallow
    if shallow.exists():
        (directory / '.git/shallow').write_bytes(shallow.read_bytes())
    # Inherited shallow roots must remain reachable while fetching an unrelated
    # shallow upstream tip. Retain only refs in this private metadata cache.
    for line in common.git(source, 'for-each-ref', '--format=%(refname) %(objectname)', 'refs/heads/alloy/').splitlines():
        ref, tip = line.split()
        common.oid(tip)
        command(directory, 'update-ref', 'refs/drill/retained/' + ref.removeprefix('refs/heads/'), tip)


def fetch_allowed(repo, url, base, paths):
    fetched = []
    for path in sorted(set(paths)):
        common.safe_path(path)
        row = text(repo, 'ls-tree', base, '--', path)
        if not row:
            continue
        mode, kind, tail = row.split(None, 2)
        oid, exact = tail.split('\t', 1)
        require(mode == '100644' and kind == 'blob' and exact == path, 'fetch:allowlisted_path_not_regular')
        if command(repo, 'cat-file', '-e', oid, check=False).returncode != 0:
            fetched.append(oid)
    fetched = sorted(set(fetched))
    if fetched:
        fetch_object(repo, url, fetched)
    return fetched


def replay(repo, branch, upstream, paths, supplemental=None):
    """A real git rebase stops at its first conflicting commit. Never skip it."""
    for path in paths:
        common.safe_path(path)
    common.oid(upstream)
    with tempfile.TemporaryDirectory(prefix='alloy-replay-') as temporary:
        checkout = Path(temporary) / 'checkout'
        dxmt.allowed_worktree(repo, checkout, branch['tip'], paths)
        original = text(repo, 'rev-list', '--reverse', branch['merge_base'] + '..' + branch['tip']).splitlines()
        require(set(original) == set(branch['downstream_commit_ids']), 'replay:inventory_range_mismatch')
        result = command(checkout, 'rebase', '--no-rebase-merges', '--no-fork-point', '--reapply-cherry-picks', '--empty=keep', '--onto', upstream, branch['merge_base'], check=False)
        unmerged = text(checkout, 'diff', '--name-only', '--diff-filter=U').splitlines()
        for path in unmerged:
            common.safe_path(path)
        require(set(unmerged) <= set(paths), 'replay:unexpected_conflict_path')
        if result.returncode == 0:
            count = int(text(checkout, 'rev-list', '--count', upstream + '..HEAD'))
            require(count == len(original), 'replay:unexpected_dropped_commit')
            patch_results = []
            for item in supplemental or []:
                content = common.first_party(ROOT, item['patch']).read_bytes()
                require(hashlib.sha256(content).hexdigest() == item['patch_sha256'], 'supplement:patch_changed')
                patch_file = Path(temporary) / 'supplement.patch'
                patch_file.write_bytes(content)
                checked = command(checkout, 'apply', '--check', patch_file, check=False)
                patch_results.append({'commit': item['commit'], 'patch_sha256': item['patch_sha256'], 'parent': item['parent'], 'status': 'clean' if checked.returncode == 0 else 'conflict'})
            return {'ref': branch['ref'], 'tip': branch['tip'], 'merge_base': branch['merge_base'], 'original_commit_count': len(original), 'status': 'clean', 'supplemental_apply_checks': patch_results, 'replayed_commit_count': count, 'first_conflicting_commit': None, 'first_stop_unmerged_paths': [], 'unattempted_commits_after_stop': 0}
        diagnostics = result.stderr.decode(errors='replace')
        require(not re.search(r'invalid object|[Cc]ould not read|could not parse|unable to read|bad object|missing (?:blob|tree|commit)', diagnostics), 'replay:incomplete_object_graph')
        require(result.returncode == 1 and bool(unmerged), f'replay:failed_without_conflict:{branch["ref"]}:exit_{result.returncode}:' + result.stderr.decode(errors='replace')[-2000:].strip())
        stopped = text(checkout, 'rev-parse', 'REBASE_HEAD')
        require(stopped in original, 'replay:unrecognized_stop')
        index = original.index(stopped)
        # Contents/log text are deliberately not part of the report.
        command(checkout, 'rebase', '--abort')
        return {'ref': branch['ref'], 'tip': branch['tip'], 'merge_base': branch['merge_base'], 'original_commit_count': len(original), 'status': 'conflict', 'replayed_commit_count': index, 'first_conflicting_commit': stopped, 'first_stop_unmerged_paths': sorted(set(unmerged)), 'unattempted_commits_after_stop': len(original) - index - 1}


def controls(fex):
    # This is the actual retained FEX policy/provenance commit, not a model of
    # the rebase algorithm. Both synthetic upstreams descend from its real base.
    commit = '60981445ceb876117a33f36c91b181adae392890'
    base = common.git(fex, 'show', '-s', '--format=%P', commit)
    paths = common.git(fex, 'diff-tree', '--no-commit-id', '--name-only', '-r', commit).splitlines()
    require(sorted(paths) == ['CLAUDE.md', 'PROVENANCE-ALLOY.md'], 'control:real_commit_paths_changed')
    branch = {'ref': 'control/real-fex-policy-commit', 'tip': commit, 'merge_base': base, 'downstream_commit_ids': [commit]}
    outcomes = {}
    for name, filename, content in (('conflicting', 'PROVENANCE-ALLOY.md', '# Deliberately conflicting first line\n'), ('unrelated', 'alloy-unrelated-control.txt', 'Independent upstream file\n')):
        with tempfile.TemporaryDirectory(prefix='alloy-replay-control-') as temporary:
            upstream = Path(temporary) / 'upstream'
            dxmt.allowed_worktree(fex, upstream, base, paths + [filename] if filename not in paths else paths)
            (upstream / filename).write_text(content)
            command(upstream, 'add', filename)
            command(upstream, 'commit', '-qm', 'Known upstream replay control')
            result = replay(upstream, branch, text(upstream, 'rev-parse', 'HEAD'), paths)
            require(result['status'] == ('conflict' if name == 'conflicting' else 'clean'), 'control:wrong_outcome:' + name)
            if name == 'conflicting':
                require(result['first_stop_unmerged_paths'] == ['PROVENANCE-ALLOY.md'], 'control:wrong_conflict_path')
            # Synthetic commit identities have wall-clock metadata; report only
            # immutable original identity and known outcomes, never random IDs.
            outcomes[name] = {'status': result['status'], 'real_commit': commit, 'first_stop_unmerged_paths': result['first_stop_unmerged_paths']}
    return outcomes


def inventories(sources):
    wine = common.generate(sources['wine'], ROOT, common.load(ROOT / 'spikes/WINE-001/patch-inventory/annotations.json'))
    fex = fex_generate(sources['fex'], ROOT, common.load(ROOT / 'spikes/CPU-001/patch-inventory/annotations.json'))
    dx = dxmt.generate(sources['dxmt'], ROOT, common.load(ROOT / 'spikes/GFX-001/patch-inventory/annotations.json'))
    return {'wine': wine, 'fex': fex, 'dxmt': dx}


def validate_receipt(receipt):
    common.fields(receipt, ('version', 'author', 'upstreams'), 'receipt')
    require(type(receipt['version']) is int and receipt['version'] == 1 and receipt['author'] == 'Timur Isaev', 'receipt:identity')
    common.fields(receipt['upstreams'], URLS, 'receipt_upstreams')
    for name, value in receipt['upstreams'].items():
        common.fields(value, ('url', 'branch', 'commit', 'observed_at_utc', 'freshness', 'commit_time'), 'receipt_upstream')
        require((value['url'], value['branch']) == URLS[name], 'receipt:upstream_identity')
        common.oid(value['commit'])
        require(value['freshness'] == 'fresh anonymous ls-remote and filtered fetch', 'receipt:freshness')
        require(type(value['observed_at_utc']) is str and re.fullmatch(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z', value['observed_at_utc']), 'receipt:observation_time')
        datetime.fromisoformat(value['observed_at_utc'].replace('Z', '+00:00'))
        require(type(value['commit_time']) is str, 'receipt:commit_time')


def _run(sources, cache, receipt, refresh=False):
    if not refresh:
        validate_receipt(receipt)
    reports = inventories(sources)
    require(not cache.exists(), 'cache:run_requires_new_empty_directory')
    for source in sources.values():
        require(cache.resolve() != source.resolve() and source.resolve() not in cache.resolve().parents, 'cache:inside_shared_source')
    cache.mkdir(parents=True)
    output = {'version': 1, 'author': 'Timur Isaev', 'scope': 'first stopping conflict per branch; not total conflicts or runtime compatibility', 'forks': {}, 'controls': controls(sources['fex'])}
    new_receipt = {'version': 1, 'author': 'Timur Isaev', 'upstreams': {}}
    for name in ('wine', 'fex', 'dxmt'):
        source = sources[name]
        repo = cache / name
        make_cache(repo, source)
        url, branch = URLS[name]
        advertised = preflight(repo, url, branch)
        if refresh:
            tip = advertised
            observation = {'url': url, 'branch': branch, 'commit': tip, 'observed_at_utc': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'), 'freshness': 'fresh anonymous ls-remote and filtered fetch'}
        else:
            observation = receipt['upstreams'][name]
            require(observation['url'] == url and observation['branch'] == branch, 'receipt:upstream_identity')
            tip = observation['commit']
            common.oid(tip)
            require(advertised == tip, 'receipt:upstream_advanced_refresh_required:' + name)
        fetch_object(repo, url, tip, 'refs/drill/upstream')
        observation = dict(observation, commit_time=text(repo, 'show', '-s', '--format=%cI', tip))
        new_receipt['upstreams'][name] = observation
        report = reports[name]
        if name == 'dxmt':
            patches = [common.first_party(ROOT, row['patch']).read_bytes() for row in report['patches']]
            paths = sorted({path for patch in patches for path in dxmt.patch_paths(patch)})
            fetch_allowed(repo, url, tip, paths)
            result = dxmt.apply_check(repo, tip, patches)
            output['forks'][name] = {'upstream': observation, 'patch_count': len(patches), 'combined_apply_check': result}
        else:
            paths = sorted({path for commit in report['commits'] for path in commit['paths']})
            if name == 'wine':
                paths = sorted(set(paths) | {path for item in report['supplemental'] for path in item['paths']})
            fetch_allowed(repo, url, tip, paths)
            branches = [row for row in report['branches'] if row.get('status', 'live') == 'live']
            results = [replay(repo, row, tip, paths, [item for item in report.get('supplemental', []) if item['parent'] == row['tip']]) for row in branches]
            supplement = []
            if name == 'wine':
                for item in report['supplemental']:
                    live = next(row for row in results if row['ref'] == 'refs/heads/alloy/spike-wine-001')
                    # Applying a dependent patch directly to bare upstream would
                    # falsely imply the shared stack had already replayed cleanly.
                    if live['status'] == 'conflict':
                        supplement.append({'commit': item['commit'], 'patch_sha256': item['patch_sha256'], 'status': 'blocked-by-shared-stack-conflict', 'parent': item['parent']})
                    else:
                        supplement.extend(live['supplemental_apply_checks'])
            output['forks'][name] = {'upstream': observation, 'branches': results, 'live_branches': len(results), 'branches_stopped_on_conflict': sum(row['status'] == 'conflict' for row in results), 'first_stop_unmerged_path_occurrences': sum(len(row['first_stop_unmerged_paths']) for row in results), 'supplemental': supplement, 'historical_branches_not_replayed': [row['ref'] for row in report['branches'] if row.get('status') == 'historical']}
    output['input_inventory_sha256'] = {name: hashlib.sha256(canonical(report).encode()).hexdigest() for name, report in reports.items()}
    return output, new_receipt


def run(sources, cache, receipt, refresh=False):
    before = preservation.snapshot(sources)
    try:
        result, observed = _run(sources, cache, receipt, refresh)
    finally:
        require(before == preservation.snapshot(sources), 'preservation:shared_source_changed')
    result['source_preservation'] = {
        'status': 'unchanged',
        'snapshot_sha256': hashlib.sha256(canonical(before).encode()).hexdigest(),
        'checkouts': {name: {'head': row['head'], 'branch': row['branch'], 'index_sha256': row['index_sha256']} for name, row in before.items()},
        'scope': 'exact refs, index and non-excluded dirty bytes; excluded contents never read',
    }
    return result, observed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('refresh', 'check'))
    parser.add_argument('--source-root', type=Path, default=ROOT / 'third_party/src')
    parser.add_argument('--output', type=Path, default=HERE / 'evidence')
    args = parser.parse_args()
    try:
        sources = {name: args.source_root / name for name in URLS}
        destination = args.output.resolve()
        for source in sources.values():
            require(destination != source.resolve() and source.resolve() not in destination.parents, 'output:inside_shared_source')
        receipt_path, report_path = destination / 'upstreams.json', destination / 'drill.json'
        require(not receipt_path.is_symlink() and not report_path.is_symlink(), 'output:symlink')
        receipt = None if args.action == 'refresh' else common.load(receipt_path)
        with tempfile.TemporaryDirectory(prefix='alloy-drill-') as temporary:
            result, new_receipt = run(sources, Path(temporary) / 'cache', receipt, args.action == 'refresh')
        if args.action == 'refresh':
            destination.mkdir(parents=True, exist_ok=True)
            receipt_path.write_text(canonical(new_receipt))
            report_path.write_text(canonical(result))
        else:
            require(report_path.read_text() == canonical(result), 'drill:output_drift')
            require(receipt == new_receipt, 'drill:receipt_drift')
        print(canonical({'status': 'PASS', 'action': args.action, 'forks': {name: {'upstream': row['upstream']['commit'], 'conflicted_branches': row.get('branches_stopped_on_conflict'), 'patch_apply': row.get('combined_apply_check', {}).get('status')} for name, row in result['forks'].items()}}).strip())
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        parser.exit(1, f'FAIL {error}\n')


if __name__ == '__main__':
    main()

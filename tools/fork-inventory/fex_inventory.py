#!/usr/bin/env python3
"""Read-only committed FEX union and literal provenance check. Author: Timur Isaev."""

import argparse
import hashlib
import importlib.util
from pathlib import Path
import os
import subprocess

ROOT = Path(__file__).resolve().parents[2]
HERE = ROOT / 'spikes/CPU-001/patch-inventory'
spec = importlib.util.spec_from_file_location('wine_inventory', ROOT / 'spikes/WINE-001/patch-inventory/inventory.py')
common = importlib.util.module_from_spec(spec)
spec.loader.exec_module(common)
require, git, canonical = common.require, common.git, common.canonical


def generate(repo, root, policy):
    common.fields(policy, ('version', 'author', 'upstream_ref', 'expected_checkout', 'historical_branches', 'bounds', 'annotations'), 'fex_policy')
    require(type(policy['version']) is int and policy['version'] == 1, 'fex_policy:version')
    require(policy['author'] == 'Timur Isaev', 'fex_policy:author')
    require(policy['upstream_ref'] == 'refs/remotes/origin/main', 'fex_policy:upstream')
    require(type(policy['historical_branches']) is list and len(set(policy['historical_branches'])) == len(policy['historical_branches']), 'historical:invalid')
    common.fields(policy['bounds'], ('retained_commit_ids', 'live_commit_ids', 'historical_only_commit_ids'), 'bounds')
    for limit in policy['bounds'].values():
        require(type(limit) is int and limit >= 0, 'bound:invalid_number')
    before = common.metadata(repo, policy)
    historical = set(policy['historical_branches'])
    require(historical <= set(before['refs']), 'historical:missing_branch')
    membership, live, branches = {}, set(), []
    for ref, tip in sorted(before['refs'].items()):
        bases = git(repo, 'merge-base', '--all', before['upstream'], tip).splitlines()
        require(len(bases) == 1, 'branch:ambiguous_merge_base')
        commits = sorted(git(repo, 'rev-list', tip, '--not', before['upstream']).splitlines())
        status = 'historical' if ref in historical else 'live'
        branches.append({'ref': ref, 'tip': tip, 'merge_base': bases[0], 'status': status, 'count': len(commits), 'downstream_commit_ids': commits})
        for commit in commits:
            membership.setdefault(commit, []).append(ref)
        if status == 'live':
            live.update(commits)
    annotations = policy['annotations']
    require(type(annotations) is dict, 'annotations:wrong_type')
    require(not set(membership) - set(annotations), 'provenance:undocumented_commit:' + ','.join(sorted(set(membership) - set(annotations))))
    require(not set(annotations) - set(membership), 'annotation:stale_commit')
    entries, records = [], {}
    for commit in sorted(membership):
        common.oid(commit)
        annotation = annotations[commit]
        common.fields(annotation, ('annotation', 'ai_assisted', 'role', 'provenance'), 'fex_annotation')
        require(annotation['ai_assisted'] is True, 'provenance:assistance_unclassified')
        require(annotation['role'] in ('code', 'provenance-record', 'fork-policy'), 'provenance:role')
        common.annotation(annotation['annotation'], root)
        paths = sorted(git(repo, 'diff-tree', '--root', '--no-commit-id', '--name-only', '--no-renames', '-r', commit).splitlines())
        require(bool(paths), 'commit:empty_or_merge_requires_review')
        for path in paths:
            common.safe_path(path)
        parents = git(repo, 'show', '-s', '--format=%P', commit).split()
        require(len(parents) == 1, 'commit:merge_requires_review')
        if annotation['role'] == 'provenance-record':
            require(paths == ['PROVENANCE-ALLOY.md'], 'provenance:role_path_mismatch')
        binding = annotation['provenance']
        common.fields(binding, ('ref', 'literal'), 'provenance')
        require(binding['ref'] in before['refs'], 'provenance:unknown_ref')
        literal = binding['literal']
        require(type(literal) is str and len(literal) >= 35, 'provenance:undocumented_entry')
        ref = binding['ref']
        if ref not in records:
            blob = git(repo, 'rev-parse', f'{ref}:PROVENANCE-ALLOY.md')
            content = git(repo, 'show', f'{ref}:PROVENANCE-ALLOY.md', binary=True)
            records[ref] = {'commit': before['refs'][ref], 'blob': blob, 'sha256': hashlib.sha256(content).hexdigest(), 'text': content.decode()}
        require(literal in records[ref]['text'], f'provenance:undocumented_entry:{commit}')
        entries.append({'commit': commit, 'parents': parents, 'subject': git(repo, 'show', '-s', '--format=%s', commit), 'paths': paths, 'branches': membership[commit], 'lifecycle': 'live' if commit in live else 'historical-only', **annotation})
    counts = {'retained_commit_ids': len(membership), 'live_commit_ids': len(live), 'historical_only_commit_ids': len(set(membership) - live)}
    common.bound(counts, policy['bounds'])
    require(common.metadata(repo, policy) == before, 'fex:references_changed_during_inventory')
    return {'version': 1, 'author': 'Timur Isaev', 'scope': 'all retained alloy branches; distinct IDs, not active effects', 'upstream': {'ref': policy['upstream_ref'], 'commit': before['upstream'], 'freshness': 'cached-ref; inventory does not fetch'}, 'checkout': {'branch': before['checkout'], 'head': before['head']}, 'counts': counts, 'bounds': policy['bounds'], 'branches': branches, 'commits': entries, 'provenance_records': {ref: {key: value for key, value in record.items() if key != 'text'} for ref, record in sorted(records.items())}}


def markdown(report):
    lines = ['<!-- Author: Timur Isaev -->', '', '# Generated FEX inventory', '', 'Generated by `tools/fork-inventory/fex_inventory.py`; edit annotations, then regenerate.', '', f"Retained IDs: **{report['counts']['retained_commit_ids']}**; live union: **{report['counts']['live_commit_ids']}**; historical-only: **{report['counts']['historical_only_commit_ids']}**.", '', 'Every entry is marked assisted, including policy/provenance-only commits. Literal', 'provenance bindings are reviewed mappings, not machine proof of original authorship.', 'Older entries have no embedded commit ID; their exact text and committed blob are', 'bound explicitly. Side-branch provenance records are included. Upstreamable means', 'a problem/idea candidate only: these exact assisted bytes require independent', 'founder reimplementation before upstream contribution.', '', '## Branches', '', '| Branch | Count | Status |', '| --- | ---: | --- |']
    for row in report['branches']:
        lines.append(f"| `{row['ref']}` | {row['count']} | {row['status']} |")
    lines += ['', '## Entries', '']
    for item in report['commits']:
        note = item['annotation']
        lines += [f"### `{item['commit'][:12]}` — {item['subject'].rstrip('.,;:!?')}", '', f"{item['lifecycle']}; {item['role']}; **{note['classification']}**.", '', note['justification'], '', f"Provenance: `{item['provenance']['ref']}:PROVENANCE-ALLOY.md`", '', '```text', item['provenance']['literal'], '```', '']
        for citation in note['evidence']:
            relative = os.path.relpath(ROOT / citation['path'], HERE)
            lines += [f"Evidence: [{citation['path']}]({relative}), {citation['heading'].lstrip('# ')}.", '']
    return '\n'.join(lines)


def outputs(report, directory, action, repo):
    destination = Path(directory).resolve()
    source = Path(repo).resolve()
    require(destination != source and source not in destination.parents, 'output:inside_source_repository')
    for name, content in (('inventory.json', canonical(report)), ('INVENTORY.md', markdown(report))):
        path = destination / name
        require(not path.is_symlink(), 'output:symlink')
        if action == 'check':
            require(path.is_file() and path.read_text() == content, f'inventory:drift:{name}')
        else:
            destination.mkdir(parents=True, exist_ok=True)
            path.write_text(content)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('generate', 'check'))
    parser.add_argument('--fex', type=Path, default=Path(os.environ.get('ALLOY_FEX_SOURCE', ROOT / 'third_party/src/fex')))
    parser.add_argument('--annotations', type=Path, default=HERE / 'annotations.json')
    parser.add_argument('--output', type=Path, default=HERE)
    args = parser.parse_args()
    try:
        result = generate(args.fex, ROOT, common.load(args.annotations))
        outputs(result, args.output, args.action, args.fex)
        print(canonical({'status': 'PASS', 'fork': 'FEX', 'counts': result['counts']}).strip())
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        parser.exit(1, f'FAIL {error}\n')


if __name__ == '__main__':
    main()

#!/usr/bin/env python3
"""Local bounded maintenance gate for three read-only source checkouts. Author: Timur Isaev."""

import argparse
import hashlib
from pathlib import Path
import subprocess
import tempfile

import drill
import dxmt_inventory
import fex_inventory
import preservation
from fex_inventory import common, ROOT

HERE = Path(__file__).resolve().parent
COUNT_KEYS = ('wine_shared_commit_ids', 'wine_supplemental_patches', 'wine_total_maintenance_items', 'fex_retained_commit_ids', 'fex_live_commit_ids', 'fex_historical_only_commit_ids', 'dxmt_patch_files')


def enforce_bounds(reports, policy):
    common.fields(policy, ('author', 'version', 'limits'), 'combined_bounds')
    common.require(policy['author'] == 'Timur Isaev' and type(policy['version']) is int and policy['version'] == 1, 'combined_bounds:identity')
    common.fields(policy['limits'], COUNT_KEYS, 'combined_bounds')
    counts = {fork + '_' + name: count for fork, report in reports.items() for name, count in report['counts'].items()}
    common.require(set(counts) == set(COUNT_KEYS), 'combined_bounds:unexpected_counts')
    for value in policy['limits'].values():
        common.require(type(value) is int and value >= 0, 'combined_bounds:invalid_number')
    common.bound(counts, policy['limits'])
    return counts


def check(sources, bounds, evidence):
    before = preservation.snapshot(sources)
    try:
        reports = drill.inventories(sources)
        counts = enforce_bounds(reports, bounds)
        common.check_outputs(reports['wine'], ROOT / 'spikes/WINE-001/patch-inventory')
        fex_inventory.outputs(reports['fex'], ROOT / 'spikes/CPU-001/patch-inventory', 'check', sources['fex'])
        dxmt_inventory.outputs(reports['dxmt'], ROOT / 'spikes/GFX-001/patch-inventory', 'check', sources['dxmt'])
        receipt = common.load(evidence / 'upstreams.json')
        with tempfile.TemporaryDirectory(prefix='alloy-check-all-') as temporary:
            replay, observed = drill.run(sources, Path(temporary) / 'cache', receipt)
        common.require(observed == receipt, 'combined:upstream_receipt_drift')
        common.require((evidence / 'drill.json').read_text() == common.canonical(replay), 'combined:replay_drift')
    finally:
        after = preservation.snapshot(sources)
        common.require(before == after, 'preservation:shared_source_changed')
    return {'version': 1, 'author': 'Timur Isaev', 'status': 'PASS', 'meaning': 'inventory and recorded first-stop compatibility evidence reproduced; conflicts are findings, not runtime approval', 'counts': counts, 'upstreams': receipt['upstreams'], 'source_identity_index_and_dirty_bytes': 'unchanged; excluded contents never read', 'preservation_snapshot_sha256': hashlib.sha256(common.canonical(before).encode()).hexdigest(), 'controls': replay['controls'], 'conflicted_live_branches': {name: replay['forks'][name]['branches_stopped_on_conflict'] for name in ('wine', 'fex')}, 'dxmt_apply': replay['forks']['dxmt']['combined_apply_check']['status'], 'drill_sha256': hashlib.sha256(common.canonical(replay).encode()).hexdigest()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-root', type=Path, default=ROOT / 'third_party/src')
    parser.add_argument('--bounds', type=Path, default=HERE / 'bounds.json')
    parser.add_argument('--evidence', type=Path, default=HERE / 'evidence')
    args = parser.parse_args()
    try:
        sources = {name: args.source_root / name for name in drill.URLS}
        print(common.canonical(check(sources, common.load(args.bounds), args.evidence)), end='')
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        parser.exit(1, f'FAIL {error}\n')


if __name__ == '__main__':
    main()

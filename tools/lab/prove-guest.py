#!/usr/bin/env python3
"""Bounded real Wine guest proof through the public lab scheduler. Author: Timur Isaev."""

import argparse
import copy
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time

from alloy_lab.common import file_digest, hashed, require
from alloy_lab.locking import HostLease, available
from alloy_lab.queue import Queue
from alloy_lab.scenario import runtime_digest
from alloy_lab.scheduler import work_one
from alloy_lab.store import Store
from alloy_lab.wine import inventory, scenario

PACKAGE = Path(__file__).resolve().parent
PRIMARY = Path('/Users/cleverclosure/Developer/Alloy')


def idle(root):
    result = subprocess.run(['/bin/ps', '-axo', 'pid=,ppid=,command='], capture_output=True, text=True, timeout=5, check=True)
    rows = [line.strip().split(None, 2) for line in result.stdout.splitlines() if line.strip()]
    parents = {int(row[0]): int(row[1]) for row in rows if len(row) == 3}
    ignored, current = set(), os.getpid()
    while current and current not in ignored:
        ignored.add(current)
        current = parents.get(current, 0)
    paths = {str(root), str(root).replace('/private/tmp/', '/tmp/')}
    busy = [row for row in rows if len(row) == 3 and int(row[0]) not in ignored and
            any(path + '/' in row[2] for path in paths)]
    require(not busy, 'guest:runtime_busy:' + repr(busy))


def prove(args):
    runtime = args.runtime.resolve(strict=True)
    idle(PRIMARY / 'spikes/WINE-001/work/build-2')
    idle(runtime)
    require(available(True), 'guest:host_reserved')
    output = args.output or Path(tempfile.mkdtemp(prefix='alloy-lab-guest-', dir='/private/tmp'))
    if args.output:
        output.mkdir(mode=0o700)
    print('Evidence directory: ' + str(output), flush=True)
    source = output / 'known-answer.c'
    shutil.copyfile(PACKAGE / 'guest/known-answer.c', source)
    subject = output / 'known-answer.exe'
    compiler = args.toolchain / ('x86_64' if args.architecture == 'x64' else 'aarch64')
    compiler = Path(str(compiler) + '-w64-mingw32-clang')
    with HostLease(True) as preparation:
        preparation.acquire(time.time() + 30)
        subprocess.run([str(compiler), '-O2', str(source), '-o', str(subject)], check=True, timeout=30)
        definition = scenario(runtime, subject)
        before = inventory(runtime)
    definition['inputs']['source'] = {'path': source.name, 'sha256': file_digest(source)['sha256']}
    (output / 'scenario-v2.json').write_text(json.dumps(definition, sort_keys=True, indent=2) + '\n')
    queue = Queue(output / 'queue')
    store = Store(queue.root / 'evidence-store')
    report = {'author': 'Timur Isaev', 'scope': 'local-engineering-not-certification',
        'runtime_sha256': definition['runtime']['sha256'], 'runtime_files': len(before),
        'guest_architecture': args.architecture, 'subject_sha256': file_digest(subject)['sha256'],
        'compiler_sha256': file_digest(compiler.resolve())['sha256'], 'runs': []}

    def run(label, control='clean', value=None):
        value = value or definition
        idle(PRIMARY / 'spikes/WINE-001/work/build-2')
        idle(runtime)
        job = queue.submit(value, hashed(value), output, runtime, control=control, deadline=time.time() + 240)
        require(work_one(queue.root) == job, 'guest:wrong_job')
        row = queue.get(job)
        address = row['history'][-1]['record_digest']
        require(address is not None, 'guest:no_evidence:' + str(row['failure']))
        record = store.record(address)
        report['runs'].append({'label': label, 'job_id': job, 'record_sha256': address,
            'state': row['state'], 'classification': row['classification'], 'observed': record['observed'],
            'steps': record['steps'], 'failures': record['failures']})
        (output / 'proof.json').write_text(json.dumps(report, sort_keys=True, indent=2) + '\n')
        idle(runtime)
        require(available(True), 'guest:host_lock_not_released')
        print(label + ': ' + str(row['classification']), flush=True)
        if record['state'] == 'COMPLETED':
            require([step['id'] for step in record['steps']][-2:] == ['stop-server', 'wait-server'], 'guest:cleanup_missing')
            require(record['steps'][-2]['exit_code'] in (0, 1) and record['steps'][-1]['exit_code'] == 0, 'guest:cleanup_failed')
            if args.architecture == 'x64':
                artifact = next(item for item in record['artifacts'] if item['path'] == 'steps/guest.stderr.log')
                trace = store.get(artifact['sha256']).decode(errors='replace')
                loaded = re.findall(r'alloy_builtin_image path="([^"]+/libarm64ecfex.dll)"', trace)
                expected = runtime / 'dlls/libarm64ecfex/aarch64-windows/libarm64ecfex.dll'
                require(loaded and all(Path(path).resolve() == expected for path in loaded), 'guest:wrong_or_missing_mapped_fex')
                report['runs'][-1]['loaded_fex_paths'] = loaded
        return row, record, address

    try:
        first, record, address = run('calibration')
        require(first['classification'] == 'UNBASELINED' and record['observed'] == {'answer': 42, 'sum': 21}, 'guest:known_answer')
        report['baseline_sha256'] = store.set_baseline([address])
        clean, record, _ = run('clean')
        require(clean['classification'] == 'CLEAN' and record['observed'] == {'answer': 42, 'sum': 21}, 'guest:clean_control')
        seeded, record, _ = run('seeded', 'seeded')
        require(seeded['classification'] == 'REGRESSION' and record['observed'] == {'answer': 43, 'sum': 22}, 'guest:seeded_control')
        require(set(seeded['history'][0]['comparison']['reasons']) == {'answer', 'sum'}, 'guest:two_observable_regressions')
        mismatch = copy.deepcopy(definition)
        mismatch['runtime']['files']['wine']['sha256'] = '0' * 64
        mismatch['runtime']['sha256'] = runtime_digest(mismatch['runtime'])
        bad, record, _ = run('digest-mismatch', value=mismatch)
        require(bad['classification'] == 'INCOMPARABLE' and record['steps'] == [], 'guest:mismatch_executed')
        hanging = copy.deepcopy(definition)
        next(step for step in hanging['steps'] if step['id'] == 'guest')['timeout_seconds'] = 1
        failed, record, _ = run('timeout-cleanup', 'hang', hanging)
        require(failed['classification'] == 'FAILED' and any(item['code'] == 'RUN_TIMEOUT' for item in record['failures']),
                'guest:timeout_not_observed')
        require([step['id'] for step in record['steps']][-2:] == ['stop-server', 'wait-server'] and
                record['steps'][-2]['exit_code'] in (0, 1) and record['steps'][-1]['exit_code'] == 0, 'guest:failure_cleanup')
        with HostLease(False) as verification:
            verification.acquire(time.time() + 30)
            report['runtime_unchanged'] = inventory(runtime) == before
        require(report['runtime_unchanged'], 'guest:runtime_changed')
        report['complete'] = True
    finally:
        (output / 'proof.json').write_text(json.dumps(report, sort_keys=True, indent=2) + '\n')
        store.close()
        queue.close()
    print('PASS real Wine guest, two automatic regressions, zero-step digest refusal and timeout cleanup', flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runtime', type=Path, default=os.environ.get('ALLOY_RUNTIME_GENERATION'))
    parser.add_argument('--toolchain', type=Path, default=os.environ.get('ALLOY_TOOLCHAIN_BIN'))
    parser.add_argument('--architecture', choices=('x64', 'arm64'), default='x64')
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    if args.runtime is None or args.toolchain is None:
        parser.error('explicit ALLOY_RUNTIME_GENERATION and ALLOY_TOOLCHAIN_BIN (or equivalent options) required')
    try:
        prove(args)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        parser.exit(1, 'FAIL ' + str(error) + '\n')

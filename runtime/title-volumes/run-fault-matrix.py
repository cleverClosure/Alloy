#!/usr/bin/env python3
# Author: Timur Isaev
"""Independent byte oracle and real process-death supervision; no guest execution."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import select
import shutil
import signal
import subprocess
import tempfile
import time

PACKAGE = Path(__file__).resolve().parent
PROBE = PACKAGE / '.build/debug/alloy-volumes-fault-probe'


def run(*args, expected=0):
    result = subprocess.run([str(PROBE), *map(str, args)], text=True, capture_output=True, timeout=30)
    if expected is not None:
        assert result.returncode == expected, (args, result.returncode, result.stdout, result.stderr)
    return result


def tree(root):
    result = {}
    for path in sorted(root.rglob('*')):
        assert not path.is_symlink(), path
        relative = str(path.relative_to(root))
        if path.is_dir():
            result[relative] = 'directory'
        else:
            assert path.is_file(), path
            result[relative] = hashlib.sha256(path.read_bytes()).hexdigest()
    return result


def killed(result, point):
    assert result.returncode == -signal.SIGKILL, (point, result.returncode, result.stderr)
    events = [json.loads(line) for line in result.stdout.splitlines()]
    assert events == [{'reached': point}], (point, events)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--json', type=Path)
    args = parser.parse_args()
    subprocess.run(['swift', 'build', '--package-path', str(PACKAGE)], check=True, timeout=180)
    started = time.monotonic()
    report = {'killPoints': [], 'cleanOperations': [], 'controls': {}}
    with tempfile.TemporaryDirectory(prefix='alloy-volumes-matrix-', dir='/private/tmp') as temporary:
        work = Path(temporary)
        base = work / 'base'
        run('prepare', base)
        before = tree(base / 'volumes/game/saves')
        other = tree(base / 'volumes/other/saves')
        after = {'slot': 'directory', 'slot/a': hashlib.sha256(bytes([1]) * 32768).hexdigest(),
                 'slot/b': hashlib.sha256(bytes([1]) * 65536).hexdigest()}
        points = json.loads(run('points').stdout)
        assert len(points) == len(set(points)) == 35

        def fresh(label):
            destination = work / label
            shutil.copytree(base, destination)
            return destination

        for index, point in enumerate(points):
            root = fresh(f'kill-{index}')
            operation = point.split('.')[0]
            killed(run('run', root, operation, point, expected=None), point)
            run('recover', root)
            current = tree(root / 'volumes/game/saves')
            assert current in (before, after) if operation == 'restore' else current == before
            if operation == 'restore':
                committed = point.split('.')[1] in ('after-swap', 'after-sync', 'after-commit')
                assert current == (after if committed else before)
            assert tree(root / 'volumes/other/saves') == other
            report['killPoints'].append(point)
            print(f'PASS killed-and-recovered {point}', flush=True)

        for operation in ('snapshot', 'backup', 'restore', 'settings', 'cache', 'scratch'):
            root = fresh('clean-' + operation)
            run('run', root, operation, 'no-fault')
            run('recover', root)
            assert tree(root / 'volumes/game/saves') == (after if operation == 'restore' else before)
            report['cleanOperations'].append(operation)

        missing = run('run', fresh('missed-point'), 'snapshot', 'deliberately-missing', expected=None)
        try:
            killed(missing, 'deliberately-missing')
        except AssertionError:
            report['controls']['missedKillPointDetected'] = True
        else:
            raise AssertionError('the kill detector accepted a process that was never killed')

        torn = fresh('torn')
        killed(run('run', torn, 'restore', 'restore.after-journal', expected=None), 'restore.after-journal')
        (torn / 'volumes/game/saves/slot/a').write_bytes(bytes([1]) * 32768)
        refused = run('recover', torn, expected=1)
        assert 'integrityMismatch' in refused.stderr
        assert any(tree(path / 'tree') == before for path in (torn / 'metadata/title-volumes/archives/game').iterdir())
        report['controls']['tornReplacementDetectedAndOriginalRetained'] = True

        quota = work / 'quota'
        run('quota-prepare', quota)
        run('quota-audit', quota)
        save = quota / 'volumes/game/saves/save'
        save.write_bytes(bytes([1]) * 9)
        refused = run('quota-audit', quota, expected=1)
        assert 'quotaExceeded' in refused.stderr and save.read_bytes() == bytes([1]) * 9
        save.write_bytes(bytes([1]) * 8)
        run('quota-audit', quota)
        report['controls']['plantedQuotaOverrunDetected'] = True

        escape = fresh('escape')
        refused = run('escape', escape, expected=1)
        assert 'unsafePath' in refused.stderr
        assert tree(escape / 'volumes/game/saves') == before
        assert tree(escape / 'volumes/other/saves') == other
        report['controls']['crossTitleEscapeDetected'] = True

        held = fresh('held-session')
        process = subprocess.Popen([str(PROBE), 'hold', str(held)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            ready, _, _ = select.select([process.stdout], [], [], 5)
            assert ready and json.loads(process.stdout.readline()) == {'lease': 'held'}
            assert json.loads(run('expire', held).stdout) == []
            process.kill()
            process.wait(timeout=5)
            assert process.returncode == -signal.SIGKILL
            assert len(json.loads(run('expire', held).stdout)) == 1
            assert tree(held / 'volumes/game/saves') == before
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=5)
        report['controls']['liveLeaseProtectedAndDeadLeaseReclaimed'] = True

        lifecycle = fresh('lifecycle')
        report['contentStore'] = json.loads(run('lifecycle', lifecycle).stdout)
        assert all(report['contentStore'].values())
        assert tree(lifecycle / 'volumes/game/saves') == before
        assert tree(lifecycle / 'volumes/other/saves') == other
        assert (lifecycle / 'volumes/legacy/saves/legacy.sav').read_bytes() == b'legacy content-store save'
        planted = run('lifecycle-planted', fresh('lifecycle-planted'), expected=1)
        assert 'save mutation detected' in planted.stderr
        report['controls']['lifecycleSaveMutationDetectorFires'] = True
    report['status'] = 'PASS'
    report['elapsedSeconds'] = round(time.monotonic() - started, 3)
    if args.json:
        args.json.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, sort_keys=True), flush=True)


if __name__ == '__main__':
    main()

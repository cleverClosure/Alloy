"""CAS, frozen baselines and honest retry controls. Author: Timur Isaev."""

import copy
import hashlib
import json
import os
from pathlib import Path
import signal
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest

from fixtures import evidence
from alloy_lab.common import canonical, hashed, load
from alloy_lab.comparison import aggregate, compare, freeze, statistics_for
from alloy_lab.evidence import seal
from alloy_lab.queue import Queue
from alloy_lab.scenario import LEGACY, read
from alloy_lab.scheduler import work_one
from alloy_lab.store import Store

PACKAGE = Path(__file__).resolve().parents[1]


class EvidenceStoreTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='alloy-lab-store-tests-', dir='/private/tmp')
        self.root = Path(self.temporary.name)
        self.queue = Queue(self.root / 'queue')
        self.store = Store(self.queue.root / 'evidence-store')
        self.locks = self.root / 'locks'
        self.definition, self.original = read(LEGACY / 'scenario-v1.json')

    def tearDown(self):
        self.store.close()
        self.queue.close()
        self.temporary.cleanup()

    def run_job(self, control='clean', definition=None):
        value = definition or self.definition
        job = self.queue.submit(value, self.original, LEGACY, Path(sys.executable).resolve().parent, control=control)
        self.assertEqual(work_one(self.queue.root, self.locks), job)
        return job

    def record_id(self, job):
        address = self.queue.get(job)['history'][-1]['record_digest']
        self.assertIsNotNone(address, self.queue.get(job))
        return address

    def test_automatic_clean_and_seeded_two_observables(self):
        reference = self.run_job()
        self.assertEqual(self.queue.get(reference)['classification'], 'UNBASELINED')
        address = self.store.set_baseline([self.record_id(reference)])
        clean = self.run_job()
        seeded = self.run_job('seeded')
        self.assertEqual(self.queue.get(clean)['classification'], 'CLEAN')
        self.assertTrue(self.queue.get(clean)['history_summary']['gating_pass'])
        row = self.queue.get(seeded)
        self.assertEqual(row['classification'], 'REGRESSION')
        comparison = row['history'][0]['comparison']
        self.assertEqual(comparison['baseline'], address)
        self.assertIn('frame-0', comparison['reasons'])
        self.assertIn('pixel_sum', comparison['reasons'])
        self.assertEqual(self.store.record(self.record_id(seeded))['observed']['pixel_sum'], 344065)
        record = self.store.record(self.record_id(clean))
        self.assertTrue(any(item['path'] == 'sources/runner.py' for item in record['artifacts']))
        self.assertTrue(any(item['path'] == 'provenance/runtime-before.json' for item in record['artifacts']))
        self.assertEqual(self.store.compare(record, None)['verdict'], 'UNBASELINED')

    def test_flaky_failure_then_clean_never_passes_and_history_is_checked(self):
        definition = copy.deepcopy(self.definition)
        definition['retry_limit'] = 1
        reference = self.run_job(definition=definition)
        self.store.set_baseline([self.record_id(reference)])
        flaky = self.run_job('flaky', definition)
        self.assertEqual(self.queue.get(flaky)['state'], 'QUEUED')
        self.assertEqual(work_one(self.queue.root, self.locks), flaky)
        row = self.queue.get(flaky)
        self.assertEqual([entry['comparison']['verdict'] for entry in row['history']], ['FAILED', 'CLEAN'])
        self.assertEqual(row['classification'], 'FLAKY')
        self.assertEqual(row['history_summary']['failure_probability'], 0.5)
        self.assertEqual(row['history_summary']['worst_verdict'], 'FAILED')
        self.assertFalse(row['history_summary']['gating_pass'])
        self.assertTrue(all(entry['record_digest'] for entry in row['history']))
        for entry in row['history']:
            record = self.store.record(entry['record_digest'])
            self.assertEqual(record['attempt'], entry['number'])
        self.queue.db.execute("UPDATE jobs SET classification='CLEAN' WHERE id=?", (flaky,))
        self.assertEqual(self.queue.get(flaky)['classification'], 'FLAKY')
        first = row['history'][0]['comparison']
        first['verdict'] = 'CLEAN'
        self.queue.db.execute('UPDATE attempts SET comparison=? WHERE job_id=? AND number=1', (json.dumps(first), flaky))
        with self.assertRaisesRegex(ValueError, 'comparison_corrupt'):
            self.queue.get(flaky)
        for history in (['REGRESSION', 'CLEAN'], ['FAILED', 'CLEAN'], ['INCOMPARABLE', 'CLEAN']):
            result = aggregate(history)
            self.assertEqual(result['classification'], 'FLAKY')
            self.assertFalse(result['gating_pass'])
        self.assertTrue(aggregate(['REGRESSION', 'CLEAN'])['regression_detected'])

    def test_frozen_performance_envelope_and_planted_bad_limits(self):
        definition = copy.deepcopy(self.definition)
        definition['observables'].append({'id': 'wall', 'source': {'kind': 'elapsed', 'step': 'render', 'path': None, 'key': []},
            'comparison': {'class': 'performance', 'absolute': 0, 'relative': 0, 'direction': 'higher'}, 'unit': 'seconds'})
        jobs = [self.run_job(definition=definition) for _ in range(8)]
        ids = [self.record_id(job) for job in jobs]
        records = [self.store.record(address) for address in ids]
        with self.assertRaisesRegex(ValueError, 'eight_calibration_runs_required'):
            self.store.set_baseline(ids[:7])
        address = self.store.set_baseline(ids)
        baseline = json.loads(self.store.get(address))
        values = [record['observed']['wall'] for record in records]
        expected = max(0.05, 4 * (max(values) - min(values)))
        self.assertEqual(baseline['limits']['wall']['slack'], expected)
        holdout = self.run_job(definition=definition)
        self.assertEqual(self.queue.get(holdout)['classification'], 'CLEAN')
        candidate = self.store.record(self.record_id(holdout))
        with self.subTest('known-number timing detector'):
            changed = copy.deepcopy(candidate)
            changed['observed']['wall'] = baseline['limits']['wall']['mean'] + expected + 1
            changed['steps'][0]['elapsed_seconds'] = changed['observed']['wall']
            changed['duration_seconds'] = changed['observed']['wall'] + 1
            result = compare(seal(changed), baseline, records)
            self.assertEqual(result['verdict'], 'REGRESSION')
            self.assertIn('wall', result['reasons'])
        corrupt = copy.deepcopy(baseline)
        corrupt['limits']['wall']['slack'] += 100
        corrupt['integrity_sha256'] = hashed({key: value for key, value in corrupt.items() if key != 'integrity_sha256'})
        with self.assertRaisesRegex(ValueError, 'recomputed_limits_mismatch'):
            compare(candidate, corrupt, records)
        self.assertEqual(compare(records[0], baseline, records)['verdict'], 'INCOMPARABLE')

    def test_comparator_controls_reject_dead_and_reversed_detectors(self):
        original = self.run_job()
        ref = self.record_id(original)
        address = self.store.set_baseline([ref])
        clean, seeded = self.run_job(), self.run_job('seeded')
        reference = self.store.record(ref)
        baseline = json.loads(self.store.get(address))
        clean_record = self.store.record(self.record_id(clean))
        seed_record = self.store.record(self.record_id(seeded))
        label = copy.deepcopy(clean_record)
        label['control'] = 'seeded'
        host = copy.deepcopy(clean_record)
        host['provenance']['host']['cpu_count'] += 1
        host['provenance']['host_class_sha256'] = hashed(host['provenance']['host'])
        controls = [(clean_record, 'CLEAN'), (seed_record, 'REGRESSION'), (seal(label), 'CLEAN'), (seal(host), 'INCOMPARABLE')]
        def audit(classifier):
            for candidate, expected in controls:
                self.assertEqual(classifier(candidate, baseline, [reference])['verdict'], expected)
        audit(compare)
        with self.assertRaises(AssertionError):
            audit(lambda *args: {'verdict': 'CLEAN'})
        def reversed_detector(*args):
            result = compare(*args)
            result['verdict'] = {'CLEAN': 'REGRESSION', 'REGRESSION': 'CLEAN'}.get(result['verdict'], result['verdict'])
            return result
        with self.assertRaises(AssertionError):
            audit(reversed_detector)

    def test_object_corruption_deduplication_and_explicit_baseline_replacement(self):
        first = self.run_job()
        record_id = self.record_id(first)
        record = self.store.record(record_id)
        directory = (self.queue.root / self.queue.get(first)['result']).parent
        self.assertEqual(self.store.add_record(record, directory), record_id)
        baseline = self.store.set_baseline([record_id])
        with self.assertRaisesRegex(ValueError, 'stale_reference'):
            self.store.set_baseline([record_id])
        new = self.store.set_baseline([record_id], expected=baseline)
        self.assertNotEqual(new, baseline)
        self.assertEqual(self.store.db.execute('SELECT count(*) FROM baseline_history').fetchone()[0], 2)
        blob = record['artifacts'][0]['sha256']
        path = self.store.objects / blob[:2] / blob
        os.chmod(path, 0o600)
        path.write_bytes(b'planted corruption')
        with self.assertRaisesRegex(ValueError, 'object:corrupt'):
            self.store.record(record_id)
        with self.assertRaisesRegex(ValueError, 'object:corrupt'):
            self.store.put((directory / record['artifacts'][0]['path']).read_bytes())

    def test_process_death_around_record_index_never_publishes_torn_evidence(self):
        fixture = evidence()
        artifacts = self.root / 'fixture'
        (artifacts / 'steps').mkdir(parents=True)
        (artifacts / 'steps/run.stdout.log').write_bytes(b'{"answer":42}\n')
        (artifacts / 'steps/run.stderr.log').write_bytes(b'')
        (artifacts / 'record.json').write_bytes(canonical(fixture))
        address = hashlib.sha256(canonical(fixture)).hexdigest()
        script = f"import sys;sys.path.insert(0,{str(PACKAGE)!r});" + '''
import os,signal
from alloy_lab.common import load
from alloy_lab.store import Store
store=Store(sys.argv[1])
def fault(point):
 if point==sys.argv[3]:
  print('REACHED:'+point,flush=True)
  os.kill(os.getpid(),signal.SIGKILL)
store.add_record(load(sys.argv[2]+'/record.json'),sys.argv[2],fault)
'''
        for point in ('before-record-index', 'after-record-index'):
            root = self.root / point
            killed = subprocess.run([sys.executable, '-B', '-c', script, str(root), str(artifacts), point],
                                    capture_output=True, text=True, timeout=5)
            self.assertEqual(killed.returncode, -signal.SIGKILL)
            self.assertEqual(killed.stdout.strip(), 'REACHED:' + point)
            reopened = Store(root)
            try:
                if point == 'before-record-index':
                    with self.assertRaisesRegex(ValueError, 'record_not_indexed'):
                        reopened.record(address)
                else:
                    self.assertEqual(reopened.record(address), fixture)
                self.assertEqual(reopened.add_record(fixture, artifacts), address)
                self.assertEqual(reopened.record(address), fixture)
            finally:
                reopened.close()

    def test_schema_one_completed_history_upgrades_without_fabricating_passes(self):
        job = self.run_job()
        old_root = self.root / 'old-queue'
        old_root.mkdir(mode=0o700)
        db = sqlite3.connect(old_root / 'queue.sqlite3')
        try:
            db.execute('ATTACH DATABASE ? AS current_queue', (str(self.queue.root / 'queue.sqlite3'),))
            db.execute('''CREATE TABLE jobs AS SELECT id,submitted,priority,deadline,state,cancel_requested,
                definition,source_sha256,definition_sha256,input_root,runtime_root,control,owner,failure,
                result,attempts FROM current_queue.jobs''')
            db.execute('''CREATE TABLE attempts AS SELECT job_id,number,owner,started,finished,state,evidence,
                failure FROM current_queue.attempts''')
            db.execute('PRAGMA user_version=1')
            db.commit()
        finally:
            db.close()
        migrated = Queue(old_root)
        try:
            row = migrated.get(job)
            self.assertEqual(row['classification'], 'UNBASELINED')
            self.assertFalse(row['history_summary']['gating_pass'])
            self.assertEqual(row['history'][0]['state'], 'COMPLETED')
            self.assertIsNone(row['history'][0]['record_digest'])
            self.assertEqual(migrated.db.execute('PRAGMA user_version').fetchone()[0], 2)
        finally:
            migrated.close()


if __name__ == '__main__':
    unittest.main()

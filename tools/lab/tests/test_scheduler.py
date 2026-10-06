"""Real-process queue, overlap and crash controls. Author: Timur Isaev."""

import copy
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

from fixtures import scenario
from alloy_lab.common import file_digest, hashed, load
from alloy_lab.evidence import validate as validate_evidence
from alloy_lab.locking import HostLease
from alloy_lab.queue import Queue
from alloy_lab.scenario import LEGACY, read, runtime_digest
from alloy_lab.scheduler import work_one

PACKAGE_ROOT = Path(__file__).resolve().parents[1]
PROBE = '''import json,os,sys,time
from pathlib import Path
work=Path(sys.argv[1]); mode=sys.argv[2]; barrier=Path(sys.argv[3])
start=time.monotonic_ns()
(work/'started').write_text(str(os.getpid()))
if mode=='flood':
 os.write(1,b'x'*(65536+8192))
 time.sleep(3)
if mode=='heartbeat':
 while True:
  (work/'heartbeat').write_text(str(time.monotonic_ns()))
  time.sleep(0.01)
if mode=='barrier':
 barrier.mkdir(exist_ok=True)
 (barrier/str(os.getpid())).write_text('ready')
 until=time.monotonic()+4
 while len(list(barrier.iterdir()))<2:
  if time.monotonic()>until: sys.exit(31)
  time.sleep(0.01)
time.sleep(0.2)
print(json.dumps({'answer':42,'begin':start,'end':time.monotonic_ns()}))
'''


def configured(root, timing=True, mode='normal'):
    root = Path(root)
    root.mkdir(mode=0o700, exist_ok=True)
    subject = root / 'subject.py'
    subject.write_text(PROBE)
    python = Path(sys.executable).resolve()
    value = scenario()
    value['subject']['sha256'] = file_digest(subject)['sha256']
    value['runtime'] = {'kind': 'native', 'executable': python.name,
                        'files': {'python': {'path': python.name, **file_digest(python)}}}
    value['runtime']['sha256'] = runtime_digest(value['runtime'])
    value['inputs'] = {}
    value['steps'][0]['argv'] = ['{runtime}', '{subject}', '{work}', mode, str(root / 'barrier')]
    value['steps'][0]['timeout_seconds'] = 8
    value['timeout_seconds'] = 12
    value['timing_sensitive'] = timing
    for name in ('begin', 'end'):
        item = copy.deepcopy(value['observables'][0])
        item['id'] = name
        item['source']['key'] = [name]
        value['observables'].append(item)
    return value, python.parent


def controller(root, locks, after_claim=False):
    script = f"import sys;sys.path.insert(0,{str(PACKAGE_ROOT)!r});from alloy_lab.scheduler import work_one;"
    if after_claim:
        script += "import os,signal;work_one(sys.argv[1],sys.argv[2],after_claim=lambda job:os.kill(os.getpid(),signal.SIGSTOP))"
    else:
        script += 'work_one(sys.argv[1],sys.argv[2])'
    return subprocess.Popen([sys.executable, '-B', '-c', script, str(root), str(locks)],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)


def wait_until(predicate, timeout=8):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.02)
    raise AssertionError('condition was not reached before the proof deadline')


def disjoint(records):
    intervals = sorted((row['observed']['begin'], row['observed']['end']) for row in records)
    assert all(end > start for start, end in intervals), 'empty interval'
    assert all(first[1] <= second[0] for first, second in zip(intervals, intervals[1:])), 'overlap detected'


class SchedulerTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='alloy-lab-tests-', dir='/private/tmp')
        self.root = Path(self.directory.name)
        self.queue = Queue(self.root / 'queue')
        self.locks = self.root / 'locks'
        self.children = []

    def tearDown(self):
        for child in self.children:
            if child.poll() is None:
                child.kill()
            child.communicate(timeout=5)
        self.queue.close()
        self.directory.cleanup()

    def submit(self, *, timing=True, mode='normal', priority=0, deadline=None):
        value, runtime = configured(self.root / 'inputs', timing, mode)
        return self.queue.submit(value, hashed(value), self.root / 'inputs', runtime, priority, deadline)

    def launch(self, after_claim=False):
        child = controller(self.queue.root, self.locks, after_claim)
        self.children.append(child)
        return child

    def result(self, job):
        row = self.queue.get(job)
        self.assertEqual(row['state'], 'COMPLETED', row['failure'])
        path = self.queue.root / row['result']
        return validate_evidence(load(path), path.parent)

    def test_v1_and_v2_run_with_complete_provenance(self):
        definition, original = read(LEGACY / 'scenario-v1.json')
        legacy = self.queue.submit(definition, original, LEGACY, Path(sys.executable).resolve().parent)
        self.assertEqual(work_one(self.queue.root, self.locks), legacy)
        record = self.result(legacy)
        self.assertEqual(record['observed']['pixel_sum'], 344064)
        native = self.submit()
        self.assertEqual(work_one(self.queue.root, self.locks), native)
        record = self.result(native)
        self.assertEqual(record['observed']['answer'], 42)
        self.assertEqual(record['provenance']['environment_health']['resource_lock'], 'exclusive')
        for name in ('runner', 'scheduler'):
            self.assertNotEqual(record['provenance'][name]['sha256'], '0' * 64)

    def test_priority_cancel_deadline_and_restart(self):
        low = self.submit(priority=-10)
        high = self.submit(priority=10)
        cancelled = self.submit(priority=100)
        expired = self.submit(deadline=time.time() - 1)
        self.assertTrue(self.queue.cancel(cancelled))
        self.queue.close()
        self.queue = Queue(self.root / 'queue')
        self.assertEqual(work_one(self.queue.root, self.locks), high)
        self.assertEqual(self.queue.get(low)['state'], 'QUEUED')
        self.assertEqual(self.queue.get(cancelled)['state'], 'CANCELLED')
        self.assertEqual(self.queue.get(expired)['state'], 'DEADLINE')
        self.assertEqual(self.queue.get(expired)['attempts'], 0)
        self.assertEqual(work_one(self.queue.root, self.locks), low)

    def test_two_exclusive_processes_never_overlap_and_detector_fires(self):
        jobs = [self.submit() for _ in range(2)]
        children = [self.launch() for _ in jobs]
        for child in children:
            out, err = child.communicate(timeout=10)
            self.assertEqual(child.returncode, 0, (out, err))
        records = [self.result(job) for job in jobs]
        disjoint(records)
        planted = copy.deepcopy(records)
        planted[1]['observed']['begin'] = planted[0]['observed']['begin']
        planted[1]['observed']['end'] = planted[0]['observed']['end']
        with self.assertRaisesRegex(AssertionError, 'overlap detected'):
            disjoint(planted)

    def test_functional_shared_runs_reach_a_real_barrier_together(self):
        jobs = [self.submit(timing=False, mode='barrier') for _ in range(2)]
        children = [self.launch() for _ in jobs]
        for child in children:
            out, err = child.communicate(timeout=10)
            self.assertEqual(child.returncode, 0, (out, err))
        records = [self.result(job) for job in jobs]
        with self.assertRaisesRegex(AssertionError, 'overlap detected'):
            disjoint(records)
        self.assertEqual(len(list((self.root / 'inputs/barrier').iterdir())), 2)

    def test_killed_scheduler_stops_child_and_releases_inherited_lock(self):
        job = self.submit(mode='heartbeat')
        child = self.launch()
        run = self.queue.runs / job / 'attempt-1'
        wait_until(lambda: (run / 'heartbeat').exists())
        with HostLease(True, self.locks) as other:
            self.assertFalse(other.try_acquire())
        child.kill()
        child.communicate(timeout=3)
        wait_until(lambda: self.queue.get(job)['state'] == 'INTERRUPTED')
        record = load(run / 'evidence.json')
        self.assertEqual(record['state'], 'INTERRUPTED')
        beat = (run / 'heartbeat').read_bytes()
        time.sleep(0.08)
        self.assertEqual((run / 'heartbeat').read_bytes(), beat)
        with HostLease(True, self.locks) as other:
            wait_until(other.try_acquire)
        clean = self.submit()
        self.assertEqual(work_one(self.queue.root, self.locks), clean)
        self.result(clean)

    def test_crash_after_durable_claim_is_interrupted_never_retried(self):
        job = self.submit()
        child = self.launch(after_claim=True)
        wait_until(lambda: self.queue.get(job)['state'] == 'RUNNING')
        self.assertEqual(self.queue.recover(), [])
        child.kill()
        child.communicate(timeout=3)
        self.assertEqual(self.queue.recover(), [job])
        row = self.queue.get(job)
        self.assertEqual(row['state'], 'INTERRUPTED')
        self.assertEqual(row['attempts'], 1)
        self.assertIsNone(row['result'])
        self.assertEqual(self.queue.recover(), [])
        with HostLease(True, self.locks) as other:
            self.assertTrue(other.try_acquire())

    def test_running_cancellation_and_runtime_mismatch(self):
        job = self.submit(mode='heartbeat')
        child = self.launch()
        run = self.queue.runs / job / 'attempt-1'
        wait_until(lambda: (run / 'heartbeat').exists())
        self.queue.cancel(job)
        child.communicate(timeout=5)
        self.assertEqual(self.queue.get(job)['state'], 'CANCELLED')
        value, runtime = configured(self.root / 'different')
        value['runtime']['files']['python']['sha256'] = '1' * 64
        value['runtime']['sha256'] = runtime_digest(value['runtime'])
        mismatch = self.queue.submit(value, hashed(value), self.root / 'different', runtime)
        work_one(self.queue.root, self.locks)
        row = self.queue.get(mismatch)
        self.assertEqual(row['state'], 'INCOMPARABLE')
        evidence = load(self.queue.root / row['result'])
        self.assertEqual(evidence['steps'], [])
        self.assertNotEqual(evidence['provenance']['runtime']['before'], evidence['provenance']['runtime']['expected'])

    def test_step_timeout_output_cap_and_running_deadline_are_failures(self):
        value, runtime = configured(self.root / 'timeout', mode='heartbeat')
        value['steps'][0]['timeout_seconds'] = 0.15
        timeout = self.queue.submit(value, hashed(value), self.root / 'timeout', runtime)
        work_one(self.queue.root, self.locks)
        row = self.queue.get(timeout)
        self.assertEqual(row['state'], 'FAILED')
        self.assertIn('RUN_TIMEOUT', row['failure'])
        heartbeat = self.queue.runs / timeout / 'attempt-1/heartbeat'
        previous = heartbeat.read_bytes()
        time.sleep(0.05)
        self.assertEqual(previous, heartbeat.read_bytes())
        flood = self.submit(mode='flood')
        work_one(self.queue.root, self.locks)
        row = self.queue.get(flood)
        self.assertEqual(row['state'], 'FAILED')
        self.assertIn('OUTPUT_LIMIT', row['failure'])
        stdout = self.queue.runs / flood / 'attempt-1/steps/run.stdout.log'
        self.assertEqual(stdout.stat().st_size, 65536)
        deadline = self.submit(mode='heartbeat', deadline=time.time() + 1)
        child = self.launch()
        wait_until(lambda: (self.queue.runs / deadline / 'attempt-1/heartbeat').exists())
        child.communicate(timeout=5)
        self.assertEqual(self.queue.get(deadline)['state'], 'DEADLINE')

    def test_public_lock_cli_reserves_the_same_host_resource(self):
        cli = [sys.executable, '-B', str(PACKAGE_ROOT / 'lab.py')]
        marker = self.root / 'external-command-started'
        code = f"from pathlib import Path;import time;Path({str(marker)!r}).write_text('ready');time.sleep(1)"
        child = subprocess.Popen([*cli, 'lock-run', '--timeout', '5', '--', sys.executable, '-c', code],
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
        self.children.append(child)
        wait_until(marker.exists)
        check = subprocess.run([*cli, 'lock-check'], capture_output=True, timeout=5)
        self.assertEqual(check.returncode, 1)
        self.assertFalse(json.loads(check.stdout)['available'])
        out, err = child.communicate(timeout=5)
        self.assertEqual(child.returncode, 0, (out, err))
        check = subprocess.run([*cli, 'lock-check'], capture_output=True, timeout=5)
        self.assertEqual(check.returncode, 0)
        self.assertTrue(json.loads(check.stdout)['available'])

    def test_corrupt_queue_definition_is_refused(self):
        job = self.submit()
        self.queue.db.execute('UPDATE jobs SET definition_sha256=? WHERE id=?', ('1' * 64, job))
        with self.assertRaisesRegex(ValueError, 'definition_corrupt'):
            self.queue.get(job)


if __name__ == '__main__':
    unittest.main()

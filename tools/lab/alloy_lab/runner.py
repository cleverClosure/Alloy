"""Bounded worker execution with inherited leases. Author: Timur Isaev."""

from datetime import datetime, timezone
import hashlib
import os
from pathlib import Path
import selectors
import signal
import subprocess
import time
import uuid

from .common import Invalid, MAX_ARTIFACT, decode, file_bytes, file_digest, hashed, require, safe_file
from .evidence import SCOPE, seal, validate
from .identity import host_identity, input_identities, requirements_met, runtime_identity, scheduler_identity, source_identity
from .scenario import TOKENS
from .storage import atomic_json, private_directory

LOG_LIMIT = 65536


def utc():
    return datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z')


def run_program(argv, environment, work, stdout_path, stderr_path, timeout, stop, inherited=(), log_limit=LOG_LIMIT):
    started = time.monotonic()
    process = None
    failure = None
    exit_code = None
    try:
        with open(stdout_path, 'xb') as stdout, open(stderr_path, 'xb') as stderr:
            process = subprocess.Popen(argv, cwd=work, env=environment, stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True, pass_fds=inherited)
            with selectors.DefaultSelector() as selector:
                selector.register(process.stdout, selectors.EVENT_READ, stdout)
                selector.register(process.stderr, selectors.EVENT_READ, stderr)
                while selector.get_map() or process.poll() is None:
                    reason = stop()
                    if reason:
                        failure = (reason, 'cancellation, deadline or parent loss observed')
                        break
                    if time.monotonic() - started >= timeout:
                        failure = ('RUN_TIMEOUT', 'bounded step deadline exceeded')
                        break
                    for key, _ in selector.select(0.02):
                        block = os.read(key.fd, 8192)
                        if not block:
                            selector.unregister(key.fileobj)
                            continue
                        remaining = log_limit - key.data.tell()
                        key.data.write(block[:remaining])
                        if len(block) > remaining:
                            failure = ('OUTPUT_LIMIT', f'step log exceeded {log_limit} bytes')
                            break
                    if failure:
                        break
                if process.poll() is not None:
                    exit_code = process.returncode
    except OSError as error:
        failure = ('EXECUTION_FAILURE', str(error))
    finally:
        if process is not None:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            except OSError as error:
                failure = ('CLEANUP_FAILURE', str(error))
            exit_code = process.wait(timeout=3)
            process.stdout.close()
            process.stderr.close()
    return exit_code, time.monotonic() - started, failure


def execute(job, queue, parent_fd, inherited):
    os.umask(0o077)
    definition = job['definition']
    started = time.monotonic()
    output = queue.runs / job['id'] / f"attempt-{job['attempts']}"
    require(not output.exists(), 'run:output_exists')
    private_directory(output.parent)
    private_directory(output)
    private_directory(output / 'steps')
    private_directory(output / 'home')
    private_directory(output / 'tmp')
    host = host_identity()
    before_runner = source_identity()
    observed_identity = lambda expected: {'expected': expected, 'before': None, 'after': None}
    provenance = {
        'runner': before_runner, 'scheduler': scheduler_identity(), 'host': host, 'host_class_sha256': hashed(host),
        'scenario_sha256': hashed(definition), 'runtime': observed_identity(definition['runtime']['sha256']),
        'subject': observed_identity(definition['subject']['sha256']),
        'inputs': {name: observed_identity(entry['sha256']) for name, entry in definition['inputs'].items()},
        'environment_health': {'resource_lock': 'exclusive' if definition['timing_sensitive'] else 'shared',
            'requirements_met': requirements_met(definition, host),
            'notes': ['firmware identity unavailable'] if host['firmware'] == 'unavailable' else []},
    }
    record = {'version': 2, 'scope': SCOPE, 'run_id': str(uuid.uuid4()), 'job_id': job['id'], 'attempt': job['attempts'],
        'created_at': utc(), 'finished_at': None, 'scenario': definition, 'source_scenario_sha256': job['source_sha256'],
        'provenance': provenance, 'control': job['control'], 'state': 'COMPLETED', 'events': [], 'steps': [],
        'observed': {}, 'artifacts': [], 'failures': [], 'duration_seconds': 0}
    os.set_blocking(parent_fd, False)
    stopping = [None]
    def signal_stop(*_):
        stopping[0] = 'INTERRUPTED'
    prior_handlers = {kind: signal.signal(kind, signal_stop) for kind in (signal.SIGTERM, signal.SIGINT)}
    def stop():
        if stopping[0]:
            return stopping[0]
        try:
            if os.read(parent_fd, 1) == b'':
                stopping[0] = 'INTERRUPTED'
        except BlockingIOError:
            pass
        if queue.cancelled(job['id']):
            stopping[0] = 'CANCELLED'
        if time.time() >= job['deadline']:
            stopping[0] = 'DEADLINE'
        return stopping[0]
    def event(state):
        record['events'].append({'state': state, 'elapsed_seconds': time.monotonic() - started})
    def fail(state, code, detail):
        if not record['failures']:
            record['state'] = state
        record['failures'].append({'code': code, 'detail': str(detail)[:4096] or code})
    def identities(which):
        provenance['runtime'][which] = runtime_identity(definition, job['runtime_root'])
        provenance['subject'][which] = file_digest(safe_file(job['input_root'], definition['subject']['path']))['sha256']
        for name, value in input_identities(definition, job['input_root']).items():
            provenance['inputs'][name][which] = value
    def expand(value):
        mode = job['control']
        if mode == 'flaky':
            mode = 'error' if job['attempts'] == 1 else 'clean'
        values = {'runtime': str(safe_file(job['runtime_root'], definition['runtime']['executable'])),
                  'subject': str(safe_file(job['input_root'], definition['subject']['path'])),
                  'work': str(output), 'control': mode, 'attempt': str(job['attempts'])}
        values.update({'input:' + key: str(safe_file(job['input_root'], entry['path'])) for key, entry in definition['inputs'].items()})
        values.update({'runtime_file:' + key: str(safe_file(job['runtime_root'], entry['path'])) for key, entry in definition['runtime']['files'].items()})
        return TOKENS.sub(lambda match: values[match[1]], value)
    def run_step(step, cleanup=False):
        argv = [expand(arg) for arg in step['argv']]
        environment = {'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'HOME': str(output / 'home'), 'TMPDIR': str(output / 'tmp'),
                       'LANG': 'C', 'LC_ALL': 'C', 'PYTHONDONTWRITEBYTECODE': '1'}
        environment.update({key: expand(value) for key, value in step['environment'].items()})
        remaining = definition['timeout_seconds'] - (time.monotonic() - started)
        timeout = min(step['timeout_seconds'], max(0.01, 3 if cleanup else remaining))
        code, elapsed, failure = run_program(argv, environment, output, output / f"steps/{step['id']}.stdout.log",
            output / f"steps/{step['id']}.stderr.log", timeout, (lambda: None) if cleanup else stop, inherited)
        record['steps'].append({'id': step['id'], 'argv': argv, 'exit_code': code, 'elapsed_seconds': elapsed})
        if failure:
            state = failure[0] if failure[0] in ('CANCELLED', 'DEADLINE', 'INTERRUPTED') else 'FAILED'
            fail(state, failure[0], failure[1])
        elif code != step['expected_exit']:
            fail('FAILED', 'EXIT_NONZERO', f"{step['id']} exited {code}; expected {step['expected_exit']}")
    event('SETUP')
    prepared = False
    try:
        require(definition['subject']['kind'] != 'windows-reference', 'runner:windows_reference_unavailable')
        identities('before')
        require(provenance['environment_health']['requirements_met'], 'host:requirements_not_met')
        for item in (provenance['runtime'], provenance['subject'], *provenance['inputs'].values()):
            require(item['before'] == item['expected'], 'execution:input_digest_mismatch')
        prepared = True
        for step in definition['steps']:
            if step['phase'] == 'teardown':
                continue
            reason = stop()
            if reason:
                fail(reason, reason, 'stopped before step execution')
                break
            if time.monotonic() - started >= definition['timeout_seconds']:
                fail('FAILED', 'RUN_TIMEOUT', 'scenario total deadline exceeded')
                break
            if step['phase'] == 'run':
                event('RUN')
            run_step(step)
            if record['failures']:
                break
    except (OSError, ValueError) as error:
        fail('INCOMPARABLE' if not prepared else 'FAILED', 'INPUT_OR_SETUP_FAILURE', error)
    finally:
        event('TEARDOWN')
        if prepared:
            for step in definition['steps']:
                if step['phase'] == 'teardown':
                    try:
                        run_step(step, cleanup=True)
                    except (OSError, ValueError) as error:
                        fail('FAILED', 'CLEANUP_FAILURE', error)
        try:
            identities('after')
            require(source_identity() == before_runner, 'runner:source_changed')
            for item in (provenance['runtime'], provenance['subject'], *provenance['inputs'].values()):
                require(item['before'] == item['after'] == item['expected'], 'execution:input_digest_mismatch')
        except (OSError, ValueError) as error:
            fail('INCOMPARABLE', 'INPUT_CHANGED', error)
        try:
            names = {f"steps/{step['id']}.{stream}.log" for step in record['steps'] for stream in ('stdout', 'stderr')}
            if not record['failures']:
                results = {step['id']: step for step in record['steps']}
                for item in definition['observables']:
                    source = item['source']
                    if source['kind'] in ('file-sha256', 'json-file'):
                        name = source['path']
                        names.add(name)
                    else:
                        name = f"steps/{source['step']}.stdout.log"
                    if source['kind'] == 'file-sha256':
                        value = file_digest(safe_file(output, name))['sha256']
                    elif source['kind'] in ('json-file', 'stdout-json'):
                        value = decode(file_bytes(safe_file(output, name)))
                        for key in source['key']:
                            require(type(value) is dict and key in value, 'capture:missing_key')
                            value = value[key]
                    else:
                        value = results[source['step']]['exit_code' if source['kind'] == 'exit-code' else 'elapsed_seconds']
                    record['observed'][item['id']] = value
                if definition['legacy'] is not None:
                    mode = 'clean' if job['control'] == 'flaky' else job['control']
                    expected = definition['legacy']['definition']['expected'][mode]
                    require([record['observed'][f'frame-{index}'] for index in range(4)] == expected['frames'], 'legacy:frame_oracle')
                    require(all(record['observed'][key] == value for key, value in expected['metrics'].items()), 'legacy:counter_oracle')
            for name in sorted(names):
                path = safe_file(output, name)
                require(path.stat().st_size <= MAX_ARTIFACT, 'artifact:too_large')
                record['artifacts'].append({'path': name, **file_digest(path)})
        except (OSError, ValueError, KeyError) as error:
            fail('FAILED', 'CAPTURE_FAILURE', error)
        for kind, handler in prior_handlers.items():
            signal.signal(kind, handler)
    event(record['state'])
    record['duration_seconds'] = time.monotonic() - started
    record['finished_at'] = utc()
    record = seal(record)
    validate(record, output)
    atomic_json(output / 'evidence.json', record)
    return record, str((output / 'evidence.json').relative_to(queue.root))

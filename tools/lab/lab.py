#!/usr/bin/env python3
"""Local lab CLI. Author: Timur Isaev."""

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

from alloy_lab.common import load
from alloy_lab.evidence import validate as validate_evidence
from alloy_lab.locking import HostLease, available
from alloy_lab.queue import Queue
from alloy_lab.scenario import read
from alloy_lab.scheduler import work_one, worker


def lock_run(args):
    if not args.argv:
        raise ValueError('lock-run:command_required')
    argv = args.argv[1:] if args.argv[0] == '--' else args.argv
    with HostLease(args.mode == 'exclusive') as lease:
        lease.acquire(time.time() + args.timeout)
        read_fd, write_fd = os.pipe()
        try:
            child = subprocess.Popen([sys.executable, '-B', str(Path(__file__).resolve()), '_command-worker',
                str(read_fd), str(lease.fd), str(args.timeout), '--', *argv],
                pass_fds=(read_fd, lease.fd), start_new_session=True)
            os.close(read_fd)
            read_fd = None
            try:
                return child.wait(timeout=args.timeout + 10)
            except (KeyboardInterrupt, subprocess.TimeoutExpired):
                os.close(write_fd)
                write_fd = None
                return child.wait(timeout=5)
        finally:
            for fd in (read_fd, write_fd):
                if fd is not None:
                    os.close(fd)


def command_worker(args):
    from alloy_lab.runner import run_program
    os.umask(0o077)
    os.set_blocking(args.parent_fd, False)
    def stop():
        try:
            return 'INTERRUPTED' if os.read(args.parent_fd, 1) == b'' else None
        except BlockingIOError:
            return None
    argv = args.argv[1:] if args.argv and args.argv[0] == '--' else args.argv
    with tempfile.TemporaryDirectory(prefix='alloy-lab-command-', dir='/private/tmp') as directory:
        output = Path(directory)
        code, _, failure = run_program(argv, dict(os.environ), Path.cwd(), output / 'stdout', output / 'stderr',
            args.timeout, stop, (args.host_fd,), log_limit=8 << 20)
        sys.stdout.buffer.write((output / 'stdout').read_bytes())
        sys.stderr.buffer.write((output / 'stderr').read_bytes())
        if failure:
            print(f"LAB_COMMAND_FAILURE {failure[0]}", file=sys.stderr)
            return 1
        return code if code is not None and code >= 0 else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    for name in ('validate-scenario', 'migrate-v1'):
        command = commands.add_parser(name)
        command.add_argument('path', type=Path)
    evidence = commands.add_parser('validate-evidence')
    evidence.add_argument('path', type=Path)
    evidence.add_argument('--artifacts', type=Path)
    submit = commands.add_parser('submit')
    submit.add_argument('root', type=Path)
    submit.add_argument('scenario', type=Path)
    submit.add_argument('--input-root', type=Path)
    submit.add_argument('--runtime-root', type=Path)
    submit.add_argument('--priority', type=int, default=0)
    submit.add_argument('--deadline', type=float)
    submit.add_argument('--control', choices=('clean', 'seeded', 'hang', 'error', 'flaky'), default='clean')
    work = commands.add_parser('work')
    work.add_argument('root', type=Path)
    work.add_argument('--drain', action='store_true')
    work.add_argument('--require-clean', action='store_true')
    baseline = commands.add_parser('baseline-set')
    baseline.add_argument('root', type=Path)
    baseline.add_argument('records', nargs='+')
    baseline.add_argument('--replace')
    for name in ('evidence', 'compare'):
        command = commands.add_parser(name)
        command.add_argument('root', type=Path)
        command.add_argument('record')
        if name == 'compare':
            command.add_argument('--baseline')
    for name in ('status', 'cancel', 'recover'):
        command = commands.add_parser(name)
        command.add_argument('root', type=Path)
        if name == 'cancel':
            command.add_argument('job')
    for name in ('lock-check', 'lock-run'):
        command = commands.add_parser(name)
        command.add_argument('--mode', choices=('exclusive', 'shared'), default='exclusive')
        if name == 'lock-run':
            command.add_argument('--timeout', type=float, default=3600)
            command.add_argument('argv', nargs=argparse.REMAINDER)
    internal = commands.add_parser('_worker')
    internal.add_argument('root', type=Path)
    internal.add_argument('job')
    internal.add_argument('owner')
    for name in ('parent_fd', 'job_fd', 'host_fd'):
        internal.add_argument(name, type=int)
    internal = commands.add_parser('_command-worker')
    internal.add_argument('parent_fd', type=int)
    internal.add_argument('host_fd', type=int)
    internal.add_argument('timeout', type=float)
    internal.add_argument('argv', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    try:
        if args.command == '_worker':
            return worker(args.root, args.job, args.owner, args.parent_fd, args.job_fd, args.host_fd)
        if args.command == '_command-worker':
            return command_worker(args)
        if args.command == 'lock-check':
            free = available(args.mode == 'exclusive')
            print(json.dumps({'available': free, 'mode': args.mode}))
            return 0 if free else 1
        if args.command == 'lock-run':
            if not 0 < args.timeout <= 7200:
                raise ValueError('lock-run:timeout')
            return lock_run(args)
        if args.command in ('baseline-set', 'evidence', 'compare'):
            from alloy_lab.store import Store
            store = Store(args.root / 'evidence-store')
            try:
                if args.command == 'baseline-set':
                    print(json.dumps({'baseline': store.set_baseline(args.records, args.replace)}))
                    return 0
                record = store.record(args.record)
                if args.command == 'evidence':
                    print(json.dumps(record, sort_keys=True))
                    return 0
                result = store.compare(record, args.baseline) if args.baseline else store.compare(record)
                print(json.dumps(result, sort_keys=True))
                return 0 if result['verdict'] == 'CLEAN' else 1
            finally:
                store.close()
        if args.command == 'validate-evidence':
            value = validate_evidence(load(args.path), args.artifacts)
            print(json.dumps({'valid': True, 'run_id': value['run_id']}))
        elif args.command in ('validate-scenario', 'migrate-v1'):
            value, source = read(args.path)
            print(json.dumps(value if args.command == 'migrate-v1' else
                             {'valid': True, 'id': value['id'], 'source_sha256': source}, sort_keys=True, indent=2))
        else:
            queue = Queue(args.root)
            try:
                if args.command == 'submit':
                    definition, source = read(args.scenario, args.input_root)
                    runtime_root = args.runtime_root
                    if runtime_root is None:
                        if definition['subject']['kind'] != 'lab001':
                            raise ValueError('submit:runtime_root_required')
                        runtime_root = Path(sys.executable).resolve().parent
                    job = queue.submit(definition, source, args.input_root or args.scenario.parent, runtime_root,
                                       args.priority, args.deadline, args.control)
                    print(json.dumps({'job_id': job, 'state': 'QUEUED'}))
                elif args.command == 'status':
                    print(json.dumps(queue.list(), sort_keys=True))
                elif args.command == 'cancel':
                    print(json.dumps({'cancel_requested': queue.cancel(args.job)}))
                elif args.command == 'recover':
                    print(json.dumps({'interrupted': queue.recover()}))
                else:
                    failed = False
                    while True:
                        job = work_one(args.root)
                        if job is None:
                            break
                        row = queue.get(job)
                        print(json.dumps({key: row[key] for key in ('id', 'state', 'result', 'failure', 'classification', 'history_summary')}, sort_keys=True))
                        failed = failed or (row['state'] != 'QUEUED' and
                            (row['state'] != 'COMPLETED' or row['classification'] not in ('CLEAN', 'UNBASELINED') or
                             (args.require_clean and row['classification'] != 'CLEAN')))
                        if not args.drain:
                            break
                    return 1 if failed else 0
            finally:
                queue.close()
    except (OSError, ValueError, TypeError, KeyError) as error:
        parser.exit(2, f'INVALID {error}\n')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())

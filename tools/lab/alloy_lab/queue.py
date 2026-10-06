"""Transactional local queue and lease-based crash recovery. Author: Timur Isaev."""

from contextlib import contextmanager
import json
import os
from pathlib import Path
import sqlite3
import time
import uuid

from .common import canonical, digest, hashed, identifier, number, require
from .locking import Lease
from .scenario import validate
from .storage import private_directory

TERMINAL = ('COMPLETED', 'FAILED', 'INCOMPARABLE', 'CANCELLED', 'DEADLINE', 'INTERRUPTED')


class Queue:
    def __init__(self, root):
        self.root = private_directory(root)
        self.leases = private_directory(self.root / 'leases')
        self.runs = private_directory(self.root / 'runs')
        path = self.root / 'queue.sqlite3'
        require(not path.is_symlink(), 'queue:symlink')
        fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        os.close(fd)
        self.db = sqlite3.connect(path, timeout=5, isolation_level=None)
        self.db.row_factory = sqlite3.Row
        require(self.db.execute('PRAGMA user_version').fetchone()[0] in (0, 1), 'queue:unsupported_version')
        self.db.execute('PRAGMA user_version=1')
        self.db.execute('PRAGMA journal_mode=WAL')
        self.db.execute('PRAGMA synchronous=FULL')
        self.db.execute('PRAGMA foreign_keys=ON')
        self.db.execute('''CREATE TABLE IF NOT EXISTS jobs (
            id TEXT PRIMARY KEY, submitted REAL NOT NULL, priority INTEGER NOT NULL, deadline REAL NOT NULL,
            state TEXT NOT NULL, cancel_requested INTEGER NOT NULL DEFAULT 0, definition TEXT NOT NULL,
            source_sha256 TEXT NOT NULL, definition_sha256 TEXT NOT NULL, input_root TEXT NOT NULL, runtime_root TEXT NOT NULL, control TEXT NOT NULL,
            owner TEXT, failure TEXT, result TEXT, attempts INTEGER NOT NULL DEFAULT 0)''')
        self.db.execute('''CREATE TABLE IF NOT EXISTS attempts (
            job_id TEXT NOT NULL REFERENCES jobs(id), number INTEGER NOT NULL, owner TEXT NOT NULL,
            started REAL NOT NULL, finished REAL, state TEXT NOT NULL, evidence TEXT, failure TEXT,
            PRIMARY KEY(job_id, number))''')

    def close(self):
        self.db.close()

    @contextmanager
    def transaction(self):
        self.db.execute('BEGIN IMMEDIATE')
        try:
            yield
            self.db.execute('COMMIT')
        except BaseException:
            self.db.execute('ROLLBACK')
            raise

    def submit(self, definition, source_sha256, input_root, runtime_root, priority=0, deadline=None, control='clean'):
        validate(definition)
        digest(source_sha256)
        number(priority, 'priority', -1000, 1000, integer=True)
        require(control in ('clean', 'seeded', 'hang', 'error', 'flaky'), 'control:invalid')
        deadline = time.time() + 86400 if deadline is None else deadline
        number(deadline, 'deadline', 0, time.time() + 30 * 86400)
        roots = [str(Path(path).resolve(strict=True)) for path in (input_root, runtime_root)]
        require(all(Path(path).is_dir() for path in roots), 'submit:root')
        job = str(uuid.uuid4())
        with self.transaction():
            self.db.execute('''INSERT INTO jobs
                (id, submitted, priority, deadline, state, definition, source_sha256, definition_sha256, input_root, runtime_root, control)
                VALUES (?, ?, ?, ?, 'QUEUED', ?, ?, ?, ?, ?, ?)''',
                (job, time.time(), priority, deadline, canonical(definition).decode(), source_sha256, hashed(definition), *roots, control))
        return job

    def get(self, job):
        identifier(job)
        row = self.db.execute('SELECT * FROM jobs WHERE id=?', (job,)).fetchone()
        require(row is not None, 'job:not_found')
        result = dict(row)
        result['definition'] = validate(json.loads(result['definition']))
        require(hashed(result['definition']) == result['definition_sha256'], 'queue:definition_corrupt')
        result['history'] = [dict(entry) for entry in self.db.execute(
            'SELECT * FROM attempts WHERE job_id=? ORDER BY number', (job,))]
        return result

    def list(self):
        return [self.get(row[0]) for row in self.db.execute('SELECT id FROM jobs ORDER BY submitted, id')]

    def cancelled(self, job):
        row = self.db.execute('SELECT cancel_requested FROM jobs WHERE id=?', (job,)).fetchone()
        require(row is not None, 'job:not_found')
        return bool(row[0])

    def cancel(self, job):
        with self.transaction():
            current = self.get(job)
            if current['state'] in TERMINAL:
                return False
            self.db.execute('UPDATE jobs SET cancel_requested=1 WHERE id=?', (job,))
            if current['state'] == 'QUEUED':
                self.db.execute("UPDATE jobs SET state='CANCELLED',failure='cancelled before execution' WHERE id=?", (job,))
            return True

    def candidates(self):
        with self.transaction():
            self.db.execute("UPDATE jobs SET state='DEADLINE',failure='deadline before execution' WHERE state='QUEUED' AND deadline<=?", (time.time(),))
            return [row[0] for row in self.db.execute("SELECT id FROM jobs WHERE state='QUEUED' ORDER BY priority DESC, submitted, id")]

    def lease(self, job):
        identifier(job)
        return Lease(self.leases / (job + '.lock'))

    def claim(self, job):
        with self.transaction():
            current = self.get(job)
            if current['state'] != 'QUEUED' or current['cancel_requested'] or current['deadline'] <= time.time():
                return None
            owner = str(uuid.uuid4())
            number = current['attempts'] + 1
            self.db.execute("UPDATE jobs SET state='RUNNING',owner=?,attempts=? WHERE id=?", (owner, number, job))
            self.db.execute("INSERT INTO attempts (job_id, number, owner, started, state) VALUES (?, ?, ?, ?, 'RUNNING')",
                            (job, number, owner, time.time()))
        return self.get(job)

    def finish(self, job, owner, state, evidence=None, failure=None):
        require(state in TERMINAL, 'finish:state')
        with self.transaction():
            current = self.get(job)
            require(current['state'] == 'RUNNING' and current['owner'] == owner, 'finish:stale_owner')
            self.db.execute('UPDATE attempts SET finished=?,state=?,evidence=?,failure=? WHERE job_id=? AND number=?',
                            (time.time(), state, evidence, failure, job, current['attempts']))
            self.db.execute('UPDATE jobs SET state=?,result=?,failure=? WHERE id=?', (state, evidence, failure, job))

    def recover(self):
        recovered = []
        for row in self.db.execute("SELECT id FROM jobs WHERE state='RUNNING'").fetchall():
            with self.lease(row[0]) as lease:
                if not lease.try_acquire():
                    continue
                current = self.get(row[0])
                if current['state'] == 'RUNNING':
                    self.finish(current['id'], current['owner'], 'INTERRUPTED', failure='worker lease ended without completion')
                    recovered.append(current['id'])
        return recovered

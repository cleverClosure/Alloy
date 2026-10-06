"""Immutable local evidence objects and explicit baseline references. Author: Timur Isaev."""

import hashlib
import os
from pathlib import Path
import sqlite3
import tempfile
import time
import uuid

from .common import MAX_ARTIFACT, canonical, decode, digest, file_bytes, file_digest, hashed, load, require, safe_file
from .comparison import compare, freeze, key, validate_baseline
from .evidence import validate
from .storage import private_directory, sync_directory


CURRENT_BASELINE = object()


class Store:
    def __init__(self, root):
        self.root = private_directory(root)
        self.objects = private_directory(self.root / 'objects')
        path = self.root / 'index.sqlite3'
        fd = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        os.close(fd)
        self.db = sqlite3.connect(path, timeout=5, isolation_level=None)
        self.db.row_factory = sqlite3.Row
        self.db.execute('PRAGMA journal_mode=WAL')
        self.db.execute('PRAGMA synchronous=FULL')
        self.db.execute('CREATE TABLE IF NOT EXISTS records (digest TEXT PRIMARY KEY, run_id TEXT UNIQUE NOT NULL, key TEXT NOT NULL, created REAL NOT NULL)')
        self.db.execute('CREATE TABLE IF NOT EXISTS baselines (key TEXT PRIMARY KEY, digest TEXT NOT NULL, revision INTEGER NOT NULL)')
        self.db.execute('CREATE TABLE IF NOT EXISTS baseline_history (key TEXT NOT NULL, revision INTEGER NOT NULL, digest TEXT NOT NULL, replaced TEXT, created REAL NOT NULL, PRIMARY KEY(key,revision))')

    def close(self):
        self.db.close()

    def put(self, data, fault=lambda point: None):
        require(type(data) is bytes and len(data) <= MAX_ARTIFACT, 'object:too_large')
        address = hashlib.sha256(data).hexdigest()
        shard = private_directory(self.objects / address[:2])
        path = shard / address
        if path.exists():
            require(self.get(address) == data, 'object:corrupt_existing')
            return address
        temporary = shard / ('.tmp-' + uuid.uuid4().hex)
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        try:
            with os.fdopen(fd, 'wb') as stream:
                stream.write(data)
                stream.flush()
                os.fsync(stream.fileno())
                os.fchmod(stream.fileno(), 0o400)
            fault('after-object-write')
            try:
                os.link(temporary, path, follow_symlinks=False)
            except FileExistsError:
                require(self.get(address) == data, 'object:corrupt_existing')
            sync_directory(shard)
            fault('after-object-publish')
            return address
        finally:
            temporary.unlink(missing_ok=True)

    def get(self, address):
        digest(address)
        data = file_bytes(safe_file(self.objects, address[:2] + '/' + address), MAX_ARTIFACT)
        require(hashlib.sha256(data).hexdigest() == address, 'object:corrupt')
        return data

    def add_record(self, record, artifact_root, fault=lambda point: None):
        validate(record, artifact_root)
        for item in record['artifacts']:
            data = file_bytes(safe_file(artifact_root, item['path']), MAX_ARTIFACT)
            require(len(data) == item['bytes'] and hashlib.sha256(data).hexdigest() == item['sha256'], 'store:artifact_changed')
            require(self.put(data, fault) == item['sha256'], 'store:artifact_binding')
        address = self.put(canonical(record), fault)
        fault('before-record-index')
        self.db.execute('BEGIN IMMEDIATE')
        try:
            existing = self.db.execute('SELECT digest FROM records WHERE run_id=?', (record['run_id'],)).fetchone()
            require(existing is None or existing[0] == address, 'store:run_id_conflict')
            self.db.execute('INSERT OR IGNORE INTO records VALUES (?, ?, ?, ?)', (address, record['run_id'], key(record), time.time()))
            self.db.execute('COMMIT')
        except BaseException:
            self.db.execute('ROLLBACK')
            raise
        fault('after-record-index')
        return address

    def record(self, address):
        row = self.db.execute('SELECT run_id FROM records WHERE digest=?', (address,)).fetchone()
        require(row is not None, 'store:record_not_indexed')
        record = decode(self.get(address))
        require(row[0] == record['run_id'], 'store:index_mismatch')
        # Materialize only validated relative artifact names in an owned private
        # temporary root, then use the same independent artifact validator.
        with tempfile.TemporaryDirectory(prefix='alloy-lab-verify-', dir='/private/tmp') as directory:
            root = Path(directory)
            validate(record)
            for item in record['artifacts']:
                data = self.get(item['sha256'])
                require(len(data) == item['bytes'], 'store:artifact_size')
                target = root / item['path']
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(data)
            validate(record, root)
        return record

    def baseline(self, record):
        row = self.db.execute('SELECT digest FROM baselines WHERE key=?', (key(record),)).fetchone()
        return row[0] if row else None

    def set_baseline(self, record_ids, expected=None):
        records = [self.record(address) for address in record_ids]
        baseline = freeze(records, record_ids)
        address = self.put(canonical(baseline))
        self.db.execute('BEGIN IMMEDIATE')
        try:
            current = self.db.execute('SELECT digest,revision FROM baselines WHERE key=?', (baseline['key'],)).fetchone()
            require((current[0] if current else None) == expected, 'baseline:stale_reference')
            revision = current[1] + 1 if current else 1
            self.db.execute('INSERT INTO baselines VALUES (?, ?, ?) ON CONFLICT(key) DO UPDATE SET digest=excluded.digest,revision=excluded.revision',
                            (baseline['key'], address, revision))
            self.db.execute('INSERT INTO baseline_history VALUES (?, ?, ?, ?, ?)',
                            (baseline['key'], revision, address, expected, time.time()))
            self.db.execute('COMMIT')
        except BaseException:
            self.db.execute('ROLLBACK')
            raise
        return address

    def compare(self, record, baseline_address=CURRENT_BASELINE):
        validate(record)
        address = self.baseline(record) if baseline_address is CURRENT_BASELINE else baseline_address
        if record['state'] != 'COMPLETED':
            return {'verdict': record['state'], 'reasons': [item['code'] for item in record['failures']], 'baseline': address}
        if address is None:
            return {'verdict': 'UNBASELINED', 'reasons': ['no_explicit_baseline'], 'baseline': None}
        baseline = decode(self.get(address))
        records = [self.record(item) for item in baseline['records']]
        return {**compare(record, baseline, records), 'baseline': address}

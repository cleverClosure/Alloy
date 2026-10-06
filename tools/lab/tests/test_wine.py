"""Wine adapter boundary controls without a runtime dependency. Author: Timur Isaev."""

import copy
from pathlib import Path
import struct
import tempfile
import unittest

import fixtures
from alloy_lab.common import hashed
from alloy_lab.identity import runtime_identity
from alloy_lab.queue import Queue
from alloy_lab.scenario import runtime_digest, validate
from alloy_lab.scheduler import work_one
from alloy_lab.store import Store
from alloy_lab.wine import architecture, inventory, scenario


class WineTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='alloy-wine-contract-', dir='/private/tmp')
        self.root = Path(self.temporary.name)
        self.runtime = self.root / 'runtime'
        for name in ('loader/wine', 'server/wineserver', 'dlls/libarm64ecfex/aarch64-windows/libarm64ecfex.dll'):
            target = self.runtime / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(b'non-executable contract fixture')
        self.subject = self.root / 'guest.exe'
        self.write_pe(0x8664)

    def tearDown(self):
        self.temporary.cleanup()

    def write_pe(self, machine):
        data = bytearray(128)
        data[:2] = b'MZ'
        struct.pack_into('<I', data, 60, 64)
        data[64:68] = b'PE\0\0'
        struct.pack_into('<H', data, 68, machine)
        self.subject.write_bytes(data)

    def test_architecture_private_prefix_and_mandatory_server_teardown(self):
        definition = scenario(self.runtime, self.subject)
        self.assertEqual(architecture(self.subject), 'x64')
        self.assertEqual([step['id'] for step in definition['steps']],
                         ['boot', 'register', 'guest', 'stop-server', 'wait-server'])
        for step in definition['steps']:
            self.assertEqual(step['environment']['WINEPREFIX'], '{work}/prefix')
            self.assertEqual(step['environment']['ALLOY_RUNTIME_GENERATION'], '{runtime_root}')
        self.assertEqual(definition['steps'][-2]['argv'], ['{runtime_file:server}', '-k'])
        self.assertEqual(definition['steps'][-1]['argv'], ['{runtime_file:server}', '-w'])
        for bad in ([], [0, 0], [True], [256]):
            invalid = copy.deepcopy(definition)
            invalid['steps'][-2]['expected_exit'] = bad
            with self.assertRaises(ValueError):
                validate(invalid)
        self.write_pe(0xaa64)
        self.assertNotIn('register', [step['id'] for step in scenario(self.runtime, self.subject)['steps']])
        self.write_pe(0x014c)
        with self.assertRaisesRegex(ValueError, 'unsupported_guest_architecture'):
            scenario(self.runtime, self.subject)

    def test_complete_inventory_rejects_extra_missing_and_linked_files(self):
        definition = scenario(self.runtime, self.subject)
        self.assertEqual(runtime_identity(definition, self.runtime), definition['runtime']['sha256'])
        extra = self.runtime / 'injected.dll'
        extra.write_bytes(b'extra')
        with self.assertRaisesRegex(ValueError, 'inventory_changed'):
            runtime_identity(definition, self.runtime)
        extra.unlink()
        extra.symlink_to(self.runtime / 'loader/wine')
        with self.assertRaisesRegex(ValueError, 'links_must_be_materialized'):
            inventory(self.runtime)
        extra.unlink()
        (self.runtime / 'server/wineserver').unlink()
        with self.assertRaisesRegex(ValueError, 'loader_or_server_missing'):
            runtime_identity(definition, self.runtime)

    def test_changed_runtime_is_incomparable_without_executing_any_step(self):
        definition = scenario(self.runtime, self.subject)
        definition['runtime']['files']['wine']['sha256'] = '0' * 64
        definition['runtime']['sha256'] = runtime_digest(definition['runtime'])
        queue = Queue(self.root / 'queue')
        store = Store(queue.root / 'evidence-store')
        try:
            job = queue.submit(definition, hashed(definition), self.root, self.runtime)
            self.assertEqual(work_one(queue.root, self.root / 'locks'), job)
            row = queue.get(job)
            self.assertEqual(row['classification'], 'INCOMPARABLE')
            record = store.record(row['history'][0]['record_digest'])
            self.assertEqual(record['steps'], [])
            self.assertEqual(record['observed'], {})
            self.assertNotEqual(record['provenance']['runtime']['before'], record['provenance']['runtime']['expected'])
        finally:
            store.close()
            queue.close()


if __name__ == '__main__':
    unittest.main()

"""Combined ceiling and preservation controls. Author: Timur Isaev."""
import copy
import hashlib
from pathlib import Path
import tempfile
import unittest

import check_all
import drill
import preservation


class CombinedGateTests(unittest.TestCase):
    def setUp(self):
        self.reports = {'wine': {'counts': {'shared_commit_ids': 28, 'supplemental_patches': 1, 'total_maintenance_items': 29}}, 'fex': {'counts': {'retained_commit_ids': 20, 'live_commit_ids': 18, 'historical_only_commit_ids': 2}}, 'dxmt': {'counts': {'patch_files': 2}}}
        self.policy = {'version': 1, 'author': 'Timur Isaev', 'limits': {'wine_shared_commit_ids': 28, 'wine_supplemental_patches': 1, 'wine_total_maintenance_items': 29, 'fex_retained_commit_ids': 20, 'fex_live_commit_ids': 18, 'fex_historical_only_commit_ids': 2, 'dxmt_patch_files': 2}}

    def test_exact_counts_and_every_lowered_bound(self):
        self.assertEqual(check_all.enforce_bounds(self.reports, self.policy), self.policy['limits'])
        for key in self.policy['limits']:
            policy = copy.deepcopy(self.policy)
            policy['limits'][key] -= 1
            with self.subTest(bound=key), self.assertRaisesRegex(ValueError, 'bound:' + key):
                check_all.enforce_bounds(self.reports, policy)

    def test_bound_types_and_unknown_fields_fail_closed(self):
        for value in (True, -1, 20.0, '20'):
            policy = copy.deepcopy(self.policy)
            policy['limits']['fex_retained_commit_ids'] = value
            with self.subTest(value=value), self.assertRaisesRegex(ValueError, 'invalid_number'):
                check_all.enforce_bounds(self.reports, policy)
        self.policy['limits']['invented'] = 3
        with self.assertRaisesRegex(ValueError, 'invalid_fields'):
            check_all.enforce_bounds(self.reports, self.policy)

    def test_snapshot_preserves_leading_status_space_and_detects_bytes(self):
        with tempfile.TemporaryDirectory() as temporary:
            repo = Path(temporary)
            drill.text(repo, 'init', '-q', '-b', 'main')
            path = repo / 'first.txt'
            path.write_bytes(b'base\n')
            drill.text(repo, 'add', '.')
            drill.text(repo, 'commit', '-qm', 'known preservation fixture')
            path.write_bytes(b'dirty\n')
            before = preservation.snapshot({'fixture': repo})
            self.assertEqual(before['fixture']['dirty'], [{'status': ' M', 'path': 'first.txt', 'kind': 'regular', 'sha256': hashlib.sha256(b'dirty\n').hexdigest()}])
            self.assertEqual(before, preservation.snapshot({'fixture': repo}))
            path.write_bytes(b'changed\n')
            self.assertNotEqual(before, preservation.snapshot({'fixture': repo}))

    def test_receipt_rejects_untrusted_upstream_before_fetch(self):
        receipt = {'version': 1, 'author': 'Timur Isaev', 'upstreams': {name: {'url': url, 'branch': branch, 'commit': 'a' * 40, 'observed_at_utc': '2026-10-04T00:00:00Z', 'freshness': 'fresh anonymous ls-remote and filtered fetch', 'commit_time': '2026-10-04T00:00:00+00:00'} for name, (url, branch) in drill.URLS.items()}}
        drill.validate_receipt(receipt)
        receipt['upstreams']['wine']['url'] = 'https://untrusted.invalid/'
        with self.assertRaisesRegex(ValueError, 'receipt:upstream_identity'):
            drill.validate_receipt(receipt)


if __name__ == '__main__':
    unittest.main()

"""Independent scratch-repository controls. Author: Timur Isaev."""
import copy
import subprocess
import tempfile
import unittest
from pathlib import Path

import fex_inventory as inventory


class FEXInventoryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / 'fex'
        self.repo.mkdir()
        self.git('init', '-q', '-b', 'main')
        self.git('config', 'user.name', 'Timur Isaev')
        self.git('config', 'user.email', 'test@example.invalid')
        self.commit('base', 'base\n')
        self.git('update-ref', 'refs/remotes/origin/main', 'HEAD')
        self.git('checkout', '-qb', 'alloy/live')
        self.literal = '- A measured, assisted fixture change with known provenance.'
        self.live = self.commit('PROVENANCE-ALLOY.md', self.literal + '\n')
        self.git('checkout', '-qb', 'alloy/historical', 'origin/main')
        self.old_literal = '- A historical assisted fixture change with known provenance.'
        self.old = self.commit('PROVENANCE-ALLOY.md', self.old_literal + '\n')
        self.git('checkout', '-q', 'alloy/live')
        evidence = self.root / 'spikes/example.md'
        evidence.parent.mkdir()
        evidence.write_text('## Known fixture\n')
        def annotation(ref, literal):
            return {'annotation': {'classification': 'Alloy-specific', 'status': 'retained', 'justification': 'Independent fixture records a known change and its origin.', 'evidence': [{'path': 'spikes/example.md', 'heading': '## Known fixture'}]}, 'ai_assisted': True, 'role': 'provenance-record', 'provenance': {'ref': ref, 'literal': literal}}
        self.policy = {'version': 1, 'author': 'Timur Isaev', 'upstream_ref': 'refs/remotes/origin/main', 'expected_checkout': 'alloy/live', 'historical_branches': ['refs/heads/alloy/historical'], 'bounds': {'retained_commit_ids': 2, 'live_commit_ids': 1, 'historical_only_commit_ids': 1}, 'annotations': {self.live: annotation('refs/heads/alloy/live', self.literal), self.old: annotation('refs/heads/alloy/historical', self.old_literal)}}

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.repo), *args], stderr=subprocess.DEVNULL).decode().strip()

    def commit(self, name, value):
        (self.repo / name).write_text(value)
        self.git('add', name)
        self.git('commit', '-qm', 'known fixture')
        return self.git('rev-parse', 'HEAD')

    def generate(self):
        return inventory.generate(self.repo, self.root, self.policy)

    def test_union_historical_alias_and_dirty_exclusion(self):
        self.git('branch', 'alloy/alias')
        (self.repo / 'PROVENANCE-ALLOY.md').write_text('uncommitted and irrelevant')
        self.git('add', 'PROVENANCE-ALLOY.md')
        report = self.generate()
        self.assertEqual(report['counts'], {'retained_commit_ids': 2, 'live_commit_ids': 1, 'historical_only_commit_ids': 1})
        self.assertEqual(len(report['branches']), 3)
        self.assertEqual({r['commit'] for r in report['commits']}, {self.live, self.old})
        self.assertEqual(next(r for r in report['commits'] if r['commit'] == self.old)['lifecycle'], 'historical-only')

    def test_seeded_undocumented_commit_fails(self):
        self.commit('seed.txt', 'new assisted change\n')
        with self.assertRaisesRegex(ValueError, 'provenance:undocumented_commit'):
            self.generate()

    def test_literal_missing_even_if_annotation_present(self):
        self.policy['annotations'][self.live]['provenance']['literal'] = '- This invented provenance entry does not exist in the record.'
        with self.assertRaisesRegex(ValueError, 'provenance:undocumented_entry'):
            self.generate()

    def test_provenance_only_role_cannot_hide_code(self):
        new = self.commit('source.c', 'fixture\n')
        self.policy['annotations'][new] = copy.deepcopy(self.policy['annotations'][self.live])
        with self.assertRaisesRegex(ValueError, 'provenance:role_path_mismatch'):
            self.generate()

    def test_each_bound_fails(self):
        for key in self.policy['bounds']:
            with self.subTest(bound=key):
                prior = self.policy['bounds'][key]
                self.policy['bounds'][key] = 0
                with self.assertRaisesRegex(ValueError, 'bound:' + key):
                    self.generate()
                self.policy['bounds'][key] = prior

    def test_missing_citation_fails(self):
        (self.root / 'spikes/example.md').write_text('## Changed heading\n')
        with self.assertRaisesRegex(ValueError, 'citation:missing_section'):
            self.generate()

    def test_history_or_assistance_cannot_silently_disappear(self):
        self.policy['historical_branches'].append('refs/heads/alloy/absent')
        with self.assertRaisesRegex(ValueError, 'historical:missing_branch'):
            self.generate()
        self.policy['historical_branches'].pop()
        self.policy['annotations'][self.live]['ai_assisted'] = False
        with self.assertRaisesRegex(ValueError, 'assistance_unclassified'):
            self.generate()

    def test_determinism_and_output_ref_drift(self):
        report = self.generate()
        output = self.root / 'output'
        inventory.outputs(report, output, 'generate', self.repo)
        inventory.outputs(self.generate(), output, 'check', self.repo)
        self.git('branch', 'alloy/new-alias')
        with self.assertRaisesRegex(ValueError, 'inventory:drift'):
            inventory.outputs(self.generate(), output, 'check', self.repo)

    def test_source_output_and_symlink_rejected(self):
        report = self.generate()
        with self.assertRaisesRegex(ValueError, 'output:inside_source'):
            inventory.outputs(report, self.repo / 'output', 'generate', self.repo)
        out = self.root / 'output'
        out.mkdir()
        (out / 'inventory.json').symlink_to(self.repo / 'PROVENANCE-ALLOY.md')
        with self.assertRaisesRegex(ValueError, 'output:symlink'):
            inventory.outputs(report, out, 'generate', self.repo)


if __name__ == '__main__':
    unittest.main()

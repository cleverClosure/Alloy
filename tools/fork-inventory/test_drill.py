"""Known-answer rebase and fetch-boundary controls. Author: Timur Isaev."""
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import drill


class ReplayTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name) / 'source'
        self.repo.mkdir()
        self.git('init', '-q', '-b', 'main')
        (self.repo / 'same.txt').write_text('base\n')
        self.commit('base')
        self.base = self.git('rev-parse', 'HEAD')
        self.git('checkout', '-qb', 'alloy/live')
        (self.repo / 'same.txt').write_text('fork\n')
        self.commit('first fork change')
        self.first = self.git('rev-parse', 'HEAD')
        (self.repo / 'later.txt').write_text('later change\n')
        self.commit('later fork change')
        self.tip = self.git('rev-parse', 'HEAD')
        self.branch = {'ref': 'refs/heads/alloy/live', 'tip': self.tip, 'merge_base': self.base, 'downstream_commit_ids': [self.first, self.tip]}
        self.paths = ['same.txt', 'later.txt']

    def git(self, *args):
        return drill.text(self.repo, *args)

    def commit(self, message):
        self.git('add', '.')
        self.git('commit', '-qm', message)

    def upstream(self, conflicting):
        self.git('checkout', '-qb', 'upstream', self.base)
        (self.repo / ('same.txt' if conflicting else 'other.txt')).write_text('upstream\n')
        self.commit('upstream fixture')
        tip = self.git('rev-parse', 'HEAD')
        self.git('checkout', '-q', 'alloy/live')
        return tip

    def test_real_conflict_stops_without_claiming_total(self):
        upstream = self.upstream(True)
        before = self.git('show-ref')
        result = drill.replay(self.repo, self.branch, upstream, self.paths)
        self.assertEqual(result['status'], 'conflict')
        self.assertEqual(result['first_conflicting_commit'], self.first)
        self.assertEqual(result['replayed_commit_count'], 0)
        self.assertEqual(result['first_stop_unmerged_paths'], ['same.txt'])
        self.assertEqual(result['unattempted_commits_after_stop'], 1)
        self.assertEqual(self.git('show-ref'), before)
        self.assertEqual(self.git('status', '--porcelain'), '')
        self.assertEqual(self.git('rev-parse', 'HEAD'), self.tip)

    def test_unrelated_upstream_all_commits_clean_deterministic(self):
        upstream = self.upstream(False)
        first = drill.replay(self.repo, self.branch, upstream, self.paths)
        second = drill.replay(self.repo, self.branch, upstream, self.paths)
        self.assertEqual(first, second)
        self.assertEqual(first['status'], 'clean')
        self.assertEqual(first['replayed_commit_count'], 2)
        self.assertEqual(first['unattempted_commits_after_stop'], 0)

    def test_inventory_range_mismatch_fails(self):
        self.branch['downstream_commit_ids'] = [self.first]
        with self.assertRaisesRegex(ValueError, 'inventory_range_mismatch'):
            drill.replay(self.repo, self.branch, self.base, self.paths)

    def test_excluded_path_fails_before_checkout(self):
        with self.assertRaisesRegex(ValueError, 'excluded_source'):
            drill.replay(Path('/absent'), self.branch, self.base, ['src/d3d12/fake.cpp'])

    def test_filtered_fetch_has_no_submodules_or_lazy_remote(self):
        result = subprocess.CompletedProcess([], 0, b'', b'')
        with patch.object(drill, 'command', return_value=result) as called, patch.object(drill, 'text', side_effect=['commit', 'upstream', 'no_fetch://alloy-guard']):
            drill.fetch_object(self.repo, 'https://example.invalid/repo', self.tip, 'refs/drill/upstream')
        arguments = called.call_args_list[0].args
        for required in ('--no-auto-maintenance', '--no-recurse-submodules', '--filter=blob:none', '--depth=1', '--no-tags', '--no-write-fetch-head'):
            self.assertIn(required, arguments)

    def test_filtered_upstream_keeps_shallow_roots_and_omitted_blobs(self):
        # Real local upload-pack, not a mocked filtered-fetch success. The
        # upstream-only file must remain absent from every borrowed object DB.
        upstream = Path(self.temp.name) / 'upstream-source'
        drill.command(Path(self.temp.name), 'clone', '--no-hardlinks', '--no-checkout', str(self.repo), str(upstream))
        drill.command(upstream, 'checkout', '-q', '--detach', self.base)
        (upstream / 'outside-sparse.txt').write_text('new upstream-only blob\n')
        drill.command(upstream, 'add', 'outside-sparse.txt')
        drill.command(upstream, 'commit', '-qm', 'upstream outside sparse checkout')
        tip = drill.text(upstream, 'rev-parse', 'HEAD')
        omitted = drill.text(upstream, 'rev-parse', 'HEAD:outside-sparse.txt')
        drill.command(upstream, 'config', 'uploadpack.allowFilter', 'true')
        (self.repo / '.git/shallow').write_text(self.base + '\n')
        cache = Path(self.temp.name) / 'filtered-cache'
        drill.make_cache(cache, self.repo)
        drill.fetch_object(cache, upstream.as_uri(), tip, 'refs/drill/upstream')
        roots = set((cache / '.git/shallow').read_text().splitlines())
        self.assertTrue({self.base, tip} <= roots)
        self.assertNotEqual(drill.command(cache, 'cat-file', '-e', omitted, check=False).returncode, 0)
        result = drill.replay(cache, self.branch, tip, self.paths)
        self.assertEqual(result['status'], 'clean')
        self.assertEqual(result['replayed_commit_count'], 2)
        self.assertNotEqual(drill.command(cache, 'cat-file', '-e', omitted, check=False).returncode, 0)
        self.assertEqual(set((cache / '.git/shallow').read_text().splitlines()), roots)

    def test_missing_object_error_is_not_counted_as_conflict(self):
        upstream = self.upstream(True)
        original = drill.command
        def missing_object(repo, *args, **kwargs):
            result = original(repo, *args, **kwargs)
            if args and args[0] == 'rebase' and '--onto' in args:
                self.assertEqual(result.returncode, 1)
                return subprocess.CompletedProcess(result.args, 1, result.stdout,
                                                   result.stderr + b'error: invalid object 100644 deadbeef for omitted file\n')
            return result
        with patch.object(drill, 'command', side_effect=missing_object):
            with self.assertRaisesRegex(ValueError, 'incomplete_object_graph'):
                drill.replay(self.repo, self.branch, upstream, self.paths)

    def test_filter_capability_required_before_fetch(self):
        ref = self.tip.encode() + b'\trefs/heads/main\n'
        for trace, passes in ((b'packet: git< fetch=shallow wait-for-done filter\n', True), (b'packet: git< fetch=shallow\n', False)):
            result = subprocess.CompletedProcess([], 0, ref, trace)
            with patch.object(drill, 'command', return_value=result) as called:
                if passes:
                    self.assertEqual(drill.preflight(self.repo, 'url', 'main'), self.tip)
                else:
                    with self.assertRaisesRegex(ValueError, 'does_not_advertise_filter'):
                        drill.preflight(self.repo, 'url', 'main')
                self.assertEqual(called.call_args.args[1], 'ls-remote')


if __name__ == '__main__':
    unittest.main()

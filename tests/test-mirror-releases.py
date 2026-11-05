import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('releases', Path(__file__).parents[1] / 'tools/check-mirror-releases.py')
releases = importlib.util.module_from_spec(spec)
spec.loader.exec_module(releases)


class MirrorReleaseTests(unittest.TestCase):
    def test_checks_each_repository_once_and_retains_old_pins(self):
        manifest = {'packages': [dict(package='owner/repo', version='1.0.0'), dict(package='owner/repo', version='2.0.0')]}
        before = repr(manifest)
        calls = []
        def fetch(repo):
            calls.append(repo)
            return dict(tag_name='2.0.0', assets=[])
        result = releases.find_updates(manifest, fetch)
        self.assertEqual(result, dict(checked=1, updates=[]))
        self.assertEqual(calls, ['owner/repo'])
        self.assertEqual(repr(manifest), before)

    def test_new_release_reports_only_supported_matching_archives(self):
        assets = [
            dict(name='hash.tar.zst', size=100, browser_download_url='https://github.com/owner/repo/releases/download/3.0.0/hash.tar.zst'),
            dict(name='wrong.tar.zst', size=100, browser_download_url='https://evil.invalid/file'),
            dict(name='large.tar.zst', size=33*1024*1024, browser_download_url='https://github.com/owner/repo/releases/download/3.0.0/large.tar.zst'),
            dict(name='docs.zip', size=100),
        ]
        result = releases.find_updates({'packages': [dict(package='owner/repo', version='2.0.0')]},
                                       lambda _: dict(tag_name='3.0.0', assets=assets))
        self.assertEqual(result['updates'][0]['archives'], [assets[0]['browser_download_url']])
        self.assertIn('owner/repo 3.0.0', releases.report(result))

    def test_prereleases_and_repositories_without_stable_releases_are_skipped(self):
        for release in [None, dict(tag_name='2.0.0', prerelease=True), dict(tag_name='2.0.0', draft=True)]:
            result = releases.find_updates({'packages': [dict(package='owner/repo', version='1.0.0')]}, lambda _: release)
            self.assertEqual(result['updates'], [])

    def test_unusable_archives_are_reported_without_silently_changing_pins(self):
        result = releases.find_updates({'packages': [dict(package='owner/repo', version='1.0.0')]},
                                       lambda _: dict(tag_name='2.0.0', assets=[]))
        self.assertIn('review manually', releases.report(result))
        for repo in ['../bad', 'owner/repo/extra', 'owner/repo\n']:
            with self.assertRaises(ValueError):
                releases.find_updates({'packages': [dict(package=repo, version='1.0.0')]}, lambda _: None)


if __name__ == '__main__':
    unittest.main()

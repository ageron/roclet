#!/usr/bin/env python3
"""Report new stable releases of mirrored packages without changing any pins."""
import argparse
import json
import os
from pathlib import Path
import re
from urllib.error import HTTPError
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parents[1]
SEGMENT = re.compile(r'[A-Za-z0-9_.+-]+\Z')


def segment(value):
    return isinstance(value, str) and value not in {'.', '..'} and SEGMENT.fullmatch(value)


def find_updates(manifest, fetch_release):
    packages = {}
    for entry in manifest['packages']:
        repo = entry['package']
        parts = repo.split('/')
        if len(parts) != 2 or not all(segment(part) for part in parts):
            raise ValueError('Invalid GitHub repository in mirror manifest')
        packages.setdefault(repo, set()).add(entry['version'])
    updates = []
    for repo, versions in sorted(packages.items(), key=lambda pair: pair[0].lower()):
        release = fetch_release(repo)
        if release is None or release.get('draft') or release.get('prerelease'):
            continue
        version = release.get('tag_name')
        if not segment(version):
            raise ValueError(f'Unsupported release tag for {repo}')
        if version in versions:
            continue
        archives = []
        for asset in release.get('assets', []):
            name = asset.get('name')
            if not segment(name) or not name.endswith('.tar.zst') or asset.get('size', 0) > 32 * 1024 * 1024:
                continue
            expected = f'https://github.com/{repo}/releases/download/{version}/{name}'
            if asset.get('browser_download_url') == expected:
                archives.append(expected)
        updates.append(dict(package=repo, version=version, archives=sorted(archives)))
    return dict(checked=len(packages), updates=updates)


def github_release(repo):
    headers = {'Accept': 'application/vnd.github+json', 'User-Agent': 'Roclet mirror release check'}
    token = os.environ.get('GITHUB_TOKEN')
    if token:
        headers['Authorization'] = f'Bearer {token}'
    request = Request(f'https://api.github.com/repos/{repo}/releases/latest', headers=headers)
    try:
        with urlopen(request, timeout=30) as response:
            return json.load(response)
    except HTTPError as error:
        if error.code == 404:
            return None
        raise RuntimeError(f'GitHub release check failed for {repo}: HTTP {error.code}') from None


def report(result):
    lines = ['# Mirrored package release check', '',
             f'Checked {result["checked"]} repositories. Existing notebook and mirror pins are unchanged.', '']
    if not result['updates']:
        lines.append('Every mirrored repository already includes its latest stable release.')
    for update in result['updates']:
        repo, version = update['package'], update['version']
        lines.extend([f'## {repo} {version}', '',
                      f'[Upstream release](https://github.com/{repo}/releases/tag/{version})', ''])
        if update['archives']:
            lines.extend(f'- [Archive]({url})' for url in update['archives'])
        else:
            lines.append('No supported .tar.zst archive under 32 MiB was found; review manually.')
        lines.append('')
    lines.extend(['', 'Review licenses and compatibility before using `tools/mirror-packages.py --add URL`.',
                  'Run mirror checks, packaging hash verification and WASM conformance before merging.'])
    return '\n'.join(lines) + '\n'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--manifest', type=Path, default=ROOT / 'web/vendor/roc-packages/manifest.json')
    parser.add_argument('--json', action='store_true')
    args = parser.parse_args()
    result = find_updates(json.loads(args.manifest.read_text()), github_release)
    print(json.dumps(result, indent=2) if args.json else report(result), end='\n' if args.json else '')


if __name__ == '__main__':
    main()

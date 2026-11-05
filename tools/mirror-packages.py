#!/usr/bin/env python3
"""Maintain Roclet's pinned static archives. Builds never download packages.

--add URL imports an unchanged release and its transitive dependencies.
--check checks local bytes, dependency closure and coverage of every demo.
Requires curl and a tar executable with zstd support, but no Python packages.
The Zig packager additionally verifies each archive's Roc BLAKE3 content hash.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
MIRROR = ROOT / 'web/vendor/roc-packages'
MANIFEST = MIRROR / 'manifest.json'
URL = re.compile(r'https://github\.com/([\w.-]+)/([\w.-]+)/releases/download/([\w.+-]+)/([\w.+-]+\.tar\.zst)\Z')
IMPORT = re.compile(r'"(https://[^"\s]+\.tar\.zst)"')
LIMIT = 32 * 1024 * 1024


def references(source):
    # Ignore documentation and commented-out examples.
    return sorted(set(IMPORT.findall('\n'.join(line for line in source.splitlines()
                                               if not line.lstrip().startswith('#')))))


def sources(path):
    names = subprocess.check_output(['tar', '-tf', str(path)], text=True).splitlines()
    return '\n'.join(subprocess.check_output(['tar', '-xOf', str(path), name], text=True)
                     for name in names if name.endswith('.roc'))


def download(url, destination):
    subprocess.run(['curl', '-fsSL', '--retry', '3', '--max-time', '120',
                    '--proto', '=https', '--proto-redir', '=https',
                    '--max-filesize', str(LIMIT), url, '-o', str(destination)], check=True)


def add(url, entries):
    if any(entry['url'] == url for entry in entries):
        return
    match = URL.fullmatch(url)
    if not match:
        raise ValueError(f'Unsupported package URL: {url}')
    owner, repo, version, archive = match.groups()
    MIRROR.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as temp:
        path = Path(temp) / archive
        download(url, path)
        data = path.read_bytes()
        if len(data) > LIMIT:
            raise ValueError('Archive exceeds browser package limit')
        dependencies = references(sources(path))
        # Preserve a separate license even when the release bundle omits it.
        license_name = f'licenses/{owner}-{repo}-{version}.txt'
        license_path = MIRROR / license_name
        license_path.parent.mkdir(exist_ok=True)
        for name in ['LICENSE', 'LICENSE.md', 'LICENSE.txt', 'LICENCE']:
            try:
                download(f'https://raw.githubusercontent.com/{owner}/{repo}/{version}/{name}',
                         Path(temp) / 'license')
                break
            except subprocess.CalledProcessError:
                continue
        else:
            raise ValueError(f'Cannot find license for {url}')
        license_path.write_bytes((Path(temp) / 'license').read_bytes())
        file = f'archives/{archive}'
        (MIRROR / file).parent.mkdir(exist_ok=True)
        (MIRROR / file).write_bytes(data)
        entries.append(dict(package=f'{owner}/{repo}', version=version, url=url, file=file,
                            bytes=len(data), sha256=hashlib.sha256(data).hexdigest(),
                            licenseFile=license_name, dependencies=dependencies))
    for dependency in dependencies:
        add(dependency, entries)


def check(entries):
    urls = {entry['url'] for entry in entries}
    if len(urls) != len(entries):
        raise ValueError('Duplicate mirror URL')
    for entry in entries:
        data = (MIRROR / entry['file']).read_bytes()
        if len(data) != entry['bytes'] or hashlib.sha256(data).hexdigest() != entry['sha256']:
            raise ValueError(f'Changed archive: {entry["file"]}')
        if not (MIRROR / entry['licenseFile']).read_text().strip():
            raise ValueError(f'Missing license: {entry["url"]}')
        actual = references(sources(MIRROR / entry['file']))
        if actual != entry['dependencies'] or not set(actual) <= urls:
            raise ValueError(f'Incomplete transitive dependencies: {entry["url"]}')
    for path in sorted((ROOT / 'demos').rglob('*')):
        if path.suffix not in {'.roc', '.md'}:
            continue
        missing = set(references(path.read_text())) - urls
        if missing:
            raise ValueError(f'Unmirrored demo dependency in {path}: {missing}')
    print(f'Checked {len(entries)} archives ({sum(e["bytes"] for e in entries):,} bytes); all demo and transitive dependencies covered.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--add', action='append', default=[], metavar='URL')
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    manifest = json.loads(MANIFEST.read_text()) if MANIFEST.exists() else dict(schema=1, packages=[])
    for url in args.add:
        add(url, manifest['packages'])
    if args.add:
        manifest['packages'].sort(key=lambda e: (e['package'].lower(), e['version']))
        MANIFEST.write_text(json.dumps(manifest, indent=2) + '\n')
    check(manifest['packages'])


if __name__ == '__main__':
    main()

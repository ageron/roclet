#!/usr/bin/env python3
"""Prepare the application update after publishing a Display package release (CI only)."""
import argparse
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
PATHS = (
    'package/display-package-url.txt', 'package/README.md',
    'demos/02-a-little-data.roc', 'demos/03-circle.roc',
    'fixtures/documents/rich-outputs.roc', 'tests/documents.json',
)


def update(version, archive):
    if not re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-[0-9A-Za-z.-]+)?', version):
        raise ValueError('Expected a release version such as 0.1.0')
    if not re.fullmatch(r'[1-9A-HJ-NP-Za-km-z]+\.tar\.zst', archive):
        raise ValueError('Expected a content-addressed Roc archive filename')
    old = (ROOT / PATHS[0]).read_text().strip()
    new = f'https://github.com/ageron/roclet/releases/download/{version}/{archive}'
    replacements = {}
    for name in PATHS:
        source = (ROOT / name).read_text()
        if old not in source:
            raise ValueError(f'{name} does not contain the current package pin')
        replacements[name] = source.replace(old, new)
    for name, source in replacements.items():
        (ROOT / name).write_text(source)
    return new


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--version', required=True)
    parser.add_argument('--archive', required=True)
    args = parser.parse_args()
    print(update(args.version, args.archive))

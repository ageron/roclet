#!/usr/bin/env python3
"""Import the Display sources used by Roclet's offline engines."""
import argparse
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MODULES = ('main.roc', 'Display.roc', 'Input.roc', 'InputValues.roc')


def sync(source):
    source = Path(source).resolve()
    if (source / "package" / "main.roc").is_file():
        source = source / "package"
    # Read every module before writing, so missing files cannot cause a partial import.
    contents = {name: (source / name).read_bytes() for name in MODULES}
    if not contents['main.roc'].startswith(b'package [Display, Input]'):
        raise ValueError('Expected the Roclet Display package')
    for name, content in contents.items():
        (ROOT / 'vendor' / 'roclet-display' / name).write_bytes(content)
    print('Imported Display sources; update the published pin separately after release.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path, help='Extracted release archive or Display source checkout')
    sync(parser.parse_args().source)

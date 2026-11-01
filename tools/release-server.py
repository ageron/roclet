"""Bundle a platform server with the browser site from the same verified commit."""
import argparse
import os
from pathlib import Path
import shutil
import tarfile
import tempfile
import zipfile


def package(site, binary, platform, version, output):
    output = Path(output)
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp) / 'roclet'
        root.mkdir()
        with zipfile.ZipFile(site) as archive:
            for name in archive.namelist():
                path = Path(name)
                if path.is_absolute() or '..' in path.parts or '\\' in name:
                    raise ValueError(f'Invalid site archive path: {name}')
            archive.extractall(root)
        for required in ('index.html', 'web/install.html', 'web/edit.html', 'artifacts/manifest.json', 'artifacts/roclet.wasm'):
            if not (root / required).is_file():
                raise ValueError(f'Missing site asset: {required}')
        executable = 'roclet.exe' if platform.startswith('windows-') else 'roclet'
        shutil.copyfile(binary, root / executable)
        os.chmod(root / executable, 0o755)
        (root / 'README.txt').write_text(
            f'Roclet server {version} ({platform})\n\n'
            'Run roclet serve (roclet.exe serve on Windows), then open the private token URL printed in the terminal.\n'
            'Keep the executable and all extracted folders together. Stop with Ctrl-C.\n'
            'Use --port 4174 to choose another port. No Zig or Roc installation is needed.\n'
            'This archive serves the browser app; it does not include the headless notebook runner.\n'
            'Installation: https://ageron.github.io/roclet/web/install.html\n', encoding='utf-8')
        name = f'roclet-{platform}'
        if executable.endswith('.exe'):
            destination = output / f'{name}.zip'
            with zipfile.ZipFile(destination, 'w', zipfile.ZIP_DEFLATED) as archive:
                for path in sorted(root.rglob('*')):
                    if path.is_file():
                        archive.write(path, path.relative_to(root.parent))
        else:
            destination = output / f'{name}.tar.gz'
            with tarfile.open(destination, 'w:gz') as archive:
                archive.add(root, arcname='roclet')
        return destination


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('site', 'binary', 'platform', 'version', 'output'):
        parser.add_argument('--' + name, required=True)
    args = parser.parse_args()
    print(package(args.site, args.binary, args.platform, args.version, args.output))

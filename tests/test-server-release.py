"""Smoke-test the actual extracted release, from an unrelated working directory."""
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request
import shutil


def check(archive):
    with tempfile.TemporaryDirectory() as tmp, tempfile.TemporaryDirectory() as cwd:
        shutil.unpack_archive(str(Path(archive).resolve()), tmp)
        root = Path(tmp) / 'roclet'
        executable = root / ('roclet.exe' if sys.platform == 'win32' else 'roclet')
        subprocess.run([str(executable), '--help'], check=True, cwd=cwd, capture_output=True)
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            port = sock.getsockname()[1]
        with tempfile.TemporaryFile() as log:
            process = subprocess.Popen([str(executable), '--port', str(port)], cwd=cwd,
                                       stdout=log, stderr=log)
            try:
                deadline = time.monotonic() + 20
                while True:
                    try:
                        with urllib.request.urlopen(f'http://127.0.0.1:{port}/', timeout=1) as response:
                            assert response.read() == (root / 'index.html').read_bytes()
                        break
                    except OSError:
                        if process.poll() is not None or time.monotonic() >= deadline:
                            log.seek(0)
                            raise RuntimeError(log.read().decode(errors='replace'))
                        time.sleep(.1)
                for path in ('web/install.html', 'web/edit.html', 'web/open-notebook.mjs', 'artifacts/manifest.json', 'artifacts/roclet.wasm'):
                    with urllib.request.urlopen(f'http://127.0.0.1:{port}/{path}', timeout=10) as response:
                        assert response.read() == (root / path).read_bytes(), path
                print('Extracted server release serves all required assets.')
            finally:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()


if __name__ == '__main__':
    check(sys.argv[1])

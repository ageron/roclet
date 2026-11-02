"""Exercise the Unix installer without network access or changing the user's home."""
import hashlib
import io
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest

INSTALLER = Path(__file__).resolve().parents[1] / 'install.sh'


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.home = self.root / 'home with spaces'
        self.home.mkdir()
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.downloads = self.root / 'downloads'
        self.downloads.mkdir()
        self.env = dict(os.environ, HOME=str(self.home), PATH=f'{self.bin}:' + os.environ['PATH'],
                        DOWNLOADS=str(self.downloads), TEST_OS='Linux', TEST_ARCH='x86_64')
        self.command('uname', '#!/bin/sh\ncase "$1" in -s) echo "$TEST_OS";; -m) echo "$TEST_ARCH";; esac\n')
        self.command('curl', '''#!/bin/sh
while [ "$#" -gt 0 ]; do
 case "$1" in -o) out=$2; shift 2;; -w|--proto|--proto-redir) shift 2;; --*) shift;; *) url=$1; shift;; esac
done
case "$url" in */latest) printf 'https://github.com/ageron/roclet/releases/tag/server-v0.2.0';; *) cp "$DOWNLOADS/${url##*/}" "$out";; esac
''')

    def command(self, name, text):
        path = self.bin / name
        path.write_text(text)
        path.chmod(0o755)

    def archive(self, platform='linux-x64', version='0.2.0', legacy=False, corrupt=False):
        name = f'roclet-{platform}.tar.gz' if legacy else f'roclet-{version}-{platform}.tar.gz'
        path = self.downloads / name
        with tarfile.open(path, 'w:gz') as archive:
            for name, data in [('roclet', b'#!/bin/sh\nprintf "%s\\n" "$PWD" "$@"\n'), ('index.html', b'site')]:
                info = tarfile.TarInfo('roclet/' + name)
                info.size = len(data)
                info.mode = 0o755 if name == 'roclet' else 0o644
                archive.addfile(info, io.BytesIO(data))
        digest = '0' * 64 if corrupt else hashlib.sha256(path.read_bytes()).hexdigest()
        (self.downloads / 'SHA256SUMS').write_text(f'{digest}  {path.name}\n')

    def run_installer(self, *args, success=True):
        result = subprocess.run(['sh', str(INSTALLER), *args], env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        return result

    def test_latest_launcher_and_repeat(self):
        self.archive()
        self.run_installer()
        launcher = self.home / '.local/bin/roclet'
        result = subprocess.check_output([str(launcher), 'serve', 'file with spaces.roc'], cwd=self.root, env=self.env, text=True)
        self.assertEqual(result.splitlines(), [str(self.root.resolve()), 'serve', 'file with spaces.roc'])
        self.assertIn('already installed', self.run_installer().stdout)
        self.archive(version='0.3.0')
        self.run_installer('0.3.0')
        self.assertIn('0.3.0', launcher.read_text())
        self.assertTrue((self.home / '.local/share/roclet/versions/0.2.0-linux-x64/index.html').exists())

    def test_platforms_and_legacy_names(self):
        for os_name, machine, platform in [('Darwin', 'arm64', 'macos-arm64'), ('Darwin', 'x86_64', 'macos-x64'), ('Linux', 'aarch64', 'linux-arm64')]:
            self.env.update(TEST_OS=os_name, TEST_ARCH=machine)
            self.archive(platform, legacy=True)
            self.run_installer('0.2.0')
            self.assertTrue((self.home / f'.local/share/roclet/versions/0.2.0-{platform}/index.html').exists())

    def test_checksum_rejected(self):
        self.archive(corrupt=True)
        self.assertIn('Checksum mismatch', self.run_installer(success=False).stderr)
        self.assertFalse((self.home / '.local/bin/roclet').exists())

    def test_existing_command_preserved(self):
        command = self.home / '.local/bin/roclet'
        command.parent.mkdir(parents=True)
        command.write_text('unrelated command')
        self.run_installer(success=False)
        self.assertEqual(command.read_text(), 'unrelated command')

    def test_invalid_version(self):
        self.run_installer('../bad', success=False)


if __name__ == '__main__':
    unittest.main()

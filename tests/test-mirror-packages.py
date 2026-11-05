import importlib.util
import io
from pathlib import Path
import tarfile
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('mirror', Path(__file__).parents[1] / 'tools/mirror-packages.py')
mirror = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mirror)


class MirrorArchiveTests(unittest.TestCase):
    def test_archive_member_names_are_operands_not_tar_options(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'fixture.tar'
            with tarfile.open(path, 'w') as archive:
                source = b'module [answer]\nanswer = 42\n'
                member = tarfile.TarInfo('--not-a-tar-option.roc')
                member.size = len(source)
                archive.addfile(member, io.BytesIO(source))
            self.assertEqual(mirror.sources(path), source.decode())


if __name__ == '__main__':
    unittest.main()

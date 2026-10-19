"""Release metadata updates must be complete and reject unsafe inputs."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('pin', Path(__file__).parents[1] / 'tools/update-package-pin.py')
pin = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pin)


class PinUpdateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        pin.ROOT = Path(self.temp.name)
        self.old = 'https://github.com/ageron/roclet/releases/download/0.1.0/Abc.tar.zst'
        for name in pin.PATHS:
            path = pin.ROOT / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(self.old + '\n')

    def test_updates_every_consumer(self):
        expected = pin.update('0.2.0', 'Def.tar.zst')
        for name in pin.PATHS:
            self.assertEqual((pin.ROOT / name).read_text(), expected + '\n')
        self.assertEqual(pin.update('0.2.0', 'Def.tar.zst'), expected)

    def test_missing_pin_leaves_every_file_unchanged(self):
        (pin.ROOT / pin.PATHS[-1]).write_text('missing')
        before = {name: (pin.ROOT / name).read_text() for name in pin.PATHS}
        with self.assertRaises(ValueError):
            pin.update('0.2.0', 'Def.tar.zst')
        self.assertEqual(before, {name: (pin.ROOT / name).read_text() for name in pin.PATHS})

    def test_invalid_inputs(self):
        for version, archive in [('latest', 'Abc.tar.zst'), ('0.1.0;echo bad', 'Abc.tar.zst'), ('0.1.0', '../Abc.tar.zst')]:
            with self.subTest(version=version, archive=archive), self.assertRaises(ValueError):
                pin.update(version, archive)


if __name__ == '__main__':
    unittest.main()

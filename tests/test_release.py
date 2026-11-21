import importlib.util
from pathlib import Path
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('release', ROOT / 'tools/build_release.py')
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleaseTests(unittest.TestCase):
    def test_installable_archive_and_checksum(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            path = release.build(output, 'v' + release.version())
            first = path.read_bytes()
            release.build(output, 'v' + release.version())
            self.assertEqual(first, path.read_bytes())
            with zipfile.ZipFile(path) as archive:
                names = set(archive.namelist())
                prefix = release.PLUGIN + '/'
                self.assertTrue(all(name.startswith(prefix) for name in names))
                self.assertTrue({prefix + '_meta.lua', prefix + 'main.lua',
                                 prefix + 'ao3lib/ui/menu.lua', prefix + 'assets/ao3.svg',
                                 prefix + 'assets/ao3-icons/COPYING',
                                 prefix + 'assets/ao3-icons-zerafina/LICENSE'} <= names)
                self.assertFalse(any('README' in name or '/source/' in name or '/tests/' in name
                                     or '/tools/' in name or '/.git' in name for name in names))
                expected = {prefix + path.relative_to(ROOT).as_posix()
                            for path in (ROOT / 'ao3lib').rglob('*.lua')}
                self.assertTrue(expected <= names)
                for style in ('ao3-icons', 'ao3-icons-eink', 'ao3-icons-zerafina', 'ao3-icons-zerafina-eink'):
                    self.assertEqual(18, sum(name.startswith(prefix + 'assets/' + style + '/') and name.endswith('.png') for name in names))
                self.assertIsNone(archive.testzip())
            self.assertEqual((output / 'SHA256SUMS').read_text(),
                             release.hashlib.sha256(first).hexdigest() + '  ' + path.name + '\n')

    def test_reject_mismatched_tag(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(ValueError):
                release.build(Path(directory), 'v99.99.99')
            self.assertFalse(list(Path(directory).iterdir()))


if __name__ == '__main__':
    unittest.main()

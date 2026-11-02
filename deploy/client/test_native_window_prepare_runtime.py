"""The native harness must never silently take a different runtime configuration."""
from pathlib import Path
import json
import shutil
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).parent / 'native_window_regression' / 'prepare_runtime.py'
PYTHON = sys.executable if Path(sys.executable).is_file() else shutil.which('python')


class PrepareRuntimeConfigurationTest(unittest.TestCase):
    def _copy(self, configuration=None):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            project = root / 'project'
            for mode in ('Profile', 'Release'):
                bundle = project / 'build/windows/x64/runner' / mode
                (bundle / 'data').mkdir(parents=True)
                for name in ('flutter_windows.dll', 'data/app.so', 'uten_imp.exe'):
                    (bundle / name).write_bytes(f'{mode}:{name}'.encode())
            output = root / 'runtime'
            command = [PYTHON, str(SCRIPT), '--project', str(project), '--output', str(output)]
            if configuration is not None:
                command += ['--configuration', configuration]
            result = subprocess.run(command, capture_output=True, text=True, check=False)
            self.assertEqual(result.returncode, 0, result.stderr)
            expected = configuration or 'Profile'
            self.assertEqual((output / 'data/app.so').read_bytes(), f'{expected}:data/app.so'.encode())
            receipt = json.loads((root / 'runtime-manifest.json').read_text(encoding='utf-8'))
            self.assertEqual(receipt['buildConfiguration'], expected)
            self.assertTrue(receipt['payloadCopiedWithoutRecompilingDart'])

    def test_explicit_release_does_not_copy_profile(self):
        self._copy('Release')

    def test_default_remains_profile(self):
        self._copy()

    def test_debug_is_not_a_supported_aot_fixture(self):
        result = subprocess.run([PYTHON, str(SCRIPT), '--project', '.', '--output', 'unused',
                                 '--configuration', 'Debug'], capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 2)
        self.assertIn('invalid choice', result.stderr)


if __name__ == '__main__':
    unittest.main()

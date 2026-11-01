"""Real child-process output must survive a non-UTF-8 host locale."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import unittest


class ToolOutputTest(unittest.TestCase):
    def test_real_release_tools_preserve_unicode_and_non_utf8_diagnostics_in_a_legacy_locale(self):
        folder = str(Path(__file__).resolve().parent)
        # Embedded Python distributions can report their runtime directory here.
        launcher = sys.executable if Path(sys.executable).is_file() else shutil.which("python")
        self.assertIsNotNone(launcher)
        child = (
            f"import sys; sys.stdout.buffer.write(bytes.fromhex('{('中文'.encode('utf-8') + bytes([255])).hex()}')); "
            f"sys.stderr.buffer.write(bytes.fromhex('{'构建诊断'.encode('utf-8').hex()}')); sys.exit(7)"
        )
        self.assertTrue(child.isascii(), "The legacy-locale child argv itself must remain ASCII")
        program = (
            "import json, subprocess, sys; "
            f"sys.path.insert(0, {folder!r}); "
            "from tool_output import UTF8_TOOL_OUTPUT; "
            f"child = {child!r}; "
            f"r = subprocess.run([{launcher!r}, '-c', child], capture_output=True, **UTF8_TOOL_OUTPUT); "
            "sys.stdout.buffer.write(json.dumps({'code':r.returncode,'stdout':r.stdout,'stderr':r.stderr}, "
            "ensure_ascii=True).encode('ascii'))"
        )
        environment = {**os.environ, "PYTHONUTF8": "0", "PYTHONCOERCECLOCALE": "0", "LC_ALL": "C", "LANG": "C"}
        result = subprocess.run([launcher, "-c", program], env=environment, capture_output=True, check=True)
        captured = json.loads(result.stdout)
        self.assertEqual(7, captured["code"])
        self.assertEqual("中文\\xff", captured["stdout"])
        self.assertEqual("构建诊断", captured["stderr"])
        self.assertEqual(b"", result.stderr, "Reader-thread decoding errors must not escape the capture")


if __name__ == "__main__":
    unittest.main()

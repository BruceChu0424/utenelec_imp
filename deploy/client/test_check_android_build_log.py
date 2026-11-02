import importlib.util
from pathlib import Path
import tempfile
import unittest


spec = importlib.util.spec_from_file_location("android_build_diagnostics", Path(__file__).with_name("check_android_build_log.py"))
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


class AndroidBuildDiagnosticsTest(unittest.TestCase):
    def findings(self, text):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "build.log"
            log.write_text(text, encoding="utf-8")
            return gate.inspect(log)

    def test_success_after_kotlin_fallback_keeps_the_real_error(self):
        result = self.findings("e: Daemon compilation failed: null\nCaused by: different roots\nBUILD SUCCESSFUL\n")
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0]["line"], 1)

    def test_compiler_source_warning_and_plain_gradle_warning_are_rejected(self):
        result = self.findings("exception: /cache/plugin/Camera.kt:63:5: warning: annotation target changes\nWARNING: Unsupported Kotlin plugin version.\n")
        self.assertEqual(len(result), 2)

    def test_gradle_deprecation_and_javac_options_warning_are_rejected(self):
        result = self.findings("Deprecated Gradle features were used in this build\nwarning: [options] source value 8 is obsolete\n")
        self.assertEqual(len(result), 2)

    def test_normal_progress_and_notice_about_a_warning_guide_are_not_diagnostics(self):
        self.assertEqual(self.findings("Running Gradle task 'assembleDebug'...\nRead warnings-guide.md\nBUILD SUCCESSFUL\nBuilt app-debug.apk\n"), [])

    def test_colored_compiler_diagnostic_is_preserved_and_empty_log_is_rejected(self):
        self.assertEqual(len(self.findings("\x1b[31mw:\x1b[0m a compiler warning\n")), 1)
        with self.assertRaises(ValueError):
            self.findings("")


if __name__ == "__main__":
    unittest.main()

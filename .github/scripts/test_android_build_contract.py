"""Android variant safety and the unchanged runtime closure of the Gradle-only plugin backports."""
import hashlib
import json
from pathlib import Path
import re
import unittest
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[2]
ANDROID = "{http://schemas.android.com/apk/res/android}"
TOOLS = "{http://schemas.android.com/tools}"


class AndroidBuildContractTest(unittest.TestCase):
    def test_ci_uses_in_process_kotlin_without_changing_local_defaults_or_diagnostics(self):
        workflow = (ROOT / ".github/workflows/quality.yml").read_text(encoding="utf-8")
        job = re.search(r"(?ms)^  native-android:\n(.*?)(?=^  [\w-]+:\n|\Z)", workflow)
        self.assertIsNotNone(job)
        compile_step = re.search(
            r"(?ms)^      - name: Compile Android application and native package installer bridge\n"
            r"(.*?)(?=^      - |\Z)", job.group(1)
        )
        self.assertIsNotNone(compile_step)
        property_name = "kotlin.compiler.execution.strategy"
        transport = f"ORG_GRADLE_PROJECT_{property_name}: in-process"
        self.assertEqual(1, workflow.count(transport))
        self.assertIn("          " + transport, compile_step.group(1))
        for relative in (
            "android/gradle.properties", "android/settings.gradle.kts",
            "android/build.gradle.kts", "android/app/build.gradle.kts",
        ):
            self.assertNotIn(property_name, (ROOT / relative).read_text(encoding="utf-8"))
        self.assertIn("set -euo pipefail", compile_step.group(1))
        self.assertIn('python3 deploy/client/check_android_build_log.py "$RUNNER_TEMP/android-build.log"', compile_step.group(1))
        self.assertNotIn("continue-on-error:", job.group(1))

    def test_development_overlays_explicitly_override_cleartext_without_weakening_release(self):
        base = ET.parse(ROOT / "android/app/src/main/AndroidManifest.xml").getroot().find("application")
        self.assertEqual("false", base.get(ANDROID + "usesCleartextTraffic"))
        self.assertIsNone(base.get(TOOLS + "replace"))
        for variant in ("debug", "profile"):
            with self.subTest(variant=variant):
                overlay = ET.parse(ROOT / f"android/app/src/{variant}/AndroidManifest.xml").getroot().find("application")
                self.assertEqual("true", overlay.get(ANDROID + "usesCleartextTraffic"))
                self.assertIn("android:usesCleartextTraffic", overlay.get(TOOLS + "replace", "").split(","))

    def test_vendored_plugin_runtime_and_licenses_match_the_original_locked_archives(self):
        archives = {
            "desktop_drop": "47ded09c85909edfed644fd4cbb5051b040d0aed5c79e7e062ea4b3b7156dbe4",
            "device_info_plus": "98f28b42168cc509abc92f88518882fd58061ea372d7999aecc424345c7bff6a",
        }
        for package, archive_sha in archives.items():
            with self.subTest(package=package):
                directory = ROOT / "third_party" / package
                manifest = json.loads((directory / "UPSTREAM-FILES.json").read_text(encoding="utf-8"))
                self.assertEqual(archive_sha, manifest["archiveSha256"])
                self.assertEqual({"android/build.gradle", "pubspec.yaml"}, set(manifest["modifiedFiles"]))
                self.assertIn("LICENSE", manifest["files"])
                actual_paths = {path.relative_to(directory).as_posix() for path in directory.rglob("*") if path.is_file()}
                self.assertEqual(set(manifest["files"]) | {"UPSTREAM.md", "UPSTREAM-FILES.json"}, actual_paths)
                for relative, expected in manifest["files"].items():
                    if relative in manifest["modifiedFiles"]:
                        continue
                    data = (directory / relative).read_bytes()
                    if relative in manifest.get("hygieneSha256", {}):
                        expected = manifest["hygieneSha256"][relative]
                    # Git checks out platform source text with native line endings.
                    candidates = (hashlib.sha256(data).hexdigest(), hashlib.sha256(data.replace(b"\r\n", b"\n")).hexdigest())
                    self.assertIn(expected, candidates, f"{package}/{relative} changed outside the reviewed Gradle patch")


if __name__ == "__main__":
    unittest.main()

"""Keep the complete inference environment inside security and release gates."""

import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
WORKER = ROOT / "services/material_forecast"


class InferenceSupplyChainContractTests(unittest.TestCase):
    def test_all_runtime_packages_are_exactly_pinned_and_hashed(self):
        source = (WORKER / "requirements.txt").read_text(encoding="utf-8")
        requirements = [line.strip() for line in source.replace("\\\n", " ").splitlines()
                        if line.strip() and not line.lstrip().startswith("#")]
        packages = {}
        for line in requirements:
            with self.subTest(requirement=line.split()[0]):
                match = re.match(r"^([a-zA-Z0-9_.-]+)==([^\s;]+)(?:\s*;\s*[^\\]+?)?\s+--hash=", line)
                self.assertIsNotNone(match, "every direct/transitive package must have an exact version and hash")
                self.assertTrue(re.search(r"--hash=sha256:[a-f0-9]{64}(?:\s|$)", line))
                self.assertNotIn("--index-url", line)
                self.assertNotIn(" @ ", line)
                name, version = match.groups()
                packages[name.lower().replace("_", "-")] = version
        direct = {}
        for line in (WORKER / "requirements.in").read_text(encoding="utf-8").splitlines():
            if line.strip() and not line.lstrip().startswith("#"):
                name, version = line.strip().split("==")
                direct[name] = version
        self.assertTrue(direct)
        self.assertTrue(all(packages.get(name) == version for name, version in direct.items()))
        # These dependencies are required by the actual inference library. A
        # manifest listing only the three direct packages is not a complete scan.
        self.assertTrue({"coreforecast", "scipy", "statsmodels", "fugue", "utilsforecast"} <= packages.keys())

    def test_ci_installs_and_osv_scans_the_identical_complete_lock(self):
        forecast = (ROOT / ".github/workflows/material-forecast.yml").read_text(encoding="utf-8")
        security = (ROOT / ".github/workflows/osv-scanner.yml").read_text(encoding="utf-8")
        self.assertIn("--require-hashes --only-binary=:all:", forecast)
        self.assertIn("-r services/material_forecast/requirements.txt", forecast)
        self.assertIn(".venv-material-forecast/bin/python -m pip check", forecast)
        self.assertIn("python3.12 -m venv", forecast)
        self.assertIn("--lockfile\n            ./services/material_forecast/requirements.txt", security)
        self.assertIn("\n            services/material_forecast/requirements.txt\n", security)
        self.assertNotIn("continue-on-error", forecast)
        self.assertNotRegex(forecast, r"(?m)^\s+paths(?:-ignore)?:")
        self.assertIn("  pull_request:", forecast)
        self.assertIn("branches: [main]", forecast)
        self.assertIn('sudo "$(command -v python3.12)" services/material_forecast/tests/check_linux_publication_permissions.py', forecast)

    def test_container_and_documented_installs_enforce_the_same_reviewed_hash_lock(self):
        dockerfile = (WORKER / "Dockerfile").read_text(encoding="utf-8")
        instructions = dockerfile.replace("\\\n", " ")
        self.assertRegex(instructions, r"RUN\s+python -m pip install\s+[^\n]*--require-hashes\s+--only-binary=:all:\s+-r /app/requirements\.txt")
        self.assertIn("&& python -m pip check", instructions)
        self.assertIn("COPY services/material_forecast/requirements.txt /app/requirements.txt", dockerfile)
        self.assertNotRegex(instructions, r"(?:CMD|ENTRYPOINT)[^\n]*(?:pip install|pip upgrade)")

        readme = (WORKER / "README.md").read_text(encoding="utf-8")
        installs = [line.strip() for line in readme.splitlines() if " -m pip install " in line]
        self.assertGreaterEqual(len(installs), 2, "automatic and CSV installations must both be checked")
        for command in installs:
            with self.subTest(command=command):
                self.assertIn("--require-hashes --only-binary=:all:", command)
                self.assertIn("-r services/material_forecast/requirements.txt", command)
        self.assertEqual(len(installs), sum(" -m pip check" in line for line in readme.splitlines()))


if __name__ == "__main__":
    unittest.main()

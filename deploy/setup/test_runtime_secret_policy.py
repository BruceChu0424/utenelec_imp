"""Execute deployment validators' real secret policy using public synthetic values."""
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class RuntimeSecretPolicyTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.policies = []
        for name in ("validate-server-env.sh", "validate-internal-test-server-env.sh"):
            source = (ROOT / "deploy/setup" / name).read_text(encoding="utf-8")
            match = re.search(r"<<'SECRET'\n(.*?)\nSECRET", source, re.DOTALL)
            if match is None:
                raise AssertionError(f"missing protected-file secret policy: {name}")
            cls.policies.append(match.group(1))

    def evaluate(self, value, minimum=32):
        with tempfile.TemporaryDirectory() as directory:
            env_file = Path(directory) / "synthetic.env"
            env_file.write_text("UTEN_JWT_SECRET=" + value + "\n", encoding="utf-8")
            return subprocess.run(
                [sys.executable, "-I", "-", str(env_file), "UTEN_JWT_SECRET", str(minimum)],
                input=self.policies[0], capture_output=True, text=True, timeout=10,
            )

    def test_both_deployment_profiles_enforce_identical_rules(self):
        self.assertEqual(self.policies[0], self.policies[1])

    def test_accepts_adequately_sized_hex_and_base64(self):
        for value in ("6f8130ac9e4bd25f0871d6b349a5ce20", "vE3+qP9/T6xJ2wU8rL0aN5cB7zD4yS1g="):
            result = self.evaluate(value)
            self.assertEqual(0, result.returncode, result.stderr)
            self.assertEqual("", result.stdout + result.stderr)

    def test_rejects_placeholders_predictable_values_and_invalid_characters_without_output(self):
        for value in (
            "", "short",
            "replace-with-a-strong-random-secret-at-least-32-bytes-long",
            "RePlAcE_GENERATED_RANDOM_SECRET_WITH_32_BYTES",
            "change-me-before-starting-this-production-service",
            "CHANGE_ME_BEFORE_STARTING_THIS_PRODUCTION_SERVICE",
            "placeholder-secret-that-is-long-enough-for-the-gate",
            "your_secret_key_that_is_at_least_32_bytes",
            "example-secret-that-is-long-enough-for-production",
            "${UTEN_JWT_SECRET:12345678901234567890123456789012}",
            "<generate-a-secret-of-at-least-32-bytes>",
            "a" * 48, "01234567" * 8,
            "6f8130ac9e4bd25f0871d6b349a5ce20 ",
            "6f8130ac9e4bd25f0871d6b349a5ce20\x01",
        ):
            with self.subTest(case="synthetic invalid credential"):
                result = self.evaluate(value)
                self.assertNotEqual(0, result.returncode)
                self.assertEqual("", result.stdout + result.stderr)

    def test_repository_development_example_can_never_be_mistaken_for_a_real_secret(self):
        template = (ROOT / "server/.env.example").read_text(encoding="utf-8")
        values = dict(line.split("=", 1) for line in template.splitlines()
                      if line and not line.startswith("#") and "=" in line)
        for key in ("UTEN_JWT_SECRET", "UTEN_PGP_MASTER_KEY", "UTEN_HMAC_KEY"):
            result = self.evaluate(values[key])
            self.assertNotEqual(0, result.returncode, key)
            self.assertEqual("", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()

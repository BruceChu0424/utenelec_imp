from __future__ import annotations

import contextlib
import importlib.util
import io
import tempfile
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).with_name("validate_oss_pull_env.py")
SPEC = importlib.util.spec_from_file_location("validate_oss_pull_env", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
VALIDATOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VALIDATOR)


VALID_ENV = """\
OSS_ACCESS_KEY_ID=fixture_invalid_access_key_id
OSS_ACCESS_KEY_SECRET=standardSecretValue1234567890
OSS_BUCKET=uten-release-private
OSS_ENDPOINT=https://oss-cn-hangzhou.aliyuncs.com
OSS_SECURITY_TOKEN=temporaryTokenValue1234567890
"""


class OssPullEnvironmentParserTest(unittest.TestCase):
    def parse(self, content: str) -> dict[str, str]:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "oss-pull.env"
            path.write_text(content, encoding="ascii", newline="\n")
            return VALIDATOR.parse(path)

    def assert_rejected(self, content: str) -> None:
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            self.parse(content)

    def test_standard_https_environment_is_accepted(self) -> None:
        values = self.parse(VALID_ENV)
        VALIDATOR.validate_endpoint(values["OSS_ENDPOINT"])
        self.assertIn("t", values["OSS_ENDPOINT"])

    def test_leading_whitespace_override_is_rejected(self) -> None:
        self.assert_rejected(VALID_ENV + " OSS_BUCKET=other-bucket\n")

    def test_duplicate_key_is_rejected(self) -> None:
        self.assert_rejected(VALID_ENV + "OSS_BUCKET=other-bucket\n")

    def test_placeholder_is_rejected(self) -> None:
        self.assert_rejected(VALID_ENV.replace("standardSecretValue1234567890", "REPLACE_ME_NOW_123456"))

    def test_quoted_or_backslash_value_is_rejected(self) -> None:
        self.assert_rejected(VALID_ENV.replace("uten-release-private", "'uten-release-private'"))
        self.assert_rejected(VALID_ENV.replace("uten-release-private", "uten\\release-private"))


if __name__ == "__main__":
    unittest.main()

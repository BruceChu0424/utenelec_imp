import pathlib
import tempfile
import unittest

from prepare_hr_keys import CryptoConfigurationError, read_crypto, render


class PrepareHrKeysTest(unittest.TestCase):
    def load(self, content, environment=None):
        with tempfile.TemporaryDirectory() as directory:
            source = pathlib.Path(directory) / "crypto.env"
            source.write_bytes(content.encode("utf-8"))
            return read_crypto(source, environment or {})

    def test_raw_backslash_quote_utf8_and_crlf_are_not_interpreted(self):
        key = "SYNTHETIC-原值\\n\\t'quote'\\end"
        values = self.load(f"UTEN_PGP_MASTER_KEY={key}\r\nUTEN_HMAC_KEY=hmac\\n原值\r\n")
        self.assertEqual(key, values["UTEN_PGP_MASTER_KEY"])
        self.assertEqual("hmac\\n原值", values["UTEN_HMAC_KEY"])
        self.assertEqual("1", values["UTEN_PGP_KEY_VERSION"])

    def test_dotenv_double_quotes_and_comments_match_application_parser(self):
        values = self.load('UTEN_PGP_MASTER_KEY="quoted\\n#value" # comment\nUTEN_HMAC_KEY=literal # comment\n')
        self.assertEqual("quoted\\n#value", values["UTEN_PGP_MASTER_KEY"])
        self.assertEqual("literal", values["UTEN_HMAC_KEY"])

    def test_dotenv_java_single_quote_value_remains_literal(self):
        values = self.load("UTEN_PGP_MASTER_KEY='literal'\nUTEN_HMAC_KEY=hmac\n")
        self.assertEqual("'literal'", values["UTEN_PGP_MASTER_KEY"])

    def test_environment_overrides_file_without_trimming_or_escape_expansion(self):
        key = " ENV\n原值\\n\t'quoted' "
        values = self.load("UTEN_PGP_MASTER_KEY=file\nUTEN_HMAC_KEY=file\n",
                           {"UTEN_PGP_MASTER_KEY": key, "UTEN_HMAC_KEY": "env"})
        self.assertEqual(key, values["UTEN_PGP_MASTER_KEY"])

    def test_environment_only_is_supported(self):
        values = read_crypto(pathlib.Path("nonexistent-synthetic.env"),
                             {"UTEN_PGP_MASTER_KEY": "key", "UTEN_HMAC_KEY": "hmac"})
        self.assertEqual("1", values["UTEN_PGP_KEY_VERSION"])

    def test_duplicates_and_invalid_version_fail_without_the_value(self):
        for content in ("UTEN_PGP_MASTER_KEY=PRIVATE_CANARY\nUTEN_PGP_MASTER_KEY=other\nUTEN_HMAC_KEY=hmac\n",
                        "UTEN_PGP_MASTER_KEY=key\nUTEN_HMAC_KEY=hmac\nUTEN_PGP_KEY_VERSION=PRIVATE_CANARY:bad\n"):
            with self.assertRaises(CryptoConfigurationError) as raised:
                self.load(content)
            self.assertNotIn("PRIVATE_CANARY", str(raised.exception))

    def test_initializer_uses_one_nonprinting_query_and_explicit_literals(self):
        script = render({"UTEN_PGP_MASTER_KEY": "literal\\n'quote'\n真实",
                         "UTEN_PGP_KEY_VERSION": "1", "UTEN_HMAC_KEY": "hmac"}).decode("utf-8")
        self.assertTrue(script.startswith("SELECT E'"))
        self.assertTrue(script.endswith("\n\\gset\n"))
        self.assertNotIn(";", script)
        self.assertNotIn("\\set ", script)
        self.assertIn("literal\\\\n''quote''\\n真实", script)


if __name__ == "__main__":
    unittest.main()

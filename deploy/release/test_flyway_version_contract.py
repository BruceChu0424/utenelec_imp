"""Cross-tool version vectors, separate from every permission/signature gate."""

import importlib.util
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "uten_flyway_version_contract", ROOT / "deploy/contracts/flyway_version_contract.py"
)
CONTRACT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CONTRACT)
FIXTURES = json.loads((ROOT / "contracts/flyway-version/fixtures.json").read_text(encoding="utf-8"))


class FlywayVersionContractTest(unittest.TestCase):
    def test_numeric_component_order_is_not_decimal_lexical_or_installed_rank_order(self):
        ordered = FIXTURES["canonicalOrder"]
        self.assertEqual(ordered, sorted(reversed(ordered), key=CONTRACT._flyway_version_key))
        self.assertLess(CONTRACT._flyway_version_key("999.2"), CONTRACT._flyway_version_key("999.11"))
        self.assertLess(CONTRACT._flyway_version_key("999.11"), CONTRACT._flyway_version_key("1000"))

    def test_comparison_aliases_match_flyway_but_are_not_canonical_wire_identities(self):
        for alias, canonical in FIXTURES["semanticAliases"]:
            with self.subTest(alias=alias):
                self.assertEqual(CONTRACT._flyway_semantic_key(alias), CONTRACT._flyway_version_key(canonical))
                with self.assertRaises(ValueError):
                    CONTRACT._flyway_version_key(alias)

    def test_noncanonical_and_forged_versions_fail_closed(self):
        for value in FIXTURES["invalidCanonical"]:
            with self.subTest(value=value):
                with self.assertRaises(ValueError):
                    CONTRACT._flyway_version_key(value)
        with self.assertRaises(ValueError):
            CONTRACT._flyway_version_key("9" * 51)

    def test_script_version_and_description_are_derived_from_the_exact_basename(self):
        for item in FIXTURES["scripts"]:
            with self.subTest(file=item["file"]):
                key, raw, display = CONTRACT._flyway_script_parts(item["file"])
                self.assertEqual(CONTRACT._flyway_version_key(item["version"]), key)
                self.assertEqual(item["rawDescription"], raw)
                self.assertEqual(item["flywayDescription"], display)
        for name in FIXTURES["invalidScripts"]:
            with self.subTest(file=name):
                with self.assertRaises(ValueError):
                    CONTRACT._flyway_script_parts(name)

    def test_integer_receipts_keep_their_exact_type_and_dotted_heads_never_become_float(self):
        self.assertEqual(1000, CONTRACT._flyway_head_identity("1000"))
        self.assertIs(type(CONTRACT._flyway_head_identity("1000")), int)
        self.assertEqual("999.10", CONTRACT._flyway_head_identity("999.10"))
        self.assertEqual((999, 10), CONTRACT._flyway_head_key("999.10"))
        self.assertEqual((1000,), CONTRACT._flyway_head_key(1000))
        for value in (True, False, 0, -1, 999.1, "1000", "999.01", "999_1", None):
            with self.subTest(head=value):
                with self.assertRaises(ValueError):
                    CONTRACT._flyway_head_key(value)

    def test_only_the_nine_exact_published_scripts_accept_their_original_history_spelling(self):
        self.assertEqual(9,len(FIXTURES["legacyHistory"]))
        self.assertEqual({item["file"] for item in FIXTURES["legacyHistory"]},set(CONTRACT._FLYWAY_LEGACY_INTEGER_SCRIPTS))
        for item in FIXTURES["legacyHistory"]:
            with self.subTest(script=item["file"]):
                expected=CONTRACT._flyway_version_key(item["canonical"])
                self.assertEqual(expected,CONTRACT._flyway_history_version_key(item["raw"],item["file"]))
                self.assertEqual(expected,CONTRACT._flyway_history_version_key(item["canonical"],item["file"]))
                self.assertEqual(item["canonical"],CONTRACT._flyway_wire_version(item["raw"],item["file"]))
                with self.assertRaises(ValueError): CONTRACT._flyway_version_key(item["raw"])
                with self.assertRaises(ValueError): CONTRACT._flyway_history_version_key("0"+item["raw"],item["file"])
        for raw,script in (("01","V01__forged.sql"),("01","V02__departments_positions.sql"),("001","V01__enable_pgcrypto.sql"),("999_1","V999_1__first_decimal.sql")):
            with self.subTest(raw=raw,script=script),self.assertRaises(ValueError): CONTRACT._flyway_history_version_key(raw,script)


if __name__ == "__main__":
    unittest.main()

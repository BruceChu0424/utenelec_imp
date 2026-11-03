import contextlib
import io
import tempfile
import unittest
from unittest.mock import patch

import import_product_lists
from legacy_goods_authority import is_missing_legacy_value, prefer_legacy_value


class LegacyGoodsAuthorityTest(unittest.TestCase):
    def test_zero_and_false_are_existing_facts_and_only_reference_zero_is_unset(self):
        for value in (0, "0", "0.0000", False, "禁用", "0.9141234567890123456789"):
            with self.subTest(value=value):
                self.assertFalse(is_missing_legacy_value(value))
                self.assertEqual(prefer_legacy_value(value, "Excel"), value)
        self.assertTrue(is_missing_legacy_value("0", reference=True))
        self.assertEqual(prefer_legacy_value("0", "92", reference=True), "92")

    def test_null_and_whitespace_allow_supplement_without_formatting(self):
        for value in (None, "", " \t\n"):
            with self.subTest(value=value):
                self.assertTrue(is_missing_legacy_value(value))
                self.assertEqual(prefer_legacy_value(value, "0.9141234567890123456789"),
                                 "0.9141234567890123456789")

    def test_retired_overwrite_switches_fail_before_loading_sources_or_connecting(self):
        with tempfile.TemporaryDirectory() as directory:
            for switch in ("--recategorize", "--overwrite-warehouse"):
                with self.subTest(switch=switch), patch("sys.argv", ["import_product_lists.py", "--data-dir", directory, switch]), \
                        patch.object(import_product_lists, "load_rows") as load, contextlib.redirect_stderr(io.StringIO()):
                    with self.assertRaises(SystemExit) as failure:
                        import_product_lists.main()
                    self.assertEqual(failure.exception.code, 2)
                    load.assert_not_called()


if __name__ == "__main__":
    unittest.main()

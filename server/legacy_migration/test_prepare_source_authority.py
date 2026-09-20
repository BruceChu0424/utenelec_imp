"""Pure source-contract tests; no database, external source data or model downloads."""
import copy
import importlib.util
import json
import pathlib
import runpy
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch

HERE = pathlib.Path(__file__).resolve().parent
RESOURCES = HERE.parent / "src/test/resources/legacy-bootstrap-fixture"
SPEC = importlib.util.spec_from_file_location("source_authority", HERE / "prepare_source_authority.py")
authority = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(authority)


class SourceAuthorityTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="uten-source-authority-")
        self.root = pathlib.Path(self.directory.name)
        target = self.root / "server/legacy_migration"
        target.mkdir(parents=True)
        for path in [*HERE.glob("migrate_*.sql"), HERE / "export_legacy.ps1"]:
            shutil.copyfile(path, target / path.name)
        self.rows = json.loads((RESOURCES / "rows.json").read_text(encoding="utf-8"))
        for name in ["historical-references.json", "orphan-bom.json"]:
            delta = json.loads((RESOURCES / "variants" / name).read_text(encoding="utf-8"))
            for source, rows in delta.items():
                self.rows.setdefault(source, []).extend(rows)

    def tearDown(self):
        # Only this test's independently created disposable directory is removed.
        resolved = self.root.resolve()
        self.assertEqual(resolved.parent, pathlib.Path(tempfile.gettempdir()).resolve())
        self.assertTrue(resolved.name.startswith("uten-source-authority-"))
        self.directory.cleanup()

    def generate(self):
        fixture = self.root / "rows.json"
        fixture.write_text(json.dumps(self.rows), encoding="utf-8")
        # Git is unrelated to the source parser; the real coordinator separately
        # verifies an actual committed candidate. All CSV shapes come from SQL.
        with patch.object(sys, "argv", ["generate_fixture.py", str(self.root), str(fixture)]), \
                patch("subprocess.check_output", return_value="0" * 40):
            runpy.run_path(str(RESOURCES / "generate_fixture.py"), run_name="__main__")
        return self.root / "server/legacy_migration/data/export_manifest.json"

    def test_real_loader_shapes_preserve_six_exact_missing_master_references(self):
        masters, references = authority.collect(self.generate())
        source_keys = {(row[0], row[1]) for row in masters}
        self.assertIn(("goods", 900101), source_keys)
        self.assertNotIn(("goods", 910101), source_keys)
        facts = {(row[0], row[1]): row[2:] for row in references}
        self.assertEqual(set(facts), {("goods", 910101), ("units", 910301), ("colors", 910401),
                                      ("warehouses", 910201), ("clients", 910501), ("suppliers", 910601)})
        self.assertEqual(facts[("goods", 910101)],
                         ("stock_goods.csv", '{"color_legacy":"910401","goods_legacy":"910101","stock_legacy":"910201","year":"2025"}',
                          "goods_legacy", 4, 2))
        self.assertEqual(facts[("clients", 910501)],
                         ("m_in.csv", "906101", "client_legacy_id", 2, 1))
        self.assertEqual(facts[("suppliers", 910601)],
                         ("m_out.csv", "906102", "supplier_legacy_id", 3, 1))
        self.assertEqual(facts[("warehouses", 910201)][-1], 2)
        # Missing and historical-only BOM endpoints cannot authorize extra masters.
        self.assertFalse(any(row[1] in (919998, 919999) for row in references))

    def test_old_or_missing_snapshot_authority_is_rejected(self):
        path = self.generate()
        original = json.loads(path.read_text(encoding="utf-8"))
        for mutation in (dict(original, formatVersion=3),
                         {key: value for key, value in original.items() if key != "sourceSnapshotAsOfUtc"},
                         dict(original, sourceSnapshotAsOfUtc="2025-02-31T00:00:00Z")):
            with self.subTest(manifest=mutation.get("sourceSnapshotAsOfUtc")):
                path.write_text(json.dumps(mutation), encoding="utf-8")
                with self.assertRaises(ValueError):
                    authority.collect(path)

    def test_source_bytes_cannot_change_after_the_manifest_is_reviewed(self):
        manifest = self.generate()
        with (manifest.parent / "stock_other_in_i.csv").open("a", encoding="utf-8") as file:
            file.write("tampered\n")
        with self.assertRaisesRegex(ValueError, "differs from the reviewed manifest"):
            authority.collect(manifest)

    def test_duplicate_master_identity_is_rejected_even_with_matching_manifest_count(self):
        self.rows["goods.csv"].append(copy.deepcopy(self.rows["goods.csv"][0]))
        with self.assertRaisesRegex(ValueError, "duplicate source master identity"):
            authority.collect(self.generate())

    def test_fractional_reference_cannot_be_rounded_into_a_different_identity(self):
        self.rows["stock_other_in_i.csv"][-1]["goods_legacy_id"] = "910101.5"
        with self.assertRaisesRegex(ValueError, "not an exact integer"):
            authority.collect(self.generate())

    def test_reference_zero_and_blank_remain_absent(self):
        self.rows["stock_other_in_i.csv"][-1]["color_legacy_id"] = 0
        self.rows["stock_other_in_i.csv"][-1]["unit_legacy_id"] = None
        self.rows["stock_goods.csv"][-1]["color_legacy"] = None
        _, references = authority.collect(self.generate())
        identities = {(row[0], row[1]) for row in references}
        self.assertNotIn(("colors", 910401), identities)
        self.assertNotIn(("units", 910301), identities)
        self.assertFalse(any(row[1] == 0 for row in references))

    def test_balance_only_goods_and_color_keep_distinct_provable_identities(self):
        delta = json.loads((RESOURCES / "variants/stock-only.json").read_text(encoding="utf-8"))
        for source, rows in delta.items():
            self.rows.setdefault(source, []).extend(rows)
        masters, references = authority.collect(self.generate())
        facts = {(row[0], row[1]): row[2:] for row in references}
        self.assertNotIn(("goods", 920101), {(row[0], row[1]) for row in masters})
        self.assertEqual(facts[("goods", 920101)][0], "stock_goods.csv")
        self.assertEqual(facts[("goods", 920101)][-1], 2)
        self.assertEqual(facts[("colors", 920401)][-1], 1)
        self.assertNotIn(("colors", 0), facts)

    def test_purchase_missing_masters_need_exact_source_references(self):
        delta = json.loads((RESOURCES / "variants/purchase-missing-masters.json").read_text(encoding="utf-8"))
        for source, rows in delta.items():
            self.rows.setdefault(source, []).extend(rows)
        masters, references = authority.collect(self.generate())
        facts = {(row[0], row[1]): row[2:] for row in references}
        self.assertNotIn(("goods", 930101), {(row[0], row[1]) for row in masters})
        self.assertNotIn(("suppliers", 930601), {(row[0], row[1]) for row in masters})
        self.assertEqual(facts[("goods", 930101)][0], "purchase_order_items.csv")
        self.assertEqual(facts[("goods", 930101)][-1], 2)
        self.assertEqual(facts[("suppliers", 930601)][0], "purchase_orders.csv")
        self.assertEqual(facts[("suppliers", 930601)][-1], 2)


if __name__ == "__main__":
    unittest.main()

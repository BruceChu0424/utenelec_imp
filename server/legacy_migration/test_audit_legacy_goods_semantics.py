import json
from pathlib import Path
import tempfile
import unittest

from audit_legacy_goods_semantics import SEMANTIC_FIELDS, SQL, audit, location, mould_codes, read_csv, rear_codes, write_csv


class GoodsSemanticRulesTest(unittest.TestCase):
    def test_explicit_rear_insert_is_extracted(self):
        self.assertEqual({"45A"},rear_codes("换后模45A镶件"))
        self.assertEqual({"V7-012"},rear_codes("换前模芯V7-012  后模镶件用V7-012"))

    def test_front_core_and_unlabelled_insert_are_never_rear(self):
        for note in ["换前模镶件","换6M镶件","前模芯MA-62-B 模具MA-62","后模借用MA-62","换后模"]:
            with self.subTest(note=note):
                self.assertEqual(set(),rear_codes(note))

    def test_multiple_distinct_rear_inserts_remain_ambiguous(self):
        self.assertEqual({"45A","平"},rear_codes("换后模45A镶件；换后模平镶件"))

    def test_labelled_mould_code_does_not_pick_front_core_or_fee(self):
        self.assertEqual({"A8-01"},mould_codes("模具A8-01 模芯A8-01-C"))
        self.assertEqual(set(),mould_codes("退模具费8000元"))
        self.assertEqual(set(),mould_codes("金本模具"))

    def test_code_before_mould_label_is_evidence_without_fuzzy_padding(self):
        self.assertEqual({"Q5-06"},mould_codes("Q5-06模具 换前模芯 编号Q5-019A"))

    def test_explicit_mould_code_rack_enriches_place(self):
        self.assertEqual(("A2-14","注塑车间 / A2-14"),location("A8-01【A2-14】","注塑车间"))
        self.assertEqual(("A2-14","A2-14"),location("A8-01【A2-14】",""))

    def test_non_location_suffix_is_not_a_rack(self):
        self.assertIsNone(location("A8-01【封存】","注塑车间"))
        self.assertIsNone(location("A8-01【A2-14】其他说明","注塑车间"))

    def test_existing_rack_is_idempotent_without_substring_confusion(self):
        self.assertEqual(("A2-14","注塑车间 / A2-14"),location("A8-01【A2-14】","注塑车间 / A2-14"))
        self.assertEqual(("A2-1","A2-14 / A2-1"),location("A8-01【A2-1】","A2-14"))


class GoodsSemanticSourcePriorityTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.raw, self.overlay, self.references, self.output = [self.root/name for name in ("raw", "overlay", "references", "output")]
        for directory in (self.raw, self.overlay, self.references):
            directory.mkdir()
        self.goods = {field: "" for field in SEMANTIC_FIELDS}
        self.goods.update(legacy_id="1", code="280243606", mould_legacy_id="")
        write_csv(self.references/"mould.csv", [{"legacy_id": "10", "place": ""}, {"legacy_id": "20", "place": ""}], ["legacy_id", "place"])
        write_csv(self.references/"original_master_codes.csv", [
            {"domain": "mould", "legacy_id": "10", "original_code": "DB-10", "original_mnumber": ""},
            {"domain": "mould", "legacy_id": "20", "original_code": "XL-20", "original_mnumber": ""},
        ], ["domain", "legacy_id", "original_code", "original_mnumber"])
        for path in (self.raw/"export_manifest.json", self.overlay/"goods_excel_manifest.json", self.references/"reference_masters_manifest.json"):
            path.write_text("{}", encoding="utf-8")

    def run_audit(self, *, legacy_paper="", excel_paper="", legacy_mould="", prepared_paper=None, prepared_mould=None, excel_mould=""):
        raw = dict(self.goods, paper=legacy_paper, mould_legacy_id=legacy_mould)
        prepared = dict(raw, paper=legacy_paper if prepared_paper is None else prepared_paper,
                        mould_legacy_id=legacy_mould if prepared_mould is None else prepared_mould)
        write_csv(self.raw/"goods.csv", [raw], list(raw))
        write_csv(self.overlay/"goods.csv", [prepared], list(prepared))
        write_csv(self.overlay/"goods_excel_identity.csv", [{"excel_code": "280243606", "legacy_id": "1"}], ["excel_code", "legacy_id"])
        record = {"file": "products.xls", "row": 2, "values": {"产品编号": "280243606", "原ERP备注": excel_paper, "模具编号": excel_mould}}
        (self.overlay/"goods_excel_raw.jsonl").write_text(json.dumps(record, ensure_ascii=False)+"\n", encoding="utf-8")
        return audit(self.raw, self.overlay, self.references, self.output)

    def test_conflicting_excel_note_cannot_replace_database_note_or_rear_insert(self):
        summary = self.run_audit(legacy_paper="后模镶件用DB-10", excel_paper="后模镶件用XL-20")
        note, = read_csv(self.output/"goods_note_semantics.csv")
        self.assertEqual("后模镶件用DB-10", note["latest_paper"])
        self.assertEqual("DB-10", note["proposed_rear"])
        self.assertEqual("goods.csv", note["source_file"])
        self.assertEqual(1, summary["changes"]["retained_database_note_conflicts"])
        self.assertEqual(0, summary["rear_insert_explicit_excel_count"])
        ledger = read_csv(self.output/"goods_semantic_decisions.csv")
        self.assertTrue(any(row["candidate_value"] == "XL-20" and row["resolution"] == "SUPPLEMENTARY_EVIDENCE_KEEP_DATABASE_PRIORITY" for row in ledger))

    def test_excel_note_fills_only_blank_database_note_and_supplies_rear(self):
        summary = self.run_audit(legacy_paper=" \t", excel_paper="后模镶件用XL-20")
        note, = read_csv(self.output/"goods_note_semantics.csv")
        self.assertEqual("后模镶件用XL-20", note["latest_paper"])
        self.assertEqual("XL-20", note["proposed_rear"])
        self.assertEqual("products.xls", note["source_file"])
        self.assertEqual(1, summary["changes"]["supplementary_display_note_fills"])

    def test_database_note_without_rear_never_imports_rear_from_conflicting_excel(self):
        self.run_audit(legacy_paper="原库包装要求", excel_paper="后模镶件用XL-20")
        note, = read_csv(self.output/"goods_note_semantics.csv")
        self.assertEqual("PRESERVE", note["rear_action"])
        self.assertEqual("", note["proposed_rear"])

    def test_existing_database_mould_cannot_be_replaced_from_excel_note(self):
        self.run_audit(legacy_paper="模具DB-10", excel_paper="模具XL-20", legacy_mould="10")
        self.assertEqual([], read_csv(self.output/"goods_mould_semantics.csv"))
        ledger = read_csv(self.output/"goods_semantic_decisions.csv")
        self.assertTrue(any(row["candidate_value"] == "XL-20" and row["resolution"] == "KEEP_EXPLICIT_RELATION_CONFLICT" for row in ledger))

    def test_database_note_can_fill_missing_mould_despite_conflicting_excel_fields(self):
        self.run_audit(legacy_paper="模具DB-10", excel_paper="模具XL-20", excel_mould="unresolved-30")
        update, = read_csv(self.output/"goods_mould_semantics.csv")
        self.assertEqual("10", update["proposed_mould_id"])
        self.assertEqual("0", update["expected_mould_id"])

    def test_unselected_excel_note_cannot_supply_missing_database_mould(self):
        self.run_audit(legacy_paper="原库包装要求", excel_paper="模具XL-20")
        self.assertEqual([], read_csv(self.output/"goods_mould_semantics.csv"))

    def test_prepared_nonempty_database_note_or_valid_mould_drift_is_rejected(self):
        for kwargs in ({"legacy_paper": "原库备注", "prepared_paper": "Excel备注"},
                       {"legacy_mould": "10", "prepared_mould": "20"}):
            with self.subTest(kwargs=kwargs), self.assertRaisesRegex(ValueError, "Legacy database goods"):
                self.run_audit(**kwargs)

    def test_sql_only_supplements_empty_notes_and_moulds(self):
        self.assertIn("NULLIF(btrim(g.paper),'') IS NULL", SQL)
        self.assertIn("COALESCE(s.expected_mould_id,0)<>0", SQL)
        self.assertIn("s.expected_paper IS DISTINCT FROM s.latest_paper", SQL)


if __name__ == "__main__":
    unittest.main()

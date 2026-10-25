import csv
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import prepare_goods_excel as subject


class GoodsExcelPreparationTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.source, self.dictionary, self.output = [self.root / name for name in ("source", "dictionary", "output")]
        self.source.mkdir()
        self.dictionary.mkdir()
        self.headers = list(subject.ALIASES)
        old = dict.fromkeys(self.headers, "")
        old.update(legacy_id="17", code="KEEP001", name="旧名称", series="旧系列", material="原材料",
                   parent_legacy="10", unit_legacy_id="92", m_weight="3.5", status="禁用", require_remark="旧备注")
        subject.write_csv(self.source / "goods.csv", self.headers, [old])
        subject.write_csv(self.source / "goods_categories.csv", ["legacy_id", "parent_legacy", "code", "name"],
                          [{"legacy_id": "10", "parent_legacy": "0", "code": "A", "name": "原材料"},
                           {"legacy_id": "11", "parent_legacy": "10", "code": "SJ", "name": "塑胶件"}])
        for filename, rows in [("unit.csv", [{"legacy_id": "92", "code": "DW000001", "name": "个"},
                                             {"legacy_id": "108", "code": "DW000002", "name": "kg"}]),
                               ("color.csv", [{"legacy_id": "345", "code": "YS000001", "name": "白色"}])]:
            subject.write_csv(self.dictionary / filename, ["legacy_id", "code", "name"], rows)
        self.crosswalk = self.dictionary / "warehouse_crosswalk.csv"
        subject.write_csv(self.crosswalk, ["action", "target_defective", "target_name", "target_code"],
                          [{"action": "TARGET", "target_defective": "false", "target_name": "塑胶仓库", "target_code": "WH000004"}])

    def rec(self, code="KEEP001", **values):
        fields = {"产品编号": code, "产品名称": "新名称", "产品角色": "自制件", "基本单位": "个", "颜色": "白色",
                  "产品分类": "86开关插座->原材料->塑胶件", "所属仓库": "塑胶仓库", "启用状态": "启用", "单位": "个", "比例": "1"}
        fields.update(values)
        return {"file": "products.xls", "sheet": "产品列表", "row": 2, "parent_code": code, "values": fields}

    def run_prepare(self, records):
        workbooks = [{"file": "products.xls", "sha256": "0" * 64, "sheets": [{"columns": list(records[0]["values"])}]}]
        with patch.object(subject, "load_excel", return_value=(records, workbooks)):
            return subject.prepare(self.source, self.dictionary, self.root, self.crosswalk, self.output, ["products.xls"])

    def test_latest_nonempty_fields_and_source_overlay_preserve_input_and_blank_fields(self):
        before = subject.digest(self.source / "goods.csv")
        result = self.run_prepare([self.rec(系列="新系列", 材质="", **{"建议售价": "12.30", "默认销售折扣": "0.2"})])
        _, rows = subject.read_csv(self.output / "goods.csv")
        self.assertEqual(subject.digest(self.source / "goods.csv"), before)
        self.assertEqual((rows[0]["legacy_id"], rows[0]["code"], rows[0]["series"], rows[0]["material"]),
                         ("17", "KEEP001", "新系列", "原材料"))
        self.assertEqual(rows[0]["name"], "新名称")
        self.assertEqual(rows[0]["price"], "12.30")
        self.assertEqual(rows[0]["status"], "使用")
        _, attrs = subject.read_csv(self.output / "goods_excel_attributes.csv")
        self.assertEqual(attrs[0]["source_type"], "自制")
        self.assertEqual(result["statistics"]["matched_goods"], 1)
        self.assertEqual(len(result["sourceInputs"]), 5)

    def test_same_name_new_code_is_distinct_goods_with_stable_negative_identity(self):
        self.run_prepare([self.rec("NEW001", 产品名称="旧名称", 基本单位="千克", 单位="千克")])
        _, rows = subject.read_csv(self.output / "goods.csv")
        self.assertEqual(len(rows), 2)
        added = rows[-1]
        self.assertLess(int(added["legacy_id"]), -1_000_000_000)
        self.assertEqual(added["code"], "NEW001")
        self.assertEqual(added["unit_legacy_id"], "108")
        self.assertEqual(added["parent_legacy"], "11")
        ids = subject.stable_new_ids(["NEW002", "NEW001"], {17})
        self.assertEqual(added["legacy_id"], str(ids["NEW001"]))
        _, review = subject.read_csv(self.output / "goods_source_engineering_review.csv")
        self.assertEqual(review[0]["legacy_id"], "17")
        self.assertEqual(review[0]["source_type"], "")
        self.assertEqual(review[0]["resolution"], "NO_EXCEL_SOURCE_ENGINEERING_REVIEW")

    def test_invalid_weight_is_reported_and_does_not_erase_legacy_weight(self):
        self.run_prepare([self.rec(**{"单重（克）": "F812-40"})])
        _, rows = subject.read_csv(self.output / "goods.csv")
        self.assertEqual(rows[0]["m_weight"], "3.5")
        _, issues = subject.read_csv(self.output / "goods_excel_issues.csv")
        self.assertTrue(any(row["field"] == "单重（克）" and row["value"] == "F812-40" for row in issues))

    def test_price_strategy_continuation_is_archived_without_creating_a_goods(self):
        main = self.rec()
        child = self.rec("", 产品名称="【价格策略】", **{"建议售价": "20", "单位": "kg"})
        child["parent_code"] = "KEEP001"
        result = self.run_prepare([main, child])
        _, rows = subject.read_csv(self.output / "goods.csv")
        self.assertEqual(len(rows), 1)
        self.assertEqual(result["statistics"]["price_strategy_rows_archived"], 1)
        archive = [json.loads(line) for line in (self.output / "goods_excel_raw.jsonl").read_text(encoding="utf-8").splitlines()]
        self.assertEqual(archive[1]["parent_code"], "KEEP001")

    def test_unknown_no_code_rows_and_duplicate_codes_fail(self):
        with self.assertRaisesRegex(ValueError, "Unidentified no-code"):
            self.run_prepare([self.rec(), self.rec("", 产品名称="未知货品")])
        with self.assertRaisesRegex(ValueError, "Duplicate Excel"):
            self.run_prepare([self.rec(), self.rec()])

    def test_required_unit_or_warehouse_cannot_silently_disappear(self):
        with self.assertRaisesRegex(ValueError, "Required cleaned dictionary reference"):
            self.run_prepare([self.rec(基本单位="吨")])
        with self.assertRaisesRegex(ValueError, "Unmapped Excel owning warehouse"):
            self.run_prepare([self.rec(所属仓库="另一个五金仓库")])

    def test_unit_change_keeps_historical_quantity_base_and_per_unit_commercial_values(self):
        _, old = subject.read_csv(self.source / "goods.csv")
        old[0].update(price="9.00", m_weight="3.5")
        subject.write_csv(self.source / "goods.csv", self.headers, old)
        subject.write_csv(self.source / "stock_goods.csv", ["stock_legacy", "goods_legacy", "color_legacy", "year", "qty", "fact_qty", "total"],
                          [dict(stock_legacy="132", goods_legacy="17", color_legacy="0", year="2026", qty="7", fact_qty="7", total="63")])
        self.run_prepare([self.rec(基本单位="千克", 单位="千克", **{"建议售价": "2", "单重（克）": "1000", "最小采购量": "25", "最小包装量": "25"})])
        _, rows = subject.read_csv(self.output / "goods.csv")
        self.assertEqual((rows[0]["unit_legacy_id"], rows[0]["price"], rows[0]["m_weight"]), ("92", "9.00", "3.5"))
        self.assertIn("基本单位待核对", rows[0]["require_remark"])
        _, attrs = subject.read_csv(self.output / "goods_excel_attributes.csv")
        self.assertEqual((attrs[0]["min_order"], attrs[0]["order_multiple"]), ("", ""))
        self.assertEqual(attrs[0]["source_type"], "自制")
        _, review = subject.read_csv(self.output / "goods_quantity_unit_review.csv")
        self.assertEqual((review[0]["legacy_unit"], review[0]["proposed_excel_unit"], review[0]["main_stock_keys"]), ("个", "kg", "1"))
        self.assertEqual(review[0]["numeric_facts_changed"], "0")
        _, stocks = subject.read_csv(self.source / "stock_goods.csv")
        self.assertEqual(stocks[0]["fact_qty"], "7")

    def test_explicit_package_factor_is_evidence_without_implicit_history_conversion(self):
        _, units = subject.read_csv(self.dictionary / "unit.csv")
        units.append({"legacy_id": "287", "code": "DW000003", "name": "包"})
        subject.write_csv(self.dictionary / "unit.csv", ["legacy_id", "code", "name"], units)
        _, old = subject.read_csv(self.source / "goods.csv")
        old[0].update(unit_legacy_id="287", price="50")
        subject.write_csv(self.source / "goods.csv", self.headers, old)
        subject.write_csv(self.source / "purchase_order_items.csv", ["legacy_id", "goods_legacy_id", "unit_legacy_id", "unit_rate", "qty", "price", "amount_original"],
                          [dict(legacy_id="91", goods_legacy_id="17", unit_legacy_id="108", unit_rate="0.04", qty="50", price="2", amount_original="100")])
        main = self.rec(基本单位="千克", 单位="千克", **{"建议售价": "2"})
        child = self.rec("", 产品名称="【价格策略】", 单位="包", 比例="25")
        child["parent_code"] = "KEEP001"
        self.run_prepare([main, child])
        _, rows = subject.read_csv(self.output / "goods.csv")
        self.assertEqual((rows[0]["unit_legacy_id"], rows[0]["price"]), ("287", "50"))
        _, review = subject.read_csv(self.output / "goods_quantity_unit_review.csv")
        self.assertEqual(review[0]["excel_units_per_legacy_unit_proposal"], "25")
        self.assertEqual(review[0]["reason"], "EXPLICIT_EXCEL_FACTOR_WITHOUT_CLOSED_HISTORICAL_RECONCILIATION")
        _, history = subject.read_csv(self.output / "goods_quantity_unit_history_evidence.csv")
        self.assertEqual((history[0]["unit_name"], history[0]["unit_rate_snapshot"]), ("kg", "0.04"))

    def test_explicit_reference_alias_resolves_without_renaming_master_and_rejects_unknown_target(self):
        subject.write_csv(self.dictionary / "supplier.csv", ["legacy_id", "code", "name"],
                          [{"legacy_id": "73", "code": "GY000001", "name": "旧供应简称"}])
        mapping = {"domain": "supplier", "source_value": "最新供应商称呼", "target_legacy_id": "73", "resolution": "exact_description", "evidence": "reviewed"}
        path = self.dictionary / "excel_reference_mapping.csv"
        subject.write_csv(path, list(mapping), [mapping])
        self.run_prepare([self.rec(产品角色="外购件", 主采购供应商="最新供应商称呼")])
        _, rows = subject.read_csv(self.output / "goods.csv")
        self.assertEqual(rows[0]["vend_legacy_id"], "73")
        self.assertEqual(subject.read_csv(self.dictionary / "supplier.csv")[1][0]["name"], "旧供应简称")
        mapping["target_legacy_id"] = "99"
        subject.write_csv(path, list(mapping), [mapping])
        with self.assertRaisesRegex(ValueError, "alias target does not exist"):
            self.run_prepare([self.rec(产品角色="外购件", 主采购供应商="最新供应商称呼")])

    def test_reviewed_mould_alias_never_resolves_a_reassigned_display_code(self):
        subject.write_csv(self.dictionary / "mould.csv", ["legacy_id", "code", "name", "mnumber"],
                          [{"legacy_id": "31", "code": "MJ000001", "name": "第一模具", "mnumber": "ORIGINAL-A"},
                           {"legacy_id": "32", "code": "MJ000002", "name": "第二模具", "mnumber": "ORIGINAL-B"}])
        mapping = {"domain": "mould", "source_value": "MJ000001", "target_legacy_id": "32", "resolution": "reviewed_original_code", "evidence": "reviewed"}
        path = self.dictionary / "excel_reference_mapping.csv"
        subject.write_csv(path, list(mapping), [mapping])
        self.run_prepare([self.rec(模具编号="MJ000001")])
        _, rows = subject.read_csv(self.output / "goods.csv")
        self.assertEqual(rows[0]["mould_legacy_id"], "32")
        mapping["source_value"] = "ORIGINAL-A"
        subject.write_csv(path, list(mapping), [mapping])
        with self.assertRaisesRegex(ValueError, "alias conflicts with an exact master key"):
            self.run_prepare([self.rec(模具编号="ORIGINAL-A")])

    def test_default_supplier_follows_route_without_using_other_route_as_secondary(self):
        subject.write_csv(self.dictionary / "supplier.csv", ["legacy_id", "code", "name"],
                          [{"legacy_id": "70", "code": "GY000070", "name": "原默认商"},
                           {"legacy_id": "71", "code": "GY000071", "name": "原第二商"},
                           {"legacy_id": "73", "code": "GY000001", "name": "采购商"},
                           {"legacy_id": "74", "code": "GY000002", "name": "委外商"},
                           {"legacy_id": "75", "code": "GY000003", "name": "通用商"}])
        _, old = subject.read_csv(self.source / "goods.csv")
        old[0].update(vend_legacy_id="70", vend2_legacy_id="71")
        subject.write_csv(self.source / "goods.csv", self.headers, old)
        for role, expected in [("委外件", "74"), ("外购件", "73"), ("自制件", "75")]:
            with self.subTest(role=role):
                self.run_prepare([self.rec(产品角色=role, 主采购供应商="采购商", 主委外供应商="委外商", 供应商="通用商")])
                _, rows = subject.read_csv(self.output / "goods.csv")
                self.assertEqual(rows[0]["vend_legacy_id"], expected)
                self.assertEqual(rows[0]["vend2_legacy_id"], "71")
                self.assertIn("主采购供应商", rows[0]["require_remark"])
                self.assertIn("主委外供应商", rows[0]["require_remark"])
        self.run_prepare([self.rec(产品角色="自制件", 主采购供应商="采购商", 主委外供应商="委外商", 供应商="")])
        self.assertEqual(subject.read_csv(self.output / "goods.csv")[1][0]["vend_legacy_id"], "70")


if __name__ == "__main__":
    unittest.main()

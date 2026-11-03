import csv
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import prepare_goods_excel as subject


class GoodsExcelPreparationTest(unittest.TestCase):
    def test_product_name_separates_only_exact_export_decoration(self):
        for source, color, series, expected in [
            ("Hanna一开单带夜光条《白色\\埃及Q120》", "白色", "埃及Q120", "Hanna一开单带夜光条"),
            ("开关（双语标签）《白色\\Q3-K》", "白色", "Q3-K", "开关（双语标签）"),
            ("开关(白色)", "白色", "Q3-K", "开关(白色)"),
            ("产品《安装说明》", "白色", "Q3-K", "产品《安装说明》"),
            ("开关《K11》", "白色", "Q3-K", "开关《K11》"),
            ("开关《白色\\Q3-K》", "黑色", "Q3-K", "开关《白色\\Q3-K》"),
            ("开关《白色/Q3-K》", "白色", "Q3-K", "开关《白色/Q3-K》"),
            ("《白色\\Q3-K》", "白色", "Q3-K", "《白色\\Q3-K》"),
            ("开关《\\》", "", "", "开关《\\》"),
            ("《图案》开关《白色\\Q3-K》", "白色", "Q3-K", "《图案》开关"),
        ]:
            with self.subTest(source=source, color=color, series=series):
                self.assertEqual(subject.excel_product_name(source, color=color, series=series), expected)

    def test_name_decoration_overlay_preserves_legacy_name_and_source_evidence(self):
        source_name = "Hanna一开单带夜光条《白色\\埃及Q120》"
        record = self.rec(产品名称=source_name, 产品型号="K11", 系列="埃及Q120")
        before = subject.digest(self.source / "goods.csv")
        result = self.run_prepare([record])
        self.assertEqual(subject.digest(self.source / "goods.csv"), before)
        self.assertEqual(record["values"]["产品名称"], source_name)
        _, rows = subject.read_csv(self.output / "goods.csv")
        self.assertEqual((rows[0]["legacy_id"], rows[0]["code"], rows[0]["name"], rows[0]["model"], rows[0]["series"], rows[0]["color_legacy_id"]),
                         ("17", "KEEP001", "旧名称", "K11", "旧系列", "345"))
        _, audit = subject.read_csv(self.output / "goods_excel_name_decorations.csv")
        self.assertEqual((audit[0]["source_name"], audit[0]["name"], audit[0]["source_row"]),
                         (source_name, "Hanna一开单带夜光条", "2"))
        self.assertEqual(audit[0]["applied"], "False")
        archived = json.loads((self.output / "goods_excel_raw.jsonl").read_text(encoding="utf-8").splitlines()[0])
        self.assertEqual(archived["values"]["产品名称"], source_name)
        self.assertEqual(result["statistics"]["excel_name_decorations_separated"], 0)
        self.assertEqual(result["namePolicy"], "source-proven-excel-display-decoration-v2")
        self.assertIn("goods_excel_name.py", {r["file"] for r in result["generators"]})
        self.assertIn("goods_excel_name_decorations.csv", {r["file"] for r in result["outputs"]})

    def test_new_excel_identity_uses_same_name_policy_and_preserves_genuine_parentheses(self):
        self.run_prepare([self.rec("NEW001", 产品名称="开关（双语标签）《白色\\Q3-K》", 产品型号="K11", 系列="Q3-K")])
        _, rows = subject.read_csv(self.output / "goods.csv")
        new = next(row for row in rows if row["code"] == "NEW001")
        self.assertEqual((new["name"], new["model"], new["series"]), ("开关（双语标签）", "K11", "Q3-K"))
        self.assertTrue(int(new["legacy_id"]) < 0)

    def test_output_name_policy_does_not_change_existing_warehouse_name_evidence(self):
        name = "开关《白色\\Q3-K》"
        self.update_old(name=name)
        self.run_prepare([self.rec(产品名称=name, 系列="Q3-K", 所属仓库=""),
                          self.rec("NEW001", 产品名称=name, 系列="Q3-K")])
        _, owners = subject.read_csv(self.output / "goods_owning_warehouse.csv")
        self.assertIn({"goods_legacy_id": "17", "warehouse_code": "WH000004"}, owners)
        _, rows = subject.read_csv(self.output / "goods.csv")
        self.assertEqual({r["name"] for r in rows}, {name, "开关"})

    def test_empty_export_tail_requires_exact_legacy_base_and_two_empty_metadata_fields(self):
        self.assertEqual(subject.excel_product_name("开关《\\》", legacy_name="开关"), "开关")
        self.assertEqual(subject.excel_product_name("开关《\\》", legacy_name="另一开关"), "开关《\\》")
        self.assertEqual(subject.excel_product_name("开关《\\》", legacy_name="开关", series="A"), "开关《\\》")
        self.run_prepare([self.rec(产品名称="旧名称《\\》", 颜色="", 系列="")])
        _, rows = subject.read_csv(self.output / "goods.csv")
        self.assertEqual(rows[0]["name"], "旧名称")
        _, audit = subject.read_csv(self.output / "goods_excel_name_decorations.csv")
        self.assertEqual(audit[0]["reason"], "legacy_corroborated_empty_export_decoration")

    def test_stale_color_tail_requires_legacy_base_series_and_real_dictionary_token(self):
        options = dict(legacy_name="旧名称", color_tokens={"白色"}, series="A")
        self.assertEqual(subject.excel_product_name("旧名称《白色\\A》", **options), "旧名称")
        self.assertEqual(subject.excel_product_name("旧名称《未知色\\A》", **options), "旧名称《未知色\\A》")
        self.assertEqual(subject.excel_product_name("旧名称《白色\\B》", **options), "旧名称《白色\\B》")
        self.run_prepare([self.rec(产品名称="旧名称《白色\\A》", 颜色="", 系列="A")])
        _, rows = subject.read_csv(self.output / "goods.csv")
        self.assertEqual((rows[0]["name"], rows[0]["series"]), ("旧名称", "旧系列"))
        _, audit = subject.read_csv(self.output / "goods_excel_name_decorations.csv")
        self.assertEqual(audit[0]["reason"], "legacy_and_color_dictionary_corroborated_export_decoration")

    def reviewed_name_fixture(self):
        raw = "旧名称《未知色\\A》"
        decision = dict(action="SEPARATE_REVIEWED_EXCEL_DISPLAY_SUFFIX", review_id="fixture-review",
                        code="KEEP001", legacy_id="17", legacy_name="旧名称", new_name="旧名称", source_name=raw,
                        color="白色", series="A", source_file="products.xls", source_sheet="产品列表", source_row=2,
                        workbook_sha256="0" * 64, company_goods_id="verified-company-uuid")
        path = self.root / "reviewed-names.json"
        return raw, decision, path

    def test_optional_reviewed_source_decision_is_exact_bound_and_retained_in_output(self):
        raw, decision, path = self.reviewed_name_fixture()
        record = self.rec(产品名称=raw, 系列="A", 产品型号="K11")
        self.run_prepare([record])
        self.assertEqual(subject.read_csv(self.output / "goods.csv")[1][0]["name"], "旧名称")
        path.write_text(json.dumps({"kind": "reviewed-excel-goods-name-decisions-v1", "decisions": [decision]}, ensure_ascii=False), encoding="utf-8")
        result = self.run_prepare([record], name_review_decisions=path)
        _, rows = subject.read_csv(self.output / "goods.csv")
        self.assertEqual((rows[0]["name"], rows[0]["model"], rows[0]["series"], rows[0]["color_legacy_id"]),
                         ("旧名称", "K11", "旧系列", "345"))
        self.assertEqual((self.output / "goods_name_review_decisions.json").read_bytes(), path.read_bytes())
        self.assertEqual(result["reviewedNameDecisions"]["sha256"], subject.digest(path))
        _, audit = subject.read_csv(self.output / "goods_excel_name_decorations.csv")
        self.assertEqual(audit[0]["reason"], "reviewed_source_name_decision:fixture-review")
        self.assertEqual(audit[0]["applied"], "False")
        self.assertEqual(json.loads((self.output / "goods_excel_raw.jsonl").read_text(encoding="utf-8"))["values"]["产品名称"], raw)

    def test_reviewed_source_decision_rejects_workbook_or_identity_drift(self):
        for field, value, error in [("workbook_sha256", "1" * 64, "workbook SHA mismatch"),
                                    ("legacy_id", "99", "source facts changed"),
                                    ("source_name", "另一名称", "source facts changed")]:
            with self.subTest(field=field):
                raw, decision, path = self.reviewed_name_fixture()
                decision[field] = value
                path.write_text(json.dumps({"kind": "reviewed-excel-goods-name-decisions-v1", "decisions": [decision]}), encoding="utf-8")
                with self.assertRaisesRegex(ValueError, error):
                    self.run_prepare([self.rec(产品名称=raw, 系列="A")], name_review_decisions=path)

    def test_reviewed_company_decision_requires_the_selected_uuid_when_given(self):
        raw, decision, _ = self.reviewed_name_fixture()
        arguments = dict(code="KEEP001", legacy_id="17", legacy_name="旧名称", name=raw, color="白色", series="A",
                         source_file="products.xls", source_sheet="产品列表", source_row=2)
        self.assertEqual(subject.reviewed_excel_product_name(decision, **arguments,
                         company_goods_id="verified-company-uuid")[0], "旧名称")
        with self.assertRaisesRegex(ValueError, "source facts changed"):
            subject.reviewed_excel_product_name(decision, **arguments, company_goods_id="other-uuid")

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

    def run_prepare(self, records, *, name_review_decisions=None):
        workbooks = [{"file": "products.xls", "sha256": "0" * 64, "sheets": [{"columns": list(records[0]["values"])}]}]
        with patch.object(subject, "load_excel", return_value=(records, workbooks)):
            return subject.prepare(self.source, self.dictionary, self.root, self.crosswalk, self.output, ["products.xls"],
                                   name_review_decisions=name_review_decisions)

    def update_old(self, **values):
        fields, rows = subject.read_csv(self.source / "goods.csv")
        rows[0].update(values)
        subject.write_csv(self.source / "goods.csv", fields, rows)

    def test_database_fields_take_priority_and_excel_fills_only_missing_fields(self):
        before = subject.digest(self.source / "goods.csv")
        result = self.run_prepare([self.rec(系列="新系列", 材质="", **{"建议售价": "12.30", "默认销售折扣": "0.2"})])
        _, rows = subject.read_csv(self.output / "goods.csv")
        self.assertEqual(subject.digest(self.source / "goods.csv"), before)
        self.assertEqual((rows[0]["legacy_id"], rows[0]["code"], rows[0]["series"], rows[0]["material"]),
                         ("17", "KEEP001", "旧系列", "原材料"))
        self.assertEqual(rows[0]["name"], "旧名称")
        self.assertEqual(rows[0]["price"], "12.30")
        self.assertEqual(rows[0]["status"], "禁用")
        _, attrs = subject.read_csv(self.output / "goods_excel_attributes.csv")
        self.assertEqual(attrs[0]["source_type"], "自制")
        self.assertEqual(result["statistics"]["matched_goods"], 1)
        self.assertEqual(len(result["sourceInputs"]), 5)
        self.assertEqual(result["policy"], "legacy-database-first-excel-fill-missing-v6")

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
        self.update_old(unit_legacy_id="0")
        with self.assertRaisesRegex(ValueError, "Required cleaned dictionary reference"):
            self.run_prepare([self.rec(基本单位="吨")])
        self.update_old(unit_legacy_id="92")
        with self.assertRaisesRegex(ValueError, "Unmapped Excel owning warehouse"):
            self.run_prepare([self.rec(所属仓库="另一个五金仓库")])

    def test_reported_280243606_price_conflict_retains_exact_database_values(self):
        self.update_old(code="280243606", price="0.914", a_price="1.2345678910", price2="0.0000000000")
        before = subject.digest(self.source / "goods.csv")
        record = self.rec("280243606", **{"建议售价": "0.817"})
        result = self.run_prepare([record])
        row = subject.read_csv(self.output / "goods.csv")[1][0]
        self.assertEqual((row["price"], row["a_price"], row["price2"]), ("0.914", "1.2345678910", "0.0000000000"))
        self.assertEqual(subject.digest(self.source / "goods.csv"), before)
        conflicts = subject.read_csv(self.output / "goods_excel_conflicts.csv")[1]
        price_conflict = next(row for row in conflicts if row["field"] == "price")
        self.assertEqual((price_conflict["code"], price_conflict["legacy_value"], price_conflict["excel_value"],
                          price_conflict["selected_value"], price_conflict["source_file"], price_conflict["source_row"]),
                         ("280243606", "0.914", "0.817", "0.914", "products.xls", "2"))
        self.assertEqual(price_conflict["reason"], "legacy_database_value_retained")
        reconciliation = subject.read_csv(self.output / "goods_price_reconciliation.csv")[1][0]
        self.assertEqual((reconciliation["legacy_price"], reconciliation["selected_price"], reconciliation["excel_suggested_price"]),
                         ("0.914", "0.914", "0.817"))
        self.assertEqual((reconciliation["legacy_a_price"], reconciliation["selected_a_price"],
                          reconciliation["legacy_price2"], reconciliation["selected_price2"]),
                         ("1.2345678910", "1.2345678910", "0.0000000000", "0.0000000000"))
        self.assertEqual(reconciliation["resolution"], "legacy_database_price_retained")
        self.assertEqual(result["statistics"]["price_reconciliation_rows"], 1)

    def test_zero_database_prices_and_numeric_defaults_are_values_not_missing(self):
        for zero in ("0", "0.000000"):
            with self.subTest(zero=zero):
                self.update_old(price=zero, a_price=zero, price2=zero, zk=zero, m_weight=zero)
                self.run_prepare([self.rec(**{"建议售价": "12.345678", "默认销售折扣": "0.8", "单重（克）": "10"})])
                row = subject.read_csv(self.output / "goods.csv")[1][0]
                self.assertEqual([row[field] for field in ("price", "a_price", "price2", "zk", "m_weight")], [zero] * 5)
                self.assertEqual(subject.read_csv(self.output / "goods_price_reconciliation.csv")[1][0]["resolution"],
                                 "legacy_database_price_retained")

    def test_missing_database_price_accepts_base_unit_supplement_without_rounding(self):
        for ratio in ("1", "1.0", "1.0000"):
            with self.subTest(ratio=ratio):
                self.update_old(price="")
                self.run_prepare([self.rec(比例=ratio, **{"建议售价": "0.9141234567"})])
                row = subject.read_csv(self.output / "goods.csv")[1][0]
                self.assertEqual(row["price"], "0.9141234567")
                self.assertEqual((row["a_price"], row["price2"]), ("", ""))
                changes = subject.read_csv(self.output / "goods_excel_changes.csv")[1]
                self.assertTrue(any(row["field"] == "price" and row["reason"] == "excel_fill_missing_legacy_value" for row in changes))

    def test_blank_or_invalid_excel_prices_never_replace_or_invent_database_price(self):
        for legacy_price in ("", "0.914"):
            for proposed in ("", "abc", "NaN", "Infinity", "-0.1"):
                with self.subTest(legacy_price=legacy_price, proposed=proposed):
                    self.update_old(price=legacy_price)
                    self.run_prepare([self.rec(**{"建议售价": proposed})])
                    self.assertEqual(subject.read_csv(self.output / "goods.csv")[1][0]["price"], legacy_price)
                    reconciliation = subject.read_csv(self.output / "goods_price_reconciliation.csv")[1][0]
                    self.assertEqual(reconciliation["excel_suggested_price"], proposed)
                    issues = subject.read_csv(self.output / "goods_excel_issues.csv")[1]
                    if proposed:
                        self.assertTrue(any(row["field"] == "建议售价" and row["reason"] == "invalid_numeric_preserve_legacy_value"
                                            for row in issues))

    def test_all_three_nonempty_database_prices_preserve_ten_decimal_places_verbatim(self):
        original = {"price": "0.9141234567", "a_price": "1.0000000001", "price2": "9876543.1234567890"}
        self.update_old(**original)
        self.run_prepare([self.rec(**{"建议售价": "0.817"})])
        row = subject.read_csv(self.output / "goods.csv")[1][0]
        reconciliation = subject.read_csv(self.output / "goods_price_reconciliation.csv")[1][0]
        for field, value in original.items():
            self.assertEqual(row[field], value)
            self.assertEqual(reconciliation["legacy_" + field], value)
            self.assertEqual(reconciliation["selected_" + field], value)

    def test_alternate_unit_or_unclosed_unit_change_cannot_fill_missing_price(self):
        for values, reason in [({"单位": "包", "比例": "25"}, "alternate_unit_price_preserved_in_raw_archive"),
                               ({"单位": "个", "比例": "2"}, "alternate_unit_price_preserved_in_raw_archive"),
                               ({"基本单位": "kg", "单位": "kg"}, "per_excel_unit_price_deferred_with_base_unit_conflict")]:
            with self.subTest(values=values):
                self.update_old(price="")
                self.run_prepare([self.rec(**{**values, "建议售价": "99.99"})])
                self.assertEqual(subject.read_csv(self.output / "goods.csv")[1][0]["price"], "")
                issues = subject.read_csv(self.output / "goods_excel_issues.csv")[1]
                self.assertTrue(any(row["field"] == "建议售价" and row["reason"] == reason for row in issues))

    def test_unit_alias_price_supplement_requires_a_known_base_unit(self):
        self.update_old(price="", unit_legacy_id="108")
        self.run_prepare([self.rec(基本单位="千克", 单位="kg", 比例="1.0", **{"建议售价": "2.123456"})])
        self.assertEqual(subject.read_csv(self.output / "goods.csv")[1][0]["price"], "2.123456")
        self.run_prepare([self.rec(基本单位="", 单位="", **{"建议售价": "7"})])
        self.assertEqual(subject.read_csv(self.output / "goods.csv")[1][0]["price"], "")

    def test_unresolved_excel_unit_or_color_preserves_existing_valid_database_reference(self):
        self.update_old(color_legacy_id="345", price="0.914")
        self.run_prepare([self.rec(基本单位="吨", 颜色="未知颜色", **{"建议售价": "2"})])
        row = subject.read_csv(self.output / "goods.csv")[1][0]
        self.assertEqual((row["unit_legacy_id"], row["color_legacy_id"], row["price"]), ("92", "345", "0.914"))
        issues = subject.read_csv(self.output / "goods_excel_issues.csv")[1]
        self.assertEqual({row["field"] for row in issues if row["reason"] == "unresolved_exact_dictionary_reference"},
                         {"基本单位", "颜色"})

    def test_legacy_text_and_foreign_keys_win_while_zero_reference_sentinels_fill(self):
        subject.write_csv(self.dictionary / "color.csv", ["legacy_id", "code", "name"],
                          [{"legacy_id": "345", "code": "YS000001", "name": "白色"},
                           {"legacy_id": "346", "code": "YS000002", "name": "黑色"}])
        subject.write_csv(self.dictionary / "mould.csv", ["legacy_id", "code", "name", "mnumber"],
                          [{"legacy_id": "31", "code": "MJ000031", "name": "旧模具", "mnumber": "OLD-M"},
                           {"legacy_id": "32", "code": "MJ000032", "name": "表格模具", "mnumber": "NEW-M"}])
        subject.write_csv(self.dictionary / "client.csv", ["legacy_id", "code", "name"],
                          [{"legacy_id": "41", "code": "KH000041", "name": "旧客户"},
                           {"legacy_id": "42", "code": "KH000042", "name": "表格客户"}])
        self.update_old(color_legacy_id="345", mould_legacy_id="31", client_legacy_id="41")
        record = self.rec(颜色="黑色", 模具编号="NEW-M", 关联客户="表格客户", 产品型号="新增型号", 规格="新增规格", 原ERP备注="表格备注")
        self.run_prepare([record])
        row = subject.read_csv(self.output / "goods.csv")[1][0]
        self.assertEqual((row["name"], row["color_legacy_id"], row["mould_legacy_id"], row["client_legacy_id"]),
                         ("旧名称", "345", "31", "41"))
        self.assertEqual((row["model"], row["spec"]), ("新增型号", "新增规格"))
        self.assertTrue(row["require_remark"].startswith("旧备注\n[Excel补充资料] "))
        conflicts = subject.read_csv(self.output / "goods_excel_conflicts.csv")[1]
        self.assertTrue({"name", "status", "color_legacy_id", "mould_legacy_id", "client_legacy_id", "require_remark"}
                        <= {row["field"] for row in conflicts})
        self.update_old(color_legacy_id="0", mould_legacy_id="0", client_legacy_id="0")
        self.run_prepare([record])
        row = subject.read_csv(self.output / "goods.csv")[1][0]
        self.assertEqual((row["color_legacy_id"], row["mould_legacy_id"], row["client_legacy_id"]), ("346", "32", "42"))

    def test_unresolved_excel_base_unit_cannot_supply_price_or_per_unit_values(self):
        self.update_old(price="", m_weight="", unit_legacy_id="92")
        self.run_prepare([self.rec(基本单位="吨", 单位="吨", **{"建议售价": "123.456789", "单重（克）": "200",
                            "最小采购量": "5", "最小包装量": "10"})])
        row = subject.read_csv(self.output / "goods.csv")[1][0]
        self.assertEqual((row["unit_legacy_id"], row["price"], row["m_weight"]), ("92", "", ""))
        attrs = subject.read_csv(self.output / "goods_excel_attributes.csv")[1][0]
        self.assertEqual((attrs["min_order"], attrs["order_multiple"]), ("", ""))

    def test_missing_legacy_name_uses_decoration_policy_but_preserves_legacy_series(self):
        self.update_old(name="")
        self.run_prepare([self.rec(产品名称="新名称《白色\\Q3-K》", 系列="Q3-K")])
        row = subject.read_csv(self.output / "goods.csv")[1][0]
        self.assertEqual((row["name"], row["series"]), ("新名称", "旧系列"))
        self.assertEqual(subject.read_csv(self.output / "goods_excel_name_decorations.csv")[1][0]["applied"], "True")

    def test_new_goods_and_unmatched_legacy_goods_both_have_price_reconciliation(self):
        self.update_old(price="0.914", a_price="0", price2="3.0000")
        self.run_prepare([self.rec("NEW001", **{"建议售价": "12.345678"})])
        rows = {row["code"]: row for row in subject.read_csv(self.output / "goods.csv")[1]}
        self.assertEqual((rows["KEEP001"]["price"], rows["NEW001"]["price"]), ("0.914", "12.345678"))
        reconciliation = {row["code"]: row for row in subject.read_csv(self.output / "goods_price_reconciliation.csv")[1]}
        self.assertEqual(reconciliation["KEEP001"]["source_file"], "")
        self.assertEqual(reconciliation["KEEP001"]["selected_price2"], "3.0000")
        self.assertEqual(reconciliation["NEW001"]["resolution"], "excel_added_goods")
        self.assertEqual(reconciliation["NEW001"]["legacy_price"], "")

    def test_original_export_column_aliases_keep_database_prices_and_identity(self):
        fields, rows = subject.read_csv(self.source / "goods.csv")
        rows[0].update(price="0.914", a_price="0", price2="2.3456")
        export_fields = [subject.ALIASES[field] for field in fields]
        exported = [{subject.ALIASES[field]: value for field, value in row.items()} for row in rows]
        subject.write_csv(self.source / "goods.csv", export_fields, exported)
        before = subject.digest(self.source / "goods.csv")
        self.run_prepare([self.rec(**{"建议售价": "0.817"})])
        output_fields, prepared = subject.read_csv(self.output / "goods.csv")
        self.assertEqual(output_fields, export_fields)
        self.assertEqual((prepared[0]["ID"], prepared[0]["ANumber"], prepared[0]["Price"],
                          prepared[0]["APrice"], prepared[0]["Price2"]), ("17", "KEEP001", "0.914", "0", "2.3456"))
        self.assertEqual(subject.digest(self.source / "goods.csv"), before)

    def test_repeated_derivation_is_identical_and_every_manifest_output_hash_matches(self):
        self.update_old(price="0.914")
        records = [self.rec(产品名称="新名称《白色\\Q3-K》", 系列="Q3-K", **{"建议售价": "0.817"}),
                   self.rec("NEW001", **{"建议售价": "4.123456"})]
        input_hashes = {path: subject.digest(path) for path in [self.source / "goods.csv", self.source / "goods_categories.csv",
                                                               self.dictionary / "unit.csv", self.dictionary / "color.csv", self.crosswalk]}
        first = self.run_prepare(records)
        first_outputs = {path.name: path.read_bytes() for path in self.output.iterdir() if path.is_file()}
        second = self.run_prepare(records)
        self.assertEqual(first, second)
        self.assertEqual(first_outputs, {path.name: path.read_bytes() for path in self.output.iterdir() if path.is_file()})
        self.assertEqual(input_hashes, {path: subject.digest(path) for path in input_hashes})
        for source in second["sourceInputs"]:
            self.assertEqual(source["sha256"], subject.digest(Path(source["path"])))
        for output in second["outputs"]:
            self.assertEqual(output["sha256"], subject.digest(self.output / output["file"]))

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

    def test_existing_supplier_is_retained_and_missing_supplier_follows_route(self):
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
                self.update_old(vend_legacy_id="70")
                self.run_prepare([self.rec(产品角色=role, 主采购供应商="采购商", 主委外供应商="委外商", 供应商="通用商")])
                _, rows = subject.read_csv(self.output / "goods.csv")
                self.assertEqual(rows[0]["vend_legacy_id"], "70")
                self.assertEqual(rows[0]["vend2_legacy_id"], "71")
                self.assertIn("主采购供应商", rows[0]["require_remark"])
                self.assertIn("主委外供应商", rows[0]["require_remark"])
                self.update_old(vend_legacy_id="0")
                self.run_prepare([self.rec(产品角色=role, 主采购供应商="采购商", 主委外供应商="委外商", 供应商="通用商")])
                self.assertEqual(subject.read_csv(self.output / "goods.csv")[1][0]["vend_legacy_id"], expected)
        self.update_old(vend_legacy_id="70")
        self.run_prepare([self.rec(产品角色="自制件", 主采购供应商="采购商", 主委外供应商="委外商", 供应商="")])
        self.assertEqual(subject.read_csv(self.output / "goods.csv")[1][0]["vend_legacy_id"], "70")


if __name__ == "__main__":
    unittest.main()

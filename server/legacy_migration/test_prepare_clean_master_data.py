"""Regression tests for dimension cleanup without quantity/value conversion."""
import collections
import csv
from decimal import Decimal
from pathlib import Path
import tempfile
import unittest

import prepare_clean_master_data as subject


class CleanMasterDataTest(unittest.TestCase):
    def test_polluted_unit_uses_its_goods_and_preserves_frozen_facts(self):
        original = {"legacy_id": "70409", "goods_legacy_id": "56118", "unit_legacy_id": "242",
                    "qty": "13", "unit_rate": "1.0000", "price": "5.00", "amount": "65.00",
                    "weight": "0.5000"}
        audit = collections.Counter()
        actual = subject.rewrite_row(original, "stock_other_out_i.csv", {"242": None}, {}, {"56118": "93"}, audit)
        self.assertEqual(actual["unit_legacy_id"], "93")
        self.assertEqual({k: v for k, v in actual.items() if k != "unit_legacy_id"},
                         {k: v for k, v in original.items() if k != "unit_legacy_id"})
        self.assertEqual(sum(audit.values()), 1)

    def test_unknown_polluted_unit_fails_closed(self):
        with self.assertRaisesRegex(ValueError, "cannot resolve"):
            subject.rewrite_row({"unit_legacy": "242", "goods_legacy": "999"}, "sales.csv",
                                {"242": None}, {}, {}, collections.Counter())

    def test_polluted_unit_non_one_rate_is_not_inferred(self):
        with self.assertRaisesRegex(ValueError, "unproven non-1"):
            subject.rewrite_row({"unit_legacy": "242", "goods_legacy": "12", "unit_rate": "0.1250"},
                                "sales.csv", {"242": None}, {}, {"12": "92"}, collections.Counter())

    def test_empty_base_unit_needs_unambiguous_excel(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            subject.write_csv(path / "goods.csv", ["ID", "Goods_Name", "UnitID"],
                              [{"ID": "12", "Goods_Name": "开关", "UnitID": "283"}])
            facts = {"by_name": {"开关": {"个", "套"}}}
            with self.assertRaisesRegex(ValueError, "exact Excel evidence"):
                subject.goods_unit_map(path, facts, [{"name": "个", "legacy_id": "92"}], {"283": None})
            facts["by_name"]["开关"] = {"个"}
            ids, evidence = subject.goods_unit_map(path, facts, [{"name": "个", "legacy_id": "92"}], {"283": None})
            self.assertEqual(ids, {"12": "92"})
            self.assertEqual(len(evidence), 1)

    def test_color_aliases_do_not_collapse_shades_or_coatings(self):
        self.assertEqual(subject.color_name("铂金，"), "铂金")
        self.assertEqual(subject.color_name("兰色"), "蓝色")
        self.assertNotEqual(subject.color_name("肤感黑色"), subject.color_name("黑色"))
        self.assertNotEqual(subject.color_name("电镀铂金"), subject.color_name("铂金"))
        self.assertEqual(subject.color_name(""), "未注明颜色")

    def test_balance_merge_carries_forward_each_original_color_latest_year(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "stock_goods.csv"
            headers = ["stock_legacy", "goods_legacy", "color_legacy", "year", "qty", "fact_qty", "total", "weight", "fact_weight"]
            subject.write_csv(path, headers, [
                dict(zip(headers, ["1", "8", "348", "2024", "9", "8", "80", "2", "3"])),
                dict(zip(headers, ["1", "8", "348", "2025", "4", "3", "30", "1", "1"])),
                dict(zip(headers, ["1", "8", "356", "2023", "6", "5", "50", "2", "2"])),
            ])
            actual, report = subject.merge_stock_balances(path, {"356": "348"})
            self.assertEqual(len(actual), 1)
            self.assertEqual(actual[0]["year"], "2025")
            self.assertEqual(Decimal(actual[0]["fact_qty"]), Decimal("8"))
            self.assertEqual(Decimal(actual[0]["total"]), Decimal("80"))
            self.assertEqual(report["numeric_totals_before"], report["numeric_totals_after"])

    def test_equal_year_place_balances_sum_as_the_existing_loader(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "stock_goods.csv"
            headers = ["stock_legacy", "goods_legacy", "color_legacy", "year", "qty", "fact_qty", "total", "weight", "fact_weight"]
            first = dict(zip(headers, ["1", "8", "348", "2025", "4", "3", "30", "1", "1"]))
            subject.write_csv(path, headers, [first, {**first, "fact_qty": "9"}])
            actual, report = subject.merge_stock_balances(path, {})
            self.assertEqual(actual[0]["fact_qty"], "12")
            self.assertEqual(report["same_year_place_rows_aggregated"], 1)

    def test_null_fact_qty_falls_back_to_qty_but_real_zero_does_not(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "stock_goods.csv"
            headers = ["stock_legacy", "goods_legacy", "color_legacy", "year", "qty", "fact_qty", "total", "weight", "fact_weight"]
            first = dict(zip(headers, ["1", "8", "348", "2025", "4", "", "30", "1", "1"]))
            subject.write_csv(path, headers, [first, {**first, "color_legacy": "350", "fact_qty": "0"}])
            actual, report = subject.merge_stock_balances(path, {})
            self.assertEqual([row["fact_qty"] for row in actual], ["4", "0"])
            self.assertEqual(report["fact_qty_null_fallbacks"], 1)

    def test_crosswalk_keeps_real_track_warehouse_identity_separate_from_hardware(self):
        # A unit fixture must not consume either the company's changing reviewed
        # crosswalk or the coordinator's deliberately different synthetic map.
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "warehouse_crosswalk.csv"
            subject.write_csv(path, ["legacy_id", "action", "target_code", "target_name"], [
                {"legacy_id": "1", "action": "SPLIT", "target_code": "MAIN", "target_name": "仓库（14年版）"},
                {"legacy_id": "2", "action": "KEEP", "target_code": "HARDWARE", "target_name": "五金仓库"},
                {"legacy_id": "3", "action": "MERGE", "target_code": "HARDWARE", "target_name": "五金仓库"},
                {"legacy_id": "134", "action": "KEEP", "target_code": "WORKSHOP", "target_name": "轨道车间"},
            ])
            actual, codes = subject.warehouse_crosswalk(path)
        self.assertEqual(next(row["target_code"] for row in actual if row["action"] == "SPLIT"), "WH000001")
        self.assertEqual(next(row["target_name"] for row in actual if row["action"] == "SPLIT"), "主仓库")
        self.assertNotEqual(next(row["target_code"] for row in actual if row["target_name"] == "五金仓库"),
                            next(row["target_code"] for row in actual if row["target_name"] == "轨道车间仓库"))
        self.assertEqual(codes, {"MAIN": "WH000001", "HARDWARE": "WH000002", "WORKSHOP": "WH000003"})


if __name__ == "__main__":
    unittest.main()

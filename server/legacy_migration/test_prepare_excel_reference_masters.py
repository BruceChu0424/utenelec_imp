import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

import prepare_excel_reference_masters as subject


SUPPLIER_HEADERS = ["legacy_id", "parent_legacy", "name", "code", "description", "mobile", "status", "remark"]
MOULD_HEADERS = ["legacy_id", "parent_legacy", "name", "code", "mnumber", "qty", "tqty", "mstatus", "status", "place", "summary", "remark"]


def supplier(identity="1", name="华星", description="中山市华星电器有限公司", status="使用"):
    return dict(zip(SUPPLIER_HEADERS, [identity, "2301", name, "OLD001", description, "", status, "原备注"]))


def mould(identity="10", name="开关面框", code="UA-41【B3-07】"):
    return dict(zip(MOULD_HEADERS, [identity, "2564", name, code, "", "", "", "", "使用", "", "", "原备注"]))


def reference(**values):
    return {"file": "products.xls", "row": 2, "values": values}


class ExcelReferenceMastersTest(unittest.TestCase):
    def enrich(self, refs, suppliers=None, moulds=None):
        return subject.enrich(SUPPLIER_HEADERS, [supplier()] if suppliers is None else suppliers,
                              MOULD_HEADERS, [mould()] if moulds is None else moulds, refs)

    def test_supplier_exact_description_reuses_short_name_identity(self):
        suppliers, _, mapping, conflicts, created, _ = self.enrich([reference(主采购供应商="中山市华星电器有限公司")])
        self.assertEqual(mapping[0]["target_legacy_id"], "1")
        self.assertEqual(suppliers[0]["name"], "华星")
        self.assertEqual((conflicts, created), ([], []))

    def test_duplicate_short_name_is_not_resolved_by_active_status(self):
        _, _, mapping, conflicts, created, _ = self.enrich([reference(供应商="华星")],
            suppliers=[supplier(status="禁用"), supplier(identity="2", description="", status="使用")])
        self.assertEqual(mapping, [])
        self.assertEqual(created, [])
        self.assertEqual(conflicts[0]["reason"], "AMBIGUOUS_EXISTING_SUPPLIER_IDENTITIES")

    def test_new_supplier_has_negative_identity_and_unknown_contacts_stay_empty(self):
        suppliers, _, mapping, _, created, _ = self.enrich([reference(供应商="新城模具厂")])
        new = next(row for row in suppliers if int(row["legacy_id"]) < 0)
        self.assertEqual((new["mobile"], new["parent_legacy"], new["code"]), ("", "-1", "GY000002"))
        self.assertEqual(len(created), 1)
        self.assertEqual(mapping[0]["resolution"], "NEW_EXCEL_MASTER")

    def test_rack_suffix_requires_matching_name(self):
        _, _, mapping, conflicts, created, _ = self.enrich([reference(模具编号="UA-41", 模具名称="开关面框")])
        self.assertEqual(mapping[0]["evidence"], "RACK_SUFFIX_CODE_AND_EXACT_NAME")
        self.assertEqual(created, [])
        _, _, mapping, conflicts, created, _ = self.enrich([reference(模具编号="UA-41", 模具名称="不同的物理模具")])
        self.assertEqual(mapping, [])
        self.assertEqual(created, [])
        self.assertEqual(conflicts[0]["reason"], "EXISTING_NAME_OR_CODE_NEEDS_IDENTITY_REVIEW")

    def test_numeric_noise_or_inconsistent_new_mould_names_do_not_create(self):
        _, _, mapping, conflicts, created, _ = self.enrich([
            reference(模具编号="1", 模具名称="外购"),
            reference(模具编号="NEW-9", 模具名称="1"),
            reference(模具编号="NEW-1", 模具名称="一号模"),
            reference(模具编号="NEW-1", 模具名称="二号模")])
        self.assertEqual(mapping, [])
        self.assertEqual(created, [])
        self.assertEqual(len(conflicts), 3)

    def test_case_variants_create_only_one_physical_mould(self):
        _, moulds, mapping, conflicts, created, _ = self.enrich([
            reference(模具编号="NEW-1", 模具名称="新模"), reference(模具编号="new-1", 模具名称="新模")])
        self.assertEqual(len(created), 1)
        self.assertEqual(len(mapping), 2)
        self.assertEqual({row["target_legacy_id"] for row in mapping}, {created[0]["legacy_id"]})
        self.assertEqual(len(moulds), 2)
        self.assertEqual(conflicts, [])

    def test_full_recode_is_unique_and_preserves_original_numbers(self):
        _, moulds, _, _, _, evidence = self.enrich([], moulds=[mould(code="UF-30"), mould("11", "插座面框", "UF-30")])
        self.assertEqual([row["code"] for row in moulds], ["MJ000001", "MJ000002"])
        self.assertEqual([row["name"] for row in moulds], ["开关面框", "插座面框"])
        self.assertTrue(all('UF-30' in row["remark"] for row in moulds))
        self.assertEqual([row["original_code"] for row in evidence if row["domain"] == "mould"], ["UF-30", "UF-30"])

    def test_unique_original_and_explicit_excel_mould_codes_remain_business_codes(self):
        _, moulds, _, _, _, _ = self.enrich([reference(模具编号="NEW-9", 模具名称="新模具")])
        self.assertEqual({row["code"] for row in moulds}, {"UA-41【B3-07】", "NEW-9"})

    def test_reviewed_duplicate_codes_require_exact_source_identity_and_stay_unique(self):
        decisions = {"10": {"expected_code": "UF-30", "code": "UF-30-OLD"},
                     "11": {"expected_code": "UF-30", "code": "UF-30-NEW"}}
        result = subject.enrich(SUPPLIER_HEADERS, [supplier()], MOULD_HEADERS,
                                [mould(code="UF-30"), mould("11", "新模", "UF-30")], [], decisions)
        self.assertEqual([row["code"] for row in result[1]], ["UF-30-OLD", "UF-30-NEW"])
        decisions["10"]["expected_code"] = "WRONG"
        with self.assertRaisesRegex(ValueError, "source identity"):
            subject.enrich(SUPPLIER_HEADERS, [], MOULD_HEADERS, [mould(code="UF-30")], [], decisions)

    def test_generated_ambiguous_code_never_collides_with_an_original_business_code(self):
        _, moulds, _, _, _, _ = self.enrich([], moulds=[mould(code="UF-30"),
            mould("11", "同号新模", "UF-30"), mould("12", "已有MJ号", "MJ000001")])
        self.assertEqual(moulds[2]["code"], "MJ000001")
        self.assertEqual(len({row["code"] for row in moulds}), 3)

    def test_duplicate_original_code_can_resolve_only_with_unique_exact_name(self):
        _, _, mapping, conflicts, _, _ = self.enrich([reference(模具编号="UF-30", 模具名称="插座面框")],
            moulds=[mould(code="UF-30"), mould("11", "插座面框", "UF-30")])
        self.assertEqual(mapping[0]["target_legacy_id"], "11")
        self.assertEqual(conflicts, [])

    def test_sealed_new_mould_is_not_activated(self):
        _, moulds, _, _, _, _ = self.enrich([reference(模具编号="W50-01", 模具名称="W50面框（封存）")])
        self.assertEqual(next(row["status"] for row in moulds if int(row["legacy_id"]) < 0), "禁用")

    def test_new_identity_is_stable_independent_of_source_order(self):
        refs = [reference(供应商="新城", 模具编号="NEW-2", 模具名称="二号模"),
                reference(供应商="南城", 模具编号="NEW-1", 模具名称="一号模")]
        first = self.enrich(refs)
        second = self.enrich(list(reversed(refs)))
        self.assertEqual(first[:2], second[:2])
        self.assertEqual(first[2], second[2])

    def test_manifest_binds_clean_parent_excel_and_each_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source, output = root / "clean", root / "references"
            source.mkdir()
            subject.write_csv(source / "supplier.csv", SUPPLIER_HEADERS, [supplier()])
            subject.write_csv(source / "mould.csv", MOULD_HEADERS, [mould()])
            parent = {"raw_manifest_sha256": "a" * 64, "outputs": [
                {"file": name, "sha256": subject.digest(source / name)} for name in ("supplier.csv", "mould.csv")]}
            (source / "clean_master_manifest.json").write_text(json.dumps(parent), encoding="utf-8")
            with mock.patch.object(subject, "load_excel", return_value=([reference(模具编号="UA-41", 模具名称="开关面框")], [])):
                subject.prepare(source, root, output)
            manifest = json.loads((output / "reference_masters_manifest.json").read_text(encoding="utf-8"))
            self.assertEqual(manifest["raw_manifest_sha256"], "a" * 64)
            self.assertEqual(len(manifest["source_inputs"]), 3)
            for record in manifest["outputs"]:
                self.assertEqual(subject.digest(output / record["file"]), record["sha256"])
            self.assertEqual(subject.digest(Path(subject.__file__)), manifest["script_sha256"])
            (source / "supplier.csv").write_text("changed", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "clean input differs"):
                subject.prepare(source, root, root / "rejected")


if __name__ == "__main__":
    unittest.main()

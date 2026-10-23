import unittest

from prepare_hr_rehearsal import ReconciliationError, reconcile


def employee(name="在册人员", identity="", mobile=""):
    return {"seq": "1", "full_name": name, "id_card": identity, "phone": mobile,
            "gender": "female", "birth_date": "1990-01-01", "hire_date": "2020-03-01",
            "dept_code": "DEPT_HR", "pos_name": "文员", "political_status": "群众",
            "huji": "表格户籍", "residence": "表格住址"}


def old(lid=1, name="历史人员", identity="", mobile="", **extra):
    return {"legacy_id": str(lid), "full_name": name, "id_card": identity, "mobile": mobile,
            "dept_legacy_id": "2132", "birth_date": "1980-01-01", "work_date": "2010-01-01",
            "sex": "1", "legacy_status": "使用", "emp_style": "员工", **extra}


def chairman():
    return old(999, "朱德洪", dept_legacy_id="2129")


class HrRehearsalTest(unittest.TestCase):
    def test_excel_plus_chairman_only_active_and_codes_restart_at_one(self):
        rows, mapping, report = reconcile([employee()], [old(), chairman()])
        self.assertEqual(["UT0001", "UT0002", "UT0003"], [row["emp_code"] for row in rows])
        self.assertEqual(["active", "active", "resigned"], [row["status"] for row in rows])
        self.assertEqual("董事长", rows[1]["pos_name"])
        self.assertEqual("GM", rows[1]["dept_code"])
        self.assertEqual(2, report["active_excluding_admin"])
        self.assertEqual({1, 999}, {row["legacy_id"] for row in mapping})

    def test_matching_id_preserves_excel_and_enriches_only_missing_fields(self):
        rows, mapping, _ = reconcile([employee(identity="sample-x")], [old(name="在册人员", identity="SAMPLE-X", education="本科", address="旧地址", work_phone="内线"), chairman()])
        self.assertEqual("1", rows[0]["legacy_id"])
        self.assertEqual("表格住址", rows[0]["residence"])
        self.assertEqual("2020-03-01", rows[0]["hire_date"])
        self.assertEqual("本科", rows[0]["education"])
        self.assertEqual("内线", rows[0]["office_phone"])
        self.assertEqual("identity", mapping[0]["method"])

    def test_unique_name_match_preserves_legacy_reference(self):
        rows, mapping, _ = reconcile([employee()], [old(name="在册人员", legacy_status="禁用"), chairman()])
        self.assertEqual("1", rows[0]["legacy_id"])
        self.assertEqual("active", rows[0]["status"])
        self.assertEqual("unique_name", mapping[0]["method"])

    def test_same_name_different_identity_is_separate_resigned_archive(self):
        rows, _, report = reconcile([employee(identity="SHEET-IDENTITY")], [old(name="在册人员", identity="OLD-IDENTITY"), chairman()])
        self.assertEqual("", rows[0]["legacy_id"])
        self.assertEqual("active", rows[0]["status"])
        historical = next(row for row in rows if row["legacy_id"] == "1")
        self.assertEqual("resigned", historical["status"])
        self.assertEqual("legacy_identity_conflict", historical["source_kind"])
        self.assertNotIn("OLD-IDENTITY", str(report))

    def test_name_and_phone_allow_authoritative_excel_identity(self):
        rows, mapping, _ = reconcile([employee(identity="first", mobile="123")], [old(name="在册人员", identity="second", mobile="123"), chairman()])
        self.assertEqual("FIRST", rows[0]["id_card"])
        self.assertEqual("1", rows[0]["legacy_id"])
        self.assertEqual("name_mobile_excel_identity", mapping[0]["method"])

    def test_duplicate_old_identity_keeps_each_business_id_and_one_active(self):
        rows, mapping, _ = reconcile([employee(identity="same")], [old(1, "在册人员", "same"), old(2, "在册人员", "same"), chairman()])
        self.assertEqual({"1", "2", "999"}, {row["legacy_id"] for row in rows if row["legacy_id"]})
        self.assertEqual(1, sum(row["full_name"] == "在册人员" and row["status"] == "active" for row in rows))
        self.assertEqual("UT0001", next(row for row in mapping if row["legacy_id"] == 2)["canonical_code"])

    def test_ambiguous_name_is_blocked(self):
        with self.assertRaises(ReconciliationError):
            reconcile([employee(), employee()], [old(name="在册人员"), chairman()])

    def test_invalid_calendar_dates_are_blocked(self):
        row = employee()
        row["birth_date"] = "1990-02-31"
        with self.assertRaises(ReconciliationError):
            reconcile([row], [chairman()])

    def test_sqlserver_legacy_slash_timestamp_dates_are_normalized(self):
        rows, _, _ = reconcile([employee()], [old(birth_date="1980/1/2 0:00:00", work_date="2010/3/4 12:00:00"), chairman()])
        historical = next(row for row in rows if row["status"] == "resigned")
        self.assertEqual("1980-01-02", historical["birth_date"])
        self.assertEqual("2010-03-04", historical["hire_date"])

    def test_unknown_legacy_department_is_blocked(self):
        with self.assertRaises(ReconciliationError):
            reconcile([employee()], [old(dept_legacy_id="9999"), chairman()])

    def test_missing_historical_hire_date_is_explicitly_unverified(self):
        rows, _, report = reconcile([employee()], [old(work_date=""), chairman()])
        historical = next(row for row in rows if row["status"] == "resigned")
        self.assertEqual("2000-01-01", historical["hire_date"])
        self.assertEqual("false", historical["hire_date_verified"])
        self.assertEqual(1, report["legacy_hire_date_fallback_count"])

    def test_chairman_must_come_from_actual_source(self):
        with self.assertRaises(ReconciliationError):
            reconcile([employee()], [old()])

    def test_legacy_id_duplicates_are_blocked(self):
        with self.assertRaises(ReconciliationError):
            reconcile([employee()], [old(), old(), chairman()])


if __name__ == "__main__":
    unittest.main()

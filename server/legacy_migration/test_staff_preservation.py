import copy
from datetime import datetime, timedelta, timezone
import hashlib
import json
from pathlib import Path
import re
import tempfile
import unittest

from staff_preservation import (CURRENT, FIXED_TABLES, KIND, REQUIRED, PreservationError,
    canonical, compare_staff, reviewed_specs, schema_sql, snapshot_sql, validate_snapshot)
from verify_staff_preservation import collector_identity, main, sealed

EMP = "11111111-1111-4111-8111-111111111111"
USER = "22222222-2222-4222-8222-222222222222"
DATASET = "33333333-3333-4333-8333-333333333333"


def fixture():
    specs = [{"name": name, "columns": [{"name": "id", "type": "uuid", "nullable": "NO"}],
              "primary_key": ["id"]} for name in sorted(REQUIRED)]
    state = {"formatVersion": 1, "kind": KIND, "read_only": "on",
        "captured_at": datetime.now(timezone.utc).isoformat(),
        "custody_key_user_id": USER, "custody_key_fingerprint": "a"*64,
        "identity": {"database": "source", "database_oid": 101, "system_identifier": "12345", "dataset_id": DATASET, "generation": 7, "authorization_epoch": 10},
        "schema": specs, "schema_in_snapshot": {"tables": copy.deepcopy(specs)},
        "tables": {name: [] for name in REQUIRED}, "audit": {"highwater": 5, "rows": 2, "token": "b"*64}}
    state["tables"]["employees"] = [{"key": [EMP], "token": "c"*64,
        "state": {"id": EMP, "code": "UT0001", "status": "active", "deleted": False, "generation": 4, "version": 5}}]
    state["tables"]["users"] = [{"key": [USER], "token": "d"*64,
        "state": {"id": USER, "employee_id": EMP, "status": "active", "deleted": False,
                  "auth_version": 8, "generation": 4, "version": 5, "credential_present": True}}]
    for name in ("employee_sensitive", "user_permission_overrides", "notices", "notice_user_states"):
        state["tables"][name] = [{"key": [name+"-synthetic"], "token": "e"*64, "state": {}}]
    target = copy.deepcopy(state)
    target["identity"].update(database="candidate", database_oid=102)
    return state, target


class StaffPreservationTests(unittest.TestCase):
    def test_employee_and_account_entity_tables_are_registered(self):
        features = Path(__file__).resolve().parents[1] / "src/main/java/com/uten/imp/features"
        entities = set()
        for directory in (features / "org/employee", features / "auth/model"):
            for path in directory.glob("*.java"):
                entities.update(re.findall(r'@Table\(name\s*=\s*"([a-z_]+)"', path.read_text(encoding="utf8")))
        self.assertTrue({"emergency_contacts", "password_history"} <= entities)
        for name in entities:
            self.assertTrue(name in FIXED_TABLES | {"employees", "users"} or name.startswith(("employee_", "user_", "auth_", "notice_")), name)

    def test_complete_native_staff_passes_without_granting_cutover(self):
        source, target = fixture()
        report = compare_staff(source, target)
        self.assertEqual("PASSED", report["status"])
        self.assertFalse(report["production_acceptance"])
        self.assertFalse(report["actual_password_login_tested"])
        self.assertNotIn("tables", report)

    def test_same_count_cannot_hide_lost_manual_staff_or_recreated_uuid(self):
        source, target = fixture()
        row = target["tables"]["employees"][0]
        row["key"] = ["44444444-4444-4444-8444-444444444444"]
        row["state"]["id"] = row["key"][0]
        self.assertEqual("FAILED", compare_staff(source, target)["status"])

    def test_authhist_deleted_anchor_does_not_preserve_a_current_employee(self):
        source, target = fixture()
        row = target["tables"]["employees"][0]
        row["token"] = "f"*64
        row["state"].update(deleted=True, code="AUTHHIST_SYNTHETIC")
        report = compare_staff(source, target)
        self.assertEqual("FAILED", report["status"])
        self.assertTrue(any(i["kind"] == "ACTIVE_ACCOUNT_WITHOUT_CURRENT_IDENTITY" for i in report["issues"]))

    def test_native_pii_history_messages_and_read_states_cannot_disappear(self):
        for table in ("employee_sensitive", "notices", "notice_user_states", "user_permission_overrides"):
            with self.subTest(table=table):
                source, target = fixture()
                target["tables"][table] = []
                self.assertEqual("FAILED", compare_staff(source, target)["status"])

    def test_password_login_binding_security_and_personal_deny_changes_are_rejected(self):
        for table in ("users", "user_permission_overrides", "employee_sensitive"):
            source, target = fixture()
            target["tables"][table][0]["token"] = "f"*64
            self.assertEqual("FAILED", compare_staff(source, target)["status"])

    def test_rewound_row_versions_and_security_generations_fail(self):
        for table, field in (("users", "auth_version"), ("users", "generation"), ("employees", "generation"), ("employees", "version")):
            source, target = fixture()
            target["tables"][table][0]["state"][field] = 0
            self.assertEqual("FAILED", compare_staff(source, target)["status"])

    def test_generations_may_move_forward_without_changing_facts(self):
        source, target = fixture()
        target["tables"]["users"][0]["state"].update(version=6, auth_version=9)
        self.assertEqual("PASSED", compare_staff(source, target)["status"])

    def test_advancing_delegation_generation_cannot_silently_revoke_preserved_grants(self):
        source, target = fixture()
        target["tables"]["users"][0]["state"]["generation"] += 1
        report = compare_staff(source, target)
        self.assertEqual("FAILED", report["status"])
        self.assertTrue(any(i["kind"] == "DELEGATION_GENERATION_CHANGED" for i in report["issues"]))

    def test_session_history_is_retained_but_tokens_must_be_revoked(self):
        source, target = fixture()
        for name in ("auth_sessions", "refresh_tokens"):
            source["tables"][name] = [{"key": [name], "token": "f"*64, "state": {"revoked_at": None}}]
            target["tables"][name] = copy.deepcopy(source["tables"][name])
        self.assertEqual("FAILED", compare_staff(source, target)["status"])
        for name in ("auth_sessions", "refresh_tokens"):
            target["tables"][name][0]["state"].update(revoked_at="2026-01-01T00:00:00Z", step_up_cleared=True)
        self.assertEqual("PASSED", compare_staff(source, target)["status"])

    def test_existing_revocation_time_is_not_rewritten(self):
        source, target = fixture()
        source["tables"]["refresh_tokens"] = [{"key": ["session"], "token": "e"*64, "state": {"revoked_at": "2026-01-01T00:00:00Z"}}]
        target["tables"]["refresh_tokens"] = [{"key": ["session"], "token": "e"*64, "state": {"revoked_at": "2026-02-01T00:00:00Z"}}]
        self.assertEqual("FAILED", compare_staff(source, target)["status"])

    def test_audit_and_one_time_completion_marker_loss_fails(self):
        source, target = fixture()
        target["audit"]["rows"] -= 1
        with self.assertRaises(PreservationError):
            compare_staff(source, target)

    def test_no_self_verification_different_dataset_or_stale_source(self):
        source, target = fixture()
        target["identity"] = copy.deepcopy(source["identity"])
        with self.assertRaises(PreservationError): compare_staff(source, target)
        self.assertEqual("PASSED", compare_staff(source, target, allow_same_database_restore=True)["status"])
        target["identity"]["dataset_id"] = "44444444-4444-4444-8444-444444444444"
        with self.assertRaises(PreservationError): compare_staff(source, target, allow_same_database_restore=True)
        source, target = fixture()
        source["captured_at"] = (datetime.now(timezone.utc)-timedelta(hours=2)).isoformat()
        with self.assertRaises(PreservationError): compare_staff(source, target)

    def test_different_custody_key_is_not_misdiagnosed_as_many_bad_rows(self):
        source, target = fixture()
        target["custody_key_fingerprint"] = "f"*64
        with self.assertRaisesRegex(PreservationError, "credential changed"):
            compare_staff(source, target)

    def test_unknown_schema_duplicate_row_and_missing_dataset_fail_closed(self):
        for mutate in (lambda t: t["tables"]["users"].append(copy.deepcopy(t["tables"]["users"][0])),
                       lambda t: t["tables"].pop("employee_sensitive"),
                       lambda t: t["identity"].update(dataset_id=None),
                       lambda t: t["schema_in_snapshot"]["tables"].pop()):
            source, target = fixture();mutate(target)
            with self.assertRaises(PreservationError): validate_snapshot(target)

    def test_sql_is_select_only_and_never_contains_production_secrets(self):
        source, _ = fixture()
        sql = snapshot_sql({"tables": source["schema"]}, 5)
        self.assertTrue(sql.startswith("SELECT "))
        self.assertIn("hmac(", sql)
        self.assertIn("custody_key", sql)
        self.assertIn("jsonb_object_agg(k,v)", sql)
        self.assertNotIn("INSERT INTO", sql)
        self.assertNotIn("UPDATE public", sql)
        self.assertIn("employee", schema_sql())
        with self.assertRaises(PreservationError): snapshot_sql({"tables": source["schema"]}, "unsafe")

    def test_row_state_cannot_override_its_primary_key_or_omit_security_counters(self):
        for field, value in (("id", EMP), ("auth_version", None), ("deleted", "false"), ("generation", -1)):
            source, target = fixture()
            target["tables"]["users"][0]["state"][field] = value
            with self.subTest(field=field), self.assertRaises(PreservationError):
                validate_snapshot(target)

    def test_cli_writes_bounded_report_and_rejects_wrong_reviewed_sha(self):
        source, target = fixture()
        source["collector"] = target["collector"] = collector_identity()
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory);a=directory/"source.json";b=directory/"candidate.json";out=directory/"report.json"
            a.write_text(json.dumps(source),encoding="utf8");b.write_text(json.dumps(target),encoding="utf8")
            sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
            args=["compare","--source",str(a),"--source-sha256",sha(a),"--candidate",str(b),"--candidate-sha256",sha(b),"--output",str(out)]
            self.assertEqual(0,main(args));self.assertFalse(json.loads(out.read_text())["production_acceptance"])
            self.assertEqual(1,main(args))
            args[4]="0"*64;args[-1]=str(directory/"wrong.json")
            self.assertEqual(1,main(args));self.assertFalse((directory/"wrong.json").exists())

    def test_cli_rejects_a_snapshot_from_an_unreviewed_collector(self):
        source, _ = fixture()
        source["collector"] = {"cli_sha256": "f"*64, "policy_sha256": "e"*64}
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)/"source.json"
            path.write_text(json.dumps(source),encoding="utf8")
            with self.assertRaisesRegex(PreservationError,"collector differs"):
                sealed(path,hashlib.sha256(path.read_bytes()).hexdigest())


if __name__ == "__main__": unittest.main()

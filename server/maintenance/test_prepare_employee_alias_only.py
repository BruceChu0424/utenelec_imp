import copy
import datetime as dt
import unittest
import uuid

from prepare_employee_alias_only import render, validate_plan


def reviewed_plan():
    return {
        "protocol": "verified-employee-alias-only-v1",
        "captured_at": dt.datetime.now(dt.timezone.utc).isoformat(),
        "database_identity": {"database": "synthetic_alias_test", "system_identifier": "123456789",
                              "database_oid": 1234, "dataset_id": str(uuid.uuid4()), "generation": 32,
                              "migration_max": 947, "migration_sha256": "b" * 64},
        "canonical": {"employee_id": str(uuid.uuid4()), "code": "CANONICAL", "version": 5},
        "retained_user": {"user_id": str(uuid.uuid4()), "version": 7, "auth_version": 8},
        "aliases": [{"employee_id": str(uuid.uuid4()), "code": "ARCHIVED", "version": 3,
                     "reason": "Explicit synthetic identity proof"}],
        "backup": {"reference": "verified-paired-backup", "manifest_sha256": "a" * 64, "verified": True},
        "evidence_reference": "reviewer's stable proof", "maintenance_actor": "ops:synthetic-alias"
    }


class AliasTransactionPreparationTest(unittest.TestCase):
    def test_default_is_an_explicit_single_rollback_transaction_without_database_connection(self):
        sql = render(reviewed_plan())
        self.assertTrue(sql.startswith("\\set ON_ERROR_STOP on\nBEGIN ISOLATION LEVEL REPEATABLE READ;"))
        self.assertTrue(sql.endswith("ROLLBACK;\n"))
        self.assertIn("reviewer''s stable proof", sql)
        self.assertNotIn("COMMIT;", sql)

    def test_commit_artifact_requires_the_explicit_option(self):
        self.assertTrue(render(reviewed_plan(), commit=True).endswith("COMMIT;\n"))

    def test_no_alias_can_be_the_canonical_identity_or_another_alias(self):
        plan = reviewed_plan()
        plan["aliases"].append(copy.deepcopy(plan["aliases"][0]))
        with self.assertRaises(ValueError): validate_plan(plan)
        plan = reviewed_plan()
        plan["aliases"][0]["employee_id"] = plan["canonical"]["employee_id"]
        with self.assertRaises(ValueError): validate_plan(plan)

    def test_old_schema_expired_plan_and_unverified_backup_are_rejected(self):
        for path, value in (("schema", 935), ("schema", 937), ("schema", 946),
                            ("time", "2020-01-01T00:00:00+00:00"), ("backup", False)):
            with self.subTest(path=path, value=value):
                plan = reviewed_plan()
                if path == "schema": plan["database_identity"]["migration_max"] = value
                elif path == "time": plan["captured_at"] = value
                else: plan["backup"]["verified"] = value
                with self.assertRaises(ValueError): validate_plan(plan)

    def test_unreviewed_extra_fields_cannot_sneak_pii_or_old_account_mutations_into_the_artifact(self):
        for target in ("plan", "canonical", "retained_user", "alias"):
            with self.subTest(target=target):
                plan = reviewed_plan()
                node = plan if target == "plan" else plan["aliases"][0] if target == "alias" else plan[target]
                node["password"] = "rejected-unreviewed-input"
                with self.assertRaises(ValueError): validate_plan(plan)

    def test_missing_identity_versions_and_control_characters_are_rejected(self):
        plan = reviewed_plan(); del plan["retained_user"]["auth_version"]
        with self.assertRaises(ValueError): validate_plan(plan)
        plan = reviewed_plan(); plan["maintenance_actor"] = "ops\nsecond-statement"
        with self.assertRaises(ValueError): validate_plan(plan)


if __name__ == "__main__":
    unittest.main()

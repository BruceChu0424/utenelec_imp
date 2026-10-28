import copy
import datetime as dt
import unittest
import uuid
from prepare_employee_resigned_duplicate import render,validate_plan,PROTOCOL

def plan():
    return {"protocol":PROTOCOL,"captured_at":dt.datetime.now(dt.timezone.utc).isoformat(),
      "database_identity":{"database":"synthetic_review","system_identifier":"123456789","database_oid":1234,
        "dataset_id":str(uuid.uuid4()),"generation":32,"migration_max":948,"migration_sha256":"a"*64},
      "canonical":{"employee_id":str(uuid.uuid4()),"code":"SYN-CANONICAL","version":0},
      "duplicate":{"employee_id":str(uuid.uuid4()),"code":"SYN-DUPLICATE","version":0,"reason":"明确规范完整证件和出生日期证据"},
      "evidence":{"reference":"reviewed-evidence","sha256":"b"*64,"canonical_sensitive_sha256":"c"*64,
        "duplicate_sensitive_sha256":"d"*64,"document_equal":True,"birth_equal":True,"valid_resident_id":True},
      "backup":{"reference":"paired-backup","manifest_sha256":"e"*64,"verified":True},"maintenance_actor":"ops:reviewed"}

class ResignedDuplicatePlanTest(unittest.TestCase):
    def test_rollback_is_the_default_and_no_connection_is_opened(self):
        sql=render(plan());self.assertTrue(sql.endswith("ROLLBACK;\n"));self.assertNotIn("COMMIT;",sql)
        self.assertIn("BEGIN ISOLATION LEVEL REPEATABLE READ",sql)
        self.assertIn("account_or_credential_writes",sql)
    def test_commit_requires_the_explicit_render_option(self):
        self.assertTrue(render(plan(),commit=True).endswith("COMMIT;\n"))
    def test_partial_or_unverified_identity_evidence_is_rejected(self):
        for key in ("document_equal","birth_equal","valid_resident_id"):
            value=plan();value["evidence"][key]=False
            with self.subTest(key=key),self.assertRaises(ValueError):validate_plan(value)
    def test_backup_physical_identity_schema_and_freshness_are_required(self):
        for target in ("backup","schema","time","physical"):
            value=plan()
            if target=="backup":value["backup"]["verified"]=False
            if target=="schema":value["database_identity"]["migration_max"]=946
            if target=="time":value["captured_at"]="2020-01-01T00:00:00+00:00"
            if target=="physical":value["database_identity"]["system_identifier"]="wrong"
            with self.subTest(target=target),self.assertRaises(ValueError):validate_plan(value)
    def test_distinct_uuids_versions_and_no_unreviewed_pii_or_account_fields(self):
        value=plan();value["duplicate"]["employee_id"]=value["canonical"]["employee_id"]
        with self.assertRaises(ValueError):validate_plan(value)
        for key in ("canonical","duplicate","evidence"):
            value=plan();value[key]["password"]="unreviewed"
            with self.subTest(key=key),self.assertRaises(ValueError):validate_plan(value)
    def test_reason_sql_quoting_preserves_a_single_transaction(self):
        value=plan();value["duplicate"]["reason"]="reviewer's original identity evidence"
        self.assertIn("reviewer''s",render(value))

if __name__=="__main__":unittest.main()

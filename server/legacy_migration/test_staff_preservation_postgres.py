"""Opt-in real PostgreSQL contract; isolated network-less synthetic databases.

This tests the collector's SQL and custody semantics, not application migrations
or employee password login. No company data or existing local database is used.
"""
import json
import os
import subprocess
import time
import unittest
import uuid

from staff_preservation import REQUIRED, compare_staff, schema_sql, snapshot_sql
from verify_rehearsal_result import ReadOnlyDatabase

EMP = "11111111-1111-4111-8111-111111111111"
USER = "22222222-2222-4222-8222-222222222222"
MANUAL = "33333333-3333-4333-8333-333333333333"
DATASET = "55555555-5555-4555-8555-555555555555"
PRIVATE = "synthetic-protected-password-credential-not-exported"


@unittest.skipUnless(os.environ.get("STAFF_PRESERVATION_POSTGRES_TESTS") == "1", "explicit private PostgreSQL contract run only")
class StaffPreservationPostgresTests(unittest.TestCase):
    @classmethod
    def command(cls, args, data=None):
        return subprocess.run(args, input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60, check=True).stdout

    @classmethod
    def sql(cls, database, sql):
        return cls.command(["docker", "exec", "-i", cls.container, "psql", "-X", "-qAt", "-v", "ON_ERROR_STOP=1", "-U", "postgres", "-d", database], sql.encode("utf8"))

    @classmethod
    def setUpClass(cls):
        cls.container = "staff-preservation-contract-" + uuid.uuid4().hex[:12]
        cls.command(["docker", "run", "--detach", "--name", cls.container, "--network", "none",
                     "--label", "uten.test=staff-preservation", "-e", "POSTGRES_HOST_AUTH_METHOD=trust", "postgres:16-alpine"])
        cls.addClassCleanup(cls.command, ["docker", "rm", "--force", cls.container])
        for attempt in range(100):
            try:
                cls.sql("postgres", "SELECT 1;")
                break
            except subprocess.CalledProcessError:
                time.sleep(.1)
        else:
            raise RuntimeError("Private PostgreSQL readiness failed")
        cls.sql("postgres", "CREATE DATABASE staff_source;")
        setup = ["CREATE EXTENSION pgcrypto;", "CREATE TABLE authorization_state(singleton_id int PRIMARY KEY,business_dataset_id uuid,business_reset_generation bigint,epoch bigint);",
                 f"INSERT INTO authorization_state VALUES(1,'{DATASET}',7,10);",
                 "CREATE TABLE audit_log(id bigint PRIMARY KEY,created_at timestamptz,payload text);",
                 "CREATE TABLE audit_log_archive(LIKE audit_log INCLUDING ALL);",
                 "INSERT INTO audit_log VALUES(1,'2026-10-26T00:00:00Z','completion-marker');"]
        for name in sorted(REQUIRED):
            common = "id uuid PRIMARY KEY,payload text,version bigint NOT NULL DEFAULT 0"
            if name == "employees":
                columns = common + ",code text,status text,is_deleted bool,permission_delegation_generation bigint"
            elif name == "users":
                columns = common + ",employee_id uuid,status text,is_deleted bool,is_super_admin bool,password_hash text,login_account text,auth_version bigint,permission_delegation_generation bigint"
            elif name == "auth_sessions":
                columns = common + ",revoked_at timestamptz,revoked_reason text,step_up_token_hash text,step_up_expires_at timestamptz"
            elif name == "refresh_tokens":
                columns = common + ",revoked_at timestamptz"
            else:
                columns = common
            setup.append(f'CREATE TABLE "{name}"({columns});')
        # Prefix discovery must remain correct beyond PostgreSQL's 100 argument
        # function limit: new staff tables cannot disappear from the inventory.
        for number in range(35):
            setup.append(f'CREATE TABLE user_contract_fixture_{number}(id uuid PRIMARY KEY,payload text);')
        setup += [f"INSERT INTO employees(id,code,status,is_deleted,permission_delegation_generation) VALUES('{EMP}','ADMIN','active',false,4),('{MANUAL}','UT0193','active',false,4);",
                  f"INSERT INTO users(id,employee_id,status,is_deleted,is_super_admin,password_hash,login_account,auth_version,permission_delegation_generation) VALUES('{USER}','{EMP}','active',false,true,'{PRIVATE}','custom-login',8,4);",
                  f"INSERT INTO employee_sensitive(id,payload) VALUES('{MANUAL}','synthetic-encrypted-pii');",
                  f"INSERT INTO user_permission_overrides(id,payload) VALUES('{USER}','explicit-deny');",
                  f"INSERT INTO notices(id,payload) VALUES('{MANUAL}','native-staff-message');",
                  f"INSERT INTO auth_sessions(id,payload,step_up_token_hash,step_up_expires_at) VALUES('{USER}','retained-session','synthetic-proof',now()+interval '1 hour');",
                  f"INSERT INTO refresh_tokens(id,payload) VALUES('{USER}','retained-refresh');"]
        cls.sql("staff_source", "\n".join(setup))
        cls.sql("postgres", "CREATE DATABASE staff_candidate TEMPLATE staff_source;")
        cls.source = cls.capture("staff_source")
        cls.sql("staff_candidate", "UPDATE auth_sessions SET revoked_at=now(),revoked_reason='restored-database',step_up_token_hash=NULL,step_up_expires_at=NULL; UPDATE refresh_tokens SET revoked_at=now();")

    @classmethod
    def capture(cls, name, highwater=None):
        identity = json.loads(cls.sql(name, "SELECT jsonb_build_object('cluster',(SELECT system_identifier::text FROM pg_control_system()),'oid',(SELECT oid::bigint FROM pg_database WHERE datname=current_database()));"))
        database = ReadOnlyDatabase(name, cls.container, "postgres", identity["cluster"], identity["oid"])
        return database.query(snapshot_sql(database.query(schema_sql()), highwater))

    def test_collector_executes_read_only_with_more_than_fifty_registered_tables(self):
        candidate = self.capture("staff_candidate", self.source["audit"]["highwater"])
        report = compare_staff(self.source, candidate)
        self.assertEqual("PASSED", report["status"])
        self.assertGreater(report["registered_tables"], 50)
        self.assertNotIn(PRIVATE, json.dumps(self.source))
        self.assertNotIn("synthetic-encrypted-pii", json.dumps(self.source))

    def test_current_manual_staff_and_explicit_deny_are_not_replaced_by_legacy_counts(self):
        self.sql("staff_candidate", f"UPDATE employee_sensitive SET payload='wrong-reimported-value' WHERE id='{MANUAL}';")
        try:
            result = compare_staff(self.source, self.capture("staff_candidate", 1))
            self.assertEqual("FAILED", result["status"])
            self.assertTrue(any(i["table"] == "employee_sensitive" and i["kind"] == "STAFF_FACTS_CHANGED" for i in result["issues"]))
        finally:
            self.sql("staff_candidate", f"UPDATE employee_sensitive SET payload='synthetic-encrypted-pii' WHERE id='{MANUAL}';")

    def test_audit_bound_allows_new_events_but_detects_deleted_completion_markers(self):
        self.sql("staff_candidate", "INSERT INTO audit_log VALUES(2,now(),'new-event');")
        try:
            self.assertEqual("PASSED", compare_staff(self.source, self.capture("staff_candidate", 1))["status"])
            self.sql("staff_candidate", "DELETE FROM audit_log WHERE id=1;")
            from staff_preservation import PreservationError
            with self.assertRaises(PreservationError):
                compare_staff(self.source, self.capture("staff_candidate", 1))
        finally:
            self.sql("staff_candidate", "DELETE FROM audit_log; INSERT INTO audit_log VALUES(1,'2026-10-26T00:00:00Z','completion-marker');")

    def test_unrevoked_candidate_sessions_cannot_pass_on_matching_row_counts(self):
        self.sql("staff_candidate", "UPDATE refresh_tokens SET revoked_at=NULL;")
        try:
            report = compare_staff(self.source, self.capture("staff_candidate", 1))
            self.assertEqual("FAILED", report["status"])
            self.assertTrue(any(i["kind"] == "CANDIDATE_SESSION_STILL_USABLE" for i in report["issues"]))
        finally:
            self.sql("staff_candidate", "UPDATE refresh_tokens SET revoked_at=now();")


if __name__ == "__main__":
    unittest.main()

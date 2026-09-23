"""Run the shipped role SQL against a disposable PostgreSQL 16 catalog."""
import ast
from pathlib import Path
import re
import shutil
import subprocess
import time
import unittest


HERE = Path(__file__).resolve().parent
HARDENER = (HERE / "harden-existing-postgres-roles.sh").read_text(encoding="utf-8")
COMMISSIONER = HERE / "existing-test-host-internal-db-commissioner.py"


def shipped_block(marker):
    match = re.search(r"DO \$" + marker + r"\$.*?\$" + marker + r"\$;", HARDENER, re.S)
    if match is None:
        raise AssertionError(f"missing shipped role SQL: {marker}")
    return match.group()


MIGRATION_ROOT = HERE.parent.parent / "server" / "src" / "main" / "resources" / "db" / "migration"
AUDIT_SEAL_FUNCTION = re.search(
    r"CREATE FUNCTION public\.fn_audit_seal_privileges\(.*?\n\$\$;",
    (MIGRATION_ROOT / "V671__audit_log_monthly_partitions_append_only.sql").read_text(encoding="utf-8"),
    re.S).group()


def commissioner_query():
    for statement in ast.parse(COMMISSIONER.read_text(encoding="utf-8")).body:
        if isinstance(statement, ast.Assign) and any(
                isinstance(target, ast.Name) and target.id == "ROLE_POSTCONDITION_SQL"
                for target in statement.targets):
            return ast.literal_eval(statement.value)
    raise AssertionError("missing commissioner role postcondition SQL")


def runtime_postcondition_queries():
    function = re.search(r"verify_runtime_role_contract\(\) \{(.*?)\n\}", HARDENER, re.S)
    if function is None:
        raise AssertionError("missing runtime privilege verifier")
    queries = re.findall(r'psql_admin "(SELECT.*?;)"', function.group(1), re.S)
    if len(queries) != 3:
        raise AssertionError("runtime verifier must check DDL, Flyway and restricted import ACLs")
    return queries


class RoleHardeningSourceContractTest(unittest.TestCase):
    def test_membership_cleanup_precedes_ownership_and_retains_maintenance_gates(self):
        self.assertLess(HARDENER.index("DO $runtime_membership_cleanup$"), HARDENER.index("REASSIGN OWNED BY uten TO"))
        self.assertLess(HARDENER.index("ALTER ROLE uten NOLOGIN"), HARDENER.index("DO $runtime_membership_cleanup$"))
        self.assertIn("GRANTED BY %I RESTRICT", shipped_block("runtime_membership_cleanup"))
        self.assertIn("WHERE rolname IN ('uten_owner', 'uten_migrator')", HARDENER)
        self.assertIn("runtime.rolname = 'uten'", HARDENER)
        self.assertIn("verify_runtime_role_contract 'completed-state'", HARDENER)
        self.assertIn("verify_runtime_role_contract 'post-change'", HARDENER)
        self.assertIn("GRANT uten_owner TO uten_migrator;", HARDENER)
        self.assertLess(HARDENER.index("GRANT EXECUTE ON ALL FUNCTIONS"), HARDENER.index("DO $restricted_import_acl$"))

    def test_postcondition_is_one_statement_and_proves_both_runtime_memberships_absent(self):
        query = commissioner_query()
        self.assertNotIn(";", query)
        self.assertIn("FROM pg_database WHERE datname='uten_imp'", query)
        self.assertIn("pg_has_role('uten','uten_owner','MEMBER')", query)
        self.assertIn("pg_has_role('uten','uten_migrator','MEMBER')", query)


@unittest.skipUnless(shutil.which("docker"), "Docker is required for the isolated PostgreSQL role proof")
class PostgresRoleHardeningTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        probe = subprocess.run(["docker", "info", "--format", "{{.ServerVersion}}"], capture_output=True, timeout=20)
        if probe.returncode:
            raise unittest.SkipTest("Docker daemon is unavailable for the isolated role proof")
        result = subprocess.run([
            "docker", "run", "--detach", "--rm", "--cpus", "1", "--memory", "512m",
            "--env", "POSTGRES_HOST_AUTH_METHOD=trust", "--env", "POSTGRES_DB=uten_imp", "postgres:16-alpine",
        ], capture_output=True, check=True, timeout=60)
        cls.container = result.stdout.decode().strip()
        if not re.fullmatch(r"[0-9a-f]{64}", cls.container):
            raise AssertionError("Docker did not return the isolated container identity")
        cls.addClassCleanup(subprocess.run, ["docker", "rm", "--force", cls.container], capture_output=True, timeout=30)
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            # The image's temporary init server exposes only its Unix socket;
            # TCP readiness proves the final server has finished initialization.
            ready = subprocess.run(["docker", "exec", cls.container, "pg_isready", "-h", "127.0.0.1", "-U", "postgres", "-d", "uten_imp"],
                                   capture_output=True, timeout=10)
            if ready.returncode == 0:
                return
            time.sleep(0.2)
        raise AssertionError("isolated PostgreSQL did not become ready")

    def sql(self, body):
        # No ports are published. Every role, grant and object below belongs only
        # to this fresh container; each test rolls its catalog changes back.
        seed = """BEGIN;
CREATE ROLE uten_owner NOLOGIN;
CREATE ROLE uten_migrator LOGIN;
CREATE ROLE uten LOGIN;
GRANT uten_owner TO uten_migrator;
ALTER DATABASE uten_imp OWNER TO uten_owner;
ALTER SCHEMA public OWNER TO uten_owner;
REVOKE ALL ON DATABASE uten_imp FROM PUBLIC;
GRANT CONNECT ON DATABASE uten_imp TO uten,uten_migrator;
REVOKE ALL ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO uten;
"""
        result = subprocess.run([
            "docker", "exec", "--interactive", self.container, "psql", "-X", "-qAt",
            "-v", "ON_ERROR_STOP=1", "-U", "postgres", "-d", "uten_imp",
        ], input=(seed + body + "\nROLLBACK;\n").encode(), capture_output=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
        return result.stdout.decode().strip()

    def test_direct_owner_and_migrator_grants_are_both_removed(self):
        result = self.sql("""GRANT uten_owner,uten_migrator TO uten;
SELECT pg_has_role('uten','uten_owner','MEMBER'),pg_has_role('uten','uten_migrator','MEMBER');
""" + shipped_block("runtime_membership_cleanup") + """
SELECT pg_has_role('uten','uten_owner','MEMBER'),pg_has_role('uten','uten_migrator','MEMBER'),
       pg_has_role('uten_migrator','uten_owner','MEMBER');
""")
        self.assertEqual(result.splitlines(), ["t|t", "f|f|t"])

    def test_indirect_paths_are_cut_only_at_runtime_edges_and_unrelated_graph_is_unchanged(self):
        result = self.sql("""CREATE ROLE bridge_a;
CREATE ROLE bridge_b;
CREATE ROLE safe_reader;
CREATE ROLE unrelated_user;
GRANT uten_migrator TO bridge_b;
GRANT bridge_b TO bridge_a;
GRANT bridge_a,safe_reader TO uten;
GRANT bridge_a,safe_reader TO unrelated_user;
CREATE TEMP TABLE unchanged_edges AS SELECT roleid,member,grantor,admin_option,inherit_option,set_option
  FROM pg_auth_members WHERE member<>'uten'::regrole;
""" + shipped_block("runtime_membership_cleanup") + """
DO $$ BEGIN
  IF EXISTS((SELECT * FROM unchanged_edges EXCEPT SELECT roleid,member,grantor,admin_option,inherit_option,set_option
      FROM pg_auth_members WHERE member<>'uten'::regrole)
    UNION ALL (SELECT roleid,member,grantor,admin_option,inherit_option,set_option FROM pg_auth_members
      WHERE member<>'uten'::regrole EXCEPT SELECT * FROM unchanged_edges)) THEN
    RAISE EXCEPTION 'unrelated role graph changed';
  END IF;
END $$;
SELECT pg_has_role('uten','uten_owner','MEMBER'),pg_has_role('uten','uten_migrator','MEMBER'),
       pg_has_role('uten','safe_reader','MEMBER'),pg_has_role('unrelated_user','bridge_a','MEMBER');
""")
        self.assertEqual(result, "f|f|t|t")

    def test_multiple_grantors_do_not_leave_a_second_membership_behind(self):
        result = self.sql("""CREATE ROLE other_grantor;
GRANT uten_migrator TO other_grantor WITH ADMIN OPTION;
GRANT uten_migrator TO uten GRANTED BY other_grantor;
GRANT uten_migrator TO uten GRANTED BY postgres;
SELECT count(*) FROM pg_auth_members WHERE member='uten'::regrole AND roleid='uten_migrator'::regrole;
""" + shipped_block("runtime_membership_cleanup") + """
SELECT count(*) FROM pg_auth_members WHERE member='uten'::regrole;
""")
        self.assertEqual(result.splitlines(), ["2", "0"])

    def test_set_role_only_path_is_removed_even_without_inherited_ddl(self):
        result = self.sql("""GRANT uten_migrator TO uten WITH INHERIT FALSE, SET TRUE;
SELECT has_schema_privilege('uten','public','CREATE');
""" + shipped_block("runtime_membership_cleanup") + """
SELECT pg_has_role('uten','uten_migrator','MEMBER'),pg_has_role('uten','uten_owner','SET');
""")
        self.assertEqual(result.splitlines(), ["f", "f|f"])

    def test_dependent_admin_grants_refuse_without_cascading_into_other_users(self):
        result = self.sql("""CREATE ROLE untouched_child;
GRANT uten_migrator TO uten WITH ADMIN OPTION;
GRANT uten_migrator TO untouched_child GRANTED BY uten;
DO $case$ BEGIN
  BEGIN
    EXECUTE $cleanup$""" + shipped_block("runtime_membership_cleanup") + """$cleanup$;
    RAISE EXCEPTION 'expected dependency refusal';
  EXCEPTION WHEN dependent_objects_still_exist THEN NULL;
  END;
END $case$;
SELECT pg_has_role('uten','uten_migrator','MEMBER'),pg_has_role('untouched_child','uten_migrator','MEMBER');
""")
        self.assertEqual(result, "t|t")

    def test_restricted_import_acl_survives_the_general_business_grants(self):
        result = self.sql("""CREATE TABLE public.legacy_subcontract_order_import_sources(id uuid);
ALTER TABLE public.legacy_subcontract_order_import_sources OWNER TO uten_owner;
CREATE FUNCTION public.fn_register_legacy_subcontract_order_source(uuid,jsonb) RETURNS uuid LANGUAGE sql AS 'SELECT $1';
ALTER FUNCTION public.fn_register_legacy_subcontract_order_source(uuid,jsonb) OWNER TO uten_owner;
CREATE TABLE public.ordinary_business_row(id uuid);
CREATE FUNCTION public.ordinary_business_function() RETURNS int LANGUAGE sql AS 'SELECT 1';
GRANT SELECT,INSERT ON public.legacy_subcontract_order_import_sources TO uten_migrator;
GRANT INSERT ON public.legacy_subcontract_order_import_sources TO PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_register_legacy_subcontract_order_source(uuid,jsonb) TO uten_migrator;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC;
GRANT SELECT,INSERT,UPDATE,DELETE ON ALL TABLES IN SCHEMA public TO uten;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO uten;
""" + shipped_block("restricted_import_acl") + """
SELECT has_table_privilege('uten','public.legacy_subcontract_order_import_sources','SELECT'),
       has_table_privilege('uten','public.legacy_subcontract_order_import_sources','INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER'),
       has_function_privilege('uten','public.fn_register_legacy_subcontract_order_source(uuid,jsonb)','EXECUTE'),
       has_table_privilege('uten_migrator','public.legacy_subcontract_order_import_sources','INSERT'),
       has_function_privilege('uten_migrator','public.fn_register_legacy_subcontract_order_source(uuid,jsonb)','EXECUTE'),
       has_table_privilege('uten','public.ordinary_business_row','INSERT'),
       has_function_privilege('uten','public.ordinary_business_function()','EXECUTE');
""")
        self.assertEqual(result, "t|f|f|t|t|t|t")

    def test_older_reviewed_head_without_v624_objects_still_hardens(self):
        self.assertEqual(self.sql(shipped_block("restricted_import_acl") + "SELECT 1;"), "1")

    def test_each_source_registration_stays_private_after_blanket_grants(self):
        for table, signature in (
                ("legacy_finance_import_sources", "fn_import_legacy_finance_source(uuid,text,jsonb,integer)"),
                ("legacy_procurement_receipt_import_sources", "fn_register_legacy_receipt_import_source(uuid,text,jsonb)")):
            with self.subTest(table=table):
                result = self.sql(f"""CREATE TABLE public.{table}(id uuid);
ALTER TABLE public.{table} OWNER TO uten_owner;
CREATE FUNCTION public.{signature} RETURNS uuid LANGUAGE sql AS 'SELECT $1';
ALTER FUNCTION public.{signature} OWNER TO uten_owner;
GRANT INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER ON public.{table} TO PUBLIC,uten;
GRANT EXECUTE ON FUNCTION public.{signature} TO PUBLIC,uten;
""" + shipped_block("restricted_import_acl") + f"""
SELECT has_table_privilege('uten','public.{table}','SELECT'),
       has_table_privilege('uten','public.{table}','INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER'),
       has_function_privilege('uten','public.{signature}','EXECUTE'),
       has_table_privilege('uten_migrator','public.{table}','INSERT'),
       has_function_privilege('uten_migrator','public.{signature}','EXECUTE');
CREATE TABLE flyway_schema_history(id int);
""" + "\n".join(runtime_postcondition_queries()))
                self.assertEqual(result.splitlines(), ["t|f|f|t|t", "0:0:0:0", "0", "1"])

    def test_audit_tables_stay_append_only_after_the_blanket_business_grants(self):
        # ADR-105: the shipped block reapplies the migration-owned seal after
        # "GRANT ... ON ALL TABLES", so the runtime login keeps SELECT/INSERT on
        # the audit parents and loses UPDATE/DELETE/TRUNCATE on parents and months.
        result = self.sql("""SET ROLE uten_owner;
CREATE TABLE public.audit_log(id bigint, created_at timestamptz NOT NULL, result text) PARTITION BY RANGE (created_at);
CREATE TABLE public.audit_log_p202609 PARTITION OF public.audit_log FOR VALUES FROM ('2026-09-01') TO ('2026-10-01');
CREATE TABLE public.audit_log_archive(id bigint, created_at timestamptz NOT NULL, result text) PARTITION BY RANGE (created_at);
CREATE FUNCTION public.fn_audit_retention_run() RETURNS void LANGUAGE sql AS 'SELECT';
CREATE FUNCTION public.fn_audit_ensure_partition(text, date) RETURNS text LANGUAGE sql AS 'SELECT NULL::text';
CREATE FUNCTION public.fn_audit_track_table(text,text,text,boolean,text[],boolean) RETURNS void LANGUAGE sql AS 'SELECT';
""" + AUDIT_SEAL_FUNCTION + """
RESET ROLE;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC;
GRANT SELECT,INSERT,UPDATE,DELETE ON ALL TABLES IN SCHEMA public TO uten;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO uten;
""" + shipped_block("restricted_import_acl") + """
SELECT has_table_privilege('uten','public.audit_log','SELECT,INSERT'),
       has_table_privilege('uten','public.audit_log','UPDATE'),
       has_table_privilege('uten','public.audit_log','DELETE'),
       has_table_privilege('uten','public.audit_log_archive','UPDATE,DELETE,TRUNCATE'),
       has_table_privilege('uten','public.audit_log_p202609','SELECT,INSERT,UPDATE,DELETE'),
       has_function_privilege('uten','public.fn_audit_retention_run()','EXECUTE'),
       has_function_privilege('uten','public.fn_audit_track_table(text,text,text,boolean,text[],boolean)','EXECUTE');
""")
        self.assertEqual(result, "t|f|f|f|f|t|f")

    def test_private_runtime_maintenance_guard_is_not_exposed_by_blanket_grants(self):
        result = self.sql("""CREATE FUNCTION public.fn_require_runtime_maintenance(boolean) RETURNS void LANGUAGE sql AS 'SELECT';
ALTER FUNCTION public.fn_require_runtime_maintenance(boolean) OWNER TO uten_owner;
GRANT EXECUTE ON FUNCTION public.fn_require_runtime_maintenance(boolean) TO PUBLIC,uten;
""" + shipped_block("restricted_import_acl") + """
SELECT has_function_privilege('uten','public.fn_require_runtime_maintenance(boolean)','EXECUTE'),
       has_function_privilege('uten_owner','public.fn_require_runtime_maintenance(boolean)','EXECUTE');
""")
        self.assertEqual(result, "f|t")

    def test_runtime_verifier_queries_execute_for_an_older_reviewed_head(self):
        result = self.sql("CREATE TABLE flyway_schema_history(id int);\n" + "\n".join(runtime_postcondition_queries()))
        self.assertEqual(result.splitlines(), ["0:0:0:0", "0", "1"])

    def test_commissioner_postcondition_executes_as_one_real_query(self):
        self.assertEqual(self.sql(commissioner_query() + ";"), "uten_owner|uten_owner|f|f|t|f|f")

    def test_commissioner_postcondition_detects_noninheriting_migration_membership(self):
        result = self.sql("GRANT uten_migrator TO uten WITH INHERIT FALSE, SET TRUE;" + commissioner_query() + ";")
        self.assertEqual(result, "uten_owner|uten_owner|f|f|t|t|t")


if __name__ == "__main__":
    unittest.main()

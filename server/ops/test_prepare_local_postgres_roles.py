"""Run the local role preparation against disposable, real PostgreSQL 16.

Run with ``python -m unittest server.ops.test_prepare_local_postgres_roles -v``.
Only randomly named containers created here are used or removed. No local .env,
existing container, host database, application process, or network service is read.
An already available PostgreSQL 16 image is required; tests never pull an image.
"""

import json
import hashlib
import hmac
import os
from pathlib import Path
import secrets
import shutil
import string
import subprocess
import time
import unittest
import uuid


SERVER = Path(__file__).resolve().parents[1]
PREPARE = SERVER / "ops/prepare-local-postgres-roles.sql"
MIGRATIONS = SERVER / "src/main/resources/db/migration"
DOCKER = shutil.which("docker")
CONFIRMATION = "PREPARE LOCAL uten_imp"
SOURCE_TABLES = (
    "legacy_subcontract_order_import_sources",
    "legacy_finance_import_sources",
    "legacy_procurement_receipt_import_sources",
    "legacy_quantity_counter_import_sources",
    "legacy_production_plan_counter_import_sources",
    "legacy_production_plan_counter_import_contexts",
)
PROTECTED_TABLES = SOURCE_TABLES + (
    "legacy_migration_runs", "legacy_migration_run_files",
    "legacy_migration_reconciliation_items", "legacy_migration_rejects",
    "legacy_migration_checkpoints",
)
PRIVATE_FUNCTIONS = (
    "business_data_reset()",
    "fn_require_runtime_maintenance(boolean)",
    "fn_require_runtime_refresh()",
    "fn_business_test_reset_verify_purged()",
    "fn_clear_business_test_object_metadata()",
    "fn_audit_track_table()",
    "fn_audit_seal_privileges()",
    "fn_migrate_financial_amount_columns()",
    "fn_register_legacy_fixture_source()",
    "fn_import_legacy_fixture_source()",
)


def password():
    # Production secrets never enter this test. All credentials are per-container.
    return "T9" + "".join(secrets.choice(string.ascii_letters + string.digits)
                          for _ in range(30))


@unittest.skipUnless(DOCKER, "Docker is required for real PostgreSQL role regression")
class PrepareLocalPostgresRolesTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        ready = subprocess.run(
            [DOCKER, "info", "--format", "{{.ServerVersion}}"],
            capture_output=True, text=True, timeout=20,
        )
        if ready.returncode:
            raise unittest.SkipTest("A running Docker engine is required")
        cls.image = None
        for candidate in ("postgres:16-alpine", "postgres:16", "postgis/postgis:16-3.4"):
            found = subprocess.run(
                [DOCKER, "image", "inspect", candidate],
                capture_output=True, text=True, timeout=20,
            )
            if found.returncode == 0:
                cls.image = candidate
                break
        if cls.image is None:
            raise unittest.SkipTest("An existing PostgreSQL 16 Docker image is required")

    def setUp(self):
        self.container = "uten-local-role-test-" + uuid.uuid4().hex
        self.runtime_password = password()
        self.admin_password = password()
        self.migrator_password = password()
        self.environment = dict(
            os.environ,
            POSTGRES_PASSWORD=self.admin_password,
            UTEN_LOCAL_ADMIN_PASSWORD=self.admin_password,
            UTEN_LOCAL_MIGRATOR_PASSWORD=self.migrator_password,
            UTEN_LOCAL_RUNTIME_PASSWORD=self.runtime_password,
        )
        launched = self.docker(
            "run", "--pull=never", "--detach", "--rm", "--name", self.container,
            "--label", "com.uten.test=local-postgres-role-regression",
            "--publish", "127.0.0.1::5432", "-e", "POSTGRES_USER=uten_dev_admin",
            "-e", "POSTGRES_DB=uten_imp", "-e", "POSTGRES_PASSWORD", self.image,
        )
        self.assertEqual(launched.returncode, 0, self.output(launched))
        # Register only after successful creation, and remove only our exact name.
        self.addCleanup(self.remove_own_container)
        # Docker Desktop can spend longer than 45s initializing a disposable
        # instance while the complete Java/Flutter suites are running. This
        # bounds fixture provisioning only; the role/ACL assertions stay exact.
        deadline = time.monotonic() + 120
        while time.monotonic() < deadline:
            ready = self.docker("exec", self.container, "pg_isready", "-U", "uten_dev_admin",
                                "-d", "uten_imp")
            if ready.returncode == 0:
                # pg_isready can see the temporary init server. TCP is the final one.
                connection = self.psql("SELECT 1", role="uten_dev_admin", check=False)
                if connection.returncode == 0:
                    break
            time.sleep(0.25)
        else:
            diagnostic = self.docker("logs", "--tail", "30", self.container)
            self.fail("Disposable PostgreSQL did not become ready within 120s:\n"
                      + self.output(diagnostic))
        self.psql("\\getenv fixture_runtime_password UTEN_LOCAL_RUNTIME_PASSWORD\n"
                  "SELECT format('CREATE ROLE uten SUPERUSER LOGIN PASSWORD %L', "
                  ":'fixture_runtime_password') \\gexec\n"
                  "ALTER DATABASE uten_imp OWNER TO uten;\n"
                  "SET ROLE uten;\n" + self.fixture_sql(), role="uten_dev_admin")
        self.system_identifier = self.scalar(
            "SELECT system_identifier::text FROM pg_control_system()"
        )

    def docker(self, *arguments, input_text=None, environment=None, timeout=60):
        return subprocess.run(
            [DOCKER, *arguments], input=input_text, env=environment or self.environment,
            capture_output=True, encoding="utf-8", errors="replace", timeout=timeout,
        )

    def output(self, result):
        output = result.stdout + result.stderr
        for secret in (self.runtime_password, self.admin_password, self.migrator_password,
                       self.environment.get("UTEN_LOCAL_ADMIN_PASSWORD"),
                       self.environment.get("UTEN_LOCAL_MIGRATOR_PASSWORD"),
                       self.environment.get("UTEN_LOCAL_RUNTIME_PASSWORD")):
            if secret:
                output = output.replace(secret, "[redacted test credential]")
        return output

    def remove_own_container(self):
        # No container enumeration, label-based deletion, or existing service names.
        self.docker("rm", "--force", self.container)

    def psql_command(self, role="uten", database="uten_imp", variables=None):
        command = [
            "exec", "-i", "-e", "PGPASSWORD", "-e", "PGAPPNAME",
            "-e", "UTEN_LOCAL_ADMIN_PASSWORD", "-e", "UTEN_LOCAL_MIGRATOR_PASSWORD",
            "-e", "UTEN_LOCAL_RUNTIME_PASSWORD",
            self.container, "psql", "-X", "-qAt", "--host=127.0.0.1",
            "--username=" + role, "--dbname=" + database,
            "--set=ON_ERROR_STOP=1", "--set=VERBOSITY=verbose",
        ]
        for name, value in (variables or {}).items():
            command.extend(["--set", name + "=" + str(value)])
        return command

    def login_environment(self, role="uten"):
        credentials = {
            "uten": self.runtime_password,
            "uten_dev_admin": self.admin_password,
            "uten_migrator": self.migrator_password,
        }
        return dict(self.environment, PGPASSWORD=credentials[role],
                    PGAPPNAME="uten-local-role-regression")

    def psql(self, sql, role="uten", database="uten_imp", variables=None, check=True):
        result = self.docker(
            *self.psql_command(role, database, variables), input_text=sql,
            environment=self.login_environment(role),
        )
        for secret in (self.admin_password, self.migrator_password, self.runtime_password,
                       *(self.environment.get(name) for name in (
                           "UTEN_LOCAL_ADMIN_PASSWORD", "UTEN_LOCAL_MIGRATOR_PASSWORD",
                           "UTEN_LOCAL_RUNTIME_PASSWORD"))):
            if secret:
                self.assertTrue(secret not in result.stdout + result.stderr,
                                "A test credential appeared in psql output")
        if check:
            self.assertEqual(result.returncode, 0, self.output(result))
        return result

    def scalar(self, sql, role="uten"):
        return self.psql(sql, role=role).stdout.strip()

    @staticmethod
    def fixture_sql():
        sources = "\n".join(
            f"CREATE TABLE public.{table}(id integer PRIMARY KEY, payload text);\n"
            f"INSERT INTO public.{table} VALUES (1,'preserve {table}');\n"
            f"GRANT UPDATE(payload), INSERT(payload), REFERENCES(payload) "
            f"ON public.{table} TO PUBLIC;"
            for table in PROTECTED_TABLES
        )
        functions = "\n".join(
            f"CREATE FUNCTION public.{signature} RETURNS void LANGUAGE plpgsql "
            "SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$ "
            "BEGIN UPDATE public.fixture_reset_invocations SET calls=calls+1; END $$;"
            for signature in PRIVATE_FUNCTIONS
        )
        return f"""
            CREATE TABLE public.app_data(id serial PRIMARY KEY, payload text NOT NULL);
            INSERT INTO public.app_data(payload) VALUES ('business sentinel');
            CREATE VIEW public.app_view AS SELECT * FROM public.app_data;
            CREATE MATERIALIZED VIEW public.app_materialized AS SELECT * FROM public.app_data;
            CREATE TYPE public.fixture_enum AS ENUM ('retained');
            CREATE TABLE public.fixture_reset_invocations(calls integer NOT NULL);
            INSERT INTO public.fixture_reset_invocations VALUES (0);
            CREATE TABLE public.flyway_schema_history(
                installed_rank integer PRIMARY KEY,version text,script text,
                checksum integer,success boolean);
            INSERT INTO public.flyway_schema_history VALUES
                (1,'914','V914__sentinel.sql',123456789,true);
            CREATE TABLE public.audit_log(id integer,payload text) PARTITION BY RANGE(id);
            CREATE TABLE public.audit_log_fixture PARTITION OF public.audit_log
                FOR VALUES FROM (0) TO (1000);
            INSERT INTO public.audit_log VALUES (1,'audit sentinel');
            CREATE TABLE public.audit_log_archive(id integer,payload text) PARTITION BY RANGE(id);
            CREATE TABLE public.audit_log_archive_fixture PARTITION OF public.audit_log_archive
                FOR VALUES FROM (0) TO (1000);
            INSERT INTO public.audit_log_archive VALUES (1,'archive sentinel');
            {sources}
            {functions}
            CREATE FUNCTION public.fixture_business_function() RETURNS integer
                LANGUAGE sql IMMUTABLE AS $$ SELECT 42 $$;
            GRANT ALL ON ALL TABLES IN SCHEMA public TO PUBLIC;
            GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO PUBLIC;
            ALTER DEFAULT PRIVILEGES FOR ROLE uten IN SCHEMA public
                GRANT ALL ON TABLES TO PUBLIC;
        """

    def snapshot(self, role="uten"):
        # Compare actual catalogs and data, not SQL strings from the implementation.
        return self.scalar("""
            SELECT jsonb_build_object(
              'roles',(SELECT jsonb_agg(to_jsonb(r) ORDER BY rolname) FROM
                (SELECT rolname,rolsuper,rolinherit,rolcreaterole,rolcreatedb,
                        rolcanlogin,rolreplication,rolbypassrls,rolconfig
                 FROM pg_roles WHERE rolname NOT LIKE 'pg_%') r),
              'members',(SELECT jsonb_agg(to_jsonb(m) ORDER BY roleid,member) FROM pg_auth_members m),
              'databases',(SELECT jsonb_agg(to_jsonb(d) ORDER BY datname) FROM
                (SELECT datname,datdba,datacl FROM pg_database) d),
              'schemas',(SELECT jsonb_agg(to_jsonb(n) ORDER BY nspname) FROM
                (SELECT nspname,nspowner,nspacl FROM pg_namespace WHERE nspname='public') n),
              'extensions',(SELECT jsonb_agg(to_jsonb(e) ORDER BY extname) FROM
                (SELECT extname,extowner,extnamespace,extversion FROM pg_extension) e),
              'relations',(SELECT jsonb_agg(to_jsonb(c) ORDER BY relname) FROM
                (SELECT relname,relowner,relacl,relkind FROM pg_class
                 WHERE relnamespace='public'::regnamespace) c),
              'columns',(SELECT jsonb_agg(to_jsonb(a) ORDER BY attrelid,attnum) FROM
                (SELECT attrelid,attnum,attacl FROM pg_attribute
                 WHERE attrelid IN(SELECT oid FROM pg_class WHERE relnamespace='public'::regnamespace)
                   AND attnum>0 AND NOT attisdropped) a),
              'functions',(SELECT jsonb_agg(to_jsonb(p) ORDER BY oid) FROM
                (SELECT oid,proowner,proacl,prosrc,proconfig FROM pg_proc
                 WHERE pronamespace='public'::regnamespace) p),
              'defaults',(SELECT jsonb_agg(to_jsonb(a) ORDER BY defaclrole,defaclnamespace,defaclobjtype)
                FROM (SELECT defaclrole,defaclnamespace,defaclobjtype,defaclacl FROM pg_default_acl) a),
              'business',(SELECT jsonb_agg(to_jsonb(d) ORDER BY id) FROM app_data d),
              'history',(SELECT jsonb_agg(to_jsonb(d) ORDER BY installed_rank) FROM flyway_schema_history d),
              'audit',(SELECT jsonb_agg(to_jsonb(d) ORDER BY id) FROM audit_log d),
              'archive',(SELECT jsonb_agg(to_jsonb(d) ORDER BY id) FROM audit_log_archive d),
              'provenance',(SELECT jsonb_agg(to_jsonb(d) ORDER BY id)
                            FROM legacy_production_plan_counter_import_sources d),
              'contexts',(SELECT jsonb_agg(to_jsonb(d) ORDER BY id)
                          FROM legacy_production_plan_counter_import_contexts d),
              'reset_calls',(SELECT calls FROM fixture_reset_invocations));
        """, role=role)

    def prepare(self, role="uten_dev_admin", confirmation=CONFIRMATION, system_identifier=None):
        variables = {"expected_system_identifier": system_identifier or self.system_identifier}
        if confirmation is not None:
            variables["local_dev_confirm"] = confirmation
        return self.psql(PREPARE.read_text(encoding="utf-8"), role=role,
                         variables=variables, check=False)

    def assert_refused_unchanged(self, expected_message, **arguments):
        before = self.snapshot(role="uten_dev_admin")
        refused = self.prepare(**arguments)
        self.assertNotEqual(refused.returncode, 0, self.output(refused))
        self.assertIn(expected_message, refused.stderr, self.output(refused))
        self.assertEqual(self.snapshot(role="uten_dev_admin"), before,
                         "A refused repair mutated roles, ACLs, or data")

    def apply_repair(self):
        result = self.prepare()
        self.assertEqual(result.returncode, 0, self.output(result))

    def assert_permission_denied(self, sql, role="uten"):
        denied = self.psql(sql, role=role, check=False)
        self.assertNotEqual(denied.returncode, 0, self.output(denied))
        self.assertIn("42501", denied.stderr, self.output(denied))

    def test_missing_or_wrong_confirmation_is_read_only(self):
        for confirmation in (None, "yes", "PREPARE LOCAL another_database"):
            with self.subTest(confirmation=confirmation):
                self.assert_refused_unchanged("local_dev_confirm", confirmation=confirmation)

    def test_wrong_cluster_identifier_is_read_only(self):
        self.assert_refused_unchanged("expected_system_identifier",
                                     system_identifier=str(int(self.system_identifier) + 1))

    def test_missing_cluster_identifier_is_read_only(self):
        before = self.snapshot(role="uten_dev_admin")
        refused = self.psql(PREPARE.read_text(encoding="utf-8"), role="uten_dev_admin",
                            variables={"local_dev_confirm": CONFIRMATION}, check=False)
        self.assertNotEqual(refused.returncode, 0, self.output(refused))
        self.assertIn("expected_system_identifier", refused.stderr, self.output(refused))
        self.assertEqual(self.snapshot(role="uten_dev_admin"), before)

    def test_shared_cluster_is_read_only(self):
        self.psql("CREATE DATABASE another_business_database")
        self.assert_refused_unchanged("single-business-database")

    def test_other_active_connection_is_not_terminated(self):
        environment = self.login_environment()
        environment["PGAPPNAME"] = "uten-local-role-test-held-session"
        command = self.psql_command()
        held = subprocess.Popen(
            [DOCKER, *command], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, env=environment, text=True,
        )
        try:
            held.stdin.write("SELECT pg_sleep(40);\n")
            held.stdin.flush()
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                count = self.scalar("SELECT count(*) FROM pg_stat_activity WHERE "
                                    "application_name='uten-local-role-test-held-session'")
                if count == "1":
                    break
                time.sleep(0.1)
            else:
                self.fail("Could not establish the independent active connection")
            self.assert_refused_unchanged("other database sessions")
            self.assertIsNone(held.poll(), "Repair terminated another database connection")
        finally:
            # This test owns that one connection; no server sessions are killed.
            held.terminate()
            try:
                held.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                held.kill()
                held.communicate(timeout=5)

    def test_unknown_role_is_read_only(self):
        self.psql("CREATE ROLE unrelated_operator LOGIN")
        self.assert_refused_unchanged("unreviewed roles")

    def test_existing_role_membership_is_read_only(self):
        self.psql("CREATE ROLE uten_migrator NOLOGIN; GRANT uten_migrator TO uten")
        self.assert_refused_unchanged("memberships")

    def test_missing_and_weak_passwords_are_read_only(self):
        for variable in ("UTEN_LOCAL_ADMIN_PASSWORD", "UTEN_LOCAL_MIGRATOR_PASSWORD",
                         "UTEN_LOCAL_RUNTIME_PASSWORD"):
            original = self.environment[variable]
            try:
                for invalid in (None, "", "WeakFixture17", "InvalidFixtureCredential+"):
                    with self.subTest(variable=variable, value=invalid):
                        if invalid is None:
                            self.environment.pop(variable)
                        else:
                            self.environment[variable] = invalid
                        self.assert_refused_unchanged("required" if invalid is None else "three different")
            finally:
                self.environment[variable] = original

    def test_passwords_must_be_distinct(self):
        self.environment["UTEN_LOCAL_MIGRATOR_PASSWORD"] = self.admin_password
        self.assert_refused_unchanged("three different")

    def test_runtime_owned_extension_is_refused_without_mutation(self):
        self.psql("CREATE EXTENSION pgcrypto")
        self.assert_refused_unchanged("owns an extension")

    def test_new_admin_instance_can_create_missing_runtime_role(self):
        self.psql("ALTER DATABASE uten_imp OWNER TO uten_dev_admin; "
                  "DROP OWNED BY uten; DROP ROLE uten;", role="uten_dev_admin")
        self.assertEqual(self.scalar("SELECT count(*) FROM pg_roles WHERE rolname='uten'",
                                     role="uten_dev_admin"), "0")
        self.apply_repair()
        self.assertEqual(self.scalar("SELECT rolsuper FROM pg_roles WHERE rolname='uten'"), "f")
        self.psql("CREATE TABLE public.first_restored_business(id serial PRIMARY KEY,payload text)",
                  role="uten_migrator")
        self.psql("INSERT INTO public.first_restored_business(payload) VALUES('new instance')")
        self.assertEqual(self.scalar("SELECT payload FROM first_restored_business"), "new instance")

    def test_admin_extension_remains_owned_by_admin_and_usable_by_runtime(self):
        self.psql("CREATE EXTENSION pgcrypto; CREATE EXTENSION pg_trgm; "
                  "CREATE FUNCTION public.fn_register_legacy_fixture_admin_decoy_source() "
                  "RETURNS integer LANGUAGE sql AS $$ SELECT 71 $$;", role="uten_dev_admin")
        self.apply_repair()
        self.assertEqual(self.scalar("SELECT pg_get_userbyid(extowner) FROM pg_extension "
                                     "WHERE extname='pgcrypto'"), "uten_dev_admin")
        self.assertEqual(self.scalar("SELECT encode(digest('hello','sha256'),'hex')"),
                         hashlib.sha256(b"hello").hexdigest())
        # Flyway owns ordinary objects, but these extension functions remain
        # bootstrap-owned. PUBLIC revocation must not break a real owner import.
        for role in ("uten_migrator", "uten"):
            self.assertEqual(self.scalar("SELECT encode(hmac('fixture-value','fixture-key','sha256'),'hex')",
                                         role=role),
                             hmac.new(b"fixture-key", b"fixture-value", hashlib.sha256).hexdigest())
            self.assertEqual(self.scalar("SELECT pgp_sym_decrypt(pgp_sym_encrypt('fixture-plaintext','fixture-key'),'fixture-key')",
                                         role=role), "fixture-plaintext")
            self.assertEqual(self.scalar("SELECT similarity('uten','uten')", role=role), "1")
        self.assertEqual(self.scalar("""
            SELECT bool_and(p.proowner='uten_dev_admin'::regrole
                            AND has_function_privilege('uten_migrator',p.oid,'EXECUTE'))
            FROM pg_proc p JOIN pg_depend d ON d.classid='pg_proc'::regclass AND d.objid=p.oid
              AND d.refclassid='pg_extension'::regclass AND d.deptype='e'
            JOIN pg_extension e ON e.oid=d.refobjid
            WHERE e.extname IN('pgcrypto','pg_trgm') AND p.pronamespace='public'::regnamespace
        """), "t")
        # The new grant is catalog-membership based, not ALL public functions or
        # a familiar name prefix. Private issuer/reset boundaries remain intact.
        self.assert_permission_denied("SELECT fn_register_legacy_fixture_admin_decoy_source()",
                                      role="uten_migrator")
        self.assert_permission_denied("SELECT fn_register_legacy_fixture_admin_decoy_source()")
        self.assert_permission_denied("SELECT fn_register_legacy_fixture_source()")
        self.assert_permission_denied("SELECT business_data_reset()")
        self.assertEqual(self.scalar("SELECT calls FROM fixture_reset_invocations"), "0")
        before = self.snapshot(role="uten_dev_admin")
        self.apply_repair()
        self.assertEqual(self.snapshot(role="uten_dev_admin"), before)
        self.assert_permission_denied("DROP EXTENSION pgcrypto")

    def test_bootstrap_runtime_is_refused_without_mutation(self):
        original_container = self.container
        original_identifier = self.system_identifier
        bootstrap_container = "uten-local-role-test-" + uuid.uuid4().hex
        environment = dict(self.environment, POSTGRES_PASSWORD=self.runtime_password)
        launched = self.docker(
            "run", "--pull=never", "--detach", "--rm", "--name", bootstrap_container,
            "--label", "com.uten.test=local-postgres-role-regression",
            "--publish", "127.0.0.1::5432", "-e", "POSTGRES_USER=uten",
            "-e", "POSTGRES_DB=uten_imp", "-e", "POSTGRES_PASSWORD", self.image,
            environment=environment,
        )
        self.assertEqual(launched.returncode, 0, self.output(launched))
        try:
            self.container = bootstrap_container
            deadline = time.monotonic() + 45
            while time.monotonic() < deadline:
                ready = self.psql("SELECT 1", check=False)
                if ready.returncode == 0:
                    break
                time.sleep(0.25)
            else:
                self.fail("Disposable bootstrap-runtime instance did not become ready")
            self.psql(self.fixture_sql())
            self.assertEqual(self.scalar("SELECT oid FROM pg_roles WHERE rolname='uten'"), "10")
            self.system_identifier = self.scalar("SELECT system_identifier::text FROM pg_control_system()")
            before = self.snapshot()
            refused = self.prepare(role="uten")
            self.assertNotEqual(refused.returncode, 0, self.output(refused))
            self.assertIn("pinned cluster bootstrap role", refused.stderr, self.output(refused))
            self.assertEqual(self.snapshot(), before)
        finally:
            self.docker("rm", "--force", bootstrap_container)
            self.container = original_container
            self.system_identifier = original_identifier

    def test_original_v915_fails_then_real_migrations_succeed_without_data_loss(self):
        v915 = (MIGRATIONS / "V915__retire_server_business_data_reset.sql").read_text(encoding="utf-8")
        v917 = (MIGRATIONS / "V917__production_plan_provenance_runtime_read_only.sql").read_text(encoding="utf-8")
        before_history = self.scalar("SELECT row_to_json(h) FROM flyway_schema_history h")
        before_sources = {table: self.scalar(f"SELECT row_to_json(s) FROM {table} s")
                          for table in PROTECTED_TABLES}
        original = self.psql(v915, check=False)
        self.assertNotEqual(original.returncode, 0)
        self.assertIn("V915: runtime role uten still inherits business reset authority", original.stderr)
        self.apply_repair()
        # These are the untouched repository migrations, executed by the actual login.
        self.psql(v915, role="uten_migrator")
        self.psql(v917, role="uten_migrator")
        self.assertEqual(self.scalar("SELECT payload FROM app_data"), "business sentinel")
        self.assertEqual(self.scalar("SELECT row_to_json(h) FROM flyway_schema_history h",
                                     role="uten_dev_admin"), before_history)
        for table, expected in before_sources.items():
            self.assertEqual(self.scalar(f"SELECT row_to_json(s) FROM {table} s"), expected)
        self.assertEqual(self.scalar("SELECT calls FROM fixture_reset_invocations"), "0")
        flags = json.loads(self.scalar("""
            SELECT jsonb_object_agg(rolname,jsonb_build_array(rolsuper,rolinherit,rolcreaterole,
                   rolcreatedb,rolcanlogin,rolreplication,rolbypassrls)) FROM pg_roles
            WHERE rolname IN('uten','uten_migrator','uten_dev_admin')
        """))
        self.assertEqual(flags["uten"], [False, False, False, False, True, False, False])
        self.assertEqual(flags["uten_migrator"], [False, False, False, False, True, False, False])
        self.assertTrue(flags["uten_dev_admin"][0])
        self.assertEqual(self.scalar("SELECT pg_get_userbyid(datdba) FROM pg_database "
                                     "WHERE datname=current_database()"), "uten_migrator")
        self.assertEqual(self.scalar("SELECT pg_get_userbyid(proowner) FROM pg_proc "
                                     "WHERE oid='business_data_reset()'::regprocedure"), "uten_migrator")

    def test_runtime_dml_works_but_maintenance_and_protected_writes_are_denied(self):
        self.apply_repair()
        self.psql("INSERT INTO app_data(payload) VALUES ('ordinary runtime write'); "
                  "UPDATE app_data SET payload='ordinary runtime update' WHERE id=2; "
                  "DELETE FROM app_data WHERE id=2;")
        self.assertEqual(self.scalar("SELECT fixture_business_function()"), "42")
        self.assertEqual(self.scalar("SELECT payload FROM app_view"), "business sentinel")
        for statement in (
            "SET ROLE uten_migrator", "SET ROLE uten_dev_admin",
            "CREATE TABLE public.runtime_ddl_must_fail(id integer)",
            "CREATE SCHEMA runtime_schema_must_fail", "CREATE DATABASE runtime_database_must_fail",
            "TRUNCATE app_data", "ALTER TABLE app_data ADD COLUMN forbidden integer",
            "SELECT * FROM pg_control_system()",
            "INSERT INTO flyway_schema_history VALUES (2,'999','forged.sql',0,true)",
            "UPDATE flyway_schema_history SET checksum=0", "DELETE FROM flyway_schema_history",
            "TRUNCATE flyway_schema_history", "SELECT * FROM flyway_schema_history",
            "UPDATE audit_log SET payload='forged'", "DELETE FROM audit_log", "TRUNCATE audit_log",
            "INSERT INTO audit_log_archive VALUES(2,'forged')",
            "UPDATE audit_log_archive SET payload='forged'", "DELETE FROM audit_log_archive",
            "TRUNCATE audit_log_archive", "INSERT INTO audit_log_fixture VALUES(2,'forged')",
            "UPDATE audit_log_archive_fixture SET payload='forged'",
            "SELECT * FROM audit_log_fixture", "SELECT * FROM audit_log_archive_fixture",
        ):
            with self.subTest(statement=statement):
                self.assert_permission_denied(statement)
        for signature in PRIVATE_FUNCTIONS:
            call = signature.replace("boolean", "false")
            with self.subTest(private_function=signature):
                self.assert_permission_denied("SELECT public." + call)
        for table in PROTECTED_TABLES:
            self.assertEqual(self.scalar(f"SELECT count(*) FROM {table}"), "1")
            for statement in (
                f"INSERT INTO {table} VALUES(2,'forged')",
                f"UPDATE {table} SET payload='forged'", f"DELETE FROM {table}",
                f"TRUNCATE {table}",
            ):
                with self.subTest(protected_source=statement):
                    self.assert_permission_denied(statement)
            self.assertEqual(self.scalar(
                f"SELECT has_table_privilege('uten','{table}','SELECT WITH GRANT OPTION') "
                f"OR has_any_column_privilege('uten','{table}','SELECT WITH GRANT OPTION')"), "f")
            self.assertEqual(self.scalar(
                f"SELECT has_table_privilege('uten','{table}','REFERENCES') "
                f"OR has_any_column_privilege('uten','{table}','REFERENCES') "
                f"OR has_table_privilege('uten','{table}','TRIGGER')"), "f")
        # Parent-table INSERT remains available for ordinary append-only auditing.
        self.psql("INSERT INTO audit_log VALUES(2,'runtime append')")
        self.assertEqual(self.scalar("SELECT count(*) FROM audit_log"), "2")
        self.assertEqual(self.scalar("SELECT payload FROM audit_log_archive"), "archive sentinel")
        self.assertEqual(self.scalar("SELECT calls FROM fixture_reset_invocations"), "0")

    def test_repeat_is_idempotent_and_new_migration_defaults_keep_runtime_useful(self):
        self.apply_repair()
        before = self.snapshot(role="uten_dev_admin")
        repeated = self.prepare(role="uten_dev_admin")
        self.assertEqual(repeated.returncode, 0, self.output(repeated))
        self.assertEqual(self.snapshot(role="uten_dev_admin"), before)
        self.psql("CREATE TABLE public.future_business(id serial PRIMARY KEY,payload text); "
                  "CREATE FUNCTION public.future_business_function() RETURNS integer "
                  "LANGUAGE sql AS $$ SELECT 43 $$;", role="uten_migrator")
        self.psql("INSERT INTO future_business(payload) VALUES('new migration DML'); "
                  "UPDATE future_business SET payload='updated'; DELETE FROM future_business;")
        self.assertEqual(self.scalar("SELECT future_business_function()"), "43")
        self.assert_permission_denied("TRUNCATE future_business")
        self.assert_permission_denied("ALTER TABLE future_business ADD COLUMN forbidden integer")


if __name__ == "__main__":
    unittest.main()

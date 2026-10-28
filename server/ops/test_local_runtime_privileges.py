"""Actual PostgreSQL ACL regression in one owned network-isolated disposable container."""
import json
import os
from pathlib import Path
import secrets
import shutil
import subprocess
import time
import unittest
import uuid

SERVER = Path(__file__).resolve().parents[1]
POLICY = SERVER / 'src/main/resources/db/local-runtime-privileges.sql'
ENTRY = SERVER / 'ops/reconcile-runtime-privileges.sql'
DOCKER = shutil.which('docker')


@unittest.skipUnless(DOCKER, 'Docker required')
class LocalRuntimePrivilegesTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.container = 'uten-runtime-acl-test-' + uuid.uuid4().hex
        image = None
        for candidate in ('postgres:16-alpine', 'postgres:16', 'postgis/postgis:16-3.4'):
            if subprocess.run([DOCKER, 'image', 'inspect', candidate], capture_output=True).returncode == 0:
                image = candidate
                break
        if image is None:
            raise unittest.SkipTest('An existing PostgreSQL 16 image is required; never pull')
        environment = dict(os.environ, POSTGRES_PASSWORD=secrets.token_hex(20))
        result = subprocess.run([DOCKER, 'run', '--pull=never', '--detach', '--rm', '--network=none',
                                 '--name', cls.container, '-e', 'POSTGRES_PASSWORD', image],
                                capture_output=True, text=True, env=environment)
        if result.returncode:
            raise RuntimeError('Unable to create owned ACL fixture')
        cls.addClassCleanup(lambda: subprocess.run([DOCKER, 'rm', '--force', cls.container], capture_output=True))
        for attempt in range(120):
            ready = subprocess.run([DOCKER, 'exec', cls.container, 'pg_isready', '-h', '127.0.0.1', '-U', 'postgres'], capture_output=True)
            if ready.returncode == 0:
                time.sleep(.3)
                break
            time.sleep(.2)
        cls.psql('CREATE ROLE uten_migrator LOGIN NOSUPERUSER NOINHERIT;'
                 'CREATE ROLE uten LOGIN NOSUPERUSER NOINHERIT;'
                 'CREATE DATABASE uten_imp OWNER uten_migrator;', database='postgres')
        cls.psql('ALTER SCHEMA public OWNER TO uten_migrator;')
        cls.psql('GRANT EXECUTE ON FUNCTION pg_catalog.pg_control_system() TO uten_migrator;')
        subprocess.run([DOCKER, 'exec', cls.container, 'mkdir', '-p',
                        '/acl/server/ops', '/acl/server/src/main/resources/db'], check=True, capture_output=True)
        subprocess.run([DOCKER, 'cp', str(POLICY), cls.container + ':/acl/server/src/main/resources/db/local-runtime-privileges.sql'],
                       check=True, capture_output=True)
        subprocess.run([DOCKER, 'cp', str(ENTRY), cls.container + ':/acl/server/ops/reconcile-runtime-privileges.sql'],
                       check=True, capture_output=True)

    @classmethod
    def psql(cls, sql, user='postgres', database='uten_imp', check=True):
        result = subprocess.run([DOCKER, 'exec', '-i', cls.container, 'psql', '-XqAt',
                                 '-v', 'ON_ERROR_STOP=1', '-U', user, '-d', database],
                                input=sql, capture_output=True, text=True, timeout=30)
        if check and result.returncode:
            raise AssertionError(result.stderr)
        return result

    def setUp(self):
        self.psql('DROP SCHEMA public CASCADE; CREATE SCHEMA public AUTHORIZATION uten_migrator;')
        self.psql('''CREATE TABLE permissions(id int PRIMARY KEY,code text);
          INSERT INTO permissions VALUES(1,'goods:view');
          CREATE TABLE permission_surfaces(id int PRIMARY KEY);
          CREATE TABLE permission_surface_permissions(id int PRIMARY KEY);
          CREATE TABLE business_rows(id serial PRIMARY KEY,value text);
          INSERT INTO business_rows(value) VALUES('preserve me');
          CREATE TABLE legacy_finance_import_sources(id int PRIMARY KEY);
          CREATE TABLE stock_measurement_holds(id int PRIMARY KEY);
          CREATE TABLE flyway_schema_history(id int PRIMARY KEY);
          CREATE TABLE audit_log(id int,created_month int) PARTITION BY RANGE(created_month);
          CREATE TABLE audit_log_p202610 PARTITION OF audit_log FOR VALUES FROM(202610) TO(202611);
          CREATE TABLE audit_log_archive(id int,created_month int);
          CREATE VIEW business_rows_v AS SELECT * FROM business_rows;
          CREATE VIEW v_audit_log_all AS SELECT * FROM audit_log UNION ALL SELECT * FROM audit_log_archive;
          CREATE FUNCTION fn_audit_log_all_insert() RETURNS trigger LANGUAGE plpgsql AS $$
            BEGIN INSERT INTO audit_log VALUES(NEW.id,NEW.created_month); RETURN NEW; END $$;
          CREATE TRIGGER trg_audit_log_all_insert INSTEAD OF INSERT ON v_audit_log_all
            FOR EACH ROW EXECUTE FUNCTION fn_audit_log_all_insert();
          CREATE FUNCTION normal_business_read() RETURNS int LANGUAGE sql AS $$ SELECT 7 $$;
          CREATE FUNCTION fn_require_runtime_refresh() RETURNS void LANGUAGE plpgsql AS $$ BEGIN END $$;
          CREATE FUNCTION fn_register_legacy_probe() RETURNS void LANGUAGE plpgsql AS $$ BEGIN END $$;
          CREATE FUNCTION fn_capture_stock_measurement_holds() RETURNS int LANGUAGE sql AS $$ SELECT 0 $$;
          CREATE FUNCTION fn_verify_stock_original_measurement_basis() RETURNS void LANGUAGE plpgsql AS $$ BEGIN END $$;
          REVOKE ALL ON FUNCTION fn_require_runtime_refresh(),fn_register_legacy_probe() FROM PUBLIC;
        ''', user='uten_migrator')

    def apply(self):
        result = self.psql('BEGIN;\n' + POLICY.read_text(encoding='utf-8') + '\nCOMMIT;', user='uten_migrator')
        self.assertNotIn('WARNING', result.stderr)
        return result

    def scalar(self, sql):
        return self.psql(sql).stdout.strip()

    def test_fresh_missing_acl_and_repeat_preserve_data_and_reset_absence(self):
        denied = self.psql('SELECT * FROM permission_surfaces;', user='uten', check=False)
        self.assertNotEqual(denied.returncode, 0)
        self.apply()
        self.assertEqual(self.psql('SELECT count(*) FROM permission_surfaces;', user='uten').stdout.strip(), '0')
        self.assertEqual(self.psql('SELECT normal_business_read();', user='uten').stdout.strip(), '7')
        self.psql("INSERT INTO business_rows(value) VALUES('runtime insert');", user='uten')
        self.apply()
        self.assertEqual(self.scalar('SELECT count(*) FROM business_rows;'), '2')
        self.assertEqual(self.scalar("SELECT to_regprocedure('business_data_reset()') IS NULL;"), 't')

    def test_private_provenance_and_audit_partitions_remain_sealed(self):
        self.psql('GRANT ALL ON legacy_finance_import_sources TO PUBLIC;'
                  'GRANT UPDATE(id) ON legacy_finance_import_sources TO uten;'
                  'GRANT SELECT ON audit_log_p202610 TO PUBLIC;'
                  'GRANT EXECUTE ON FUNCTION fn_register_legacy_probe() TO PUBLIC;', user='uten_migrator')
        self.apply()
        for sql in ('INSERT INTO legacy_finance_import_sources VALUES(1);',
                    'DELETE FROM audit_log;', 'SELECT * FROM audit_log_p202610;',
                    'SELECT * FROM flyway_schema_history;',
                    'SELECT fn_require_runtime_refresh();', 'SELECT fn_register_legacy_probe();',
                    'DELETE FROM stock_measurement_holds;',
                    'SELECT fn_capture_stock_measurement_holds();',
                    'SELECT fn_verify_stock_original_measurement_basis();',
                    'TRUNCATE business_rows;', 'SET ROLE uten_migrator;'):
            self.assertNotEqual(self.psql(sql, user='uten', check=False).returncode, 0, sql)
        self.psql('SELECT * FROM legacy_finance_import_sources;', user='uten')
        self.psql('INSERT INTO audit_log VALUES(1,202610);', user='uten')
        self.psql('SELECT * FROM stock_measurement_holds;', user='uten')

    def test_audit_unified_view_keeps_only_its_runtime_insert_channel(self):
        self.apply()
        self.assertEqual(self.scalar("SELECT has_table_privilege('uten','v_audit_log_all','SELECT,INSERT');"), 't')
        self.psql('INSERT INTO v_audit_log_all(id,created_month) VALUES(9,202610);', user='uten')
        self.assertEqual(self.scalar('SELECT count(*) FROM audit_log;'), '1')
        for sql in ("UPDATE v_audit_log_all SET id=id WHERE false",
                    'DELETE FROM v_audit_log_all',
                    "INSERT INTO business_rows_v(value) VALUES('view write')"):
            self.assertNotEqual(self.psql(sql, user='uten', check=False).returncode, 0, sql)
        self.assertEqual(self.scalar("SELECT has_table_privilege('uten','business_rows_v','INSERT');"), 'f')
        self.apply()
        self.assertEqual(self.scalar("SELECT has_table_privilege('uten','v_audit_log_all','INSERT');"), 't')

    def test_future_tables_sequences_and_functions_get_runtime_permissions(self):
        self.apply()
        self.psql('CREATE TABLE later_business(id serial PRIMARY KEY);'
                  'CREATE FUNCTION later_read() RETURNS int LANGUAGE sql AS $$ SELECT 9 $$;', user='uten_migrator')
        self.psql('INSERT INTO later_business DEFAULT VALUES; SELECT later_read();', user='uten')
        self.assertNotEqual(self.psql("SELECT setval('later_business_id_seq',100);", user='uten', check=False).returncode, 0)
        self.assertNotEqual(self.psql('SELECT last_value FROM later_business_id_seq;', user='uten', check=False).returncode, 0)

    def test_standard_database_owner_schema_is_accepted_without_ownership_changes(self):
        self.psql('ALTER SCHEMA public OWNER TO pg_database_owner;')
        self.apply()
        self.assertEqual(self.scalar("SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname='public';"),
                         'pg_database_owner')
        self.psql("INSERT INTO business_rows(value) VALUES('native runtime append');", user='uten')

    def test_candidate_wrapper_requires_exact_independent_identity_pins(self):
        candidate = 'uten_acl_candidate_' + uuid.uuid4().hex[:12]
        self.psql('CREATE DATABASE ' + candidate + ' OWNER uten_migrator TEMPLATE uten_imp;', database='postgres')
        try:
            self.psql('ALTER SCHEMA public OWNER TO pg_database_owner;', database=candidate)
            system_id = self.psql('SELECT system_identifier FROM pg_control_system();',
                                  user='uten_migrator', database=candidate).stdout.strip()
            database_oid = self.psql("SELECT oid FROM pg_database WHERE datname=current_database();", database=candidate).stdout.strip()
            self.assertEqual(self.psql("SELECT has_database_privilege('uten',current_database(),'CONNECT');", database=candidate).stdout.strip(), 't')

            def run(**overrides):
                values = dict(expected_database=candidate, expected_database_oid=database_oid,
                              expected_system_identifier=system_id, expected_owner='uten_migrator',
                              runtime_acl_confirm='RECONCILE CANDIDATE RUNTIME ACL ' + candidate)
                values.update(overrides)
                command = [DOCKER, 'exec', self.container, 'psql', '-XqAt', '-U', 'uten_migrator', '-d', candidate]
                for key, value in values.items():
                    command.extend(['-v', key + '=' + value])
                command.extend(['-f', '/acl/server/ops/reconcile-runtime-privileges.sql'])
                return subprocess.run(command, capture_output=True, text=True, timeout=30)

            for pins in ({'expected_database': 'uten_another_candidate'},
                         {'expected_database_oid': '1'}, {'expected_system_identifier': '1'},
                         {'expected_owner': 'postgres'}, {'runtime_acl_confirm': 'unapproved'}):
                result = run(**pins)
                self.assertNotEqual(result.returncode, 0, pins)
                self.assertNotIn('WARNING', result.stderr)
                self.assertEqual(self.psql("SELECT has_table_privilege('uten','business_rows','INSERT');", database=candidate).stdout.strip(), 'f')
            result = run()
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn('WARNING', result.stderr)
            self.assertEqual(self.psql("SELECT has_table_privilege('uten','business_rows','INSERT');", database=candidate).stdout.strip(), 't')
            self.assertEqual(self.psql("SELECT has_database_privilege('uten',current_database(),'CONNECT');", database=candidate).stdout.strip(), 'f')
            self.assertNotEqual(self.psql('SELECT 1;', user='uten', database=candidate, check=False).returncode, 0)
        finally:
            self.psql('DROP DATABASE ' + candidate + ' WITH (FORCE);', database='postgres')

    def test_ungrantable_admin_functions_are_preserved_and_private_leaks_fail_closed(self):
        self.psql('CREATE FUNCTION admin_extension_like() RETURNS int LANGUAGE sql AS $$ SELECT 11 $$;')
        before = self.scalar("SELECT coalesce(proacl::text,'default') FROM pg_proc WHERE oid='admin_extension_like()'::regprocedure;")
        self.apply()
        self.assertEqual(self.psql('SELECT admin_extension_like();', user='uten').stdout.strip(), '11')
        self.assertEqual(self.scalar("SELECT coalesce(proacl::text,'default') FROM pg_proc WHERE oid='admin_extension_like()'::regprocedure;"), before)
        self.psql('CREATE FUNCTION fn_register_legacy_admin_leak() RETURNS void LANGUAGE plpgsql AS $$ BEGIN END $$;')
        self.psql('REVOKE SELECT ON permission_surfaces FROM uten;', user='uten_migrator')
        result = self.psql('BEGIN;\n' + POLICY.read_text(encoding='utf-8') + '\nCOMMIT;', user='uten_migrator', check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('WARNING', result.stderr)
        self.assertEqual(self.scalar("SELECT has_table_privilege('uten','permission_surfaces','SELECT');"), 'f')

    def test_existing_runtime_catalog_information_access_is_preserved_without_policy_grants(self):
        # Only the owned fixture administrator simulates the independently observed
        # pre-existing ACL. The canonical helper must neither open nor close it.
        self.psql('GRANT EXECUTE ON FUNCTION pg_catalog.pg_control_system() TO uten;')
        try:
            before = self.scalar("SELECT coalesce(proacl::text,'default') FROM pg_proc WHERE oid='pg_catalog.pg_control_system()'::regprocedure;")
            self.apply()
            self.assertEqual(self.scalar("SELECT coalesce(proacl::text,'default') FROM pg_proc WHERE oid='pg_catalog.pg_control_system()'::regprocedure;"), before)
            self.assertEqual(self.scalar("SELECT has_function_privilege('uten','pg_catalog.pg_control_system()','EXECUTE');"), 't')
        finally:
            self.psql('REVOKE EXECUTE ON FUNCTION pg_catalog.pg_control_system() FROM uten;')

    def test_unreviewed_database_and_schema_delegation_is_rejected_before_any_grant(self):
        for grant, undo in (
                ('GRANT CONNECT ON DATABASE uten_imp TO uten WITH GRANT OPTION;',
                 'REVOKE GRANT OPTION FOR CONNECT ON DATABASE uten_imp FROM uten RESTRICT;'),
                ('GRANT TEMPORARY ON DATABASE uten_imp TO uten WITH GRANT OPTION;',
                 'REVOKE GRANT OPTION FOR TEMPORARY ON DATABASE uten_imp FROM uten RESTRICT;'),
                ('GRANT USAGE ON SCHEMA public TO uten WITH GRANT OPTION;',
                 'REVOKE GRANT OPTION FOR USAGE ON SCHEMA public FROM uten RESTRICT;')):
            self.psql(grant, user='uten_migrator')
            try:
                result = self.psql('BEGIN;\n' + POLICY.read_text(encoding='utf-8') + '\nCOMMIT;',
                                   user='uten_migrator', check=False)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('delegation is unreviewed', result.stderr)
                self.assertEqual(self.scalar("SELECT has_table_privilege('uten','permission_surfaces','SELECT');"), 'f')
            finally:
                self.psql(undo, user='uten_migrator')

    def test_rejects_runtime_owner_or_privileged_runtime_before_acl_changes(self):
        for change, undo in [('ALTER ROLE uten SUPERUSER;', 'ALTER ROLE uten NOSUPERUSER;'),
                             ('GRANT uten_migrator TO uten;', 'REVOKE uten_migrator FROM uten;')]:
            self.psql(change)
            result = self.psql('BEGIN;\n' + POLICY.read_text(encoding='utf-8') + '\nCOMMIT;',
                               user='uten_migrator', check=False)
            self.assertNotEqual(result.returncode, 0)
            self.psql(undo)
            self.assertEqual(self.scalar("SELECT has_table_privilege('uten','permission_surfaces','SELECT');"), 'f')

    def test_employee_identity_extension_seals_survive_repeated_runtime_acl_reconciliation(self):
        relations = ('employee_identity_merges', 'employee_identity_merge_payloads',
                     'employee_legacy_identity_aliases', 'employee_identity_historical_claims',
                     'employee_identity_user_tombstones', 'employee_identity_legacy_roles',
                     'employee_identity_review_certificates', 'employee_identity_merge_installation',
                     'employee_code_reuse_installation', 'employee_code_reuse_releases', 'employee_code_reuse_claims')
        self.psql(''.join('CREATE TABLE public.' + name + '(id integer PRIMARY KEY);'
                          'REVOKE ALL ON public.' + name + ' FROM PUBLIC,uten;' for name in relations)
                  + '''GRANT SELECT ON employee_identity_merges,employee_identity_historical_claims,
                           employee_legacy_identity_aliases TO uten;
                  CREATE FUNCTION fn_employee_merge_source_snapshot(uuid) RETURNS text LANGUAGE sql
                    SECURITY DEFINER AS $$ SELECT 'synthetic-private-ciphertext' $$;
                  CREATE FUNCTION fn_merge_employee_identity(jsonb) RETURNS jsonb LANGUAGE sql
                    SECURITY DEFINER AS $$ SELECT $1 $$;
                  CREATE FUNCTION fn_release_merged_employee_code(uuid) RETURNS text LANGUAGE sql
                    SECURITY DEFINER AS $$ SELECT 'synthetic-retired-code' $$;
                  CREATE FUNCTION fn_employee_merge_completed(uuid,uuid,text) RETURNS boolean LANGUAGE sql
                    SECURITY DEFINER AS $$ SELECT true $$;
                  CREATE FUNCTION fn_claim_next_released_employee_code(uuid) RETURNS text LANGUAGE sql
                    SECURITY DEFINER AS $$ SELECT 'synthetic-next-code' $$;
                  CREATE FUNCTION fn_claim_global_business_identifier() RETURNS text LANGUAGE sql
                    AS $$ SELECT 'synthetic-reservation' $$;
                  CREATE FUNCTION fn_employee_code_reuse_evidence_immutable() RETURNS trigger LANGUAGE plpgsql
                    AS $$ BEGIN RETURN NULL; END $$;
                  GRANT EXECUTE ON FUNCTION fn_employee_code_reuse_evidence_immutable() TO PUBLIC;
                  REVOKE ALL ON FUNCTION fn_employee_merge_source_snapshot(uuid),fn_merge_employee_identity(jsonb),
                    fn_release_merged_employee_code(uuid),fn_employee_merge_completed(uuid,uuid,text),
                    fn_claim_next_released_employee_code(uuid),fn_claim_global_business_identifier() FROM PUBLIC,uten;
                  GRANT EXECUTE ON FUNCTION fn_employee_merge_completed(uuid,uuid,text),
                    fn_claim_next_released_employee_code(uuid),fn_claim_global_business_identifier() TO uten;''',
                  user='uten_migrator')
        def seal():
            return self.scalar('''SELECT jsonb_build_object(
                'relations',(SELECT jsonb_agg(jsonb_build_array(relname,relacl::text) ORDER BY relname)
                  FROM pg_class WHERE relnamespace='public'::regnamespace AND relname LIKE 'employee_%'),
                'functions',(SELECT jsonb_agg(jsonb_build_array(proname,proacl::text) ORDER BY proname)
                  FROM pg_proc WHERE pronamespace='public'::regnamespace
                    AND (proname LIKE 'fn_employee_%' OR proname IN('fn_merge_employee_identity',
                      'fn_release_merged_employee_code','fn_claim_next_released_employee_code','fn_claim_global_business_identifier'))));''')
        before = seal()
        for _ in range(2):
            self.apply()
            self.assertEqual(self.scalar("SELECT has_table_privilege('uten','employee_identity_merge_payloads','SELECT');"), 'f')
            self.assertEqual(self.scalar("SELECT has_function_privilege('uten','fn_merge_employee_identity(jsonb)','EXECUTE');"), 'f')
            self.assertEqual(self.scalar("SELECT has_function_privilege('uten','fn_release_merged_employee_code(uuid)','EXECUTE');"), 'f')
            self.assertEqual(self.scalar("SELECT has_function_privilege('uten','fn_claim_next_released_employee_code(uuid)','EXECUTE');"), 't')
            self.assertEqual(seal(), before, 'ACL reconciliation changed the frozen extension catalog')
        self.psql('GRANT SELECT ON employee_identity_merge_payloads TO PUBLIC;', user='uten_migrator')
        result = self.psql('BEGIN;\n' + POLICY.read_text(encoding='utf-8') + '\nCOMMIT;',
                           user='uten_migrator', check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Sealed employee identity', result.stderr)

    def test_failed_retirement_is_not_bypassed_and_no_acl_is_written(self):
        self.psql('CREATE FUNCTION business_data_reset() RETURNS void LANGUAGE plpgsql AS $$ BEGIN END $$;',
                  user='uten_migrator')
        result = self.psql('BEGIN;\n' + POLICY.read_text(encoding='utf-8') + '\nCOMMIT;',
                           user='uten_migrator', check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.scalar("SELECT has_table_privilege('uten','permission_surfaces','SELECT');"), 'f')


if __name__ == '__main__':
    unittest.main()

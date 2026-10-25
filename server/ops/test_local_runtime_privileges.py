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
          CREATE TABLE flyway_schema_history(id int PRIMARY KEY);
          CREATE TABLE audit_log(id int,created_month int) PARTITION BY RANGE(created_month);
          CREATE TABLE audit_log_p202610 PARTITION OF audit_log FOR VALUES FROM(202610) TO(202611);
          CREATE TABLE audit_log_archive(id int);
          CREATE FUNCTION normal_business_read() RETURNS int LANGUAGE sql AS $$ SELECT 7 $$;
          CREATE FUNCTION fn_require_runtime_refresh() RETURNS void LANGUAGE plpgsql AS $$ BEGIN END $$;
          CREATE FUNCTION fn_register_legacy_probe() RETURNS void LANGUAGE plpgsql AS $$ BEGIN END $$;
          REVOKE ALL ON FUNCTION fn_require_runtime_refresh(),fn_register_legacy_probe() FROM PUBLIC;
        ''', user='uten_migrator')

    def apply(self):
        return self.psql('BEGIN;\n' + POLICY.read_text(encoding='utf-8') + '\nCOMMIT;', user='uten_migrator')

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
                    'TRUNCATE business_rows;', 'SET ROLE uten_migrator;'):
            self.assertNotEqual(self.psql(sql, user='uten', check=False).returncode, 0, sql)
        self.psql('SELECT * FROM legacy_finance_import_sources;', user='uten')
        self.psql('INSERT INTO audit_log VALUES(1,202610);', user='uten')

    def test_future_tables_sequences_and_functions_get_runtime_permissions(self):
        self.apply()
        self.psql('CREATE TABLE later_business(id serial PRIMARY KEY);'
                  'CREATE FUNCTION later_read() RETURNS int LANGUAGE sql AS $$ SELECT 9 $$;', user='uten_migrator')
        self.psql('INSERT INTO later_business DEFAULT VALUES; SELECT later_read();', user='uten')

    def test_rejects_runtime_owner_or_privileged_runtime_before_acl_changes(self):
        for change, undo in [('ALTER ROLE uten SUPERUSER;', 'ALTER ROLE uten NOSUPERUSER;'),
                             ('GRANT uten_migrator TO uten;', 'REVOKE uten_migrator FROM uten;')]:
            self.psql(change)
            result = self.psql('BEGIN;\n' + POLICY.read_text(encoding='utf-8') + '\nCOMMIT;',
                               user='uten_migrator', check=False)
            self.assertNotEqual(result.returncode, 0)
            self.psql(undo)
            self.assertEqual(self.scalar("SELECT has_table_privilege('uten','permission_surfaces','SELECT');"), 'f')

    def test_failed_retirement_is_not_bypassed_and_no_acl_is_written(self):
        self.psql('CREATE FUNCTION business_data_reset() RETURNS void LANGUAGE plpgsql AS $$ BEGIN END $$;',
                  user='uten_migrator')
        result = self.psql('BEGIN;\n' + POLICY.read_text(encoding='utf-8') + '\nCOMMIT;',
                           user='uten_migrator', check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.scalar("SELECT has_table_privilege('uten','permission_surfaces','SELECT');"), 'f')


if __name__ == '__main__':
    unittest.main()

"""The first-import guard must work after V919 and reject schema/data drift.

Every native case owns a network-none PostgreSQL fixture. It never reads source
data or connects to an application database.
"""
from pathlib import Path
import re
import subprocess
import time
import unittest
import uuid

import compose_bootstrap

HERE = Path(__file__).resolve().parent
GUARD = (HERE / 'migrate_bootstrap_target_guard.sql').read_text(encoding='utf-8')
INVENTORY = re.findall(r"\('([a-z][a-z0-9_]*)','(EMPTY|SEED_OR_ADMIN)'\)", GUARD)


class BootstrapInventoryContractTest(unittest.TestCase):
    def test_readonly_guard_is_independent_of_retired_runtime_reset(self):
        compose_bootstrap.compose(GUARD.encode('utf-8'), 'migrate_bootstrap_target_guard.sql')
        executable = '\n'.join(line for line in GUARD.splitlines() if not line.lstrip().startswith('--'))
        self.assertNotIn('business_data_reset', executable)
        self.assertNotIn('pg_get_functiondef', executable)
        self.assertEqual(len(INVENTORY), len(dict(INVENTORY)))
        inventory = dict(INVENTORY)
        for table in ('ar_ap_ledger', 'production_plan_costs', 'stock_movements', 'business_record_identities'):
            self.assertEqual(inventory[table], 'EMPTY')
        self.assertEqual(inventory['users'], 'SEED_OR_ADMIN')

    def test_new_projection_assignments_and_sealed_identity_evidence_are_never_seed_exemptions(self):
        inventory = dict(INVENTORY)
        for table in (
                'business_archive_eligibility', 'business_archive_packages', 'business_outbox_payload_history',
                'department_permission_template_bindings', 'user_permission_template_bindings', 'permission_template_applies',
                'employee_code_reuse_claims', 'employee_code_reuse_releases', 'employee_identity_document_claims',
                'employee_identity_historical_claims', 'employee_identity_legacy_roles', 'employee_identity_merge_payloads',
                'employee_identity_merges', 'employee_identity_review_certificates', 'employee_identity_user_tombstones',
                'employee_legacy_identity_aliases', 'party_month_dirty', 'party_monthly_summaries',
                'scheduled_task_runs', 'stock_monthly_summaries'):
            with self.subTest(table=table):
                self.assertEqual(inventory[table], 'EMPTY')

    def test_actual_flyway_seed_metadata_is_preserved_without_clearing_it(self):
        inventory = dict(INVENTORY)
        for table in ('data_lifecycle_policies', 'stock_monthly_verification_state',
                      'employee_identity_merge_installation', 'employee_code_reuse_installation'):
            with self.subTest(table=table):
                self.assertEqual(inventory[table], 'SEED_OR_ADMIN')


class BootstrapInventoryPostgresTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.container = 'uten-bootstrap-inventory-' + uuid.uuid4().hex[:12]
        subprocess.run(['docker', 'run', '--detach', '--network', 'none', '--name', cls.container,
                        '-e', 'POSTGRES_PASSWORD=isolated-contract-only', 'postgres:16-alpine'],
                       check=True, capture_output=True)
        for _ in range(120):
            # The image's temporary initialization server has only a Unix
            # socket; require the final TCP server before starting assertions.
            if subprocess.run(['docker', 'exec', cls.container, 'pg_isready', '-h', '127.0.0.1', '-U', 'postgres', '-d', 'postgres'],
                              capture_output=True).returncode == 0:
                return
            time.sleep(.25)
        subprocess.run(['docker', 'rm', '--force', cls.container], capture_output=True)
        raise RuntimeError('Private PostgreSQL fixture did not start')

    @classmethod
    def tearDownClass(cls):
        subprocess.run(['docker', 'rm', '--force', cls.container], check=True, capture_output=True)

    def execute(self, change='', error=None, postcheck=''):
        columns = {
            'legacy_migration_runs': '''run_id uuid,status text,target text,migration_mode text,
                finished_at timestamptz,exit_code int,mapping_version text,migration_repository_commit text,
                export_manifest_sha256 text,reconciliation_summary jsonb,reconciliation_status text,rejected_count int''',
            'employees': 'code text, legacy_id int',
            'currencies': 'is_base_currency boolean',
            'material_categories': 'legacy_id int, legacy_code_snapshot text',
            'system_master_category_registry': 'client_category_id uuid,supplier_category_id uuid,mould_category_id uuid',
            'business_record_identities': 'source_table text',
        }
        fixture = 'BEGIN;\n' + '\n'.join(
            'CREATE TABLE public.' + name + '(id uuid' + (',' + columns[name] if name in columns else '') + ');'
            for name, _ in INVENTORY)
        sql = fixture + '\n' + change + '\n' + GUARD + '\n' + postcheck + '\nROLLBACK;'
        result = subprocess.run(['docker', 'exec', '-i', '-e', 'PGPASSWORD=isolated-contract-only', self.container,
                                 'psql', '-h', '127.0.0.1', '-d', 'postgres', '-X', '-q',
                                 '-v', 'ON_ERROR_STOP=1', '-U', 'postgres'], input=sql.encode('utf-8'),
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        diagnostics = result.stderr.decode('utf-8', errors='replace')
        if error:
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(error, diagnostics)
        else:
            self.assertEqual(result.returncode, 0, diagnostics)

    def test_empty_reviewed_schema_passes_without_any_reset_function(self):
        self.execute(postcheck="DO $$ BEGIN IF to_regprocedure('public.business_data_reset()') IS NOT NULL THEN RAISE EXCEPTION 'retired function unexpectedly exists'; END IF; END $$;")

    def test_new_unclassified_root_table_fails_closed(self):
        self.execute('CREATE TABLE public.unreviewed_business_fact(id int);',
                     error='unclassified unreviewed_business_fact')

    def test_missing_reviewed_table_fails_closed(self):
        self.execute('DROP TABLE public.stock_movements;', error='missing stock_movements')

    def test_existing_business_fact_is_rejected(self):
        self.execute('INSERT INTO public.production_plan_costs DEFAULT VALUES;',
                     error='bootstrap target already contains business facts in production_plan_costs')

    def test_configuration_identity_is_preserved_without_allowing_business_identity(self):
        self.execute("INSERT INTO public.business_record_identities(source_table) VALUES('departments');",
                     postcheck="DO $$ BEGIN IF (SELECT count(*) FROM public.business_record_identities)<>1 THEN RAISE EXCEPTION 'configuration identity changed'; END IF; END $$;")
        self.execute("INSERT INTO public.business_record_identities(source_table) VALUES('stock_movements');",
                     error='bootstrap target already contains business facts in business_record_identities')


if __name__ == '__main__':
    unittest.main()

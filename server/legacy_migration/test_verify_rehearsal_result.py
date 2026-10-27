import contextlib
from copy import deepcopy
import csv
import hashlib
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import verify_rehearsal_result as verifier

COMMIT = '1' * 40
RUN = 'f1000000-0000-4000-8000-000000000001'
ADMIN = 'f2000000-0000-4000-8000-000000000001'
MEDIA = 'f3000000-0000-4000-8000-000000000001'
PRIVATE_HASH = 'TEST_ONLY_PRIVATE_PASSWORD_HASH_MUST_NOT_APPEAR'
PRIVATE_ACCOUNT = 'TEST_ONLY_PRIVATE_LOGIN_MUST_NOT_APPEAR'
GRAPH = hashlib.sha256(b'1:10:11:1.00000\n2:10:12:2.00000\n').hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value), encoding='utf-8')


class Fixture:
    def __init__(self, root):
        self.root = root
        self.inputs = root / 'inputs'
        self.inputs.mkdir()
        self.layer = root / 'topology'
        self.layer.mkdir()
        self.snapshot = root / 'admin.private.json'
        write_json(self.snapshot, {'id': ADMIN, 'password_hash': PRIVATE_HASH, 'login_account': PRIVATE_ACCOUNT})
        rows = {
            'hr_rehearsal.csv': (['emp_code', 'status'], [['UT0001', 'active'], ['UT0002', 'active'], ['UT0003', 'resigned']]),
            'goods.csv': (['legacy_id'], [['10'], ['11'], ['12']]),
            'goods_bom.csv': (['legacy_id'], [['1'], ['2'], ['3']]),
            'goods_material_identity.csv': (['status'], [['PENDING_QUANTITY']]),
            'goods_legacy_media.csv': (['attachment_id'], [[MEDIA]]),
        }
        records = []
        for name, (header, data) in rows.items():
            with (self.inputs / name).open('w', encoding='utf-8', newline='') as stream:
                writer = csv.writer(stream, delimiter='|'); writer.writerow(header); writer.writerows(data)
            path = self.inputs / name
            records.append({'file': name, 'rows': len(data), 'bytes': path.stat().st_size, 'sha256': verifier.digest(path)})
        self.summary = {'valid': True, 'source_conservation': True, 'source_edges': 3, 'retained_edges': 2,
                        'excluded_edges': 1, 'cyclic_components': 0, 'duplicate_active_parent_component_groups': 0,
                        'graph_sha256': GRAPH}
        self.topology = {'valid': True, 'inputs': [{'path': str(self.inputs / record['file']), 'sha256': record['sha256']}
                         for record in records if record['file'] in ('goods.csv', 'goods_bom.csv')]}
        self.manifest = {'formatVersion': 4, 'target': 'All', 'files': records,
                         'provenance': {'inputKind': 'derived-local-rehearsal-v1', 'importerRepositoryCommit': COMMIT,
                                        'extraInputs': {}, 'auxiliaryLayers': {}}}
        self.reseal_topology()

    def reseal_topology(self):
        summary_path = self.layer / 'bom_topology_summary.json'
        write_json(summary_path, self.summary)
        self.topology['outputs'] = [{'file': summary_path.name, 'bytes': summary_path.stat().st_size, 'sha256': verifier.digest(summary_path)}]
        topology_path = self.layer / 'bom_topology_manifest.json'
        write_json(topology_path, self.topology)
        self.manifest['provenance']['auxiliaryLayers'][str(self.layer)] = {'manifest': topology_path.name, 'sha256': verifier.digest(topology_path)}
        self.reseal()

    def reseal(self):
        for record in self.manifest['files']:
            path = self.inputs / record['file']
            record['sha256'] = verifier.digest(path)
            record['bytes'] = path.stat().st_size
        write_json(self.inputs / 'derived_inputs.json', self.manifest)
        self.manifest_sha = verifier.digest(self.inputs / 'derived_inputs.json')

    def expected(self):
        return verifier.load_inputs(self.inputs, self.manifest_sha, COMMIT)


def successful_run(expected):
    return {'status': 'SUCCESS', 'reconciliation_status': 'PASSED', 'target': '--bootstrap-all', 'mode': 'BOOTSTRAP',
            'exit_code': 0, 'rejected_count': 0, 'mapping_version': 'bootstrap-v13', 'manifest_sha256': expected['manifest_sha256'],
            'checksum_sha256': expected['manifest_sha256'], 'frozen_commit': COMMIT, 'automated_checks': 7,
            'bom_graph_sha256': GRAPH, 'bom_items': 2, 'bom_identity_verified': True, 'bom_exclusions_verified': True}


def successful_facts(expected):
    return {'run': successful_run(expected), 'user_count': 1,
            'admin': {'id': ADMIN, 'login_account': PRIVATE_ACCOUNT, 'password_hash': PRIVATE_HASH,
                      'status': 'active', 'super': True, 'deleted': False, 'bound_admin': True},
            'counts': {'employees': 4, 'employee_statuses': {'active': 3, 'resigned': 1}, 'regular_goods': 3, 'goods': 3,
                       'bom_items': 2, 'material_identities': 1, 'attachments': 1, 'deleted_employees': 0,
                       'disabled_bom_components': 0, 'invalid_material_identities': 0,
                       'identity_relations_in_active_bom': 0, 'failed_migrations': 0, 'matched_clean_attachments': 1,
                       'schema_version': 907}, 'checks': {'total': 7, 'passed': 7},
            'bom_graph_sha256': GRAPH, 'run_files': deepcopy(expected['files'])}


class FakeDatabase:
    def __init__(self, expected):
        self.database = 'local_rehearsal'
        self.results = [successful_run(expected), successful_facts(expected)]
        for result in (self.results[0], self.results[1]['run']):
            result.update(target_database='local_rehearsal', actual_database='local_rehearsal',
                          target_system_identifier='fixture-cluster', actual_system_identifier='fixture-cluster', actual_database_oid=1001)
        self.queries = []

    def query(self, sql):
        self.queries.append(sql)
        return self.results[len(self.queries) - 1]


class InputTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.fixture = Fixture(Path(self.temp.name))

    def tearDown(self):
        self.temp.cleanup()

    def test_dynamic_counts_include_only_separate_admin_once(self):
        expected = self.fixture.expected()
        self.assertEqual(expected['employees'], 4)
        self.assertEqual(expected['employee_statuses'], {'active': 3, 'resigned': 1})
        self.assertEqual(expected['bom_items'], 2)
        self.assertEqual(expected['material_identities'], 1)
        self.assertEqual(expected['attachments'], 1)

    def test_manifest_drift_is_rejected_before_parsing(self):
        with self.assertRaisesRegex(verifier.VerificationError, 'manifest SHA'):
            verifier.load_inputs(self.fixture.inputs, 'a' * 64, COMMIT)

    def test_any_csv_sha_drift_is_rejected(self):
        with (self.fixture.inputs / 'goods.csv').open('a') as stream:
            stream.write('888\n')
        with self.assertRaisesRegex(verifier.VerificationError, 'input SHA'):
            self.fixture.expected()

    def test_different_frozen_commit_is_rejected(self):
        with self.assertRaisesRegex(verifier.VerificationError, 'frozen commit differs'):
            verifier.load_inputs(self.fixture.inputs, self.fixture.manifest_sha, '2' * 40)

    def test_hr_duplicated_code_is_rejected_even_when_resealed(self):
        (self.fixture.inputs / 'hr_rehearsal.csv').write_text('emp_code|status\nUT0001|active\nUT0001|active\nUT0003|resigned\n')
        self.fixture.reseal()
        with self.assertRaisesRegex(verifier.VerificationError, 'employee codes'):
            self.fixture.expected()

    def test_admin_cannot_be_duplicated_in_hr_csv(self):
        (self.fixture.inputs / 'hr_rehearsal.csv').write_text('emp_code|status\nADMIN|active\nUT0002|active\nUT0003|resigned\n')
        self.fixture.reseal()
        with self.assertRaisesRegex(verifier.VerificationError, 'contain ADMIN'):
            self.fixture.expected()

    def test_nonpending_material_csv_is_rejected(self):
        (self.fixture.inputs / 'goods_material_identity.csv').write_text('status\nAPPROVED\n')
        self.fixture.reseal()
        with self.assertRaisesRegex(verifier.VerificationError, 'pending quantities'):
            self.fixture.expected()

    def test_topology_summary_drift_is_rejected(self):
        (self.fixture.layer / 'bom_topology_summary.json').write_text('{}')
        with self.assertRaisesRegex(verifier.VerificationError, 'SHA'):
            self.fixture.expected()

    def test_resealed_nonconserved_graph_is_rejected(self):
        self.fixture.summary['excluded_edges'] = 0
        self.fixture.reseal_topology()
        with self.assertRaisesRegex(verifier.VerificationError, 'not conserved'):
            self.fixture.expected()

    def test_topology_parent_sha_must_match_final_csv(self):
        self.fixture.topology['inputs'][0]['sha256'] = 'a' * 64
        self.fixture.reseal_topology()
        with self.assertRaisesRegex(verifier.VerificationError, 'source SHA'):
            self.fixture.expected()

    def test_offline_cli_never_queries_target_or_emits_snapshot_values(self):
        output = self.fixture.root / 'offline.json'
        args = ['--inputs', str(self.fixture.inputs), '--admin-snapshot', str(self.fixture.snapshot),
                '--run-id', RUN, '--database', 'local_rehearsal', '--manifest-sha256', self.fixture.manifest_sha,
                '--frozen-commit', COMMIT, '--output', str(output), '--offline-only']
        stdout = io.StringIO()
        with patch.object(verifier.ReadOnlyDatabase, 'query', side_effect=AssertionError('Database must not be queried')), contextlib.redirect_stdout(stdout):
            self.assertEqual(verifier.main(args), 0)
        receipt = json.loads(output.read_text())
        self.assertEqual(receipt['status'], 'INPUTS_VERIFIED_TARGET_NOT_QUERIED')
        self.assertEqual(receipt['acceptance_scope'], 'SEALED_LEGACY_BOOTSTRAP_ONLY')
        self.assertEqual(receipt['current_staff_preservation'], 'NOT_EVALUATED')
        self.assertFalse(receipt['company_data_replacement_authorized'])
        for private in (PRIVATE_HASH, PRIVATE_ACCOUNT, ADMIN):
            self.assertNotIn(private, stdout.getvalue() + output.read_text())


class DatabaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.fixture = Fixture(Path(self.temp.name))
        self.expected = self.fixture.expected()
        self.db = FakeDatabase(self.expected)
        self.original = json.loads(self.fixture.snapshot.read_text())

    def tearDown(self):
        self.temp.cleanup()

    def verify(self, schema=None):
        return verifier.verify_database(self.db, self.expected, self.original, RUN, schema)

    def pre_rename_proof(self):
        return {'status': 'PASSED', 'run_id': RUN, 'manifest_sha256': self.expected['manifest_sha256'],
                'frozen_commit': COMMIT, 'database': 'local_rehearsal', 'database_name_mode': 'UNCHANGED',
                'recorded_import_database': 'local_rehearsal', 'database_identity': {'system_identifier': 'fixture-cluster', 'database_oid': 1001},
                'counts': deepcopy(self.db.results[1]['counts']), 'bom_graph_sha256': GRAPH,
                'protected_account_uuid_and_password_hash_preserved': True,
                'protected_account_active_super_and_admin_bound': True}

    def test_success_projects_only_counts_and_safe_proofs(self):
        report = self.verify(907)
        self.assertEqual(report['status'], 'PASSED')
        self.assertFalse(report['actual_password_login_tested'])
        for private in (PRIVATE_HASH, PRIVATE_ACCOUNT, ADMIN):
            self.assertNotIn(private, json.dumps(report))
        self.assertNotIn('admin', report)
        self.assertNotIn('run', report)

    def test_running_run_stops_before_account_or_business_query(self):
        self.db.results[0]['status'] = 'RUNNING'
        with self.assertRaisesRegex(verifier.VerificationError, 'must be SUCCESS'):
            self.verify()
        self.assertEqual(len(self.db.queries), 1)
        self.assertNotIn('FROM users', self.db.queries[0])

    def test_manifest_commit_and_reconciliation_identity_are_required(self):
        for key, value in [('manifest_sha256', 'a' * 64), ('frozen_commit', '2' * 40), ('reconciliation_status', 'NOT_RUN')]:
            with self.subTest(key=key):
                self.db = FakeDatabase(self.expected); self.db.results[0][key] = value
                with self.assertRaises(verifier.VerificationError):
                    self.verify()

    def test_run_identity_is_rechecked_in_business_snapshot(self):
        self.db.results[1]['run']['status'] = 'FAILED'
        with self.assertRaisesRegex(verifier.VerificationError, 'must be SUCCESS'):
            self.verify()

    def test_password_login_account_uuid_and_eligibility_changes_are_rejected(self):
        for key, value in [('password_hash', 'changed'), ('login_account', 'changed'), ('id', RUN),
                           ('super', False), ('status', 'disabled'), ('deleted', True), ('bound_admin', False)]:
            with self.subTest(key=key):
                self.db = FakeDatabase(self.expected); self.db.results[1]['admin'][key] = value
                with self.assertRaises(verifier.VerificationError):
                    self.verify()

    def test_extra_login_user_is_rejected(self):
        self.db.results[1]['user_count'] = 2
        with self.assertRaisesRegex(verifier.VerificationError, 'Exactly'):
            self.verify()

    def test_changed_cluster_is_rejected_even_when_the_run_identity_matches(self):
        self.db.results[0]['actual_system_identifier'] = 'different-cluster'
        with self.assertRaisesRegex(verifier.VerificationError, 'cluster differs'):
            self.verify()

    def test_database_rename_needs_explicit_matching_declaration(self):
        self.db.database = 'uten_imp'
        for result in (self.db.results[0], self.db.results[1]['run']):
            result['actual_database'] = 'uten_imp'
        with self.assertRaisesRegex(verifier.VerificationError, '--renamed-from'):
            self.verify()
        self.db.queries.clear()
        with self.assertRaisesRegex(verifier.VerificationError, '--pre-rename-proof'):
            verifier.verify_database(self.db, self.expected, self.original, RUN, renamed_from='local_rehearsal')
        self.db.queries.clear()
        result = verifier.verify_database(self.db, self.expected, self.original, RUN, renamed_from='local_rehearsal', pre_rename_proof=self.pre_rename_proof())
        self.assertEqual(result['database_name_mode'], 'EXPLICIT_RENAME')
        self.assertEqual(result['recorded_import_database'], 'local_rehearsal')

    def test_explicit_rename_never_waives_manifest_account_or_graph_proof(self):
        for damaged in ('manifest', 'account', 'graph'):
            with self.subTest(damaged=damaged):
                self.db = FakeDatabase(self.expected); self.db.database = 'uten_imp'
                for result in (self.db.results[0], self.db.results[1]['run']):
                    result['actual_database'] = 'uten_imp'
                if damaged == 'manifest': self.db.results[0]['manifest_sha256'] = 'a' * 64
                if damaged == 'account': self.db.results[1]['admin']['password_hash'] = 'changed'
                if damaged == 'graph': self.db.results[1]['bom_graph_sha256'] = 'a' * 64
                with self.assertRaises(verifier.VerificationError):
                    verifier.verify_database(self.db, self.expected, self.original, RUN, renamed_from='local_rehearsal', pre_rename_proof=self.pre_rename_proof())

    def test_same_cluster_copy_with_a_different_database_oid_is_rejected_after_rename(self):
        self.db.database = 'uten_imp'
        previous = self.pre_rename_proof()
        for result in (self.db.results[0], self.db.results[1]['run']):
            result.update(actual_database='uten_imp', actual_database_oid=2002)
        with self.assertRaisesRegex(verifier.VerificationError, 'database_identity'):
            verifier.verify_database(self.db, self.expected, self.original, RUN, renamed_from='local_rehearsal', pre_rename_proof=previous)

    def test_pre_rename_receipt_different_run_or_counts_is_rejected(self):
        for damaged in ('run_id', 'counts'):
            with self.subTest(damaged=damaged):
                self.db = FakeDatabase(self.expected); self.db.database = 'uten_imp'
                previous = self.pre_rename_proof()
                previous[damaged] = RUN.replace('f1', 'a1') if damaged == 'run_id' else {}
                for result in (self.db.results[0], self.db.results[1]['run']): result['actual_database'] = 'uten_imp'
                with self.assertRaisesRegex(verifier.VerificationError, damaged):
                    verifier.verify_database(self.db, self.expected, self.original, RUN, renamed_from='local_rehearsal', pre_rename_proof=previous)

    def test_dynamic_counts_do_not_accept_a_fixed_previous_population(self):
        self.db.results[1]['counts']['employees'] = 193
        with self.assertRaisesRegex(verifier.VerificationError, 'employees'):
            self.verify()

    def test_bom_graph_quantity_or_parent_change_is_rejected(self):
        self.db.results[1]['bom_graph_sha256'] = 'a' * 64
        with self.assertRaisesRegex(verifier.VerificationError, 'current BOM graph'):
            self.verify()

    def test_disabled_bom_material_nonpending_or_real_bom_identity_is_rejected(self):
        for key in ('disabled_bom_components', 'invalid_material_identities', 'identity_relations_in_active_bom'):
            with self.subTest(key=key):
                self.db = FakeDatabase(self.expected); self.db.results[1]['counts'][key] = 1
                with self.assertRaisesRegex(verifier.VerificationError, key):
                    self.verify()

    def test_missing_clean_media_and_wrong_schema_are_rejected(self):
        self.db.results[1]['counts']['matched_clean_attachments'] = 0
        with self.assertRaisesRegex(verifier.VerificationError, 'media identities'):
            self.verify()
        self.db = FakeDatabase(self.expected)
        with self.assertRaisesRegex(verifier.VerificationError, 'schema version'):
            self.verify(906)

    def test_consumed_file_and_structural_check_mismatch_are_rejected(self):
        self.db.results[1]['run_files']['goods.csv']['sha256'] = 'a' * 64
        with self.assertRaisesRegex(verifier.VerificationError, 'Consumed run file'):
            self.verify()
        self.db = FakeDatabase(self.expected); self.db.results[1]['checks']['passed'] = 6
        with self.assertRaisesRegex(verifier.VerificationError, 'structural checks'):
            self.verify()

    def test_real_query_adapter_has_readonly_repeatable_transaction_and_no_credentials_in_command(self):
        completed = subprocess.CompletedProcess([], 0, b'{"database":"local_rehearsal","system_identifier":"123456","database_oid":42,"result":{"ok":true}}\n', b'')
        with patch.object(verifier.ReadOnlyDatabase,'_pin_transport',return_value=['docker','exec','-i','uten-imp-postgres']), \
             patch.object(verifier.subprocess, 'run', return_value=completed) as run:
            self.assertEqual(verifier.ReadOnlyDatabase('local_rehearsal').query('SELECT jsonb_build_object(\'ok\',true);'), {'ok': True})
        argv = run.call_args.args[0]
        self.assertEqual(argv[:4], ['docker', 'exec', '-i', 'uten-imp-postgres'])
        self.assertIn('BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;', run.call_args.kwargs['input'].decode())
        self.assertNotIn(PRIVATE_HASH, ' '.join(argv))
        with self.assertRaises(verifier.VerificationError):
            verifier.ReadOnlyDatabase('local;DROP DATABASE x')

    def test_server_error_does_not_emit_raw_sql_or_private_stderr(self):
        completed = subprocess.CompletedProcess([], 1, b'', PRIVATE_HASH.encode())
        with patch.object(verifier.ReadOnlyDatabase,'_pin_transport',return_value=['docker','exec','-i','uten-imp-postgres']), \
             patch.object(verifier.subprocess, 'run', return_value=completed):
            with self.assertRaises(verifier.VerificationError) as error:
                verifier.ReadOnlyDatabase('local_rehearsal').query('SELECT secret;')
        self.assertNotIn(PRIVATE_HASH, str(error.exception))


if __name__ == '__main__':
    unittest.main()

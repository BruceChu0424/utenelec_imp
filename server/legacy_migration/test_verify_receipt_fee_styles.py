from copy import deepcopy
import csv
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

import verify_receipt_fee_styles as fees
import verify_rehearsal_result as verifier
from test_verify_rehearsal_result import Fixture, FakeDatabase, RUN, PRIVATE_ACCOUNT, PRIVATE_HASH
from test_verify_rehearsal_counter_baseline import baseline
from test_verify_receipt_order_references import populate as populate_receipts, valid_facts as valid_receipts

PRIVATE = 'PRIVATE_SOURCE_ORIGINAL_REMARK_MUST_NOT_APPEAR'


def populate(fixture, rows=None):
    populate_receipts(fixture)
    rows = rows if rows is not None else [[71, 1, '0', PRIVATE], [72, 20, '2', ''],
            [73, 0, '3', ''], [74, 99, '0', ''], [75, '', '0', '']]
    with (fixture.inputs / 'm_get.csv').open('w', encoding='utf-8', newline='') as stream:
        writer = csv.writer(stream, delimiter='|'); writer.writerow(['legacy_id', 'qtfymc', 'qtfy', 'remark']); writer.writerows(rows)
    fixture.manifest['files'].append({'file': 'm_get.csv', 'rows': len(rows), 'bytes': 0, 'sha256': 'a' * 64})
    fixture.reseal()
    return fixture.expected()


def valid_facts(source, valid=1):
    return {'total_receipt_proofs': source['rows'], 'proof_rows': source['rows'], 'target_rows': source['rows'],
            'proof_source_ids_sha256': source['source_ids_sha256'], 'target_source_ids_sha256': source['source_ids_sha256'],
            'original_style_ids_sha256': source['original_style_ids_sha256'],
            **{key: source[key] for key in ('positive_original_style_rows', 'original_no_style_rows', 'nonzero_fee_rows',
                'original_no_style_nonzero_fee_rows', 'positive_original_style_nonzero_fee_rows')},
            'valid_expense_style_rows': valid, 'pending_original_style_rows': source['positive_original_style_rows'] - valid,
            'pending_nonzero_fee_rows': 0, **{key: 0 for key in fees.ZERO_INVARIANTS}}


class FeeAcceptanceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.fixture = Fixture(Path(self.temp.name))
        self.expected = populate(self.fixture); self.source = self.expected['receipt_fee_sources']

    def tearDown(self):
        self.temp.cleanup()

    def inventory(self):
        return fees.source_inventory(self.fixture.inputs, {r['file']: r for r in self.fixture.manifest['files']})

    def rewrite(self, rows, header=None):
        with (self.fixture.inputs / 'm_get.csv').open('w', encoding='utf-8', newline='') as stream:
            writer = csv.writer(stream, delimiter='|'); writer.writerow(header or ['legacy_id', 'qtfymc', 'qtfy', 'remark']); writer.writerows(rows)
        for record in self.fixture.manifest['files']:
            if record['file'] == 'm_get.csv': record['rows'] = len(rows)
        self.fixture.reseal()

    def database(self, schema=912, mapping='bootstrap-v15', announce=True):
        db = FakeDatabase(self.expected)
        for run in (db.results[0], db.results[1]['run']):
            run['mapping_version'] = mapping
            if announce: run['actual_schema_version'] = schema
        facts = db.results[1]; facts['counts']['schema_version'] = schema
        facts['quantity_counter_baseline'] = baseline(self.expected['counter_sources'])
        facts['receipt_order_references'] = valid_receipts(self.expected['receipt_order_sources'])
        facts['receipt_fee_styles'] = valid_facts(self.source)
        return db

    def test_inventory_binds_all_ids_and_original_integer_pairs_without_hardcoded_live_counts(self):
        self.assertEqual(self.source['rows'], 5)
        self.assertEqual(self.source['source_ids_sha256'], hashlib.sha256(b'71\n72\n73\n74\n75\n').hexdigest())
        self.assertEqual(self.source['original_style_ids_sha256'], hashlib.sha256(b'71:1\n72:20\n73:0\n74:99\n75:0\n').hexdigest())
        self.assertEqual((self.source['positive_original_style_rows'], self.source['original_no_style_nonzero_fee_rows']), (3, 1))
        self.assertNotIn(PRIVATE, json.dumps(self.source))

    def test_pair_hash_is_order_independent_but_detects_raw_ids_swapped_between_sources(self):
        self.rewrite([[75, '', 0, ''], [74, 99, 0, ''], [73, 0, 3, ''], [72, 20, 2, ''], [71, 1, 0, '']])
        self.assertEqual(self.inventory()['original_style_ids_sha256'], self.source['original_style_ids_sha256'])
        self.rewrite([[75, '', 0, ''], [74, 99, 0, ''], [73, 0, 3, ''], [72, 1, 2, ''], [71, 20, 0, '']])
        self.assertNotEqual(self.inventory()['original_style_ids_sha256'], self.source['original_style_ids_sha256'])

    def test_money_is_only_a_nonzero_count_not_a_new_typed_source_row_hash(self):
        self.rewrite([[71, 1, 0, ''], [72, 20, '123.4567', ''], [73, 0, '-1', ''], [74, 99, 0, ''], [75, '', 0, '']])
        changed = self.inventory()
        self.assertEqual(changed['original_style_ids_sha256'], self.source['original_style_ids_sha256'])
        self.assertEqual(changed['nonzero_fee_rows'], 2)
        self.assertNotIn('123.4567', json.dumps(changed))

    def test_sealed_file_hash_drift_is_rejected(self):
        with (self.fixture.inputs / 'm_get.csv').open('a') as stream: stream.write('999|1|0|\n')
        with self.assertRaisesRegex(ValueError, 'source SHA'): self.inventory()

    def test_bad_negative_duplicate_or_nonfinite_source_values_fail_closed(self):
        for rows in ([[[71, -1, 0, '']], [[0, 1, 0, '']], [[71, 1, 0, ''], [71, 20, 0, '']],
                     [[71, 1, 'NaN', '']], [[71, 1, 'Infinity', '']], [[71, '1.5', 0, '']]]):
            with self.subTest(rows=len(rows)):
                self.rewrite(rows)
                with self.assertRaises(ValueError): self.inventory()

    def test_missing_or_bad_csv_shape_is_not_fabricated_success(self):
        self.assertIsNone(fees.source_inventory(self.fixture.inputs, {}))
        self.rewrite([[71, 1]], ['legacy_id', 'qtfymc'])
        with self.assertRaises(ValueError): self.inventory()

    def test_empty_current_source_has_a_real_empty_identity_proof(self):
        self.rewrite([]); source = self.inventory(); result = fees.validate(valid_facts(source, 0), source)
        self.assertEqual(result['source_proof_rows'], 0)
        self.assertEqual(source['original_style_ids_sha256'], hashlib.sha256(b'').hexdigest())

    def test_sql_is_one_aggregate_select_and_describes_the_complete_v626_v912_target_projection(self):
        sql = fees.acceptance_sql(RUN, self.source)
        self.assertTrue(sql.startswith('SELECT '))
        self.assertEqual(len(set(fees.TARGET_FIELDS)), 34)
        for field in fees.TARGET_FIELDS: self.assertIn("'" + field + "'", sql)
        for forbidden in ('UPDATE ', 'DELETE ', 'COPY ', PRIVATE): self.assertNotIn(forbidden, sql)
        self.assertIn('fn_legacy_finance_snapshot', sql)
        self.assertIn("z.category='EXPENSE'", sql)
        self.assertNotIn("z.status='使用'", sql)
        self.assertNotIn('is_deleted', sql)

    def test_each_identity_hash_typed_link_proof_and_projection_failure_is_rejected(self):
        original = valid_facts(self.source)
        for key, value in original.items():
            with self.subTest(key=key):
                actual = deepcopy(original)
                actual[key] = ('b' * 64 if isinstance(value, str) else
                    self.source['positive_original_style_nonzero_fee_rows'] + 1 if key == 'pending_nonzero_fee_rows' else value + 1)
                with self.assertRaises(ValueError): fees.validate(actual, self.source)

    def test_output_contains_aggregate_counts_and_no_source_payload_money_or_hashes(self):
        result = fees.validate(valid_facts(self.source), self.source)
        self.assertEqual((result['positive_original_style_rows'], result['valid_expense_style_rows'], result['pending_original_style_rows']), (3, 1, 2))
        for private in (PRIVATE, PRIVATE_ACCOUNT, PRIVATE_HASH, self.source['source_ids_sha256']): self.assertNotIn(private, json.dumps(result))

    def test_v912_fact_snapshot_includes_fee_acceptance_in_the_same_query(self):
        db = self.database(); result = verifier.verify_database(db, self.expected, json.loads(self.fixture.snapshot.read_text()), RUN, 912)
        self.assertTrue(result['receipt_fee_styles']['verified'])
        self.assertIn('other_fee_style_legacy_id', db.queries[1]); self.assertIn('legacy_finance_import_sources', db.queries[1])
        self.assertIn('actual_schema_version', db.queries[0])
        for private in (PRIVATE, PRIVATE_ACCOUNT, PRIVATE_HASH): self.assertNotIn(private, json.dumps(result))

    def test_v912_requires_mapping15_or_m_get_inventory_before_business_query(self):
        for mapping in ('bootstrap-v14', None):
            db = self.database(mapping=mapping)
            with self.assertRaisesRegex(verifier.VerificationError, 'V912.*bootstrap-v15'):
                verifier.verify_database(db, self.expected, json.loads(self.fixture.snapshot.read_text()), RUN, 912)
            self.assertEqual(len(db.queries), 1)
        expected = deepcopy(self.expected); expected['receipt_fee_sources'] = None; db = self.database()
        with self.assertRaisesRegex(verifier.VerificationError, 'sealed m_get'):
            verifier.verify_database(db, expected, json.loads(self.fixture.snapshot.read_text()), RUN, 912)
        self.assertEqual(len(db.queries), 1)

    def test_implicit_actual_v912_cannot_use_old_mapping_or_fake_low_expected_schema(self):
        db = self.database(mapping='bootstrap-v14')
        with self.assertRaises(verifier.VerificationError): verifier.verify_database(db, self.expected, json.loads(self.fixture.snapshot.read_text()), RUN)
        db = self.database()
        with self.assertRaises(verifier.VerificationError): verifier.verify_database(db, self.expected, json.loads(self.fixture.snapshot.read_text()), RUN, 909)
        db = self.database(announce=False)
        with self.assertRaisesRegex(verifier.VerificationError, 'V912 actual schema'):
            verifier.verify_database(db, self.expected, json.loads(self.fixture.snapshot.read_text()), RUN)

    def test_pre912_schema_mapping15_does_not_query_the_new_column(self):
        db = self.database(schema=909); result = verifier.verify_database(db, self.expected, json.loads(self.fixture.snapshot.read_text()), RUN)
        self.assertNotIn('receipt_fee_styles', result); self.assertNotIn('other_fee_style_legacy_id', db.queries[1])
        db = self.database(schema=911)
        with self.assertRaisesRegex(verifier.VerificationError, 'V912 target schema'):
            verifier.verify_database(db, self.expected, json.loads(self.fixture.snapshot.read_text()), RUN, 912)
        self.assertEqual(len(db.queries), 1)

    def test_raw_forgery_wrong_typed_style_or_changed_fee_projection_blocks_full_acceptance(self):
        for key in ('original_style_ids_sha256', 'wrong_typed_style_references', 'changed_original_projections', 'wrong_target_fields'):
            db = self.database(); db.results[1]['receipt_fee_styles'][key] = 'b' * 64 if key.endswith('sha256') else 1
            with self.assertRaises(verifier.VerificationError): verifier.verify_database(db, self.expected, json.loads(self.fixture.snapshot.read_text()), RUN, 912)

    def test_schema_cannot_change_between_the_two_read_only_snapshots(self):
        db = self.database(); db.results[1]['counts']['schema_version'] = 913
        with self.assertRaisesRegex(verifier.VerificationError, 'schema changed'):
            verifier.verify_database(db, self.expected, json.loads(self.fixture.snapshot.read_text()), RUN)

    def test_rename_continuity_requires_the_same_fee_acceptance_receipt(self):
        before = verifier.verify_database(self.database(), self.expected, json.loads(self.fixture.snapshot.read_text()), RUN, 912)
        before.update(database='local_rehearsal', manifest_sha256=self.expected['manifest_sha256'], frozen_commit=self.expected['frozen_commit'])
        db = self.database(); db.database = 'local_active'
        for run in (db.results[0], db.results[1]['run']): run['actual_database'] = 'local_active'
        result = verifier.verify_database(db, self.expected, json.loads(self.fixture.snapshot.read_text()), RUN, 912, 'local_rehearsal', before)
        self.assertEqual(result['receipt_fee_styles'], before['receipt_fee_styles'])
        before['receipt_fee_styles']['pending_original_style_rows'] += 1; db.queries.clear()
        with self.assertRaisesRegex(verifier.VerificationError, 'Pre-rename receipt fee'):
            verifier.verify_database(db, self.expected, json.loads(self.fixture.snapshot.read_text()), RUN, 912, 'local_rehearsal', before)


if __name__ == '__main__': unittest.main()

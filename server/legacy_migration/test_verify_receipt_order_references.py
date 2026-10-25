from copy import deepcopy
import csv
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

import verify_receipt_order_references as receipt
import verify_rehearsal_result as verifier
from test_verify_rehearsal_result import Fixture, FakeDatabase, RUN, PRIVATE_ACCOUNT, PRIVATE_HASH
from test_verify_rehearsal_counter_baseline import baseline

PRIVATE_SOURCE = 'PRIVATE_SYNTHETIC_SOURCE_REMARK_MUST_NOT_APPEAR'


def populate(fixture):
    rows = {
        'warehouse_crosswalk.csv': (['legacy_id', 'action'], [['1', 'KEEP'], ['2', 'KEEP'], ['130', 'DROP'], ['', 'TARGET']]),
        'purchase_receipts.csv': (['legacy_id', 'warehouse_legacy_id'], [[101, 1], [102, 1], [103, 130]]),
        'purchase_receipt_items.csv': (['legacy_id', 'bill_legacy_id', 'order_item_legacy_id', 'remark'],
                                       [[11, 101, 31, PRIVATE_SOURCE], [12, 101, 99, ''], [13, 102, 0, ''], [14, 103, 99, '']]),
        'purchase_order_items.csv': (['legacy_id'], [[31], [32]]),
        'subcontract_in_m.csv': (['legacy_id', 'warehouse_legacy_id'], [[201, 2]]),
        'subcontract_in_i.csv': (['legacy_id', 'bill_legacy_id', 'order_item_legacy_id'], [[21, 201, 41], [22, 201, 88], [23, 201, '']]),
        'subcontract_order_i.csv': (['legacy_id'], [[41]]),
        'sales_order_items.csv': (['legacy_id'], [[51]]),
        'sales_shipment_items.csv': (['legacy_id'], [[61]]),
    }
    for name, (header, data) in rows.items():
        with (fixture.inputs / name).open('w', encoding='utf-8', newline='') as stream:
            writer = csv.writer(stream, delimiter='|'); writer.writerow(header); writer.writerows(data)
        if name == 'warehouse_crosswalk.csv':
            fixture.manifest['provenance']['extraInputs'][name] = verifier.digest(fixture.inputs / name)
        else:
            fixture.manifest['files'].append({'file': name, 'rows': len(data), 'bytes': 0, 'sha256': 'a' * 64})
    fixture.reseal()
    return fixture.expected()


def valid_facts(sources):
    result = {'total_item_proofs': sum(s['rows'] for s in sources.values()), 'wrong_run_item_proofs': 0,
              'unregistered_item_proof_routes': 0, 'families': {}}
    for kind, source in sources.items():
        result['families'][kind] = {
            'proof_rows': source['rows'], 'target_rows': source['rows'],
            'proof_source_ids_sha256': source['source_ids_sha256'], 'target_source_ids_sha256': source['source_ids_sha256'],
            **{key: source[key] for key in ('original_order_ids_sha256', 'receipt_parent_ids_sha256',
                'header_rows', 'header_source_ids_sha256', 'upstream_rows', 'upstream_source_ids_sha256',
                'pending_rows', 'pending_distinct_order_ids', 'pending_source_ids_sha256')},
            **{key: 0 for key in ('wrong_file_sha', 'wrong_target_fields', 'invalid_source_row_hashes',
                'missing_or_mismatched_targets', 'changed_original_projections', 'wrong_or_null_target_run',
                'targets_without_exact_proof', 'invalid_original_order_ids', 'wrong_real_upstream_links')},
        }
    return result


class ReceiptReferenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.fixture = Fixture(Path(self.temp.name))
        self.expected = populate(self.fixture)
        self.sources = self.expected['receipt_order_sources']

    def tearDown(self):
        self.temp.cleanup()

    def inventory(self):
        return receipt.source_inventory(self.fixture.inputs, {r['file']: r for r in self.fixture.manifest['files']},
                                        self.fixture.manifest['provenance']['extraInputs'])

    def rewrite(self, name, header, rows):
        with (self.fixture.inputs / name).open('w', encoding='utf-8', newline='') as stream:
            writer = csv.writer(stream, delimiter='|'); writer.writerow(header); writer.writerows(rows)
        for record in self.fixture.manifest['files']:
            if record['file'] == name: record['rows'] = len(rows)
        if name == 'warehouse_crosswalk.csv':
            self.fixture.manifest['provenance']['extraInputs'][name] = verifier.digest(self.fixture.inputs / name)
        self.fixture.reseal()

    def test_derives_exact_included_ids_original_pairs_and_drop_decision(self):
        purchase = self.sources['PURCHASE_ITEM']
        self.assertEqual((purchase['rows'], purchase['excluded_source_rows'], purchase['header_rows']), (3, 1, 2))
        self.assertEqual(purchase['source_ids_sha256'], hashlib.sha256(b'11\n12\n13\n').hexdigest())
        self.assertEqual(purchase['original_order_ids_sha256'], hashlib.sha256(b'11:31\n12:99\n13:0\n').hexdigest())
        self.assertEqual(purchase['receipt_parent_ids_sha256'], hashlib.sha256(b'11:101\n12:101\n13:102\n').hexdigest())
        self.assertEqual((purchase['pending_rows'], purchase['pending_distinct_order_ids']), (1, 1))
        self.assertEqual(self.sources['SUBCONTRACT_ITEM']['rows'], 3)

    def test_source_pair_hash_is_order_independent_but_binds_each_source_id(self):
        self.rewrite('purchase_receipt_items.csv', ['legacy_id', 'bill_legacy_id', 'order_item_legacy_id'],
                     [[14, 103, 99], [13, 102, 0], [12, 101, 99], [11, 101, 31]])
        self.assertEqual(self.inventory()['PURCHASE_ITEM']['original_order_ids_sha256'], self.sources['PURCHASE_ITEM']['original_order_ids_sha256'])
        self.rewrite('purchase_receipt_items.csv', ['legacy_id', 'bill_legacy_id', 'order_item_legacy_id'],
                     [[14, 103, 99], [13, 102, 0], [12, 101, 31], [11, 101, 99]])
        self.assertNotEqual(self.inventory()['PURCHASE_ITEM']['original_order_ids_sha256'], self.sources['PURCHASE_ITEM']['original_order_ids_sha256'])

    def test_existing_drop_decision_excludes_that_rows_optional_reference_validation(self):
        self.rewrite('purchase_receipt_items.csv', ['legacy_id', 'bill_legacy_id', 'order_item_legacy_id'],
                     [[14, 103, -1], [13, 102, 0], [12, 101, 99], [11, 101, 31]])
        self.assertEqual(self.inventory()['PURCHASE_ITEM']['original_order_ids_sha256'], self.sources['PURCHASE_ITEM']['original_order_ids_sha256'])

    def test_crosswalk_is_sha_bound_supplement_not_assumed_manifest_row(self):
        path = self.fixture.inputs / 'warehouse_crosswalk.csv'
        path.write_text(path.read_text().replace('130|DROP', '130|KEEP'), encoding='utf-8')
        with self.assertRaisesRegex(ValueError, 'supplemental source SHA'): self.inventory()

    def test_invalid_duplicate_or_missing_source_relationships_fail_closed(self):
        cases = [
            ('purchase_receipt_items.csv', ['legacy_id', 'bill_legacy_id', 'order_item_legacy_id'], [[11, 101, 31], [11, 102, 99]]),
            ('purchase_receipt_items.csv', ['legacy_id', 'bill_legacy_id', 'order_item_legacy_id'], [[11, 777, 31]]),
            ('purchase_receipt_items.csv', ['legacy_id', 'bill_legacy_id', 'order_item_legacy_id'], [[11, 101, -1]]),
            ('purchase_order_items.csv', ['legacy_id'], [[31], [31]]),
            ('purchase_receipts.csv', ['legacy_id', 'warehouse_legacy_id'], [[101, 1], [101, 2]]),
            ('warehouse_crosswalk.csv', ['legacy_id', 'action'], [[1, 'KEEP'], [1, 'DROP']]),
            ('warehouse_crosswalk.csv', ['legacy_id', 'action'], [['', 'DROP']]),
            ('subcontract_in_m.csv', ['legacy_id', 'warehouse_legacy_id'], [[201, 130]]),
        ]
        for name, header, rows in cases:
            with self.subTest(name=name, rows=len(rows)):
                with tempfile.TemporaryDirectory() as temporary:
                    fixture = Fixture(Path(temporary)); populate(fixture)
                    with (fixture.inputs / name).open('w', newline='') as stream:
                        writer = csv.writer(stream, delimiter='|'); writer.writerow(header); writer.writerows(rows)
                    records = {r['file']: deepcopy(r) for r in fixture.manifest['files']}
                    if name in records: records[name]['rows'] = len(rows)
                    supplements = deepcopy(fixture.manifest['provenance']['extraInputs'])
                    if name in supplements: supplements[name] = verifier.digest(fixture.inputs / name)
                    with self.assertRaises(ValueError): receipt.source_inventory(fixture.inputs, records, supplements)

    def test_incomplete_old_inventory_is_absent_not_a_fabricated_empty_success(self):
        self.assertIsNone(receipt.source_inventory(self.fixture.inputs, {}))

    def test_empty_families_remain_valid_and_do_not_create_missing_references(self):
        for _, _, item, _, head, _, upstream in receipt.ROUTES:
            for name, header in ((item, ['legacy_id', 'bill_legacy_id', 'order_item_legacy_id']),
                                 (head, ['legacy_id', 'warehouse_legacy_id']), (upstream, ['legacy_id'])):
                self.rewrite(name, header, [])
        empty = self.inventory()
        self.assertEqual(receipt.validate(valid_facts(empty), empty)['source_proof_rows'], 0)

    def test_sql_is_aggregate_select_and_contains_all_fixed_v909_projection_fields(self):
        sql = receipt.acceptance_sql(RUN, self.sources)
        self.assertTrue(sql.startswith('SELECT '))
        self.assertNotIn(PRIVATE_SOURCE, sql)
        self.assertNotIn('COPY ', sql)
        self.assertNotIn('UPDATE ', sql)
        for kind in self.sources:
            for field in receipt.COMMON_FIELDS + receipt.EXTRA_FIELDS[kind]: self.assertIn("'" + field + "'", sql)
        self.assertIn('IS DISTINCT FROM', sql)
        self.assertIn('ORDER BY field COLLATE "C"', sql)
        self.assertIn('unnest(p.target_fields)', sql)
        self.assertIn('targets_without_exact_proof', sql)

    def test_aggregate_result_is_safe_and_retains_pending_counts(self):
        result = receipt.validate(valid_facts(self.sources), self.sources)
        self.assertEqual(result['pending_rows'], {'PURCHASE_ITEM': 1, 'SUBCONTRACT_ITEM': 1})
        self.assertTrue(result['real_upstream_links_verified'])
        for private in (PRIVATE_SOURCE, PRIVATE_ACCOUNT, PRIVATE_HASH): self.assertNotIn(private, json.dumps(result))
        self.assertNotIn('source_ids_sha256', result)

    def test_each_coverage_hash_binding_and_real_upstream_invariant_fails_closed(self):
        original = valid_facts(self.sources)
        for key, value in original['families']['PURCHASE_ITEM'].items():
            with self.subTest(key=key):
                actual = deepcopy(original)
                actual['families']['PURCHASE_ITEM'][key] = 'b' * 64 if isinstance(value, str) else value + 1
                with self.assertRaises(ValueError): receipt.validate(actual, self.sources)
        for key in ('total_item_proofs', 'wrong_run_item_proofs', 'unregistered_item_proof_routes'):
            with self.subTest(key=key):
                actual = deepcopy(original); actual[key] += 1
                with self.assertRaises(ValueError): receipt.validate(actual, self.sources)

    def prepared_database(self, schema=909, mapping='bootstrap-v15'):
        db = FakeDatabase(self.expected)
        for run in (db.results[0], db.results[1]['run']): run['mapping_version'] = mapping
        db.results[1]['counts']['schema_version'] = schema
        db.results[1]['quantity_counter_baseline'] = baseline(self.expected['counter_sources'])
        db.results[1]['receipt_order_references'] = valid_facts(self.sources)
        return db

    def test_v909_full_fact_snapshot_includes_independent_receipt_acceptance(self):
        db = self.prepared_database()
        result = verifier.verify_database(db, self.expected, json.loads(self.fixture.snapshot.read_text()), RUN, 909)
        self.assertTrue(result['receipt_order_references']['verified'])
        self.assertIn('order_item_legacy_id', db.queries[1])
        self.assertEqual(result['mapping_version'], 'bootstrap-v15')
        for private in (PRIVATE_SOURCE, PRIVATE_ACCOUNT, PRIVATE_HASH): self.assertNotIn(private, json.dumps(result))

    def test_explicit_v909_cannot_use_mapping14_or_omit_sources_before_fact_query(self):
        for mapping in ('bootstrap-v14', None):
            db = self.prepared_database(mapping=mapping)
            with self.assertRaisesRegex(verifier.VerificationError, 'requires bootstrap-v15'):
                verifier.verify_database(db, self.expected, json.loads(self.fixture.snapshot.read_text()), RUN, 909)
            self.assertEqual(len(db.queries), 1)
        expected = deepcopy(self.expected); expected['receipt_order_sources'] = None
        db = self.prepared_database()
        with self.assertRaisesRegex(verifier.VerificationError, 'both complete sealed'):
            verifier.verify_database(db, expected, json.loads(self.fixture.snapshot.read_text()), RUN, 909)
        self.assertEqual(len(db.queries), 1)

    def test_implicit_actual_v909_cannot_silently_skip_mapping15(self):
        db = self.prepared_database(mapping='bootstrap-v14')
        with self.assertRaisesRegex(verifier.VerificationError, 'actual schema requires bootstrap-v15'):
            verifier.verify_database(db, self.expected, json.loads(self.fixture.snapshot.read_text()), RUN)

    def test_v908_mapping14_compatibility_never_queries_new_columns(self):
        db = self.prepared_database(schema=908, mapping='bootstrap-v14')
        result = verifier.verify_database(db, self.expected, json.loads(self.fixture.snapshot.read_text()), RUN, 908)
        self.assertNotIn('receipt_order_references', result)
        self.assertNotIn('order_item_legacy_id', db.queries[1])

    def test_independent_source_id_hash_or_fk_mismatch_rejects_full_acceptance(self):
        for key in ('original_order_ids_sha256', 'wrong_real_upstream_links', 'changed_original_projections'):
            db = self.prepared_database()
            facts = db.results[1]['receipt_order_references']['families']['PURCHASE_ITEM']
            facts[key] = 'b' * 64 if isinstance(facts[key], str) else 1
            with self.assertRaises(verifier.VerificationError):
                verifier.verify_database(db, self.expected, json.loads(self.fixture.snapshot.read_text()), RUN, 909)

    def test_rename_requires_the_same_independent_receipt_proof(self):
        before = verifier.verify_database(self.prepared_database(), self.expected,
            json.loads(self.fixture.snapshot.read_text()), RUN, 909)
        before.update(database='local_rehearsal', manifest_sha256=self.expected['manifest_sha256'],
                      frozen_commit=self.expected['frozen_commit'])
        db = self.prepared_database(); db.database = 'local_active'
        for run in (db.results[0], db.results[1]['run']): run['actual_database'] = 'local_active'
        result = verifier.verify_database(db, self.expected, json.loads(self.fixture.snapshot.read_text()),
            RUN, 909, 'local_rehearsal', before)
        self.assertEqual(result['receipt_order_references'], before['receipt_order_references'])
        before['receipt_order_references']['pending_rows']['PURCHASE_ITEM'] += 1
        db.queries.clear()
        with self.assertRaisesRegex(verifier.VerificationError, 'Pre-rename receipt source proof'):
            verifier.verify_database(db, self.expected, json.loads(self.fixture.snapshot.read_text()),
                RUN, 909, 'local_rehearsal', before)


if __name__ == '__main__': unittest.main()

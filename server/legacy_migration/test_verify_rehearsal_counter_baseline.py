from copy import deepcopy
import csv
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

import verify_rehearsal_result as verifier
from test_verify_rehearsal_result import Fixture, FakeDatabase, RUN, PRIVATE_ACCOUNT, PRIVATE_HASH


def sources():
    return {kind: {'rows': number, 'source_file': table + '.csv', 'target_table': table,
                   'file_sha256': 'a' * 64, 'source_ids_sha256': hashlib.sha256(''.join(str(n) + '\n' for n in range(1, number + 1)).encode()).hexdigest()}
            for number, (kind, table) in enumerate(verifier.COUNTER_SOURCES, 1)}


def baseline(expected):
    return {'total_proofs': sum(item['rows'] for item in expected.values()), 'wrong_run_proofs': 0,
            'unregistered_proof_routes': 0,
            'families': {kind: {'proof_rows': source['rows'], 'target_rows': source['rows'], 'source_ids_sha256': source['source_ids_sha256'],
                               **{key: 0 for key in ('wrong_file_sha', 'wrong_target_fields', 'missing_or_mismatched_targets',
                                  'changed_original_projections', 'wrong_or_null_target_run', 'targets_without_exact_proof')}}
                         for kind, source in expected.items()},
            'historical_review_counts': {'purchase_order_received_gt_qty_plus_returned': 263,
                'purchase_order_returned_gt_received': 2, 'purchase_receipt_returned_gt_qty': 7,
                'sales_order_shipped_gt_qty_plus_returned': 11, 'sales_order_returned_gt_shipped': 13,
                'sales_shipment_returned_gt_qty': 17}}


class CounterBaselineTests(unittest.TestCase):
    def test_inventory_derives_each_family_count_and_exact_identity_set(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); records = {}
            for number, (_, table) in enumerate(verifier.COUNTER_SOURCES, 1):
                name = table + '.csv'
                with (root / name).open('w', newline='') as stream:
                    writer = csv.writer(stream, delimiter='|'); writer.writerow(['legacy_id']); writer.writerows([[n] for n in range(number, 0, -1)])
                records[name] = {'rows': number, 'sha256': 'a' * 64}
            self.assertEqual(verifier.counter_source_inventory(root, records), sources())
            first = root / 'purchase_order_items.csv'; first.write_text('legacy_id\n1\n1\n')
            records[first.name]['rows'] = 2
            with self.assertRaises(verifier.VerificationError): verifier.counter_source_inventory(root, records)

    def test_accepts_original_overages_as_review_counts_without_approving_them(self):
        expected = sources(); result = verifier.validate_counter_baseline(baseline(expected), expected)
        self.assertEqual(result['source_proof_rows'], 6)
        self.assertFalse(result['historical_review_is_finance_approval'])
        self.assertFalse(result['verifier_changed_capacity'])
        self.assertEqual(result['historical_review_counts']['purchase_order_returned_gt_received'], 2)

    def test_wrong_run_extra_or_unregistered_proof_fails(self):
        for key in ('total_proofs', 'wrong_run_proofs', 'unregistered_proof_routes'):
            with self.subTest(key=key):
                expected = sources(); actual = baseline(expected); actual[key] += 1
                with self.assertRaises(verifier.VerificationError): verifier.validate_counter_baseline(actual, expected)

    def test_target_count_source_id_set_or_each_snapshot_invariant_fails_closed(self):
        for key in ('proof_rows', 'target_rows', 'source_ids_sha256', 'wrong_file_sha', 'wrong_target_fields',
                    'missing_or_mismatched_targets', 'changed_original_projections', 'wrong_or_null_target_run', 'targets_without_exact_proof'):
            with self.subTest(key=key):
                expected = sources(); actual = baseline(expected)
                proof = actual['families']['SALES_ORDER_ITEM']
                proof[key] = 'b' * 64 if key == 'source_ids_sha256' else proof[key] + 1
                with self.assertRaises(verifier.VerificationError): verifier.validate_counter_baseline(actual, expected)

    def test_v908_mapping14_is_required_in_same_full_fact_snapshot(self):
        with tempfile.TemporaryDirectory() as temporary:
            fixture = Fixture(Path(temporary)); expected = fixture.expected(); expected['counter_sources'] = sources()
            db = FakeDatabase(expected)
            for run in (db.results[0], db.results[1]['run']): run['mapping_version'] = 'bootstrap-v14'
            db.results[1]['counts']['schema_version'] = 908
            db.results[1]['quantity_counter_baseline'] = baseline(expected['counter_sources'])
            result = verifier.verify_database(db, expected, json.loads(fixture.snapshot.read_text()), RUN, 908)
            self.assertTrue(result['quantity_counter_baseline']['verified'])
            self.assertIn('legacy_quantity_counter_import_sources', db.queries[1])
            for private in (PRIVATE_ACCOUNT, PRIVATE_HASH): self.assertNotIn(private, json.dumps(result))
            db.queries.clear(); db.results[1]['quantity_counter_baseline']['families']['PURCHASE_ORDER_ITEM']['changed_original_projections'] = 1
            with self.assertRaises(verifier.VerificationError):
                verifier.verify_database(db, expected, json.loads(fixture.snapshot.read_text()), RUN, 908)

    def test_v908_mapping14_missing_sealed_inventory_is_rejected_before_facts(self):
        with tempfile.TemporaryDirectory() as temporary:
            fixture = Fixture(Path(temporary)); expected = fixture.expected(); db = FakeDatabase(expected)
            db.results[0]['mapping_version'] = 'bootstrap-v14'
            with self.assertRaisesRegex(verifier.VerificationError, 'three sealed'):
                verifier.verify_database(db, expected, json.loads(fixture.snapshot.read_text()), RUN, 908)
            self.assertEqual(len(db.queries), 1)

    def test_pre_v14_does_not_query_unavailable_counter_tables(self):
        with tempfile.TemporaryDirectory() as temporary:
            fixture = Fixture(Path(temporary)); expected = fixture.expected(); db = FakeDatabase(expected)
            for run in (db.results[0], db.results[1]['run']): run['mapping_version'] = 'bootstrap-v13'
            result = verifier.verify_database(db, expected, json.loads(fixture.snapshot.read_text()), RUN, 907)
            self.assertNotIn('quantity_counter_baseline', result)
            self.assertNotIn('legacy_quantity_counter_import_sources', db.queries[1])

    def test_explicit_v908_cannot_silently_skip_v13_or_missing_mapping(self):
        with tempfile.TemporaryDirectory() as temporary:
            fixture = Fixture(Path(temporary)); expected = fixture.expected()
            for mapping in ('bootstrap-v13', None):
                with self.subTest(mapping=mapping):
                    db = FakeDatabase(expected); db.results[0]['mapping_version'] = mapping
                    with self.assertRaisesRegex(verifier.VerificationError, 'requires bootstrap-v14'):
                        verifier.verify_database(db, expected, json.loads(fixture.snapshot.read_text()), RUN, 908)
                    self.assertEqual(len(db.queries), 1)


if __name__ == '__main__':
    unittest.main()

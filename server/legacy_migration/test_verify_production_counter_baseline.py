from copy import deepcopy
import contextlib
import csv
import hashlib
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import verify_production_counter_baseline as production
import verify_rehearsal_result as verifier
import verify_stock_typed_source_hashes as typed_stock
from test_verify_rehearsal_result import Fixture,FakeDatabase,RUN,PRIVATE_ACCOUNT,PRIVATE_HASH
from test_verify_rehearsal_counter_baseline import baseline
from test_verify_receipt_order_references import valid_facts as valid_receipts
from test_verify_receipt_fee_styles import valid_facts as valid_fees
from test_verify_stock_movement_checks import populate as populate_stock,valid_facts as valid_stock


def write(fixture,name,columns,rows):
    with (fixture.inputs/name).open('w',encoding='utf-8',newline='') as stream:
        writer=csv.writer(stream,delimiter='|');writer.writerow(columns)
        for values in rows:writer.writerow([values.get(column,'') for column in columns])
    record=next((r for r in fixture.manifest['files'] if r['file']==name),None)
    if record is None:fixture.manifest['files'].append({'file':name,'rows':len(rows),'bytes':0,'sha256':'a'*64})
    else:record['rows']=len(rows)


def populate(fixture):
    populate_stock(fixture)
    write(fixture,production.PARENT_FILE,production.PARENT_COLUMNS,[{'legacy_id':201,'bill_no':'SYN-PLAN','bill_date':'2025/1/2 0:00:00','status':1}])
    write(fixture,production.ITEM_FILE,production.ITEM_COLUMNS,[
        {'legacy_id':101,'plan_legacy_id':201,'product_no':'SYN-ITEM-1','goods_legacy_id':10,'unit_legacy_id':0,
         'qty':10,'fqty':20,'iqty':30,'client_name':'PRIVATE-PRODUCTION-CLIENT','remark':'PRIVATE|QUOTE"\nSECOND LINE'},
        {'legacy_id':102,'plan_legacy_id':201,'product_no':'SYN-ITEM-2','goods_legacy_id':11,'qty':3,'fqty':3,'iqty':3},
    ])
    for name in ('production_daily_reports.csv','production_daily_report_items.csv'):
        write(fixture,name,['legacy_id'],[])
    write(fixture,production.OPERATOR_FILE,production.OPERATOR_COLUMNS,[])
    fixture.manifest['sourceSnapshotAsOfUtc']='2025-01-31T15:59:59Z'
    fixture.reseal();return fixture.expected()


def typed_facts(source):
    return {'rows':source['rows'],'parents':source['parent_rows'],
      'source_ids_sha256':source['source_ids_sha256'],'source_parent_line_sha256':source['source_parent_line_sha256'],
      **{key:hashlib.sha256(key.encode()).hexdigest() for key in ('typed_source_rows_sha256','typed_parent_bindings_sha256',
        'source_reference_rows_sha256','normalized_business_rows_sha256','counter_rows_sha256','header_identity_rows_sha256','header_business_rows_sha256')}}


def valid_facts(source):
    return {'proof_rows':source['rows'],'target_rows':source['rows'],'parent_rows':source['parent_rows'],
      'issued_txid_count':1 if source['rows'] else 0,'retained_prior_run_proofs':0,
      'context_rows':1,'context_evidence_sha256':'c'*64,'context_origin_system_identifier':'fixture-cluster',
      'context_origin_database_oid':1001,'context_origin_database_name':'local_rehearsal',
      'target_business_columns':list(production.TARGET_FIELDS),
      'proof_source_ids_sha256':source['source_ids_sha256'],'target_source_ids_sha256':source['source_ids_sha256'],
      'parent_source_ids_sha256':source['parent_ids_sha256'],
      **{key:value for key,value in typed_facts(source).items() if key.endswith('_sha256') and key!='source_ids_sha256'},
      'target_uuid_binding_sha256':'b'*64,**{key:0 for key in production.ZERO_INVARIANTS}}


class ProductionFixtureCase(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.fixture=Fixture(Path(self.temp.name))
        self.expected=populate(self.fixture);self.source=self.expected['production_counter_sources']
    def tearDown(self):self.temp.cleanup()


class ProductionSourceTests(ProductionFixtureCase):
    def test_offline_inventory_accepts_real_historical_overrun_without_new_capacity(self):
        with patch.object(production,'verify_local_docker',side_effect=AssertionError('offline must not inspect Docker')),patch.object(production.subprocess,'run',side_effect=AssertionError('offline must not run a process')):
            expected=self.fixture.expected()
        self.assertEqual(expected['production_counter_sources']['rows'],2)
        self.assertEqual(len(production.ITEM_COLUMNS),45);self.assertEqual(len(production.PARENT_COLUMNS),15)
        self.assertEqual(len(production.COUNTERS),13)
        self.assertNotIn('PRIVATE-PRODUCTION',json.dumps(self.source))
    def test_public_source_cli_defaults_to_offline_without_docker_target_or_secrets(self):
        output=self.fixture.root/'production-source-offline.json'
        args=['--inputs',str(self.fixture.inputs),'--manifest-sha256',self.fixture.manifest_sha,
              '--frozen-commit',self.expected['frozen_commit'],'--output',str(output)]
        with (patch.object(production,'verify_local_docker',side_effect=AssertionError('no Docker')),
             patch.object(production.subprocess,'run',side_effect=AssertionError('no subprocess')),
             contextlib.redirect_stdout(io.StringIO()) as stream):
            self.assertEqual(production.main(args),0)
        receipt=json.loads(output.read_text());self.assertFalse(receipt['docker_used'])
        self.assertFalse(receipt['target_database_queried']);self.assertNotIn('PRIVATE-PRODUCTION',stream.getvalue())
    def test_all_counters_are_bound_without_clamp_or_new_sign_rules(self):
        for field in production.COUNTERS:self.assertIn("'"+field+"',COALESCE(s."+field+",0)",production._source_payload_sql())
        self.assertNotIn('LEAST(',production._source_payload_sql());self.assertNotIn('GREATEST(',production._source_payload_sql())
        rows=verifier.read_csv(self.fixture.inputs/production.ITEM_FILE);rows[0]['rqty']='-2'
        write(self.fixture,production.ITEM_FILE,production.ITEM_COLUMNS,rows);self.fixture.reseal()
        self.assertEqual(self.fixture.expected()['production_counter_sources']['rows'],2)
    def test_negative_qty_finished_and_inbound_rejected(self):
        original=verifier.read_csv(self.fixture.inputs/production.ITEM_FILE)
        for field in ('qty','fqty','iqty'):
            rows=deepcopy(original);rows[0][field]='-1';write(self.fixture,production.ITEM_FILE,production.ITEM_COLUMNS,rows);self.fixture.reseal()
            with self.subTest(field=field),self.assertRaises(verifier.VerificationError):self.fixture.expected()
    def test_duplicate_or_unknown_source_parent_and_duplicate_item_rejected(self):
        original=verifier.read_csv(self.fixture.inputs/production.ITEM_FILE)
        for change in ('duplicate','unknown_parent'):
            rows=deepcopy(original)
            if change=='duplicate':rows[1]['legacy_id']=rows[0]['legacy_id']
            else:rows[0]['plan_legacy_id']='99999'
            write(self.fixture,production.ITEM_FILE,production.ITEM_COLUMNS,rows);self.fixture.reseal()
            with self.subTest(change=change),self.assertRaises(verifier.VerificationError):self.fixture.expected()
    def test_complete_raw_parent_shape_not_derived_operator_names(self):
        rows=verifier.read_csv(self.fixture.inputs/production.PARENT_FILE)
        write(self.fixture,production.PARENT_FILE,production.PARENT_COLUMNS+('maker_name',),rows);self.fixture.reseal()
        with self.assertRaisesRegex(verifier.VerificationError,'complete typed'):self.fixture.expected()
    def test_source_sha_drift_and_nonfinite_counter_rejected(self):
        with (self.fixture.inputs/production.ITEM_FILE).open('a') as stream:stream.write('SOURCE_DRIFT\n')
        with self.assertRaises(verifier.VerificationError):self.fixture.expected()
        rows=[{'legacy_id':101,'plan_legacy_id':201,'product_no':'SYN','qty':'NaN'}]
        write(self.fixture,production.ITEM_FILE,production.ITEM_COLUMNS,rows);self.fixture.reseal()
        with self.assertRaises(verifier.VerificationError):self.fixture.expected()
    def test_new_nonempty_legacy_daily_report_requires_its_own_protocol(self):
        write(self.fixture,'production_daily_reports.csv',['legacy_id'],[{'legacy_id':1}]);self.fixture.reseal()
        with self.assertRaisesRegex(verifier.VerificationError,'reports require'):self.fixture.expected()


class ProductionAcceptanceTests(ProductionFixtureCase):
    def prepared(self):
        source=deepcopy(self.source);source['typed_source_facts']=typed_facts(source);return source
    def test_complete_independent_hashes_and_relations_verify(self):
        source=self.prepared();proof=production.validate(valid_facts(source),source)
        self.assertTrue(proof['verified']);self.assertEqual(proof['counter_fields_verified'],13)
        self.assertFalse(proof['historical_baseline_is_new_capacity']);self.assertNotIn('PRIVATE',json.dumps(proof))
    def test_every_negative_invariant_has_a_failure_case(self):
        source=self.prepared()
        for key in production.ZERO_INVARIANTS:
            actual=valid_facts(source);actual[key]=1
            with self.subTest(key=key),self.assertRaisesRegex(ValueError,key):production.validate(actual,source)
    def test_count_equality_cannot_hide_unknown_source_rows_or_changed_business_fields(self):
        source=self.prepared()
        for key in ('proof_source_ids_sha256','target_source_ids_sha256','parent_source_ids_sha256',
                    'typed_source_rows_sha256','typed_parent_bindings_sha256','source_parent_line_sha256',
                    'source_reference_rows_sha256','normalized_business_rows_sha256','counter_rows_sha256','header_identity_rows_sha256','header_business_rows_sha256'):
            actual=valid_facts(source);actual[key]='f'*64
            with self.subTest(key=key),self.assertRaises(ValueError):production.validate(actual,source)
    def test_unreviewed_business_field_or_missing_typed_proof_rejected(self):
        source=self.prepared();actual=valid_facts(source);actual['target_business_columns'].append('new_capacity')
        with self.assertRaisesRegex(ValueError,'schema changed'):production.validate(actual,source)
        source.pop('typed_source_facts')
        with self.assertRaisesRegex(ValueError,'independent typed'):production.validate(valid_facts(source),source)
    def test_bool_float_or_missing_issued_identity_cannot_impersonate_counts(self):
        source=self.prepared()
        for key in ('proof_rows','target_rows','parent_rows','issued_txid_count','wrong_file_sha'):
            for value in (True,0.0,None):
                actual=valid_facts(source);actual[key]=value
                with self.subTest(key=key,value=value),self.assertRaises(ValueError):production.validate(actual,source)
    def test_prior_unbound_preserved_proofs_are_not_misclassified_as_current_targets(self):
        source=self.prepared();actual=valid_facts(source);actual['retained_prior_run_proofs']=99
        self.assertEqual(production.validate(actual,source)['retained_prior_run_proofs'],99)
    def test_sql_uses_only_readonly_aggregates_and_pure_normalization(self):
        sql=production.acceptance_sql(RUN,self.source)
        self.assertTrue(sql.lstrip().startswith('WITH '));self.assertNotIn('set_config',sql)
        self.assertNotIn('fn_register_',sql);self.assertNotIn('fn_assert_legacy_',sql)
        self.assertNotIn('fn_legacy_production_plan_counter_source_projection',sql)
        self.assertIn('information_schema.columns',sql);self.assertIn('production_overproduction_rate_requests',sql)


class ProductionGenericGateTests(ProductionFixtureCase):
    def setUp(self):
        super().setUp()
        self.stock_mock=patch.object(verifier,'stock_typed_source_hash',return_value='d'*64).start()
        self.production_mock=patch.object(verifier,'production_typed_source_facts',side_effect=lambda source:typed_facts(source)).start()
        self.addCleanup(patch.stopall)
    def database(self,schema=913,mapping='bootstrap-v17'):
        db=FakeDatabase(self.expected)
        for run in (db.results[0],db.results[1]['run']):run.update(mapping_version=mapping,actual_schema_version=schema)
        facts=db.results[1];facts['counts']['schema_version']=schema
        facts['quantity_counter_baseline']=baseline(self.expected['counter_sources'])
        facts['receipt_order_references']=valid_receipts(self.expected['receipt_order_sources'])
        facts['receipt_fee_styles']=valid_fees(self.expected['receipt_fee_sources'])
        stock=deepcopy(self.expected['stock_movement_sources']);stock['nonposting_source_rows_sha256']='d'*64
        facts['stock_movement_checks']=valid_stock(stock)
        facts['production_counter_baseline']=valid_facts(self.source)
        return db
    def verify(self,db,expected_schema=None,**kwargs):
        return verifier.verify_database(db,self.expected,json.loads(self.fixture.snapshot.read_text()),RUN,expected_schema,**kwargs)
    def test_v913_report_has_mandatory_verified_baseline_and_retains_existing_gates(self):
        report=self.verify(self.database(),913)
        self.assertTrue(report['production_counter_baseline']['verified'])
        for key in ('quantity_counter_baseline','receipt_order_references','receipt_fee_styles','stock_movement_checks'):
            self.assertTrue(report[key]['verified'])
        self.production_mock.assert_called_once()
    def test_actual_913_requires_mapping17_before_payload_or_second_query(self):
        for expected in (None,907,913):
            db=self.database(mapping='bootstrap-v16')
            with self.subTest(expected=expected),self.assertRaisesRegex(verifier.VerificationError,'bootstrap-v17'):self.verify(db,expected)
            self.assertEqual(len(db.queries),1)
        self.production_mock.assert_not_called()
    def test_mapping17_requires_actual913_even_when_expected_schema_omitted_or_low(self):
        for expected in (None,907,913):
            db=self.database(schema=912)
            with self.subTest(expected=expected),self.assertRaisesRegex(verifier.VerificationError,'V913 actual'):self.verify(db,expected)
            self.assertEqual(len(db.queries),1)
    def test_missing_source_or_typed_failure_cannot_downgrade(self):
        expected=deepcopy(self.expected);expected['production_counter_sources']=None;db=self.database()
        with self.assertRaisesRegex(verifier.VerificationError,'complete sealed'):verifier.verify_database(db,expected,json.loads(self.fixture.snapshot.read_text()),RUN)
        self.assertEqual(len(db.queries),1)
        self.production_mock.side_effect=ValueError('owned typed production failed');db=self.database()
        with self.assertRaisesRegex(ValueError,'owned typed production failed'):self.verify(db)
        self.assertEqual(len(db.queries),1)
    def test_low_expected_schema_still_executes_mandatory_gate_before_exact_schema_rejection(self):
        db=self.database()
        with self.assertRaisesRegex(verifier.VerificationError,'schema version differs'):self.verify(db,907)
        self.production_mock.assert_called_once()
        self.assertIn('legacy_production_plan_counter_import_sources',db.queries[1])
    def test_pre913_mapping16_remains_compatible_without_new_table_or_docker(self):
        db=self.database(schema=912,mapping='bootstrap-v16');db.results[1].pop('production_counter_baseline')
        report=self.verify(db,912)
        self.assertNotIn('production_counter_baseline',report);self.production_mock.assert_not_called()
        self.assertNotIn('legacy_production_plan_counter_import_sources',db.queries[1])
    def test_failed_run_and_offline_cli_never_hash_or_query_target(self):
        db=self.database();db.results[0]['status']='FAILED'
        with self.assertRaises(verifier.VerificationError):self.verify(db)
        self.assertEqual(len(db.queries),1);self.production_mock.assert_not_called()
        output=self.fixture.root/'production-offline.json'
        args=['--inputs',str(self.fixture.inputs),'--admin-snapshot',str(self.fixture.snapshot),'--run-id',RUN,
              '--database','local_rehearsal','--manifest-sha256',self.fixture.manifest_sha,'--frozen-commit',self.expected['frozen_commit'],
              '--output',str(output),'--offline-only']
        with patch.object(verifier.ReadOnlyDatabase,'query',side_effect=AssertionError('no target')),contextlib.redirect_stdout(io.StringIO()) as stream:
            self.assertEqual(verifier.main(args),0)
        self.production_mock.assert_not_called();self.assertNotIn('PRIVATE-PRODUCTION',stream.getvalue())
        self.assertNotIn(PRIVATE_ACCOUNT,stream.getvalue());self.assertNotIn(PRIVATE_HASH,stream.getvalue())
    def test_before_after_rename_preserves_production_target_uuid_identity(self):
        before=self.verify(self.database(),913)
        before.update(database='local_rehearsal',manifest_sha256=self.expected['manifest_sha256'],frozen_commit=self.expected['frozen_commit'])
        db=self.database();db.database='uten_imp'
        for run in (db.results[0],db.results[1]['run']):run['actual_database']='uten_imp'
        report=self.verify(db,913,renamed_from='local_rehearsal',pre_rename_proof=before)
        self.assertTrue(report['production_counter_baseline']['verified'])
        before['production_counter_baseline']['target_uuid_binding_sha256']='e'*64
        db=self.database();db.database='uten_imp'
        for run in (db.results[0],db.results[1]['run']):run['actual_database']='uten_imp'
        with self.assertRaisesRegex(verifier.VerificationError,'production historical'):self.verify(db,913,renamed_from='local_rehearsal',pre_rename_proof=before)


class ProductionDockerGuardTests(unittest.TestCase):
    def test_remote_context_or_environment_refuses_before_payload_copy(self):
        for endpoint,env in [('ssh://private-remote',{}),('unix:///var/run/docker.sock',{'DOCKER_HOST':'tcp://private-remote'})]:
            with self.subTest(endpoint=endpoint),patch.object(typed_stock.subprocess,'check_output',return_value=endpoint),patch.dict(os.environ,env,clear=True),patch.object(production.subprocess,'run') as operations,patch.object(Path,'read_bytes') as payload:
                with self.assertRaisesRegex(ValueError,'Remote Docker'):production.typed_source_facts({})
                operations.assert_not_called();payload.assert_not_called()

if __name__=='__main__':unittest.main()

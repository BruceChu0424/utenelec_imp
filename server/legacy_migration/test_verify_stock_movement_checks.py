from copy import deepcopy
import csv
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import contextlib
import io
import os
import subprocess
import verify_stock_typed_source_hashes as typed_stock

import verify_stock_movement_checks as stock
import verify_rehearsal_result as verifier
from test_verify_rehearsal_result import Fixture, FakeDatabase, RUN, PRIVATE_ACCOUNT, PRIVATE_HASH
from test_verify_rehearsal_counter_baseline import baseline
from test_verify_receipt_order_references import valid_facts as valid_receipts
from test_verify_receipt_fee_styles import populate as populate_fees, valid_facts as valid_fees

HEAD = ['legacy_id','bill_no','bill_date','stock_legacy_id','to_stock_legacy_id','supplier_legacy_id',
        'client_legacy_id','worker_legacy','maker_legacy','approver_legacy','total_original','status']
ITEM = ['legacy_id','bill_legacy_id','goods_legacy_id','color_legacy_id','unit_legacy_id','qty',
        'unit_rate','price','amount','surplus_qty','count_qty','upstream_legacy_id']


def write(fixture, name, header, rows, extra=False):
    if header == ITEM:
        from verify_stock_typed_source_hashes import COLUMNS
        rows = [[dict(zip(ITEM,row)).get(column,'') for column in COLUMNS] for row in rows]
        header = COLUMNS
    with (fixture.inputs/name).open('w', encoding='utf-8', newline='') as stream:
        writer=csv.writer(stream,delimiter='|');writer.writerow(header);writer.writerows(rows)
    if extra:
        fixture.manifest['provenance']['extraInputs'][name]=verifier.digest(fixture.inputs/name)
    else:
        existing=next((r for r in fixture.manifest['files'] if r['file']==name),None)
        if existing is None:fixture.manifest['files'].append({'file':name,'rows':len(rows),'bytes':0,'sha256':'a'*64})
        else:existing['rows']=len(rows)


def populate(fixture):
    populate_fees(fixture)
    write(fixture,'warehouse_crosswalk.csv',['legacy_id','action','target_code','target_defective'],
          [[1,'KEEP','A','false'],[2,'KEEP','B','false'],[132,'SPLIT','R','false'],[130,'DROP','',''],['','TARGET','C','false']],True)
    write(fixture,'goods_owning_warehouse.csv',['goods_legacy_id','warehouse_code'],[[10,'A'],[-100,'C']],True)
    for kind in stock.TYPES:
        write(fixture,f'stock_{kind.lower()}_m.csv',HEAD,[])
        write(fixture,f'stock_{kind.lower()}_i.csv',ITEM,[])
    # Independent source namespaces intentionally reuse both header and item IDs.
    write(fixture,'stock_other_in_m.csv',HEAD,[[1,'IN-1','2025/1/2 0:00:00',1,0,0,0,0,0,0,0,1],
          [2,'IN-DROP','2025-01-02',130,0,0,0,0,0,0,0,1],[3,'IN-SPLIT','2025-01-02',132,0,0,0,0,0,0,0,1]])
    write(fixture,'stock_other_in_i.csv',ITEM,[[1,1,10,0,0,0,'',2,0,0,0,0],
          [2,2,10,0,0,9,1,1,9,0,0,0],[3,3,11,0,0,9,1,1,9,0,0,0]])
    write(fixture,'stock_draw_m.csv',HEAD,[[1,'DRAW-1','2025-01-02',1,0,0,0,0,0,0,4,1],
          [2,'DRAW-2','2025-01-02',1,0,0,0,0,0,0,4,-1]])
    write(fixture,'stock_draw_i.csv',ITEM,[[1,1,10,0,0,2,1,2,'',0,0,0],[2,2,10,0,0,2,1,2,4,0,0,0]])
    write(fixture,'stock_transfer_m.csv',HEAD,[[1,'TR-1','2025-01-02',1,2,0,0,0,0,0,99,1]])
    write(fixture,'stock_transfer_i.csv',ITEM,[[1,1,10,0,0,3,1,33,99,0,0,0]])
    write(fixture,'stock_check_m.csv',HEAD,[[1,'CH-1','2025-01-02',1,0,0,0,0,0,0,7,1]])
    write(fixture,'stock_check_i.csv',ITEM,[[1,1,10,0,0,0,1,2,7,-4,0,0]])
    fixture.reseal();return fixture.expected()


def valid_facts(source):
    result={key:0 for key in stock.ZERO_INVARIANTS}
    result.update(summary_present=True,summary_passed=True,summary_exact=True,summary_entries_persisted=True,
        summary_version=stock.VERSION,summary_zero_quantity_movements=0,
        summary_declared_entries_sha256='a'*64,summary_actual_entries_sha256='a'*64,
        document_uuid_identity_sha256='b'*64,item_uuid_identity_sha256='c'*64,movement_uuid_identity_sha256='d'*64)
    for actual,expected in [('summary_retained_source_items','retained_items'),('summary_expected_movements','expected_movements'),
        ('summary_matched_movements','expected_movements'),('summary_nonposting_items','nonposting_items'),
        ('summary_nonposting_nonzero_amount_items','nonposting_nonzero_amount_items'),('document_rows','retained_documents'),
        ('item_rows','retained_items'),('movement_rows','expected_movements'),('nonposting_rows','nonposting_items'),
        ('nonposting_nonzero_amount_rows','nonposting_nonzero_amount_items')]:result[actual]=source[expected]
    for key in ('document_facts_sha256','item_facts_sha256','movement_facts_sha256','nonposting_source_facts_sha256','nonposting_source_rows_sha256'):result[key]=source[key]
    return result


class StockAcceptanceTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.fixture=Fixture(Path(self.temp.name))
        self.expected=populate(self.fixture);self.source=self.expected['stock_movement_sources']
        self.source['nonposting_source_rows_sha256']='e'*64
        self.typed_patch=patch.object(verifier,'stock_typed_source_hash',return_value='e'*64);self.typed_mock=self.typed_patch.start()

    def tearDown(self):self.typed_patch.stop();self.temp.cleanup()

    def inventory(self):
        return stock.source_inventory(self.fixture.inputs,{r['file']:r for r in self.fixture.manifest['files']},
                                      self.fixture.manifest['provenance']['extraInputs'])

    def rewrite(self,name,header,rows,extra=False):
        write(self.fixture,name,header,rows,extra);self.fixture.reseal()

    def database(self,mapping='bootstrap-v16',schema=912):
        db=FakeDatabase(self.expected)
        for run in (db.results[0],db.results[1]['run']):run.update(mapping_version=mapping,actual_schema_version=schema)
        f=db.results[1];f['counts']['schema_version']=schema
        f['quantity_counter_baseline']=baseline(self.expected['counter_sources'])
        f['receipt_order_references']=valid_receipts(self.expected['receipt_order_sources'])
        f['receipt_fee_styles']=valid_fees(self.expected['receipt_fee_sources'])
        f['stock_movement_checks']=valid_facts(self.source)
        return db

    def verify(self,db=None,schema=None,expected=None):
        return verifier.verify_database(db or self.database(),expected or self.expected,
            json.loads(self.fixture.snapshot.read_text()),RUN,schema)

    def test_inventory_uses_composite_identities_drop_split_status_and_check_surplus(self):
        self.assertEqual((self.source['retained_documents'],self.source['retained_items'],self.source['expected_movements'],self.source['nonposting_items']),(6,5,4,1))
        self.assertEqual(self.source['families']['OTHER_IN']['dropped_items'],1)
        self.assertEqual(self.source['families']['OTHER_IN']['unassigned_split_items'],1)
        self.assertEqual(self.source['families']['CHECK']['expected_movements'],1)
        self.assertEqual(self.source['families']['TRANSFER']['expected_movements'],2)

    def test_source_hash_binds_numeric_values_nulls_dates_and_identity_without_disclosure(self):
        result=stock.validate(valid_facts(self.source),self.source)
        for private in (PRIVATE_ACCOUNT,PRIVATE_HASH,'DRAW-1','99.0000'):self.assertNotIn(private,json.dumps(result))
        for column,value in [('qty','1'),('unit_rate','1'),('price','3'),('amount','8')]:
            row=[1,1,10,0,0,0,'',2,0,0,0,0];row[ITEM.index(column)]=value
            self.rewrite('stock_other_in_i.csv',ITEM,[row])
            changed=self.inventory()
            if column != 'unit_rate':self.assertNotEqual(changed['item_facts_sha256'],self.source['item_facts_sha256'])
            if column != 'price':self.assertNotEqual(changed['nonposting_source_facts_sha256'],self.source['nonposting_source_facts_sha256'])

    def test_source_order_is_independent_and_rounding_matches_typed_numeric(self):
        self.rewrite('stock_draw_i.csv',ITEM,[[2,2,10,0,0,'2.00000','1.0000000','2.00000',4,0,0,0],[1,1,10,0,0,2,1,2,'',0,0,0]])
        self.assertEqual(self.inventory()['item_facts_sha256'],self.source['item_facts_sha256'])

    def test_duplicate_and_unestablished_upstream_namespaces_fail(self):
        row=[1,1,10,0,0,2,1,2,0,0,0,0]
        self.rewrite('stock_draw_i.csv',ITEM,[row,row])
        with self.assertRaises(ValueError):self.inventory()
        row[-1]=44;self.rewrite('stock_draw_i.csv',ITEM,[row])
        with self.assertRaises(ValueError):self.inventory()

    def test_missing_inputs_or_decisions_cannot_fabricate_v16_success(self):
        records={r['file']:r for r in self.fixture.manifest['files']};records.pop('stock_check_i.csv')
        self.assertIsNone(stock.source_inventory(self.fixture.inputs,records,self.fixture.manifest['provenance']['extraInputs']))
        extra=deepcopy(self.fixture.manifest['provenance']['extraInputs']);extra.pop('goods_owning_warehouse.csv')
        self.assertIsNone(stock.source_inventory(self.fixture.inputs,{r['file']:r for r in self.fixture.manifest['files']},extra))

    def test_resealed_unknown_warehouse_decision_and_ambiguous_owning_fail(self):
        self.rewrite('goods_owning_warehouse.csv',['goods_legacy_id','warehouse_code'],[[10,'A'],[10,'C']],True)
        with self.assertRaises(ValueError):self.inventory()

    def test_source_manifest_sha_and_rows_are_checked(self):
        records={r['file']:deepcopy(r) for r in self.fixture.manifest['files']}
        for key,value in [('sha256','f'*64),('rows',99)]:
            modified=deepcopy(records);modified['stock_draw_i.csv'][key]=value
            with self.assertRaises(ValueError):stock.source_inventory(self.fixture.inputs,modified,self.fixture.manifest['provenance']['extraInputs'])

    def test_each_summary_fact_hash_and_relational_failure_is_rejected(self):
        original=valid_facts(self.source)
        for key,value in original.items():
            actual=deepcopy(original)
            if key.endswith('uuid_identity_sha256'):continue  # Any real UUID continuity hash is accepted before rename.
            actual[key]=False if type(value) is bool else value+1 if type(value) is int else 'f'*64 if key.endswith('sha256') else 'wrong'
            with self.subTest(key=key),self.assertRaises(ValueError):stock.validate(actual,self.source)

    def test_sql_is_readonly_aggregate_and_embeds_no_source_quantities_or_payload(self):
        sql=stock.acceptance_sql(RUN,self.source)
        self.assertTrue(sql.startswith('SELECT '))
        for forbidden in ('UPDATE ','DELETE ','COPY ','DRAW-1',PRIVATE_ACCOUNT,PRIVATE_HASH):self.assertNotIn(forbidden,sql)
        for field in stock.ENTRY_FIELDS:self.assertIn("'"+field+"'",sql)
        self.assertIn('trim_scale',sql);self.assertIn('stock_movement_checks',verifier.facts_sql(RUN,RUN,[]))

    def test_v16_uses_same_snapshot_and_safe_report_key(self):
        db=self.database();report=self.verify(db,912)
        self.assertTrue(report['stock_movement_checks']['verified'])
        self.assertEqual(report['mapping_version'],'bootstrap-v16')
        self.assertIn('stockMovementChecks',db.queries[1]);self.assertEqual(len(db.queries),2)

    def test_v16_mandatory_even_when_expected_schema_omitted_or_low(self):
        for schema in (None,907,909,912):
            expected=deepcopy(self.expected);expected['stock_movement_sources']=None;db=self.database()
            with self.assertRaisesRegex(verifier.VerificationError,'bootstrap-v16.*sealed stock'):self.verify(db,schema,expected)
            self.assertEqual(len(db.queries),1)

    def test_old_v15_schema912_keeps_existing_contract_without_stock_gate(self):
        db=self.database('bootstrap-v15');db.results[1].pop('stock_movement_checks')
        report=self.verify(db,912);self.assertNotIn('stock_movement_checks',report)
        self.assertNotIn('stockMovementChecks',db.queries[1]);self.typed_mock.assert_not_called()

    def test_forged_source_amount_warehouse_entry_sha_or_zero_event_blocks_acceptance(self):
        for key in ('item_facts_sha256','movement_facts_sha256','nonposting_source_facts_sha256','invalid_nonposting_files',
                    'invalid_movement_relations','nonposting_entries_with_movements','summary_entries_persisted'):
            db=self.database();value=db.results[1]['stock_movement_checks'][key]
            db.results[1]['stock_movement_checks'][key]=False if type(value) is bool else 1 if type(value) is int else 'f'*64
            with self.subTest(key=key),self.assertRaises(verifier.VerificationError):self.verify(db,912)

    def test_rename_continuity_includes_stock_uuid_identity_hashes(self):
        before=self.verify(schema=912);before.update(database='local_rehearsal',manifest_sha256=self.expected['manifest_sha256'],frozen_commit=self.expected['frozen_commit'])
        def renamed():
            db=self.database();db.database='local_active'
            for run in (db.results[0],db.results[1]['run']):run['actual_database']='local_active'
            return db
        db=renamed();report=verifier.verify_database(db,self.expected,json.loads(self.fixture.snapshot.read_text()),RUN,912,'local_rehearsal',before)
        self.assertTrue(report['stock_movement_checks']['verified'])
        before['stock_movement_checks']['item_uuid_identity_sha256']='f'*64
        with self.assertRaisesRegex(verifier.VerificationError,'Pre-rename stock movement'):verifier.verify_database(renamed(),self.expected,json.loads(self.fixture.snapshot.read_text()),RUN,912,'local_rehearsal',before)

    def test_offline_cli_never_starts_typed_postgres_or_queries_business(self):
        output=self.fixture.root/'offline.json'
        args=['--inputs',str(self.fixture.inputs),'--admin-snapshot',str(self.fixture.snapshot),'--run-id',RUN,
              '--database','local_rehearsal','--manifest-sha256',self.fixture.manifest_sha,
              '--frozen-commit',self.expected['frozen_commit'],'--output',str(output),'--offline-only']
        with patch.object(verifier.ReadOnlyDatabase,'query',side_effect=AssertionError('Must not query')),contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(verifier.main(args),0)
        self.typed_mock.assert_not_called()

    def test_failed_run_rejects_before_owned_source_hash_and_business_queries(self):
        db=self.database();db.results[0]['status']='FAILED'
        with self.assertRaises(verifier.VerificationError):self.verify(db,912)
        self.assertEqual(len(db.queries),1);self.typed_mock.assert_not_called()

    def test_complete_typed_source_hash_failure_cannot_downgrade_to_shape_only(self):
        db=self.database();self.typed_mock.side_effect=ValueError('Owned source hash failed')
        with self.assertRaisesRegex(ValueError,'Owned source hash failed'):self.verify(db,912)
        self.assertEqual(len(db.queries),1)

    def test_summary_boolean_or_float_cannot_impersonate_integer_counts(self):
        for value in (True,1.0):
            actual=valid_facts(self.source);actual['summary_nonposting_items']=value
            with self.assertRaises(ValueError):stock.validate(actual,self.source)

    def test_complete_source_hash_must_be_present_before_accepting_summary(self):
        source=deepcopy(self.source);source.pop('nonposting_source_rows_sha256')
        with self.assertRaisesRegex(ValueError,'Complete stock typed source'):stock.validate(valid_facts(self.source),source)


class LocalDockerGuardTests(unittest.TestCase):
    def rejected_before_payload(self,endpoint,environment):
        with patch.object(typed_stock.subprocess,'check_output',return_value=endpoint) as context, \
             patch.object(typed_stock.subprocess,'run') as operations, \
             patch.object(Path,'read_bytes',side_effect=AssertionError('Source must not be read')) as source_read, \
             patch.dict(os.environ,environment,clear=True):
            # An empty inventory is deliberate: the local guard must run first.
            with self.assertRaisesRegex(ValueError,'Remote Docker endpoints') as error:
                typed_stock.typed_source_hash({})
            if endpoint.strip():self.assertNotIn(endpoint.strip(),str(error.exception))
            context.assert_called_once_with(['docker','context','inspect','--format','{{.Endpoints.docker.Host}}'],
                text=True,stderr=subprocess.PIPE,timeout=15)
            operations.assert_not_called();source_read.assert_not_called()

    def test_local_npipe_and_unix_contexts_allow_only_local_overrides(self):
        for endpoint in ('npipe:////./pipe/docker_engine\n','unix:///var/run/docker.sock\n'):
            for environment in ({},{'DOCKER_HOST':'npipe:////./pipe/docker_engine'},
                                {'DOCKER_HOST':'unix:///var/run/docker.sock'}):
                with self.subTest(endpoint=endpoint,environment=environment), \
                     patch.object(typed_stock.subprocess,'check_output',return_value=endpoint), \
                     patch.dict(os.environ,environment,clear=True):
                    typed_stock.verify_local_docker()

    def test_remote_context_cannot_be_masked_by_local_environment_override(self):
        for endpoint in ('tcp://remote:2375','ssh://remote'):
            for override in ('npipe:////./pipe/docker_engine','unix:///var/run/docker.sock'):
                with self.subTest(endpoint=endpoint,override=override):
                    self.rejected_before_payload(endpoint,{'DOCKER_HOST':override})

    def test_remote_environment_is_rejected_despite_local_context(self):
        for endpoint in ('npipe:////./pipe/docker_engine','unix:///var/run/docker.sock'):
            for override in ('tcp://remote:2375','ssh://remote'):
                with self.subTest(endpoint=endpoint,override=override):
                    self.rejected_before_payload(endpoint,{'DOCKER_HOST':override})

    def test_explicit_remote_docker_context_is_resolved_and_rejected(self):
        self.rejected_before_payload('ssh://selected-remote',
            {'DOCKER_CONTEXT':'selected-remote','DOCKER_HOST':'unix:///var/run/docker.sock'})

    def test_remote_context_without_environment_override_is_rejected(self):
        for endpoint in ('tcp://remote:2375','ssh://remote','https://remote:2376'):
            with self.subTest(endpoint=endpoint):self.rejected_before_payload(endpoint,{})

    def test_empty_context_or_environment_fails_closed_before_payload(self):
        self.rejected_before_payload('',{})
        self.rejected_before_payload('unix:///var/run/docker.sock',{'DOCKER_HOST':''})

    def test_failed_context_inspection_fails_before_any_container_or_payload(self):
        for error in (FileNotFoundError('PRIVATE_DIAGNOSTIC'),
                      subprocess.CalledProcessError(1,['docker'],stderr=b'PRIVATE_DIAGNOSTIC'),
                      subprocess.TimeoutExpired(['docker'],15)):
            with self.subTest(error=type(error).__name__), \
                 patch.object(typed_stock.subprocess,'check_output',side_effect=error), \
                 patch.object(typed_stock.subprocess,'run') as operations, \
                 patch.object(Path,'read_bytes') as source_read:
                with self.assertRaisesRegex(ValueError,'Local Docker endpoint could not be verified') as caught:
                    typed_stock.typed_source_hash({})
                self.assertNotIn('PRIVATE_DIAGNOSTIC',str(caught.exception))
                operations.assert_not_called();source_read.assert_not_called()


if __name__=='__main__':unittest.main()

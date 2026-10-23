import copy
from contextlib import ExitStack
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import verify_finance_flow_monthly as gate
import verify_rehearsal_result as generic
from test_verify_rehearsal_result import Fixture,FakeDatabase,RUN


def successful():
    facts={key:hashlib.sha256(key.encode()).hexdigest() for key in gate.HASH_KEYS}
    facts.update(source_rows=5,active_source_rows=4,archive_only_rows=1,monthly_groups=2,signed_active_rows=1)
    source={'source_rows':5,'typed_source_facts':copy.deepcopy(facts),'files':{name:{'sha256':'a'*64} for name in gate.FILES},
            '_manifest_sha256':'a'*64,'_frozen_commit':'b'*40,'_source_cutoff':'2026-01-01T00:00:00Z'}
    actual={**facts,**{key:0 for key in gate.ZERO_INVARIANTS},'run_rows':1,'proof_rows':4,
            'target_business_columns':list(gate.TARGET_BUSINESS_COLUMNS),'target_uuid_binding_sha256':'c'*64,'source_execution_sha256':'d'*64}
    return source,actual


class FinanceFlowValidationTests(unittest.TestCase):
    def test_complete_source_projection_is_safe_and_dynamic(self):
        source,actual=successful();result=gate.validate(actual,source)
        self.assertTrue(result['verified']);self.assertEqual(result['archive_only_rows'],1)
        self.assertEqual(result['signed_active_rows'],1)
        self.assertFalse(result['target_writes_performed'])
        self.assertNotIn('typed_source_facts',result)

    def test_each_native_invariant_is_mandatory(self):
        for key in gate.ZERO_INVARIANTS:
            for value in (1,None,False):
                with self.subTest(key=key,value=value):
                    source,actual=successful();actual[key]=value
                    with self.assertRaises(ValueError):gate.validate(actual,source)

    def test_all_independent_source_hashes_are_mandatory(self):
        for key in gate.HASH_KEYS:
            with self.subTest(key=key):
                source,actual=successful();actual[key]='0'*64
                with self.assertRaises(ValueError):gate.validate(actual,source)

    def test_dynamic_counts_and_no_boolean_substitution(self):
        for key in ('run_rows','proof_rows','source_rows','active_source_rows','archive_only_rows','monthly_groups','signed_active_rows'):
            for value in (None,True,999):
                with self.subTest(key=key,value=value):
                    source,actual=successful();actual[key]=value
                    with self.assertRaises(ValueError):gate.validate(actual,source)

    def test_future_business_field_fails_closed(self):
        source,actual=successful();actual['target_business_columns'].append('extra_capacity')
        with self.assertRaises(ValueError):gate.validate(actual,source)

    def test_uuid_and_immutable_execution_continuity_are_required(self):
        for key in ('target_uuid_binding_sha256','source_execution_sha256'):
            source,actual=successful();actual[key]=None
            with self.assertRaises(ValueError):gate.validate(actual,source)

    def test_sql_never_calls_rebuild_or_running_only_assert(self):
        source,_=successful();sql=gate.acceptance_sql(RUN,source)
        self.assertIn('EXCEPT ALL',sql)
        self.assertIn('source_row_sha256',sql)
        self.assertIn('proof_initial',sql)
        self.assertIn('legacy_account_flow_origin_database_oid',sql)
        self.assertNotIn('fn_rebuild_',sql);self.assertNotIn('fn_assert_account_flow_monthly_integrity',sql)
        self.assertNotIn('fn_require_legacy_bootstrap',sql)
        self.assertNotIn('UPDATE ',sql);self.assertNotIn('INSERT ',sql)

    def test_remote_context_rejected_before_payload_and_run(self):
        meta=json.dumps([{'Endpoints':{'docker':{'Host':'ssh://untrusted'}}}])
        with patch.dict(gate.os.environ,{},clear=True),patch.object(gate.subprocess,'check_output',side_effect=['remote\n',meta]),patch.object(gate.subprocess,'run',side_effect=AssertionError('No Docker run expected')),patch.object(Path,'read_bytes',side_effect=AssertionError('No payload expected')):
            with self.assertRaises(ValueError):gate.typed_source_facts({'_input_directory':'unused'})

    def test_environment_override_cannot_hide_remote_context(self):
        with patch.dict(gate.os.environ,{'DOCKER_HOST':'unix:///var/run/docker.sock'},clear=True),patch.object(gate.subprocess,'check_output',side_effect=AssertionError('No Docker expected')):
            with self.assertRaises(ValueError):gate._local_context()

    def test_local_context_is_resolved_once_for_pinning(self):
        meta=json.dumps([{'Endpoints':{'docker':{'Host':'npipe:////./pipe/dockerDesktopLinuxEngine'}}}])
        with patch.dict(gate.os.environ,{},clear=True),patch.object(gate.subprocess,'check_output',side_effect=['desktop-linux\n',meta]):
            self.assertEqual(gate._local_context(),'desktop-linux')


class FinanceFlowGenericGateTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.fixture=Fixture(Path(self.temp.name));self.expected=self.fixture.expected()
        self.original=json.loads(self.fixture.snapshot.read_text())

    def tearDown(self):self.temp.cleanup()

    def test_actual916_requires_protocol19_even_when_expected_schema_is_low(self):
        for schema in (None,907,914,916):
            db=FakeDatabase(self.expected)
            for value in (db.results[0],db.results[1]['run']):value.update(mapping_version='bootstrap-v18',actual_schema_version=916)
            with patch.object(generic,'finance_flow_typed_source_facts',side_effect=AssertionError('No source container expected')):
                with self.assertRaisesRegex(generic.VerificationError,'bootstrap-v19'):
                    generic.verify_database(db,self.expected,self.original,RUN,schema)
            self.assertEqual(len(db.queries),1)

    def test_protocol19_requires_actual916(self):
        db=FakeDatabase(self.expected)
        for value in (db.results[0],db.results[1]['run']):value.update(mapping_version='bootstrap-v19',actual_schema_version=914)
        with self.assertRaisesRegex(generic.VerificationError,'actual V916'):
            generic.verify_database(db,self.expected,self.original,RUN)
        self.assertEqual(len(db.queries),1)

    def test_protocol19_missing_complete_source_fails_before_typing(self):
        db=FakeDatabase(self.expected)
        for value in (db.results[0],db.results[1]['run']):value.update(mapping_version='bootstrap-v19',actual_schema_version=916)
        with self.assertRaisesRegex(generic.VerificationError,'complete sealed finance flow'):
            generic.verify_database(db,self.expected,self.original,RUN)

    def configure(self):
        source,actual=successful();expected=copy.deepcopy(self.expected)
        expected.update(finance_flow_sources=source,counter_sources={},receipt_order_sources={},receipt_fee_sources={},stock_movement_sources={},production_counter_sources={},finance_master_sources={},finance_seed_baseline={})
        db=FakeDatabase(expected)
        for value in (db.results[0],db.results[1]['run']):value.update(mapping_version='bootstrap-v19',actual_schema_version=916)
        db.results[1]['counts']['schema_version']=916;db.results[1]['finance_flow_monthly']=actual
        return expected,db

    def mocks(self):
        stack=ExitStack()
        for name in ('stock_typed_source_hash','production_typed_source_facts','finance_master_typed_source_facts'):
            stack.enter_context(patch.object(generic,name,return_value={}))
        stack.enter_context(patch.object(generic,'finance_flow_typed_source_facts',side_effect=lambda source:source['typed_source_facts']))
        stack.enter_context(patch.object(generic,'facts_sql',return_value='SELECT safe_test_facts'))
        for name in ('validate_counter_baseline','validate_receipt_reference_acceptance','validate_receipt_fee_acceptance','validate_stock_acceptance'):
            stack.enter_context(patch.object(generic,name,return_value={'verified':True}))
        stack.enter_context(patch.object(generic,'validate_production_acceptance',return_value={'verified':True,'context_rows':0}))
        stack.enter_context(patch.object(generic,'validate_finance_master_acceptance',return_value={'verified':True,'origin_database_identity':{'system_identifier':'fixture-cluster','database_oid':1001}}))
        return stack

    def test_full_protocol19_projects_seventh_independent_gate(self):
        expected,db=self.configure()
        with self.mocks():result=generic.verify_database(db,expected,self.original,RUN,916)
        self.assertTrue(result['finance_flow_monthly']['verified']);self.assertEqual(result['mapping_version'],'bootstrap-v19')

    def test_missing_actual_seventh_gate_is_not_accepted(self):
        expected,db=self.configure();db.results[1].pop('finance_flow_monthly')
        with self.mocks(),self.assertRaises(generic.VerificationError):generic.verify_database(db,expected,self.original,RUN,916)

    def test_post_snapshot_schema_cannot_hide_seventh_gate(self):
        expected,db=self.configure();db.results[1]['counts']['schema_version']=914
        with self.mocks(),self.assertRaises(generic.VerificationError):generic.verify_database(db,expected,self.original,RUN)

    def test_rename_requires_identical_seventh_gate(self):
        expected,db=self.configure()
        with self.mocks():before=generic.verify_database(db,expected,self.original,RUN,916)
        before.update(database='local_rehearsal',manifest_sha256=expected['manifest_sha256'],frozen_commit=self.fixture.COMMIT if hasattr(self.fixture,'COMMIT') else db.results[0]['frozen_commit'])
        expected,db=self.configure();db.database='renamed'
        for value in (db.results[0],db.results[1]['run']):value['actual_database']='renamed'
        with self.mocks():result=generic.verify_database(db,expected,self.original,RUN,916,'local_rehearsal',before)
        self.assertTrue(result['finance_flow_monthly']['verified'])
        before['finance_flow_monthly']['target_uuid_binding_sha256']='f'*64
        expected,db=self.configure();db.database='renamed'
        for value in (db.results[0],db.results[1]['run']):value['actual_database']='renamed'
        with self.mocks(),self.assertRaisesRegex(generic.VerificationError,'monthly source projection'):
            generic.verify_database(db,expected,self.original,RUN,916,'local_rehearsal',before)


if __name__=='__main__':unittest.main()

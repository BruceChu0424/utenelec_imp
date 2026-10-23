import copy
import csv
import hashlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import verify_finance_master_sources as gate
import verify_rehearsal_result as generic
import rehearse_local_import as coordinator
from test_verify_rehearsal_result import Fixture,FakeDatabase,RUN,PRIVATE_ACCOUNT,PRIVATE_HASH


class MasterFixture:
    def __init__(self,root):
        self.root=Path(root);self.records={}
        self.write(gate.STYLE_FILE,gate.STYLE_COLUMNS,[
            dict(legacy_id=1,style_class_id=1,code='102',name='银行存款',parent_legacy=0,item_id=0),
            dict(legacy_id=2,style_class_id=1,code='102',name='PRIVATE-FUND-LABEL',parent_legacy=1,item_id=10),
            dict(legacy_id=3,style_class_id=4,code='044',name='PRIVATE-EXPENSE',parent_legacy=0,item_id=0)])
        self.write(gate.ACCOUNT_FILE,gate.ACCOUNT_COLUMNS,[dict(legacy_id=10,code='DUPLICATE',name='PRIVATE-ACCOUNT-NAME',bank_account_no='PRIVATE-BANK-NUMBER',style_legacy_id=2,status='使用')])
        self.write(gate.CURRENCY_FILE,gate.CURRENCY_COLUMNS,[dict(legacy_id=1,code='001',name='CNY',exchange_rate=1,status='使用')])
    def write(self,name,columns,rows):
        with (self.root/name).open('w',encoding='utf-8',newline='') as stream:
            writer=csv.writer(stream,delimiter='|');writer.writerow(columns)
            for row in rows:writer.writerow([row.get(key,'') for key in columns])
        path=self.root/name;self.records[name]={'file':name,'rows':len(rows),'bytes':path.stat().st_size,'sha256':gate.digest(path)}
    def source(self):return gate.source_inventory(self.root,self.records)

def proof_fixture(source):
    hashes={key:hashlib.sha256(key.encode()).hexdigest() for key in ('style_business_sha256','account_business_sha256','typed_style_rows_sha256','typed_account_rows_sha256','reference_rows_sha256','seed_business_sha256','role_business_sha256','seed_roles_before_sha256')}
    typed={'style_rows':source['style_rows'],'account_rows':source['account_rows'],**hashes,
           'reason_counts':{'BOUND':1,'NO_SOURCE_REFERENCE':2},'role_candidates':{},
           'source_roots':[{'legacy_id':1,'category':'ACCOUNT','raw_code':'102'},{'legacy_id':3,'category':'EXPENSE','raw_code':'044'}]}
    source=dict(source,typed_source_facts=typed)
    baseline={'sha256':'a'*64,'database_identity':{'system_identifier':'123456','database_oid':123},
              'data':{'database':'uten_imp_rehearsal_fixture','payment_styles':[{'id':'seed-id'}],'posting_roles':[{'role_key':'EXISTING','style_id':'seed-id'}]}}
    actual={'run_rows':1,**hashes,**{key:0 for key in gate.ZERO_INVARIANTS},
        'style_rows':source['style_rows'],'account_rows':source['account_rows'],'total_style_rows':source['style_rows']+1,
        'seed_style_rows':1,'role_rows':1,'seed_before_rows':2,'style_business_columns':list(gate.SEED_STYLE_FIELDS),
        'account_business_columns':sorted((*gate.ACCOUNT_FIELDS,'id','legacy_id')),
        'seed_before_styles_sha256':hashes['seed_business_sha256'],'reason_counts':typed['reason_counts'],
        'actual_system_identifier':'123456','actual_database_oid':123,'recorded_import_database':'uten_imp_rehearsal_fixture',
        'target_uuid_binding_sha256':'b'*64,'master_code_sequences':{'SK':source['style_rows'],'ZH':source['account_rows']},
        'source_roots':[dict(row,identity_verified=True) for row in typed['source_roots']]}
    return source,baseline,actual


class FinanceMasterSourceTest(unittest.TestCase):
    def setUp(self):self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup);self.f=MasterFixture(self.temp.name)
    def test_inventory_is_dynamic_and_private(self):
        source=self.f.source();self.assertEqual((source['style_rows'],source['account_rows']),(3,1))
        self.assertNotIn('PRIVATE-',json.dumps(source))
    def test_source_graph_cycle_is_rejected(self):
        self.f.write(gate.STYLE_FILE,gate.STYLE_COLUMNS,[dict(legacy_id=1,parent_legacy=2),dict(legacy_id=2,parent_legacy=1)])
        with self.assertRaisesRegex(ValueError,'cyclic'):self.f.source()
    def test_missing_positive_account_style_is_rejected(self):
        self.f.write(gate.ACCOUNT_FILE,gate.ACCOUNT_COLUMNS,[dict(legacy_id=10,style_legacy_id=999)])
        with self.assertRaisesRegex(ValueError,'ancestry'):self.f.source()
    def test_ambiguous_true_bank_root_is_rejected(self):
        self.f.write(gate.STYLE_FILE,gate.STYLE_COLUMNS,[dict(legacy_id=1,parent_legacy=0,style_class_id=1,code='102',name='银行存款'),dict(legacy_id=2,parent_legacy=0,style_class_id=1,code='102',name='银行存款')])
        with self.assertRaisesRegex(ValueError,'ambiguous'):self.f.source()
    def test_source_finite_amount_check(self):
        for value in ('NaN','Infinity','-Infinity'):
            self.f.write(gate.ACCOUNT_FILE,gate.ACCOUNT_COLUMNS,[dict(legacy_id=10,style_legacy_id=2,init_balance=value)])
            with self.assertRaisesRegex(ValueError,'non-finite'):self.f.source()
    def test_hash_drift_is_rejected_before_any_docker(self):
        (self.f.root/gate.ACCOUNT_FILE).write_text('changed',encoding='utf-8')
        with patch.object(gate.subprocess,'run',side_effect=AssertionError('No Docker expected')):
            with self.assertRaisesRegex(ValueError,'bytes differ'):self.f.source()
    def test_valid_complete_proof_keeps_unmapped_root_explicit(self):
        source,baseline,actual=proof_fixture(self.f.source());report=gate.validate(actual,source,baseline)
        self.assertTrue(report['verified']);self.assertEqual(report['source_style_rows'],3)
        self.assertEqual(report['unmapped_report_roots'],[{'legacy_id':3,'category':'EXPENSE','raw_code':'044'}])
        self.assertNotIn('PRIVATE-',json.dumps(report));self.assertFalse(report['historical_source_reference_is_current_approval'])
    def test_every_independent_hash_is_mandatory(self):
        source,baseline,actual=proof_fixture(self.f.source())
        for key in ('style_business_sha256','account_business_sha256','typed_style_rows_sha256','typed_account_rows_sha256','reference_rows_sha256','seed_business_sha256','role_business_sha256','seed_roles_before_sha256','seed_before_styles_sha256'):
            changed=copy.deepcopy(actual);changed[key]='f'*64
            with self.subTest(key=key),self.assertRaises(ValueError):gate.validate(changed,source,baseline)
    def test_every_native_and_relation_invariant_is_mandatory(self):
        source,baseline,actual=proof_fixture(self.f.source())
        for key in gate.ZERO_INVARIANTS:
            changed=copy.deepcopy(actual);changed[key]=1
            with self.subTest(key=key),self.assertRaises(ValueError):gate.validate(changed,source,baseline)
    def test_counts_and_source_runs_are_not_boolean_or_self_declared(self):
        source,baseline,actual=proof_fixture(self.f.source())
        for key in ('run_rows','style_rows','account_rows','seed_style_rows','role_rows'):
            changed=copy.deepcopy(actual);changed[key]=True
            with self.subTest(key=key),self.assertRaises(ValueError):gate.validate(changed,source,baseline)
    def test_schema_columns_future_business_field_is_rejected(self):
        source,baseline,actual=proof_fixture(self.f.source());actual['account_business_columns'].append('fake_future_approval')
        with self.assertRaises(ValueError):gate.validate(actual,source,baseline)
    def test_source_root_is_not_same_code_modern_identity(self):
        source,baseline,actual=proof_fixture(self.f.source());actual['source_roots'][0]['identity_verified']=False
        with self.assertRaises(ValueError):gate.validate(actual,source,baseline)
    def test_physical_database_and_seed_are_bound(self):
        source,baseline,actual=proof_fixture(self.f.source())
        for key,value in (('actual_database_oid',124),('actual_system_identifier','different'),('recorded_import_database','another')):
            changed=copy.deepcopy(actual);changed[key]=value
            with self.subTest(key=key),self.assertRaises(ValueError):gate.validate(changed,source,baseline)
    def test_display_sequence_is_not_restarted_per_depth(self):
        source,baseline,actual=proof_fixture(self.f.source());actual['master_code_sequences']['SK']=2
        with self.assertRaises(ValueError):gate.validate(actual,source,baseline)
    def test_bank_fallback_follows_known_general_aliases(self):
        sql=gate._account_type_sql();self.assertIn("('一般账户','一般帐户')",sql)
        self.assertLess(sql.index("THEN 'GENERAL'"),sql.index('source_account_ancestry'))
        self.assertIn("root.style_class_id=1",sql);self.assertIn("root.name)='银行存款'",sql)
    def test_remote_docker_is_rejected_before_source_payload(self):
        with patch.object(gate,'verify_local_docker',side_effect=ValueError('remote refused')),patch.object(gate.subprocess,'run',side_effect=AssertionError('No container expected')):
            with self.assertRaisesRegex(ValueError,'remote refused'):gate.typed_source_facts({'_input_directory':'missing'})


class FinanceProtocolGateTest(unittest.TestCase):
    def test_actual_schema914_requires_v18_even_with_low_or_missing_expected(self):
        temp=tempfile.TemporaryDirectory();self.addCleanup(temp.cleanup);fixture=Fixture(Path(temp.name))
        expected=fixture.expected();original=json.loads(fixture.snapshot.read_text(encoding='utf-8'))
        for expected_schema in (None,913,914):
            db=FakeDatabase(expected)
            for run in (db.results[0],db.results[1]['run']):run.update(mapping_version='bootstrap-v17',actual_schema_version=914)
            with self.subTest(expected_schema=expected_schema),self.assertRaisesRegex(generic.VerificationError,'bootstrap-v18'):
                generic.verify_database(db,expected,original,RUN,expected_schema)

if __name__=='__main__':unittest.main()

from pathlib import Path
import csv, tempfile, unittest
from types import SimpleNamespace
from verify_employee_bindings import Audit, number, sales_owner_graph, pin_inputs, unique_by

class FinalRunBindingTest(unittest.TestCase):
    def fixture(self,**options):
        args=SimpleNamespace(run_id='5e62d24f-21f4-4a98-bc16-66e782e3e1db',database='example_rehearsal',
            inputs=Path('inputs'),verify=True,manifest_sha256='manifest-final',sales_owner_mapper_sha256='sales-final',
            frozen_commit='commit-final',admin_user_id='11111111-1111-4111-8111-111111111111')
        for key,value in options.items():setattr(args,key,value)
        manifest={'provenance':{'importerRepositoryCommit':'commit-final','scripts':{'migrate_sales_owner.sql':'sales-final','migrate_owner_custody.sql':'shared-helper'}}}
        return args,manifest
    def test_explicit_final_inputs_are_bound_separately_from_shared_helper(self):
        args,manifest=self.fixture();binding=pin_inputs(args,manifest,'manifest-final')
        self.assertEqual('sales-final',binding['sales_owner_mapper_sha256'])
        self.assertEqual('shared-helper',binding['custody_helper_sha256'])
        self.assertEqual('commit-final',binding['frozen_commit'])
    def test_database_mode_cannot_accidentally_use_previous_manifest(self):
        args,manifest=self.fixture()
        with self.assertRaisesRegex(AssertionError,'manifest SHA mismatch'):pin_inputs(args,manifest,'manifest-previous')
    def test_database_mode_cannot_accidentally_use_previous_owner_mapper(self):
        args,manifest=self.fixture(sales_owner_mapper_sha256='sales-previous')
        with self.assertRaisesRegex(AssertionError,'mapper SHA mismatch'):pin_inputs(args,manifest,'manifest-final')
    def test_database_mode_requires_explicit_locks(self):
        args,manifest=self.fixture(manifest_sha256=None)
        with self.assertRaisesRegex(AssertionError,'requires explicit'):pin_inputs(args,manifest,'manifest-final')
    def test_explicit_final_commit_must_be_manifest_importer_commit(self):
        args,manifest=self.fixture(frozen_commit='commit-previous')
        with self.assertRaisesRegex(AssertionError,'importer commit mismatch'):pin_inputs(args,manifest,'manifest-final')
    def test_source_only_preparation_remains_available_without_target_query(self):
        args,manifest=self.fixture(verify=False,manifest_sha256=None,sales_owner_mapper_sha256=None)
        self.assertEqual('manifest-final',pin_inputs(args,manifest,'manifest-final')['derived_manifest_sha256'])
    def test_database_mode_requires_preserved_administrator_uuid(self):
        args,manifest=self.fixture(admin_user_id=None)
        with self.assertRaisesRegex(AssertionError,'administrator user UUID'):pin_inputs(args,manifest,'manifest-final')
    def test_administrator_identifier_is_uuid_validated_before_sql(self):
        args,manifest=self.fixture(admin_user_id="unsafe'identifier")
        with self.assertRaises(ValueError):pin_inputs(args,manifest,'manifest-final')

class UniqueSourceIdentityTest(unittest.TestCase):
    def test_identity_count_comes_from_source_without_a_sample_size_constant(self):
        self.assertEqual({1:{'old':'1'},2:{'old':'2'}},unique_by([{'old':'1'},{'old':'2'}],lambda row:int(row['old']),'test source'))
    def test_duplicate_source_id_cannot_disappear_in_dictionary_projection(self):
        with self.assertRaisesRegex(AssertionError,'duplicate identity'):
            unique_by([{'old':'1'},{'old':'1'}],lambda row:int(row['old']),'test source')
    def test_missing_source_id_is_rejected_before_database_access(self):
        with self.assertRaisesRegex(AssertionError,'Missing'):
            unique_by([{'old':''}],lambda row:number(row['old']),'test source')

class EmployeeBindingRulesTest(unittest.TestCase):
    def fixture(self):
        audit=Audit.__new__(Audit);audit.admin='admin';audit.issues=[];audit.pending=[]
        audit.by_legacy={409:[dict(id='current',legacy_id=409,code='UT0004',status='active',is_deleted=False)],
                         546:[dict(id='historical',legacy_id=546,code='UT0192',status='resigned',is_deleted=False)]}
        return audit
    def test_current_owner_and_historical_identity_are_different(self):
        audit=self.fixture()
        self.assertEqual(('admin','historical','SOURCE_EMPLOYEE_NOT_CURRENT'),audit.resolve_owner('546'))
        self.assertEqual('historical',audit.employee(546)['id'])
        self.assertEqual(('current','current','CURRENT_EMPLOYEE'),audit.resolve_owner('409'))
    def test_owner_public_and_unknown_text_never_guess_employee(self):
        audit=self.fixture()
        self.assertEqual((None,None,'PUBLIC_SOURCE'),audit.resolve_owner('000'))
        self.assertEqual(('admin',None,'UNRESOLVED_SOURCE_REFERENCE'),audit.resolve_owner('UT0004'))
        self.assertEqual(('admin',None,'SOURCE_EMPLOYEE_MISSING'),audit.resolve_owner('129'))
    def test_only_explicit_current_statuses_can_take_current_ownership(self):
        audit=self.fixture()
        for status in ['active','probation','onLeave']:
            audit.by_legacy[409][0]['status']=status
            self.assertEqual('current',audit.resolve_owner('409')[0])
        for status in ['resigned','unknown','retired','']:
            audit.by_legacy[409][0]['status']=status
            self.assertEqual('admin',audit.resolve_owner('409')[0])
    def test_actual_legacy_target_is_not_canonical_person_alias(self):
        audit=self.fixture();audit.crosswalk={546:dict(canonical_code='UT0004',method='duplicate_historical')}
        audit.workers={409:{},546:{}};audit.crosswalk[409]=dict(canonical_code='UT0004',method='identity')
        audit.hr_by_legacy={409:dict(emp_code='UT0004',status='active'),546:dict(emp_code='UT0192',status='resigned')}
        with tempfile.TemporaryDirectory() as folder:
            audit.out=Path(folder);audit.verify_crosswalk()
            self.assertEqual([],audit.issues)
            with (audit.out/'actual_employee_crosswalk.csv').open() as stream: rows=list(csv.DictReader(stream))
            self.assertEqual('UT0192',rows[1]['employee_code']);self.assertEqual('UT0004',rows[1]['canonical_person_alias'])
    def test_same_canonical_alias_cannot_conceal_wrong_uuid_binding(self):
        audit=self.fixture();audit.by_legacy[546][0]['code']='UT0004'
        audit.crosswalk={546:dict(canonical_code='UT0004',method='duplicate_historical')}
        audit.workers={409:{},546:{}};audit.hr_by_legacy={546:dict(emp_code='UT0192',status='resigned')}
        with tempfile.TemporaryDirectory() as folder:
            audit.out=Path(folder);audit.verify_crosswalk()
        self.assertEqual('WORKER_CROSSWALK_MISMATCH',audit.issues[0]['kind'])
    def test_legacy_zero_normalization_is_protocol_specific(self):
        self.assertIsNone(number('0'));self.assertEqual(0,number('0',False));self.assertEqual(546,number('546'))

class SalesOwnerGraphPolicyTest(unittest.TestCase):
    def data(self):
        return {'sales_orders.csv':[dict(legacy_id='11',seller_legacy='545'),dict(legacy_id='12',seller_legacy='129'),dict(legacy_id='13',seller_legacy='0')],
            'sales_shipments.csv':[dict(legacy_id='21',seller_legacy='545')],
            'sales_other_shipments.csv':[],'sales_returns.csv':[dict(legacy_id='31',seller_legacy='0')],
            'sales_order_items.csv':[dict(legacy_id=str(100+i),bill_legacy=str(10+i)) for i in range(1,4)],
            'sales_shipment_items.csv':[dict(legacy_id=str(200+i),bill_legacy='21',order_item_legacy=str(100+i)) for i in range(1,4)],
            'sales_return_items.csv':[dict(legacy_id='301',bill_legacy='31',out_item_legacy='201',order_item_legacy='101')]}
    def resolve(self,ref):
        if ref in (None,'0'):return None,None,'PUBLIC_SOURCE'
        if ref=='545':return 'UT0005','UT0005','CURRENT_EMPLOYEE'
        return 'ADMIN',None,'SOURCE_EMPLOYEE_MISSING'
    def test_mixed_source_custody_keeps_public_reference_and_every_original_seller(self):
        data=self.data();expected,conflicts,missing=sales_owner_graph(data.__getitem__,self.resolve,'ADMIN')
        ship=conflicts[('sales_shipments',21)]
        self.assertEqual('ADMIN',expected[('sales_shipments',21)][0])
        self.assertEqual('MIXED_UPSTREAM_OWNER_CUSTODY',expected[('sales_shipments',21)][2])
        self.assertEqual(['ADMIN','UT0005'],ship['resolved_owner_ids'])
        self.assertEqual([545,129,0],[r['source_seller_legacy_id'] for r in ship['upstream_references']])
        self.assertIsNone(ship['upstream_references'][2]['resolved_owner_employee_id'])
        self.assertEqual({},missing)
    def test_returns_see_final_shipment_custody_and_exact_direct_order(self):
        expected,conflicts,_=sales_owner_graph(self.data().__getitem__,self.resolve,'ADMIN')
        ret=conflicts[('sales_returns',31)]
        self.assertEqual('ADMIN',expected[('sales_returns',31)][0])
        self.assertEqual({'SHIPMENT_ITEM','ORDER_ITEM'},{r['upstream_kind'] for r in ret['upstream_references']})
        self.assertEqual([21,11],[r['upstream_document_legacy_id'] for r in ret['upstream_references']])
    def test_two_current_owners_do_not_pick_one(self):
        def resolve(ref):return ('UT0006','UT0006','CURRENT_EMPLOYEE') if ref=='129' else self.resolve(ref)
        expected,conflicts,_=sales_owner_graph(self.data().__getitem__,resolve,'ADMIN')
        self.assertEqual('ADMIN',expected[('sales_shipments',21)][0])
        self.assertEqual(['UT0005','UT0006'],conflicts[('sales_shipments',21)]['resolved_owner_ids'])
    def test_single_current_plus_public_inherits_current_and_all_public_stays_public(self):
        data=self.data();data['sales_shipment_items.csv']=[data['sales_shipment_items.csv'][0],data['sales_shipment_items.csv'][2]]
        expected,conflicts,_=sales_owner_graph(data.__getitem__,self.resolve,'ADMIN')
        self.assertEqual('UT0005',expected[('sales_shipments',21)][0]);self.assertFalse(conflicts)
        data['sales_orders.csv'][0]['seller_legacy']='0';data['sales_shipments.csv'][0]['seller_legacy']='0'
        expected,conflicts,_=sales_owner_graph(data.__getitem__,self.resolve,'ADMIN')
        self.assertIsNone(expected[('sales_shipments',21)][0]);self.assertFalse(conflicts)
    def test_missing_upstream_is_recorded_without_guessing_owner(self):
        data=self.data();data['sales_shipment_items.csv']=[dict(legacy_id='201',bill_legacy='21',order_item_legacy='999')]
        data['sales_shipments.csv'][0]['seller_legacy']='0';data['sales_return_items.csv']=[]
        expected,conflicts,missing=sales_owner_graph(data.__getitem__,self.resolve,'ADMIN')
        self.assertIsNone(expected[('sales_shipments',21)][0]);self.assertFalse(conflicts)
        self.assertEqual({'shipment_order_reference':1},missing)

if __name__=='__main__':unittest.main()

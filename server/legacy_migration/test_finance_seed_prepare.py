import ast
import copy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import rehearse_local_import as coordinator
import verify_finance_master_sources as gate
from verify_candidate import flyway_checksum
import test_rehearse_source_completeness as completeness_fixture


class SeedFixture:
    def __init__(self,root):
        self.root=Path(root);self.sql=self.root/'sql';self.sql.mkdir()
        file=self.sql/'V914__fixture.sql';file.write_text('SELECT 1;\n',encoding='utf-8')
        sources=[{'file':file.name,'sha256':gate.digest(file)}]
        style={key:None for key in gate.SEED_STYLE_FIELDS};style.update(id='00000000-0000-4000-8000-000000000001',code='SYS-TEST',category='ACCOUNT',name='SYNTHETIC SEED',status='使用',legacy_id=None)
        role={'id':'00000000-0000-4000-8000-000000000002','role_key':'AR_CONTROL','style_id':style['id'],'required_category':'ACCOUNT','description':'SYNTHETIC ROLE'}
        zero_keys=('goods','users','accounts','gl_entries','ar_ap_ledger','finance_expenses','finance_payments','finance_receipts','source_legacy_styles','finance_other_incomes','finance_bank_transfers','finance_reconciliations')
        self.data={'format':'finance-seed-baseline-v1','status':'CAPTURED_READONLY','schema_version':914,'successful_migration_count':1,'failed_migration_count':0,
            'database':'uten_imp_rehearsal_fixture','database_identity':{'system_identifier':'123456','database_oid':'123'},
            'payment_styles':[style],'posting_roles':[role],'business_counts':{key:0 for key in zero_keys},
            'applied_sql':[{'script':file.name,'checksum':flyway_checksum(file.read_bytes())}],
            'migration_sources':sources,'applied_sql_sha256':hashlib.sha256(json.dumps(sources,sort_keys=True,separators=(',',':'),ensure_ascii=False).encode()).hexdigest()}
        self.path=self.root/'baseline.synthetic.json';self.save()
    def save(self):self.path.write_text(json.dumps(self.data,indent=2)+'\n',encoding='utf-8');self.sha=gate.digest(self.path)
    def load(self):return gate.load_seed_baseline(self.path,self.sha,migration_directory=self.sql)


class FinanceSeedBaselineTest(unittest.TestCase):
    def setUp(self):self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup);self.f=SeedFixture(self.temp.name)
    def test_complete_file_sql_schema_and_uuid_capture_identity(self):
        value=self.f.load();self.assertEqual(value['database_identity'],{'system_identifier':'123456','database_oid':123})
    def test_wrong_sha_is_rejected(self):
        with self.assertRaisesRegex(ValueError,'bytes differ'):gate.load_seed_baseline(self.f.path,'0'*64,migration_directory=self.f.sql)
    def test_839_capture_cannot_be_relabelled_914(self):
        self.f.data['schema_version']=913;self.f.save()
        with self.assertRaisesRegex(ValueError,'schema'):self.f.load()
    def test_sql_native_checksum_and_actual_source_bytes_are_independent(self):
        self.f.data['applied_sql'][0]['checksum']+=1;self.f.save()
        with self.assertRaisesRegex(ValueError,'checksum'):self.f.load()
    def test_complete_sql_inventory_is_required(self):
        (self.f.sql/'V915__unexpected.sql').write_text('SELECT 2;\n')
        with self.assertRaisesRegex(ValueError,'inventory'):self.f.load()
    def test_business_or_preexisting_source_rows_are_rejected(self):
        for key in self.f.data['business_counts']:
            self.f.data['business_counts'][key]=1;self.f.save()
            with self.subTest(key=key),self.assertRaisesRegex(ValueError,'precede business'):self.f.load()
            self.f.data['business_counts'][key]=0
    def test_missing_source_columns_or_seed_legacy_identity_is_rejected(self):
        for column in ('legacy_source_code','legacy_source_item_id','legacy_source_import_run_id'):
            original=self.f.data['payment_styles'][0].pop(column);self.f.save()
            with self.subTest(column=column),self.assertRaisesRegex(ValueError,'business fields'):self.f.load()
            self.f.data['payment_styles'][0][column]=original
    def test_configured_role_cannot_reference_unknown_uuid(self):
        self.f.data['posting_roles'][0]['style_id']='00000000-0000-4000-8000-000000000999';self.f.save()
        with self.assertRaisesRegex(ValueError,'exact seed'):self.f.load()
    def test_external_sealed_provenance_and_file_sha_must_all_match(self):
        sealed=self.f.root/gate.BASELINE_FILE;sealed.write_bytes(self.f.path.read_bytes())
        provenance={'financeSeedBaselineFile':gate.BASELINE_FILE,'financeSeedBaselineSha256':self.f.sha}
        baseline=self.f.load()
        with patch.object(gate,'load_seed_baseline',return_value=baseline):
            with self.assertRaisesRegex(ValueError,'anchor differs'):gate.sealed_seed_baseline(self.f.root,provenance,self.f.path,'b'*64)
            result=gate.sealed_seed_baseline(self.f.root,provenance,self.f.path,self.f.sha)
        self.assertEqual(result['sha256'],self.f.sha)


class FinanceSeedPrepareTest(unittest.TestCase):
    def setUp(self):
        self.base=completeness_fixture.CoordinatorCompletenessTest(methodName='test_prepare_binds_aux_and_policy_shas_without_counting_archived_csv_as_loader_files')
        self.base.setUp();self.addCleanup(self.base.tearDown)
        (self.base.code/'mapping-version.txt').write_text('bootstrap-v18\n',encoding='ascii')
        seed_dir=self.base.base/'seed';seed_dir.mkdir();self.fixture=SeedFixture(seed_dir)
    def prepare(self,path,sha):
        original=coordinator.prepare_inputs
        def bound(*args,**kwargs):return original(*args,**kwargs,finance_seed_baseline=path,finance_seed_baseline_sha256=sha)
        with patch.object(coordinator,'prepare_inputs',side_effect=bound),patch.object(coordinator,'load_seed_baseline',side_effect=lambda path,sha:gate.load_seed_baseline(path,sha,migration_directory=self.fixture.sql)):
            return self.base.prepare(self.base.f.audit)
    def test_protocol18_missing_root_held_anchor_fails_before_output(self):
        with self.assertRaisesRegex(ValueError,'explicit actual finance seed'):self.prepare(None,None)
        self.assertFalse((self.base.base/'final').exists())
    def test_wrong_anchor_fails_before_any_copy(self):
        with self.assertRaisesRegex(ValueError,'bytes differ'):self.prepare(self.fixture.path,'0'*64)
        self.assertFalse((self.base.base/'final').exists())
    def test_prepare_copies_exact_json_and_binds_provenance_without_new_csv(self):
        result=self.prepare(self.fixture.path,self.fixture.sha);provenance=result['provenance']
        self.assertEqual(provenance['financeSeedBaselineSha256'],self.fixture.sha)
        self.assertEqual(provenance['financeSeedBaselineFile'],gate.BASELINE_FILE)
        self.assertEqual((self.base.base/'final'/gate.BASELINE_FILE).read_bytes(),self.fixture.path.read_bytes())
        self.assertNotIn(gate.BASELINE_FILE,{row['file'] for row in result['files']})
    def test_late_personnel_hook_follows_all_modules_before_reconciliation(self):
        source=Path(coordinator.__file__).read_text(encoding='utf-8')
        function=next(n for n in ast.parse(source).body if isinstance(n,ast.FunctionDef) and n.name=='apply')
        loop=next(n for n in ast.walk(function) if isinstance(n,ast.For) and isinstance(n.iter,ast.Call)
                  and isinstance(n.iter.func,ast.Name) and n.iter.func.id=='executable_modules')
        hook=next(n for n in ast.walk(function) if isinstance(n,ast.Call) and isinstance(n.func,ast.Name)
                  and n.func.id=='render_personnel_source_archive_sql')
        counts=next(n for n in ast.walk(function) if isinstance(n,ast.Assign)
                    and any(isinstance(t,ast.Name) and t.id=='counts' for t in n.targets))
        self.assertLess(loop.end_lineno,hook.lineno)
        self.assertLess(hook.end_lineno,counts.lineno)

if __name__=='__main__':unittest.main()

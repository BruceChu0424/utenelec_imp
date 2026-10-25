import copy,csv,json,tempfile,unittest,uuid
from pathlib import Path
import prepare_clean_master_data as clean
import prepare_goods_excel as goods
import import_product_lists as old_entry
import prepare_workshop_stock_location_policy as policy
import compose_bootstrap
import test_prepare_goods_excel as fixtures
from validate_loader_csv_contract import validate_modules

class WorkshopWarehousePolicyTest(unittest.TestCase):
 def test_real_ordinary_eight_codes_stable_and_old_target_cannot_return(self):
  rows,codes=clean.warehouse_crosswalk(Path(__file__).with_name('warehouse_crosswalk.csv'))
  self.assertEqual(set(codes.values()),{f'WH{i:06d}' for i in range(1,9)})
  self.assertEqual(codes['C01'],'WH000004');self.assertEqual(codes['01'],'WH000003')
  self.assertEqual(next(r for r in rows if r['legacy_id']=='134')['target_name'],'轨道车间仓库')
  self.assertNotIn('WH000009',codes.values())
 def test_new_targets_never_recycle_wh9_or_shift_existing_codes(self):
  base=list(clean.rows(Path(__file__).with_name('warehouse_crosswalk.csv')))
  base.append({'legacy_id':'','legacy_code':'','legacy_name':'','action':'TARGET','target_code':'AAA_NEW',
               'target_name':'受审新增普通仓','target_defective':'false','note':'fixture'})
  with tempfile.TemporaryDirectory() as t:
   p=Path(t)/'map.csv';clean.write_csv(p,list(base[0]),base);_,codes=clean.warehouse_crosswalk(p)
  self.assertEqual(codes['C01'],'WH000004');self.assertEqual(codes['XW02'],'WH000008')
  self.assertEqual(codes['AAA_NEW'],'WH000010')
 def test_workshop_labels_are_explicit_not_a_name_substring_rule(self):
  self.assertEqual(clean.classify_owning_warehouse('五金车间',{})[0],'WORKSHOP_REFERENCE')
  self.assertEqual(clean.classify_owning_warehouse('另一个五金车间',{})[0],'UNMAPPED')
  target=clean.ordinary_warehouse_targets([{'legacy_id':'134','action':'KEEP','target_name':'轨道车间','target_code':'WH000003','target_defective':'false'}])
  self.assertEqual(clean.classify_owning_warehouse('轨道车间',target)[:2],('ORDINARY','WH000003'))
  with self.assertRaisesRegex(ValueError,'synthetic ordinary TARGET'):
   clean.ordinary_warehouse_targets([{'action':'TARGET','target_name':'五金车间','target_code':'XW_NEW','target_defective':'false'}])
  with self.assertRaisesRegex(ValueError,'Retired'):
   clean.ordinary_warehouse_targets([{'action':'TARGET','target_name':'别的仓','target_code':'WH000009','target_defective':'false'}])
 def test_excel_reference_keeps_raw_and_department_without_an_ordinary_owner(self):
  f=fixtures.GoodsExcelPreparationTest();f.setUp();self.addCleanup(f.doCleanups)
  rec=f.rec(**{'所属仓库':'五金车间','生产车间':'五金车间'})
  result=f.run_prepare([rec])
  _,own=goods.read_csv(f.output/'goods_owning_warehouse.csv');self.assertEqual(own,[])
  _,refs=goods.read_csv(f.output/'goods_workshop_stock_location_review.csv')
  self.assertEqual(refs[0]['original_owning_warehouse'],'五金车间');self.assertEqual(refs[0]['workshop_code'],'WS_WJTZ')
  _,attrs=goods.read_csv(f.output/'goods_excel_attributes.csv')
  self.assertEqual(attrs[0]['workshop_name'],'五金铜铸车间')
  raw=json.loads((f.output/'goods_excel_raw.jsonl').read_text(encoding='utf-8').splitlines()[0])
  self.assertEqual(raw['values'],rec['values'])
  self.assertEqual(policy.csv_rows(f.output/policy.FILES[0]),[])
  self.assertEqual(policy.csv_rows(f.output/policy.FILES[1]),[])
  self.assertEqual(result['statistics']['workshop_warehouse_references'],1)
 def test_legacy_emit_entry_does_not_refill_retired_workshop_target(self):
  f=fixtures.GoodsExcelPreparationTest();f.setUp();self.addCleanup(f.doCleanups)
  out=f.root/'emitted.csv'
  count=old_entry.emit_owning_csv([{'name':'旧名称','warehouse':'五金车间'}],f.source/'goods.csv',f.crosswalk,out)
  self.assertEqual(count,0);self.assertEqual(policy.csv_rows(out),[])
  refs=policy.csv_rows(f.root/'emitted_workshop_references.csv')
  self.assertEqual(refs[0]['goods_legacy_id'],'17');self.assertEqual(refs[0]['original_owning_warehouse'],'五金车间')
 def test_unknown_ordinary_label_still_fails_closed(self):
  f=fixtures.GoodsExcelPreparationTest();f.setUp();self.addCleanup(f.doCleanups)
  with self.assertRaisesRegex(SystemExit,'没有可选'):
   old_entry.emit_owning_csv([{'name':'旧名称','warehouse':'未知普通仓'}],f.source/'goods.csv',f.crosswalk,f.root/'bad.csv')
 def test_real_stock_entry_prepends_checked_consumer_once(self):
  root=Path(__file__).parent
  body=(root/'migrate_stock_docs.sql').read_bytes()
  combined=compose_bootstrap.reviewed_loader_content(body,'migrate_stock_docs.sql')
  self.assertEqual(combined,compose_bootstrap.reviewed_loader_content(combined,'migrate_stock_docs.sql'))
  rendered=compose_bootstrap.compose(combined,'migrate_stock_docs.sql')
  self.assertEqual(rendered.count(b'CREATE TEMP TABLE workshop_stock_location_authority_stage ('),1)
  self.assertLess(rendered.index(b'$reviewed_workshop_stock_location$'),rendered.index(b'DELETE FROM stock_movements'))
  self.assertIn(b'reviewed.warehouse_id',rendered)
  late=(root/'migrate_rehearsal_code_sequences.sql').read_text(encoding='utf-8')
  self.assertIn("SELECT 'WH',9::bigint",late);self.assertNotIn('UPDATE warehouses',late)
 def test_actual_consumer_csv_contracts_match_generated_headers(self):
  with tempfile.TemporaryDirectory() as t:
   d=Path(t)
   policy.write_csv(d/'workshop_stock_location_crosswalk.csv',policy.CROSSWALK_COLUMNS,[])
   policy.write_csv(d/'workshop_stock_location_authority.csv',policy.AUTHORITY_COLUMNS,[])
   policy.write_csv(d/'goods_workshop_stock_location_review.csv',
    ['goods_legacy_id','goods_code','goods_name','original_owning_warehouse','workshop_code','workshop_name','owning_warehouse','resolution','source_file','source_row'],[])
   result=validate_modules([('reviewed_workshop_stock_location.sql',Path(__file__).with_name('reviewed_workshop_stock_location.sql').read_bytes())],d)
   self.assertEqual(result['copy_count'],3)
 def test_both_real_launchers_and_independent_checker_consume_the_policy(self):
  root=Path(__file__).parent
  recipe=(root/'rehearse_local_import.py').read_text(encoding='utf-8')
  self.assertIn('compose_bootstrap.reviewed_loader_content(content,name)',recipe)
  self.assertIn("prepare.add_argument('--workshop-stock-location-policy'",recipe)
  self.assertIn('workshop_locations.validate_package',recipe)
  shell=(root/'migrate.sh').read_text(encoding='utf-8')
  for file in ['goods_workshop_stock_location_review.csv',*policy.FILES]:self.assertIn('copy_manual_csv '+file,shell)
  checks=(root/'migrate_rehearsal_stock_movement_checks.sql').read_text(encoding='utf-8')
  self.assertIn('workshop_stock_location_crosswalk_stage reviewed',checks)
  self.assertNotIn('reviewed_workshop_stock_location_stage',checks,
                   'independent source acceptance must not trust the loader resolved output stage')

class ReviewedPolicyPackageTest(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
  self.root=Path(self.tmp.name);self.inputs=self.root/'inputs';self.inputs.mkdir()
  self.review=self.inputs/'review.csv';self.snapshot=self.inputs/'snapshot.json';self.approval=self.inputs/'approval.json'
  cols=['goods_legacy_id','goods_code','goods_name','original_owning_warehouse','workshop_code','owning_warehouse']
  records=[{'goods_legacy_id':key,'goods_code':code,'goods_name':name,'original_owning_warehouse':'五金车间','workshop_code':'WS_WJTZ','owning_warehouse':''} for key,(code,name) in sorted(policy.IDENTITIES.items())]
  policy.write_csv(self.review,cols,records)
  dept,warehouse,parent,actor=map(str,[uuid.uuid4(),uuid.uuid4(),uuid.uuid4(),uuid.uuid4()]);root=str(uuid.uuid4())
  self.snap={'format':'ACTUAL_OPEN_WORKSHOP_BIN_RRRO_V1','read_only':'on','xid':None,'identity':{'database':'owned_fake_future_candidate','oid':12345,'sid':'1234567890123456789'},
   'department':{'id':dept,'code':'WS_WJTZ','parent_id':parent,'is_deleted':False},'production_parent':{'id':parent,'code':'DEPT_PROD','is_deleted':False},
   'warehouse':{'id':warehouse,'parent_id':root,'workshop_department_id':dept,'is_line_side':True,'is_accountable':True,'is_defective':False,'is_deleted':False,'status':'使用'},
   'bin':{'workshop_department_id':dept,'bin_warehouse_id':warehouse,'opened_by':actor,'opened_at':'2026-10-26T04:35:58+08:00','row_version':0,'source_warehouse_id':None},
   'root_id':root,'periodic_enabled':False,'bin_row_sha256':'a'*64,'warehouse_row_sha256':'b'*64,'department_row_sha256':'c'*64}
  self.snapshot.write_text(json.dumps(self.snap,ensure_ascii=False),encoding='utf-8')
  self.auth={'format':'REVIEWED_OPEN_BIN_STOCK_LOCATION_APPROVAL_V1','approved_by_root':True,'purpose':'FOUR_EXACT_HISTORICAL_GOODS_LOCATION_ONLY',
   'review_csv_sha256':policy.sha(self.review),'opening_snapshot_sha256':policy.sha(self.snapshot),'quantity_policy':'SOURCE_VALUES_UNCHANGED','change_periodic_settings':False,
   'identity_scope':[{'goods_legacy_id':key,'goods_code':code,'goods_name':name} for key,(code,name) in sorted(policy.IDENTITIES.items())]}
  self.approval.write_text(json.dumps(self.auth,ensure_ascii=False),encoding='utf-8')
 def test_explicit_exact_package_contains_locations_not_rewritten_quantities(self):
  before=self.review.read_bytes();out=self.root/'out'
  policy.build(self.review,self.snapshot,self.approval,out);policy.validate_package(out)
  rows=policy.csv_rows(out/policy.FILES[0]);self.assertEqual(len(rows),4)
  self.assertEqual(self.review.read_bytes(),before)
  self.assertTrue(all('qty' not in row and 'amount' not in row for row in rows))
  self.assertEqual({r['goods_legacy_id'] for r in rows},set(policy.IDENTITIES))
 def test_missing_approval_or_changed_identity_cannot_guess_recent_goods(self):
  records=policy.csv_rows(self.review);a=copy.deepcopy(self.auth);a['approved_by_root']=False
  with self.assertRaisesRegex(ValueError,'AUTHORITY_REQUIRED'):policy.validate(records,self.snap,a,policy.sha(self.review),policy.sha(self.snapshot))
  records[0]['goods_code']='GD2059'
  with self.assertRaisesRegex(ValueError,'IDENTITIES_CHANGED'):policy.validate(records,self.snap,self.auth,policy.sha(self.review),policy.sha(self.snapshot))
 def test_missing_or_arbitrary_bin_is_not_opening_evidence(self):
  for mutate in [lambda x:x.update(bin=None),lambda x:x['warehouse'].update(is_line_side=False),lambda x:x['department'].update(code='WS_OTHER'),lambda x:x.update(periodic_enabled=True)]:
   x=copy.deepcopy(self.snap);mutate(x)
   with self.assertRaises(ValueError):policy.validate(policy.csv_rows(self.review),x,self.auth,policy.sha(self.review),policy.sha(self.snapshot))
 def test_authority_and_csv_tampering_are_detected(self):
  out=self.root/'out';policy.build(self.review,self.snapshot,self.approval,out)
  p=out/policy.FILES[0];p.write_bytes(p.read_bytes().replace(b'GD2056',b'GD2059'))
  with self.assertRaisesRegex(ValueError,'OUTPUT_DRIFT'):policy.validate_package(out)

if __name__=='__main__':unittest.main()

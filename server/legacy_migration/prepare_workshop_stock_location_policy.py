"""File-only explicit policy for four historical identities. Never connects or opens a bin."""
from pathlib import Path
import argparse,csv,hashlib,json,re,shutil,uuid

IDENTITIES={
 '65919':('GD2056','B款暗装轨道E极铜条（90型）'),
 '65920':('GD2057','B款暗装轨道LN极铜条（90型  磨床切割）'),
 '65921':('GD2058','B款暗装轨道PVC线槽（90型）'),
 '65923':('GD2060','B款暗装铝合金轨道90型（铣床加工）')}
CROSSWALK_COLUMNS=['goods_legacy_id','goods_code','goods_name','workshop_code','bin_warehouse_id','authority_sha256']
AUTHORITY_COLUMNS=['format','approved','target_database','target_database_oid','target_sid','workshop_code',
 'workshop_department_id','bin_warehouse_id','bin_row_sha256','warehouse_row_sha256','department_row_sha256',
 'opened_by','opened_at','source_warehouse_id','bin_row_version','authority_sha256','snapshot_sha256','review_sha256']
FILES=('workshop_stock_location_crosswalk.csv','workshop_stock_location_authority.csv')
def sha(path):
 with Path(path).open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
def read(path):return json.loads(Path(path).read_text(encoding='utf-8-sig'))
def need(ok,code):
 if not ok:raise ValueError(code)
def csv_rows(path):
 with Path(path).open(encoding='utf-8-sig',newline='') as f:return list(csv.DictReader(f,delimiter='|'))
def write_csv(path,columns,records):
 with Path(path).open('x',encoding='utf-8',newline='') as f:
  w=csv.DictWriter(f,fieldnames=columns,delimiter='|',lineterminator='\n');w.writeheader();w.writerows(records)

def validate(review,snapshot,approval,review_sha,snapshot_sha):
 need(approval.get('format')=='REVIEWED_OPEN_BIN_STOCK_LOCATION_APPROVAL_V1'
      and approval.get('approved_by_root') is True
      and approval.get('purpose')=='FOUR_EXACT_HISTORICAL_GOODS_LOCATION_ONLY'
      and approval.get('review_csv_sha256')==review_sha
      and approval.get('opening_snapshot_sha256')==snapshot_sha
      and approval.get('quantity_policy')=='SOURCE_VALUES_UNCHANGED'
      and approval.get('change_periodic_settings') is False,'EXPLICIT_REVIEWED_AUTHORITY_REQUIRED')
 expected=[{'goods_legacy_id':key,'goods_code':value[0],'goods_name':value[1]} for key,value in sorted(IDENTITIES.items())]
 need(approval.get('identity_scope')==expected,'EXACT_LEGACY_CODE_NAME_SCOPE_REQUIRED')
 observed=[{k:r[k] for k in ('goods_legacy_id','goods_code','goods_name')} for r in review]
 need(sorted(observed,key=lambda x:x['goods_legacy_id'])==expected,'SOURCE_IDENTITIES_CHANGED_OR_AMBIGUOUS')
 need(all(r['original_owning_warehouse']=='五金车间' and r['workshop_code']=='WS_WJTZ'
          and not r.get('owning_warehouse') for r in review),'WORKSHOP_REFERENCE_NOT_ORDINARY_OWNER')
 need(snapshot.get('format')=='ACTUAL_OPEN_WORKSHOP_BIN_RRRO_V1' and snapshot.get('read_only')=='on'
      and snapshot.get('xid') is None,'ACTUAL_READONLY_OPENING_SNAPSHOT_REQUIRED')
 d,w,b,parent=snapshot.get('department') or {},snapshot.get('warehouse') or {},snapshot.get('bin') or {},snapshot.get('production_parent') or {}
 need(d.get('code')=='WS_WJTZ' and d.get('is_deleted') is False
      and parent.get('code')=='DEPT_PROD' and parent.get('is_deleted') is False
      and d.get('parent_id')==parent.get('id'),'EXACT_PRODUCTION_DEPARTMENT_REQUIRED')
 need(b.get('workshop_department_id')==d.get('id') and b.get('bin_warehouse_id')==w.get('id')
      and b.get('opened_by') and b.get('opened_at') and type(b.get('row_version')) is int
      and w.get('workshop_department_id')==d.get('id') and w.get('is_line_side') is True
      and w.get('is_accountable') is True and w.get('is_defective') is False and w.get('is_deleted') is False
      and w.get('status')=='使用' and w.get('parent_id')==snapshot.get('root_id')
      and snapshot.get('periodic_enabled') is False,'ACTUAL_UNIFIED_OPEN_BIN_REQUIRED_NO_PERIODIC')
 need(b.get('source_warehouse_id') is None or snapshot.get('source_is_good_stock_leaf') is True,'INVALID_ORDINARY_SOURCE_WAREHOUSE')
 for x in (d['id'],w['id'],b['opened_by']):uuid.UUID(x)
 need(all(re.fullmatch('[0-9a-f]{64}',snapshot.get(key,'')) for key in
          ('bin_row_sha256','warehouse_row_sha256','department_row_sha256')),'PG_ROW_HASHES_REQUIRED')
 ident=snapshot.get('identity',{})
 need(type(ident.get('oid')) is int and ident['oid']>0 and str(ident.get('sid','')).isdigit()
      and re.fullmatch('[a-z_][a-z0-9_]{0,62}',ident.get('database','')),'ACTUAL_TARGET_IDENTITY_REQUIRED')

def build(review_path,snapshot_path,approval_path,out):
 paths=list(map(lambda p:Path(p).resolve(),[review_path,snapshot_path,approval_path]));out=Path(out).resolve()
 need(all(out!=p.parent and p.parent not in out.parents for p in paths),'POLICY_OUTPUT_MUST_NOT_MUTATE_INPUT_DIRECTORY')
 need(not out.exists() or not any(out.iterdir()),'NEW_EMPTY_POLICY_DIRECTORY_REQUIRED')
 review=csv_rows(paths[0]);snap,approval=read(paths[1]),read(paths[2]);rs,ss,auth=sha(paths[0]),sha(paths[1]),sha(paths[2])
 validate(review,snap,approval,rs,ss)
 out.mkdir(parents=True,exist_ok=True)
 for src,name in zip(paths,['goods_workshop_stock_location_review.csv','opening-snapshot.json','approval.json']):shutil.copyfile(src,out/name)
 b,d,w=snap['bin'],snap['department'],snap['warehouse'];ident=snap['identity']
 write_csv(out/FILES[0],CROSSWALK_COLUMNS,[{'goods_legacy_id':key,'goods_code':code,'goods_name':name,
   'workshop_code':'WS_WJTZ','bin_warehouse_id':w['id'],'authority_sha256':auth} for key,(code,name) in sorted(IDENTITIES.items())])
 row={'format':'REVIEWED_OPEN_BIN_HISTORICAL_STOCK_V1','approved':'true','target_database':ident['database'],
  'target_database_oid':ident['oid'],'target_sid':ident['sid'],'workshop_code':'WS_WJTZ','workshop_department_id':d['id'],
  'bin_warehouse_id':w['id'],'bin_row_sha256':snap['bin_row_sha256'],'warehouse_row_sha256':snap['warehouse_row_sha256'],
  'department_row_sha256':snap['department_row_sha256'],'opened_by':b['opened_by'],'opened_at':b['opened_at'],
  'source_warehouse_id':b.get('source_warehouse_id') or '', 'bin_row_version':b['row_version'],
  'authority_sha256':auth,'snapshot_sha256':ss,'review_sha256':rs}
 write_csv(out/FILES[1],AUTHORITY_COLUMNS,[row])
 manifest={'format':'reviewed-workshop-stock-location-policy-v1','source_review_sha256':rs,
  'opening_snapshot_sha256':ss,'approval_sha256':auth,'quantity_fields_changed':0,'periodic_changes':0,
  'generator_sha256':sha(__file__),'outputs':[{'file':p.name,'sha256':sha(p)} for p in sorted(out.iterdir()) if p.is_file()]}
 (out/'LOCATION_POLICY_MANIFEST.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
 return manifest

def validate_package(directory):
 directory=Path(directory);m=read(directory/'LOCATION_POLICY_MANIFEST.json')
 need(m.get('format')=='reviewed-workshop-stock-location-policy-v1' and m.get('generator_sha256')==sha(__file__),'LOCATION_POLICY_GENERATOR_CHANGED')
 for rec in m['outputs']:need(sha(directory/rec['file'])==rec['sha256'],'LOCATION_POLICY_OUTPUT_DRIFT')
 need(set(r['file'] for r in m['outputs'])==set(FILES)|{'goods_workshop_stock_location_review.csv','opening-snapshot.json','approval.json'},'LOCATION_POLICY_INVENTORY_CHANGED')
 need(sha(directory/'goods_workshop_stock_location_review.csv')==m['source_review_sha256']
      and sha(directory/'opening-snapshot.json')==m['opening_snapshot_sha256'],'LOCATION_POLICY_SOURCE_BINDING_DRIFT')
 validate(csv_rows(directory/'goods_workshop_stock_location_review.csv'),read(directory/'opening-snapshot.json'),read(directory/'approval.json'),m['source_review_sha256'],m['opening_snapshot_sha256'])
 need(sha(directory/'approval.json')==m['approval_sha256'],'LOCATION_AUTHORITY_DRIFT')
 snapshot=read(directory/'opening-snapshot.json');b,d,w=snapshot['bin'],snapshot['department'],snapshot['warehouse']
 cross=csv_rows(directory/FILES[0]);auth=csv_rows(directory/FILES[1])
 need(cross==[{'goods_legacy_id':key,'goods_code':code,'goods_name':name,'workshop_code':'WS_WJTZ',
              'bin_warehouse_id':w['id'],'authority_sha256':m['approval_sha256']} for key,(code,name) in sorted(IDENTITIES.items())],
      'LOCATION_CROSSWALK_NOT_EXACT_APPROVED_SCOPE')
 expected={'format':'REVIEWED_OPEN_BIN_HISTORICAL_STOCK_V1','approved':'true',
  'target_database':snapshot['identity']['database'],'target_database_oid':str(snapshot['identity']['oid']),
  'target_sid':str(snapshot['identity']['sid']),'workshop_code':'WS_WJTZ','workshop_department_id':d['id'],
  'bin_warehouse_id':w['id'],'bin_row_sha256':snapshot['bin_row_sha256'],
  'warehouse_row_sha256':snapshot['warehouse_row_sha256'],'department_row_sha256':snapshot['department_row_sha256'],
  'opened_by':b['opened_by'],'opened_at':b['opened_at'],'source_warehouse_id':b.get('source_warehouse_id') or '',
  'bin_row_version':str(b['row_version']),'authority_sha256':m['approval_sha256'],
  'snapshot_sha256':m['opening_snapshot_sha256'],'review_sha256':m['source_review_sha256']}
 need(auth==[expected],'LOCATION_AUTHORITY_CSV_NOT_EXACT_APPROVED_SNAPSHOT')
 return m

OPENING_SQL="""BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET LOCAL TimeZone='Asia/Shanghai';
SELECT jsonb_build_object('format','ACTUAL_OPEN_WORKSHOP_BIN_RRRO_V1','read_only',current_setting('transaction_read_only'),'xid',txid_current_if_assigned()::text,
 'identity',jsonb_build_object('database',current_database(),'oid',(SELECT oid::bigint FROM pg_database WHERE datname=current_database()),'sid',(SELECT system_identifier::text FROM pg_control_system())),
 'department',to_jsonb(d),'production_parent',to_jsonb(parent),'warehouse',to_jsonb(w),'bin',to_jsonb(b),
 'root_id',fn_warehouse_root_id(),'source_is_good_stock_leaf',CASE WHEN b.source_warehouse_id IS NULL THEN NULL ELSE fn_warehouse_is_good_stock_leaf(b.source_warehouse_id) END,
 'periodic_enabled',COALESCE(s.periodic_enabled,false),
 'bin_row_sha256',encode(sha256(convert_to(to_jsonb(b)::text,'UTF8')),'hex'),
 'warehouse_row_sha256',encode(sha256(convert_to(to_jsonb(w)::text,'UTF8')),'hex'),
 'department_row_sha256',encode(sha256(convert_to(to_jsonb(d)::text,'UTF8')),'hex'))
FROM departments d JOIN departments parent ON parent.id=d.parent_id
JOIN workshop_bins b ON b.workshop_department_id=d.id JOIN warehouses w ON w.id=b.bin_warehouse_id
LEFT JOIN workshop_material_settings s ON s.workshop_department_id=d.id
WHERE d.code='WS_WJTZ' AND NOT d.is_deleted;
ROLLBACK;
"""
def main():
 p=argparse.ArgumentParser();p.add_argument('--review',type=Path);p.add_argument('--opening-snapshot',type=Path);p.add_argument('--approval',type=Path);p.add_argument('--out-dir',type=Path);p.add_argument('--emit-opening-sql',type=Path);a=p.parse_args()
 if a.emit_opening_sql:
  with a.emit_opening_sql.open('xb') as f:f.write(OPENING_SQL.encode('utf-8'))
  return
 need(all([a.review,a.opening_snapshot,a.approval,a.out_dir]),'EXPLICIT_INPUT_FILES_REQUIRED')
 print(json.dumps(build(a.review,a.opening_snapshot,a.approval,a.out_dir),ensure_ascii=False))
if __name__=='__main__':main()

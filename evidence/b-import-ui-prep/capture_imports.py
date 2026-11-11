"""Read-only complete synthetic import receipts and business fingerprints.
Keep each before/after path new; source bytes and private credentials are omitted.
"""
from pathlib import Path
import argparse,json,psycopg2
from psycopg2.extras import RealDictCursor
from datetime import datetime,timezone
p=argparse.ArgumentParser();p.add_argument('--config',required=True);p.add_argument('--out',required=True);a=p.parse_args();out=Path(a.out)
if out.exists():raise SystemExit('Preserve old evidence')
config=json.loads(Path(a.config).read_text(encoding='utf-8-sig'));assert config['jdbcUrl']=='jdbc:postgresql://127.0.0.1:26630/feedback'
result={'status':'prep/read-only; SQL is not browser interaction evidence','capturedAtUtc':datetime.now(timezone.utc).isoformat(),'fingerprints':{},'receipts':{}}
with psycopg2.connect(host='127.0.0.1',port=26630,dbname='feedback',user=config['username'],password=config['password']) as db:
 db.set_session(readonly=True,isolation_level='REPEATABLE READ')
 with db.cursor(cursor_factory=RealDictCursor) as c:
  for table in ['goods','goods_bom_items','goods_cost_import_mappings','finance_chart_codes','finance_operating_report_notes','finance_auxiliary_items','gl_entries','finance_gl_opening_baselines','finance_accounting_period_coverage','system_posting_style_roles']:
   c.execute("SELECT count(*) count,md5(COALESCE(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text)::text,'[]')) content_md5 FROM "+table+' t');result['fingerprints'][table]=dict(c.fetchone())
  for table in ['goods_import_batches','goods_cost_imports','finance_chart_imports','finance_expense_note_imports','finance_statement_source_reviews','finance_accounting_import_batches','finance_template_sources']:
   c.execute("SELECT column_name FROM information_schema.columns WHERE table_schema='public' AND table_name=%s",(table,));columns={row['column_name'] for row in c.fetchall()}
   if not columns:result['receipts'][table]={'tablePresent':False};continue
   wanted=['id','actor_id','created_by','goods_id','kind','period','source_system','source_name','source_filename','file_name','sha256','status','row_version','parent_import_id','applied_at','directory_applied_at','applied_result','result']
   selected=[name for name in wanted if name in columns]
   if 'preview' in columns:selected += ["preview->>'columnContractVersion' column_contract_version","jsonb_array_length(COALESCE(preview->'issues','[]'::jsonb)) issues_count"]
   c.execute('SELECT '+','.join(selected)+' FROM '+table+' ORDER BY id');result['receipts'][table]=list(c.fetchall())
out.parent.mkdir(parents=True,exist_ok=True);out.write_bytes(json.dumps(result,ensure_ascii=False,indent=2,default=str).encode('utf8'));print('Wrote complete read-only import evidence '+str(out))

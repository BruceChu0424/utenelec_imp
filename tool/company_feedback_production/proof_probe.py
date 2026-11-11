from pathlib import Path
import subprocess as sp,uuid,time,json,argparse,textwrap
from decimal import Decimal
parser=argparse.ArgumentParser();parser.add_argument('--root',type=Path,default=Path(__file__).resolve().parents[2]);parser.add_argument('--output',type=Path,required=True)
a=parser.parse_args();root=a.root.resolve();p=a.output.resolve();p.mkdir(parents=True,exist_ok=True)
if (p/'candidate-legacy-repeat.log').exists():raise SystemExit('Choose a fresh output directory to preserve evidence')
def run(args,sql=None):
 r=sp.run(args,input=sql,stdout=sp.PIPE,stderr=sp.STDOUT,encoding='utf8',errors='replace')
 if r.returncode: raise RuntimeError(r.stdout)
 return r.stdout
fixture=(root/'server/src/test/java/com/uten/imp/migration/PartialMaterialReportCapacityPostgresTest.java').read_text(encoding='utf8')
bootstrap=textwrap.dedent(fixture.split('db.execute("""',1)[1].split('""");',1)[0]).strip()
v609=(root/'server/src/main/resources/db/migration/V609__execution_material_capacity_snapshot.sql').read_text(encoding='utf8')
def original_function(name):
 sql=v609[v609.index('CREATE FUNCTION '+name+'('):]
 return sql[:sql.index('$$;',sql.index(' AS $$'))+3].replace('CREATE FUNCTION ','CREATE OR REPLACE FUNCTION ',1)
seed="""
INSERT INTO production_execution_segments(id,planned_qty,material_snapshot_product_qty,material_requirement_mode) VALUES(md5('segment')::uuid,20,20,'DEMANDED');
INSERT INTO production_material_demands(id,execution_segment_id,required_qty) VALUES(md5('material')::uuid,md5('segment')::uuid,20);
INSERT INTO production_material_stock_postings(id,event_id,demand_id,posting_type,qty_base) VALUES(md5('issue')::uuid,md5('issue-event')::uuid,md5('material')::uuid,'ISSUE',10);
INSERT INTO production_material_stock_postings(id,event_id,demand_id,posting_type,qty_base,source_posting_id) VALUES(md5('return')::uuid,md5('return-event')::uuid,md5('material')::uuid,'GOOD_RETURN',9,md5('issue')::uuid);
"""
base=bootstrap+'\n'+original_function('fn_material_snapshot_required')+'\n'+original_function('fn_demand_material_output_capacity')+'\n'+seed+'\n'+(root/'server/src/main/resources/db/migration/V1129__partial_material_reporting_capacity.sql').read_text(encoding='utf8')
forward=(root/'server/src/main/resources/db/migration/V1130__verify_legacy_material_basis_and_linear_proof_sweep.sql').read_text(encoding='utf8')
name='uten-remediate-a-'+uuid.uuid4().hex[:9]
run(['docker','run','-d','--name',name,'--network','none','-e','POSTGRES_HOST_AUTH_METHOD=trust','postgres:16-alpine'])
cmd=['docker','exec','-i',name,'psql','-X','-qAt','-v','ON_ERROR_STOP=1','-U','postgres']
try:
 for _ in range(60):
  if not sp.run(['docker','exec',name,'pg_isready','-h','127.0.0.1','-U','postgres'],capture_output=True).returncode:time.sleep(.5);break
  time.sleep(.25)
 oldchecks="""SELECT 'baseline_before_cap',fn_execution_partial_material_report_room(md5('segment')::uuid); UPDATE production_execution_segments SET planned_qty=10; SELECT 'baseline_after_cap',fn_execution_partial_material_report_room(md5('segment')::uuid);"""
 (p/'baseline-legacy-repeat.log').write_text(run(cmd,base+oldchecks),encoding='utf8')
 upgrade=forward
 checks="""SELECT 'candidate_current_capacity',fn_execution_material_output_capacity(md5('segment')::uuid,TRUE); SELECT 'candidate_checkpoint_valid',fn_execution_full_kit_checkpoint_valid(md5('segment')::uuid); SELECT 'candidate_room',fn_execution_partial_material_report_room(md5('segment')::uuid); DO $$ BEGIN IF fn_execution_partial_material_report_room(md5('segment')::uuid)<>1 THEN RAISE EXCEPTION 'must remain capped at 1'; END IF;END;$$;"""
 (p/'candidate-legacy-repeat.log').write_text(run(cmd,upgrade+checks),encoding='utf8')
 steps="(n INT) RETURNS void LANGUAGE plpgsql AS $$\nDECLARE s uuid := md5('new segment')::uuid; d uuid:=md5('new material')::uuid;\n        first_issue uuid:=md5('first issue')::uuid; later_issue uuid; k int;\nBEGIN\n  INSERT INTO production_execution_segments(id,planned_qty,material_requirement_mode) VALUES(s,10,'DEMANDED');\n  INSERT INTO production_material_demands(id,execution_segment_id,required_qty) VALUES(d,s,10);\n  INSERT INTO production_material_stock_postings(id,event_id,demand_id,posting_type,qty_base) VALUES(first_issue,gen_random_uuid(),d,'ISSUE',10);\n  PERFORM fn_capture_execution_full_material_kit(s);\n  FOR k IN 1..n LOOP\n    later_issue:=gen_random_uuid();\n    INSERT INTO production_material_stock_postings(id,event_id,demand_id,posting_type,qty_base) VALUES(later_issue,gen_random_uuid(),d,'ISSUE',1);\n    PERFORM fn_capture_execution_full_material_kit(s);\n    INSERT INTO production_material_stock_postings(id,event_id,demand_id,posting_type,qty_base,source_posting_id) VALUES(gen_random_uuid(),gen_random_uuid(),d,'ISSUE_REVERSE',1,later_issue);\n    PERFORM fn_capture_execution_full_material_kit(s);\n  END LOOP;\n  INSERT INTO production_material_stock_postings(id,event_id,demand_id,posting_type,qty_base,source_posting_id) VALUES(gen_random_uuid(),gen_random_uuid(),d,'ISSUE_REVERSE',10,first_issue);\nEND; $$;\n\n"
 run(cmd,'CREATE FUNCTION audit_capture_cycles'+steps)
 body=forward.split(' RETURN (',1)[1].split('END;\n$$;',1)[0].rstrip()[:-2]
 body=body.replace('p_stock_order IS NULL OR proof.source_stock_order=p_stock_order','TRUE').replace('=p_segment',"=md5('new segment')::uuid")
 for cycles in [256,512,1024]:
  setup=f"""TRUNCATE production_material_full_kit_proof_items,production_material_full_kit_proofs,production_material_stock_postings,production_material_demands,production_execution_segments; SELECT audit_capture_cycles({cycles}); ANALYZE;"""
  t=time.monotonic(); result=run(cmd,setup);write=time.monotonic()-t
  timing=run(cmd,"\\timing on\n"+"SELECT fn_execution_partial_material_report_room(md5('new segment')::uuid);\n"*3)
  (p/f'candidate-hot-read-{cycles}.log').write_text(timing,encoding='utf8')
  outputs=[]
  for _ in range(3):
   t=time.monotonic();value=run(cmd,"SELECT fn_execution_partial_material_report_room(md5('new segment')::uuid)").strip();elapsed=time.monotonic()-t
   assert Decimal(value)==Decimal('0'),value;outputs.append({'result':value,'wallMs':round(elapsed*1000,2)})
  plan=json.loads(run(cmd,'EXPLAIN (ANALYZE,BUFFERS,FORMAT JSON) '+body))[0]
  (p/f'candidate-proof-plan-{cycles}.json').write_text(json.dumps(plan,indent=2),encoding='utf8')
  nodes=[]
  def walk(n):
   if 'Relation Name' in n:nodes.append({k:n.get(k) for k in ['Relation Name','Alias','Actual Rows','Actual Loops']})
   for c in n.get('Plans',[]):walk(c)
  walk(plan['Plan'])
  print(json.dumps({'cycles':cycles,'proofs':2*cycles+1,'writeSeconds':round(write,2),'reads':outputs,'executionMs':plan['Execution Time'],'nodes':nodes}),flush=True)
finally:
 run(['docker','rm','-f',name])



"""Explicit synthetic-only SQL/READ ONLY adversarial smoke, never a candidate DB.

The fixture deliberately allows corruption so the independent verifier, rather
than production triggers, must reject it. Migration guard regression is separate.
"""
import argparse
import hashlib
import io
import json
from pathlib import Path
import subprocess
import tempfile
import time
import uuid
from unittest.mock import patch

import verify_production_counter_baseline as production
import verify_rehearsal_result as generic
from test_verify_rehearsal_result import Fixture,RUN
from test_verify_production_counter_baseline import populate

def lit(value):return "'"+str(value).replace("'","''")+"'"

def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--output-directory',type=Path,required=True);args=parser.parse_args()
    out=args.output_directory.resolve()
    if out.exists():parser.error('Use a new private evidence directory')
    out.mkdir(parents=True,exist_ok=False)
    real_run=subprocess.run;name='uten-production-verify-smoke-'+uuid.uuid4().hex[:12];owned=name;created=False
    report={'format':'production-baseline-readonly-adversarial-smoke-v1','candidate_connected':False,
            'production_source_or_secrets_read':False,'network':'none','status':'FAILED','cases':[],
            'script_sha256_at_start':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
            'helper_sha256_at_start':hashlib.sha256(Path(production.__file__).read_bytes()).hexdigest(),
            'generic_sha256_at_start':hashlib.sha256(Path(generic.__file__).read_bytes()).hexdigest()}
    def command(args,data=None,timeout=90):return real_run(args,input=data,capture_output=True,timeout=timeout)
    def execute(sql):
        result=command(['docker','exec','-i',owned,'psql','-X','-qAt','-U','uten','-d','verifier','-v','ON_ERROR_STOP=1'],sql.encode())
        if result.returncode:raise ValueError('Owned synthetic SQL failed; raw source/server output withheld')
        return result.stdout
    try:
        production.verify_local_docker()
        result=command(['docker','run','-d','--network','none','--name',name,'-e','POSTGRES_USER=uten','-e','POSTGRES_PASSWORD=synthetic-fixture-only','-e','POSTGRES_DB=verifier','postgres:16-alpine'])
        if result.returncode:raise ValueError('Owned synthetic PostgreSQL startup failed')
        created=True
        for _ in range(60):
            if command(['docker','exec',name,'pg_isready','-U','uten','-d','verifier']).returncode==0:break
            time.sleep(.15)
        else:raise ValueError('Owned synthetic PostgreSQL did not become ready')
        meta=json.loads(command(['docker','inspect',name]).stdout)[0]
        if meta['HostConfig']['NetworkMode']!='none' or meta['HostConfig']['PortBindings']:raise ValueError('Synthetic network isolation differs')
        owned=meta['Id']
        with tempfile.TemporaryDirectory() as folder:
            fixture=Fixture(Path(folder));expected=populate(fixture);source=expected['production_counter_sources']
            source['typed_source_facts']=production.typed_source_facts(source)
            for filename in (production.ITEM_FILE,production.PARENT_FILE,production.OPERATOR_FILE):
                data=(fixture.inputs/filename).read_bytes()
                if command(['docker','exec','-i',owned,'sh','-c','cat > /tmp/'+filename],data).returncode:raise ValueError('Synthetic source transfer failed')
            uuid_fields={'id',production.RUN_COLUMN,'plan_id','goods_id','color_id','mgoods_id','unit_id','sales_order_item_id'}
            dates={'bill_date','order_date','outbound_date','plan_begin_date','plan_end_date'}
            integers={'legacy_id','line_no','lstatus','cstatus','step_legacy_id','veil_legacy_id','ass_team_legacy_id'}
            numerics=set(production.COUNTERS)|{'finished_weight','inbound_weight','discount','capped_qty'}
            def field_type(field):
                if field in uuid_fields:return 'uuid'
                if field in dates:return 'date'
                if field in integers:return 'integer'
                if field in numerics:return 'numeric(18,4)'
                if field=='unit_rate':return 'numeric(18,6)'
                if field=='allowed_overproduction_rate':return 'numeric(9,6)'
                if field=='is_deleted':return 'boolean'
                return 'text'
            sql='''CREATE EXTENSION pgcrypto;
CREATE FUNCTION public.fn_legacy_finance_snapshot(p_row jsonb,p_fields text[]) RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
 SELECT COALESCE(jsonb_object_agg(key,CASE WHEN jsonb_typeof(value)='number' THEN to_jsonb(trim_scale((value#>>'{}')::numeric)) ELSE value END),'{}'::jsonb)
 FROM jsonb_each(p_row) WHERE key=ANY(p_fields) $$;
CREATE TABLE goods(id uuid PRIMARY KEY,legacy_id int,production_overproduction_rate numeric,source_type text,is_deleted boolean DEFAULT false);
CREATE TABLE goods_bom_items(goods_id uuid,component_goods_id uuid,is_deleted bool,control_stage text);
CREATE FUNCTION fn_goods_structural_overproduction_rate(p_goods uuid) RETURNS numeric LANGUAGE sql STABLE AS $$
 SELECT CASE WHEN g.source_type IN('采购','委外') THEN 0::numeric
 WHEN EXISTS(SELECT 1 FROM goods_bom_items bom JOIN goods component ON component.id=bom.component_goods_id
 WHERE bom.goods_id=g.id AND NOT bom.is_deleted AND bom.control_stage NOT IN('SHIP','REFERENCE')
 AND (component.source_type IN('自制','委外') OR EXISTS(SELECT 1 FROM goods_bom_items child
 WHERE child.goods_id=component.id AND NOT child.is_deleted AND child.control_stage NOT IN('SHIP','REFERENCE')))) THEN 0::numeric ELSE .10 END
 FROM goods g WHERE g.id=p_goods AND NOT g.is_deleted $$;
CREATE FUNCTION fn_goods_default_overproduction_rate(p_goods uuid) RETURNS numeric LANGUAGE sql STABLE AS $$
 SELECT COALESCE(g.production_overproduction_rate,fn_goods_structural_overproduction_rate(g.id)) FROM goods g WHERE g.id=p_goods AND NOT g.is_deleted $$;
CREATE TABLE colors(id uuid,legacy_id int);CREATE TABLE units(id uuid,legacy_id int);
CREATE TABLE sales_order_items(id uuid,legacy_id int);
CREATE TABLE production_plans(id uuid PRIMARY KEY,legacy_id int,bill_no text,bill_date date,f_style text,delivery_date date,
workshop_name text,worker_name text,seller_name text,maker_legacy_id int,approver_legacy_id int,maker_name text,approver_name text,
remark text,status int,is_closed bool,is_stopped bool,is_canceled bool,source_daily_report_id uuid,maker_id uuid,approver_id uuid,
auto_generated bool DEFAULT false,material_analysis_id uuid,material_analysis_item_id uuid,actual_output_supplement_request_id uuid);
CREATE TABLE legacy_migration_runs(run_id uuid,target text,migration_mode text,database_user text,export_manifest_sha256 text,checksum_manifest_sha256 text,
migration_repository_commit text,migration_script_sha256 text,mapping_version text,source_backup_sha256 text,export_approval_reference text,reconciliation_summary jsonb);
CREATE TABLE legacy_production_plan_counter_import_contexts(run_id uuid,issued_txid bigint,origin_system_identifier text,origin_database_oid oid,origin_database_name text,evidence jsonb,evidence_sha256 char(64));
CREATE TABLE production_execution_segments(id uuid);CREATE TABLE production_daily_reports(id uuid);
CREATE TABLE production_daily_report_items(id uuid);CREATE TABLE production_overproduction_rate_requests(id uuid);
CREATE TABLE production_overproduction_rate_decisions(id uuid);CREATE TABLE stock_document_items(id uuid,source_daily_report_item_id uuid,execution_segment_id uuid,execution_segment_sales_allocation_id uuid);
'''
            sql+='CREATE TABLE production_plan_items('+','.join(field+' '+field_type(field) for field in production.TARGET_FIELDS)+',created_at timestamptz DEFAULT now(),updated_at timestamptz DEFAULT now(),created_by uuid,updated_by uuid);\n'
            sql+=f'''CREATE TABLE {production.PROOF_TABLE}(id uuid,run_id uuid,source_kind text,source_legacy_id int,source_parent_legacy_id int,
target_table text,target_id uuid,target_plan_id uuid,source_file text,source_parent_file text,source_file_sha256 char(64),source_parent_file_sha256 char(64),
source_row_sha256 char(64),source_parent_row_sha256 char(64),source_reference_legacy_ids jsonb,parent_identity_sha256 char(64),run_evidence_sha256 char(64),
target_fields text[],target_snapshot_sha256 char(64),issued_txid bigint);
CREATE TEMP TABLE source_stage({production.ITEM_DDL});CREATE TEMP TABLE parent_stage({production.PARENT_DDL});
CREATE TEMP TABLE operator_stage(legacy_id int PRIMARY KEY,name text);CREATE TEMP TABLE upstream_stage(legacy_id int PRIMARY KEY);
\\copy source_stage FROM '/tmp/production_plan_items.csv' WITH(FORMAT csv,DELIMITER '|',HEADER true)
\\copy parent_stage FROM '/tmp/production_plans.csv' WITH(FORMAT csv,DELIMITER '|',HEADER true)
\\copy operator_stage FROM '/tmp/legacy_operators_ref.csv' WITH(FORMAT csv,DELIMITER '|',HEADER true)
'''
            for old in (10,11,12):sql+=f"INSERT INTO goods VALUES(md5('g{old}')::uuid,{old},NULL,'自制',false);\n"
            for old in source['_upstream_ids']:sql+=f"INSERT INTO sales_order_items VALUES(md5('so{old}')::uuid,{old});INSERT INTO upstream_stage VALUES({old});\n"
            sql+="INSERT INTO units VALUES(md5('unit301')::uuid,301);INSERT INTO colors VALUES(md5('color401')::uuid,401);\n"
            header=production._source_header_payload_sql()
            sql+='CREATE TEMP TABLE header_payloads AS SELECT '+header+"||jsonb_build_object('id',md5('plan-'||h.legacy_id)::uuid) payload FROM parent_stage h;\n"
            header_columns=['id',*production.HEADER_FIELDS]
            sql+='INSERT INTO production_plans('+','.join(header_columns)+') SELECT '+','.join('x.'+field for field in header_columns)+' FROM header_payloads p CROSS JOIN LATERAL jsonb_populate_record(NULL::production_plans,p.payload) x;\n'
            summary={'targetDatabase':'verifier','targetSystemIdentifier':'synthetic-only-cluster','targetApprovalReference':'synthetic-approved','importAtomicity':'single-transaction-v1','sourceSnapshotAsOfUtc':source['source_snapshot_as_of_utc']}
            values=[RUN,'--bootstrap-all','BOOTSTRAP','uten',expected['manifest_sha256'],expected['manifest_sha256'],expected['frozen_commit'],'a'*64,'bootstrap-v17','b'*64,'synthetic-reviewed',json.dumps(summary)]
            sql+='INSERT INTO legacy_migration_runs VALUES('+','.join(lit(v) for v in values[:-1])+','+lit(values[-1])+"::jsonb||jsonb_build_object('targetSystemIdentifier',(SELECT system_identifier::text FROM pg_control_system())));\n"
            source_payload=production._source_payload_sql()
            sql+='CREATE TEMP TABLE original_rows AS SELECT s.*,to_jsonb(s) source_json,to_jsonb(h) parent_json,'+source_payload+' normalized FROM source_stage s JOIN parent_stage h ON h.legacy_id=s.plan_legacy_id LEFT JOIN upstream_stage upstream ON upstream.legacy_id=NULLIF(s.s_order_item_legacy,0);\n'
            sql+=f'''CREATE TEMP TABLE target_payloads AS SELECT o.*,o.normalized||jsonb_build_object('id',md5('target-'||o.legacy_id)::uuid,'{production.RUN_COLUMN}','{RUN}'::uuid,
'plan_id',p.id,'goods_id',g.id,'color_id',c.id,'mgoods_id',mg.id,'unit_id',u.id,'sales_order_item_id',so.id,
'allowed_overproduction_rate',fn_goods_default_overproduction_rate(g.id)) payload
FROM original_rows o JOIN production_plans p ON p.legacy_id=o.plan_legacy_id
JOIN goods g ON g.legacy_id=o.goods_legacy_id LEFT JOIN colors c ON c.legacy_id=NULLIF(o.color_legacy_id,0)
LEFT JOIN goods mg ON mg.legacy_id=NULLIF(o.mgoods_legacy_id,0) LEFT JOIN units u ON u.legacy_id=o.unit_legacy_id
LEFT JOIN sales_order_items so ON so.legacy_id=NULLIF(o.s_order_item_legacy,0);
'''
            columns=','.join(production.TARGET_FIELDS)
            sql+='INSERT INTO production_plan_items('+columns+') SELECT '+','.join('t.'+x for x in production.TARGET_FIELDS)+' FROM target_payloads p CROSS JOIN LATERAL jsonb_populate_record(NULL::production_plan_items,p.payload)t;\n'
            # Extract the exact independent run JSON expression from the verifier
            # only for fixture proof minting; adversarial cases below re-sign it
            # and still must fail independent source hashes.
            run_hash="encode(digest("+production._run_evidence_sql()+"::text,'sha256'),'hex')"
            sql+=f"INSERT INTO legacy_production_plan_counter_import_contexts SELECT r.run_id,10001,(SELECT system_identifier::text FROM pg_control_system()),(SELECT oid FROM pg_database WHERE datname=current_database()),current_database(),{production._run_evidence_sql()},{run_hash} FROM legacy_migration_runs r;\n"
            fields=production._fields_sql(production.TARGET_FIELDS)
            sql+=f'''INSERT INTO {production.PROOF_TABLE}
SELECT md5('proof-'||x.legacy_id)::uuid,'{RUN}'::uuid,'PRODUCTION_PLAN_ITEM',x.legacy_id,x.plan_legacy_id,'production_plan_items',
(x.payload->>'id')::uuid,(x.payload->>'plan_id')::uuid,'production_plan_items.csv','production_plans.csv',
'{source['file_sha256']}','{source['parent_file_sha256']}',encode(digest(x.source_json::text,'sha256'),'hex'),encode(digest(x.parent_json::text,'sha256'),'hex'),
jsonb_build_object('goods_legacy_id',x.goods_legacy_id,'color_legacy_id',x.color_legacy_id,'mgoods_legacy_id',x.mgoods_legacy_id,'unit_legacy_id',x.unit_legacy_id,'s_order_item_legacy',x.s_order_item_legacy),
encode(digest(jsonb_build_object('id',p.id,'legacy_id',p.legacy_id,'bill_no',p.bill_no,'bill_date',p.bill_date)::text,'sha256'),'hex'),{run_hash},
{fields},encode(digest(fn_legacy_finance_snapshot(x.payload,{fields})::text,'sha256'),'hex'),10001
FROM target_payloads x JOIN production_plans p ON p.id=(x.payload->>'plan_id')::uuid CROSS JOIN legacy_migration_runs r;
CREATE TABLE baseline_targets AS TABLE production_plan_items;
CREATE TABLE baseline_proofs AS TABLE {production.PROOF_TABLE};
CREATE TABLE baseline_headers AS TABLE production_plans;
CREATE TABLE baseline_goods AS TABLE goods;
CREATE TABLE baseline_runs AS TABLE legacy_migration_runs;
CREATE TABLE baseline_contexts AS TABLE legacy_production_plan_counter_import_contexts;
'''
            execute(sql)
            def route(argv,**kwargs):
                if argv[:4]!=['docker','exec','-i','uten-imp-postgres']:raise AssertionError('Verifier attempted an unexpected subprocess')
                args=argv.copy();args[3]=owned;return real_run(args,**kwargs)
            def actual(database='verifier'):
                with patch.object(generic.subprocess,'run',side_effect=route):
                    db=generic.ReadOnlyDatabase(database)
                    return db.query('SELECT ('+production.acceptance_sql(RUN,source)+');')
            with patch.object(generic.subprocess,'run',side_effect=route):
                readonly=generic.ReadOnlyDatabase('verifier').query("SELECT jsonb_build_object('read_only',current_setting('transaction_read_only'),'isolation',current_setting('transaction_isolation'));")
            if readonly!={'read_only':'on','isolation':'repeatable read'}:raise ValueError('Target read-only snapshot differs')
            proof=production.validate(actual(),source)
            report['cases'].append({'case':'valid_independent_full_source_and_target','status':'PASS'})
            resign=f"UPDATE {production.PROOF_TABLE} p SET target_snapshot_sha256=encode(digest(fn_legacy_finance_snapshot(to_jsonb(t),p.target_fields)::text,'sha256'),'hex') FROM production_plan_items t WHERE t.id=p.target_id;"
            changes=[('tampered_typed_item_row_sha',f"UPDATE {production.PROOF_TABLE} SET source_row_sha256=repeat('f',64) WHERE source_legacy_id=101;"),
             ('tampered_typed_parent_row_sha',f"UPDATE {production.PROOF_TABLE} SET source_parent_row_sha256=repeat('f',64) WHERE source_legacy_id=101;"),
             ('wrong_parent_file_sha',f"UPDATE {production.PROOF_TABLE} SET source_parent_file_sha256=repeat('f',64);"),
             ('wrong_raw_reference',f"UPDATE {production.PROOF_TABLE} SET source_reference_legacy_ids=jsonb_set(source_reference_legacy_ids,'{{goods_legacy_id}}','999') WHERE source_legacy_id=101;"),
             ('unknown_item_self_resigned',f'UPDATE production_plan_items SET legacy_id=999 WHERE legacy_id=101;UPDATE {production.PROOF_TABLE} SET source_legacy_id=999 WHERE source_legacy_id=101;'+resign),
             ('business_text_self_resigned',"UPDATE production_plan_items SET client_name='WRONG' WHERE legacy_id=101;"+resign),
             ('wrong_master_self_resigned',"UPDATE production_plan_items SET goods_id=md5('g12')::uuid WHERE legacy_id=101;"+resign),
             ('same_uuid_master_identity_drift',"UPDATE goods SET legacy_id=999 WHERE legacy_id=10;"),
             ('wrong_unit_self_resigned',"UPDATE production_plan_items SET unit_id=md5('unit301')::uuid WHERE legacy_id=101;"+resign),
             ('dangling_unit_uuid_self_resigned',"UPDATE production_plan_items SET unit_id=gen_random_uuid() WHERE legacy_id=101;"+resign),
             ('modern_unit_without_legacy_identity_self_resigned',"INSERT INTO units VALUES(md5('modern-unit')::uuid,NULL);UPDATE production_plan_items SET unit_id=md5('modern-unit')::uuid WHERE legacy_id=101;"+resign),
             ('wrong_upstream_self_resigned',"UPDATE production_plan_items SET sales_order_item_id=(SELECT id FROM sales_order_items LIMIT 1) WHERE legacy_id=101;"+resign),
             ('dangling_upstream_uuid_self_resigned',"UPDATE production_plan_items SET sales_order_item_id=gen_random_uuid() WHERE legacy_id=101;"+resign),
             ('wrong_parent_uuid_self_resigned',"UPDATE production_plan_items SET plan_id=gen_random_uuid() WHERE legacy_id=101;"+resign),
             ('wrong_target_uuid',"UPDATE production_plan_items SET id=gen_random_uuid() WHERE legacy_id=101;"),
             ('forged_line_no_self_resigned',"UPDATE production_plan_items SET line_no=99 WHERE legacy_id=101;"+resign),
             ('wrong_parent_header_status',"UPDATE production_plans SET status=99;"),
             ('header_actor_namespace_misbinding',"UPDATE production_plans SET maker_id=gen_random_uuid();"),
             ('fake_remembered_allowance',"UPDATE goods SET production_overproduction_rate=.9;UPDATE production_plan_items SET allowed_overproduction_rate=.9;"+resign),
             ('fake_report',"INSERT INTO production_daily_report_items VALUES(gen_random_uuid());"),
             ('fake_modern_surplus_route',"INSERT INTO stock_document_items VALUES(gen_random_uuid(),gen_random_uuid(),NULL,NULL);"),
             ('fake_execution',"INSERT INTO production_execution_segments VALUES(gen_random_uuid());"),
             ('wrong_protocol_fields',f"UPDATE {production.PROOF_TABLE} SET target_fields=ARRAY['id','legacy_id'];"),
             ('wrong_context_origin_oid',"UPDATE legacy_production_plan_counter_import_contexts SET origin_database_oid=1;"),
             ('wrong_context_issued_txid',"UPDATE legacy_production_plan_counter_import_contexts SET issued_txid=10002;"),
             ('missing_context',"DELETE FROM legacy_production_plan_counter_import_contexts;"),
             ('self_signed_wrong_context_without_run_change',"UPDATE legacy_production_plan_counter_import_contexts SET evidence=jsonb_set(evidence,'{targetApprovalReference}',to_jsonb('synthetic-forged'::text));UPDATE legacy_production_plan_counter_import_contexts SET evidence_sha256=encode(digest(evidence::text,'sha256'),'hex');UPDATE "+production.PROOF_TABLE+" p SET run_evidence_sha256=c.evidence_sha256 FROM legacy_production_plan_counter_import_contexts c WHERE c.run_id=p.run_id;"),
             ('self_signed_wrong_source_cutoff',"UPDATE legacy_migration_runs SET reconciliation_summary=jsonb_set(reconciliation_summary,'{sourceSnapshotAsOfUtc}',to_jsonb('2099-01-01T00:00:00Z'::text));UPDATE legacy_production_plan_counter_import_contexts c SET evidence="+production._run_evidence_sql()+" FROM legacy_migration_runs r WHERE r.run_id=c.run_id;UPDATE legacy_production_plan_counter_import_contexts SET evidence_sha256=encode(digest(evidence::text,'sha256'),'hex');UPDATE "+production.PROOF_TABLE+" p SET run_evidence_sha256=c.evidence_sha256 FROM legacy_production_plan_counter_import_contexts c WHERE c.run_id=p.run_id;"),
             ('fake_new_capacity_column',"ALTER TABLE production_plan_items ADD COLUMN fake_modern_capacity numeric DEFAULT 999;"),
            ]
            changes += [(f'counter_{field}_self_resigned',f'UPDATE production_plan_items SET {field}={field}+1 WHERE legacy_id=101;'+resign) for field in production.COUNTERS]
            for label,mutation in changes:
                execute(mutation)
                try:production.validate(actual(),source)
                except ValueError:pass
                else:raise ValueError('Synthetic corruption was not rejected: '+label)
                report['cases'].append({'case':label,'status':'PASS'})
                if label=='fake_new_capacity_column':execute('ALTER TABLE production_plan_items DROP COLUMN fake_modern_capacity;')
                execute(f'''TRUNCATE production_plan_items,{production.PROOF_TABLE},production_plans,goods,legacy_migration_runs,legacy_production_plan_counter_import_contexts,
production_daily_report_items,stock_document_items,production_execution_segments;
INSERT INTO production_plan_items SELECT * FROM baseline_targets;
INSERT INTO {production.PROOF_TABLE} SELECT * FROM baseline_proofs;
INSERT INTO production_plans SELECT * FROM baseline_headers;
INSERT INTO goods SELECT * FROM baseline_goods;
INSERT INTO legacy_migration_runs SELECT * FROM baseline_runs;''')
                execute('INSERT INTO legacy_production_plan_counter_import_contexts SELECT * FROM baseline_contexts;')
            renamed=command(['docker','exec','-i',owned,'psql','-X','-qAt','-U','uten','-d','postgres','-v','ON_ERROR_STOP=1'],b'ALTER DATABASE verifier RENAME TO verifier_after;')
            if renamed.returncode:raise ValueError('Owned synthetic rename failed')
            if production.validate(actual('verifier_after'),source)!=proof:raise ValueError('Production context/source/UUID continuity changed after legitimate database rename')
            report['cases'].append({'case':'actual_database_rename_keeps_cluster_oid_source_context','status':'PASS'})
            report['status']='PASSED';report['read_only_snapshot']=readonly
            report['verified_safe_projection']=proof
    finally:
        report['container_removed']=not created or command(['docker','rm','-f','-v',owned]).returncode==0
        for key,path in (('script',Path(__file__)),('helper',Path(production.__file__)),('generic',Path(generic.__file__))):
            report[key+'_sha256_at_end']=hashlib.sha256(path.read_bytes()).hexdigest()
            if report[key+'_sha256_at_end']!=report[key+'_sha256_at_start']:report['status']='FAILED_CODE_CHANGED_DURING_TEST'
        (out/'production-readonly-smoke-receipt.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
    print(json.dumps({'status':report['status'],'passed':len(report['cases']),'container_removed':report['container_removed']}))
    if report['status']!='PASSED' or not report['container_removed']:raise SystemExit(1)

if __name__=='__main__':main()

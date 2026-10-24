"""Independent sealed-source/READ ONLY acceptance for V913 initial production facts.

Offline inventory never calls Docker or a database. Actual typed row hashes are
computed only on explicit post-SUCCESS verification in an owned network-none
PostgreSQL. No quantities, original descriptions or complete rows are returned.
"""
from collections import defaultdict
import argparse
import csv
from decimal import Decimal, InvalidOperation
from datetime import datetime
import hashlib
import io
import json
from pathlib import Path
import re
import subprocess
import time
import uuid

from verify_stock_typed_source_hashes import verify_local_docker

ITEM_FILE='production_plan_items.csv'
PARENT_FILE='production_plans.csv'
UPSTREAM_FILE='sales_order_items.csv'
OPERATOR_FILE='legacy_operators_ref.csv'
KIND='PRODUCTION_PLAN_ITEM'
TABLE='production_plan_items'
PROOF_TABLE='legacy_production_plan_counter_import_sources'
CONTEXT_TABLE='legacy_production_plan_counter_import_contexts'
RUN_COLUMN='legacy_production_import_run_id'
COUNTERS=('oqty','qty','lqty','iqty','fqty','rqty','bqty','tqty','paqty','isrqty','cpqty','poqty','piqty')
ITEM_COLUMNS=('legacy_id','plan_legacy_id','product_no','goods_legacy_id','color_legacy_id','mgoods_legacy_id',
 'unit_legacy_id','unit_rate','s_order_item_legacy','sales_order_no','client_name','client_no',*COUNTERS,
 'order_date','outbound_date','plan_begin_date','plan_end_date','finished_weight','inbound_weight','lstatus','cstatus',
 'step_legacy_id','veil_legacy_id','ass_team_legacy_id','fittings','request_note','customer_model','discount',
 'label_no','plan_app_no','in_no','tran_no','remark')
PARENT_COLUMNS=('legacy_id','bill_no','bill_date','f_style','delivery_date','workshop_name','worker_name','seller_name',
 'maker_legacy','approver_legacy','remark','status','fulfill_bit','stop_bit','cancel_bit')
OPERATOR_COLUMNS=('legacy_id','name')
HEADER_FIELDS=tuple(sorted(('legacy_id','bill_no','bill_date','f_style','delivery_date','workshop_name','worker_name','seller_name',
 'maker_legacy_id','approver_legacy_id','maker_name','approver_name','remark','status','is_closed','is_stopped','is_canceled',
 'source_daily_report_id','maker_id','approver_id')))
TARGET_FIELDS=tuple(sorted(('id',RUN_COLUMN,'legacy_id','bill_no','bill_date','plan_id','line_no','product_no',
 'goods_id','color_id','mgoods_id','unit_id','unit_rate','sales_order_item_id','sales_order_no','client_name','client_no',
 *COUNTERS,'order_date','outbound_date','plan_begin_date','plan_end_date','finished_weight','inbound_weight','lstatus','cstatus',
 'step_legacy_id','veil_legacy_id','ass_team_legacy_id','fittings','request_note','customer_model','discount','label_no',
 'plan_app_no','source_doc_no','remark','is_deleted','capped_qty','allowed_overproduction_rate','allowed_overproduction_rate_source')))
# The source-derived projection covers every business field except the goods'
# structure-derived default rate. Its independent policy check below is separate
# from the self-signed proof snapshot; rate-source DEFAULT is included here.
NORMALIZED_FIELDS=tuple(sorted(set(TARGET_FIELDS)-{'id',RUN_COLUMN,'allowed_overproduction_rate'}
                                | {'__parent_bill_no','__parent_bill_date'}))
ITEM_DDL='''legacy_id int,plan_legacy_id int,product_no text,goods_legacy_id int,color_legacy_id int,mgoods_legacy_id int,
unit_legacy_id int,unit_rate numeric(18,6),s_order_item_legacy int,sales_order_no text,client_name text,client_no text,
oqty numeric(18,4),qty numeric(18,4),lqty numeric(18,4),iqty numeric(18,4),fqty numeric(18,4),rqty numeric(18,4),
bqty numeric(18,4),tqty numeric(18,4),paqty numeric(18,4),isrqty numeric(18,4),cpqty numeric(18,4),poqty numeric(18,4),piqty numeric(18,4),
order_date date,outbound_date date,plan_begin_date date,plan_end_date date,finished_weight numeric(18,4),inbound_weight numeric(18,4),
lstatus smallint,cstatus smallint,step_legacy_id int,veil_legacy_id int,ass_team_legacy_id int,fittings text,request_note text,
customer_model text,discount numeric(18,4),label_no text,plan_app_no text,in_no text,tran_no text,remark text'''
PARENT_DDL='''legacy_id int,bill_no text,bill_date date,f_style text,delivery_date date,workshop_name text,worker_name text,
seller_name text,maker_legacy int,approver_legacy int,remark text,status smallint,fulfill_bit boolean,stop_bit boolean,cancel_bit boolean'''

def _require(ok,message):
    if not ok:raise ValueError(message)

def _sha(lines):return hashlib.sha256(''.join(lines).encode()).hexdigest()

def _integer(value,positive=False,require=_require):
    require(isinstance(value,str) and re.fullmatch(r'-?[0-9]+',value or '') is not None,'Production source integer identity is absent or invalid')
    result=int(value)
    require(-(2**31)<=result<2**31 and (not positive or result>0),'Production source identity is outside its exact integer domain')
    return result

def _read(directory,name,records,columns=None,require=_require):
    record=records[name];path=Path(directory)/name;data=path.read_bytes()
    require(re.fullmatch('[0-9a-f]{64}',record['sha256']) is not None and hashlib.sha256(data).hexdigest()==record['sha256'],
            'Production sealed source SHA-256 differs')
    require('bytes' not in record or len(data)==record['bytes'],'Production sealed source byte count differs')
    require(type(record['rows']) is int and record['rows']>=0,'Production sealed source row count is invalid')
    reader=csv.DictReader(io.StringIO(data.decode('utf-8-sig'),newline=''),delimiter='|',strict=True)
    require(reader.fieldnames and len(reader.fieldnames)==len(set(reader.fieldnames)),'Production source CSV header is absent or duplicated')
    if columns is not None:require(tuple(reader.fieldnames)==columns,'Production complete typed source CSV shape differs')
    rows=list(reader)
    require(len(rows)==record['rows'] and all(None not in row for row in rows),'Production source CSV row count or shape differs')
    return rows

def source_inventory(directory,records,require=_require):
    """Default/offline path: source metadata only; no Docker, target or secrets."""
    names=(ITEM_FILE,PARENT_FILE,UPSTREAM_FILE,OPERATOR_FILE,'production_daily_reports.csv','production_daily_report_items.csv')
    if not all(name in records for name in names):return None
    source_snapshot=json.loads((Path(directory)/'derived_inputs.json').read_text(encoding='utf-8-sig')).get('sourceSnapshotAsOfUtc')
    require(isinstance(source_snapshot,str),'Production approved source cutoff is absent')
    try:parsed_snapshot=datetime.fromisoformat(source_snapshot.replace('Z','+00:00'))
    except ValueError:require(False,'Production approved source cutoff shape differs')
    require(parsed_snapshot.tzinfo is not None,'Production approved source cutoff lacks its timezone')
    items=_read(directory,ITEM_FILE,records,ITEM_COLUMNS,require)
    parents=_read(directory,PARENT_FILE,records,PARENT_COLUMNS,require)
    upstream=_read(directory,UPSTREAM_FILE,records,require=require)
    operators=_read(directory,OPERATOR_FILE,records,OPERATOR_COLUMNS,require)
    operator_ids=[_integer(row['legacy_id'],True,require) for row in operators]
    require(len(operator_ids)==len(set(operator_ids)),'Production frozen operator reference identity is duplicated')
    for name in ('production_daily_reports.csv','production_daily_report_items.csv'):
        require(records[name]['rows']==0,'Nonempty legacy production reports require a separately implemented protocol')
    parent_ids={};item_ids=set();parent_lines=defaultdict(list)
    for row in parents:
        old=_integer(row['legacy_id'],True,require)
        require(old not in parent_ids,'Production source parent identity is duplicated')
        parent_ids[old]=row
    for row in items:
        old=_integer(row['legacy_id'],True,require);parent=_integer(row['plan_legacy_id'],True,require)
        require(old not in item_ids,'Production source item identity is duplicated');item_ids.add(old)
        require(parent in parent_ids,'Production source item has no exact original parent header')
        parent_lines[parent].append(old)
        for field in COUNTERS:
            try:number=Decimal(row[field] or '0')
            except (InvalidOperation,ValueError):require(False,'Production source counter numeric shape differs')
            require(number.is_finite(),'Production source counter is not finite')
            if field in ('qty','fqty','iqty'):require(number>=0,'Production source planned/finished/inbound quantity cannot be negative')
    upstream_ids=set()
    for row in upstream:
        old=_integer(row['legacy_id'],True,require)
        require(old not in upstream_ids,'Production upstream source identity is duplicated');upstream_ids.add(old)
    lines={old:line for values in parent_lines.values() for line,old in enumerate(sorted(values),1)}
    return {'source_file':ITEM_FILE,'source_parent_file':PARENT_FILE,'rows':len(items),'parent_rows':len(parents),
       'source_snapshot_as_of_utc':source_snapshot,
       'file_sha256':records[ITEM_FILE]['sha256'],'parent_file_sha256':records[PARENT_FILE]['sha256'],
       'source_ids_sha256':_sha(str(old)+'\n' for old in sorted(item_ids)),
       'parent_ids_sha256':_sha(str(old)+'\n' for old in sorted(parent_ids)),
       'source_parent_line_sha256':_sha(f"{int(r['legacy_id'])}|{int(r['plan_legacy_id'])}|{lines[int(r['legacy_id'])]}\n" for r in sorted(items,key=lambda r:int(r['legacy_id']))),
       'upstream_ids_sha256':_sha(str(old)+'\n' for old in sorted(upstream_ids)),
       'files':{name:{'sha256':records[name]['sha256'],'rows':records[name]['rows']} for name in names},
       '_input_directory':str(Path(directory).resolve()),'_upstream_ids':sorted(upstream_ids)}

def _fields_sql(fields):return 'ARRAY['+','.join("'"+x+"'" for x in sorted(fields))+']::text[]'

def _snapshot_sql(expression,fields):
    # This local SQL helper has the identical pure numeric normalization as V626,
    # and does not invoke registration, source projection or bootstrap context.
    return 'private_snapshot('+expression+','+_fields_sql(fields)+')'

def _source_payload_sql():
    same=('product_no','order_date','outbound_date','plan_begin_date','plan_end_date','finished_weight','inbound_weight',
          'lstatus','cstatus','step_legacy_id','veil_legacy_id','ass_team_legacy_id','discount')
    nullable=('sales_order_no','client_name','client_no','fittings','request_note','customer_model','label_no','plan_app_no','remark')
    pairs=["'legacy_id',s.legacy_id","'bill_no',h.bill_no","'bill_date',h.bill_date","'plan_id',s.plan_legacy_id",
        "'line_no',row_number() OVER(PARTITION BY s.plan_legacy_id ORDER BY s.legacy_id)",
        "'goods_id',NULLIF(s.goods_legacy_id,0)","'color_id',NULLIF(s.color_legacy_id,0)",
        "'mgoods_id',NULLIF(s.mgoods_legacy_id,0)","'unit_id',NULLIF(s.unit_legacy_id,0)",
        "'unit_rate',COALESCE(s.unit_rate,1)","'sales_order_item_id',upstream.legacy_id",
        "'is_deleted',false","'capped_qty',NULL","'allowed_overproduction_rate_source','DEFAULT'",
        "'__parent_bill_no',h.bill_no","'__parent_bill_date',h.bill_date"]
    pairs += [f"'{field}',s.{field}" for field in same]
    pairs += [f"'{field}',NULLIF(s.{field},'')" for field in nullable]
    pairs += [f"'{field}',COALESCE(s.{field},0)" for field in COUNTERS]
    pairs += ["'source_doc_no',CONCAT_WS(' | ',CASE WHEN NULLIF(s.in_no,'') IS NOT NULL THEN 'IN:'||s.in_no END,CASE WHEN NULLIF(s.tran_no,'') IS NOT NULL THEN 'TRAN:'||s.tran_no END)"]
    # jsonb_build_object has a 100-argument ceiling; this projection has >50
    # keys, so concatenate bounded chunks instead of depending on source shape.
    return '||'.join('jsonb_build_object('+','.join(pairs[start:start+24])+')' for start in range(0,len(pairs),24))


def _source_header_payload_sql():
    pairs=[f"'{field}',h.{field}" for field in ('legacy_id','bill_no','bill_date','delivery_date','status')]
    pairs += [f"'{field}',NULLIF(h.{field},'')" for field in ('f_style','workshop_name','worker_name','seller_name','remark')]
    pairs += ["'maker_legacy_id',h.maker_legacy","'approver_legacy_id',h.approver_legacy",
      "'maker_name',(SELECT NULLIF(name,'') FROM operator_stage WHERE legacy_id=h.maker_legacy)",
      "'approver_name',(SELECT NULLIF(name,'') FROM operator_stage WHERE legacy_id=h.approver_legacy)",
      "'is_closed',COALESCE(h.fulfill_bit,false)","'is_stopped',COALESCE(h.stop_bit,false)",
      "'is_canceled',COALESCE(h.cancel_bit,false)","'source_daily_report_id',NULL","'maker_id',NULL","'approver_id',NULL"]
    return 'jsonb_build_object('+','.join(pairs)+')'

def typed_source_facts(source):
    """Explicit online acceptance only: local context first, own isolated PG."""
    verify_local_docker()
    directory=Path(source['_input_directory']);name='uten-production-source-hash-'+uuid.uuid4().hex[:12]
    created=False;owned=name
    def command(args,data=None,timeout=90):
        try:return subprocess.run(args,input=data,capture_output=True,timeout=timeout)
        except (OSError,subprocess.SubprocessError):raise ValueError('Owned production source PostgreSQL is unavailable; details withheld') from None
    def check(ok):_require(ok,'Owned production typed-source verification failed; raw server details withheld')
    try:
        result=command(['docker','run','-d','--name',name,'--network','none','-e','POSTGRES_HOST_AUTH_METHOD=trust','postgres:16-alpine'])
        check(result.returncode==0);created=True
        for _ in range(60):
            # Only the final server listens on TCP; the initialization server is socket-only.
            if command(['docker','exec',name,'pg_isready','-h','127.0.0.1','-U','postgres']).returncode==0:break
            time.sleep(.15)
        else:check(False)
        result=command(['docker','inspect',name]);check(result.returncode==0);meta=json.loads(result.stdout)[0]
        check(meta['HostConfig']['NetworkMode']=='none' and not meta['HostConfig']['PortBindings'])
        check(meta.get('Name')=='/'+name and isinstance(meta.get('Id'),str)
              and re.fullmatch('[0-9a-f]{64}',meta['Id']) is not None)
        owned=meta['Id']  # Pin all payload operations and cleanup to this owned container ID.
        for filename,columns in ((ITEM_FILE,ITEM_COLUMNS),(PARENT_FILE,PARENT_COLUMNS),(OPERATOR_FILE,OPERATOR_COLUMNS)):
            data=(directory/filename).read_bytes()
            check(hashlib.sha256(data).hexdigest()==source['files'][filename]['sha256'])
            check(tuple(next(csv.reader(io.StringIO(data.decode('utf-8-sig')),delimiter='|')))==columns)
            check(command(['docker','exec','-i',owned,'sh','-c','cat > /tmp/'+filename],data).returncode==0)
        # Pin the upstream identity source bytes again before using the sealed
        # offline ID inventory. No source order quantities or names are copied.
        check(hashlib.sha256((directory/UPSTREAM_FILE).read_bytes()).hexdigest()==source['files'][UPSTREAM_FILE]['sha256'])
        upstream=''.join(str(old)+'\n' for old in source['_upstream_ids']).encode()
        check(hashlib.sha256(upstream).hexdigest()==source['upstream_ids_sha256'])
        check(command(['docker','exec','-i',owned,'sh','-c','cat > /tmp/upstream.csv'],upstream).returncode==0)
        sql=['CREATE EXTENSION pgcrypto;',f'CREATE TEMP TABLE source_stage({ITEM_DDL});',f'CREATE TEMP TABLE parent_stage({PARENT_DDL});',
             'CREATE TEMP TABLE upstream_stage(legacy_id int PRIMARY KEY);CREATE TEMP TABLE operator_stage(legacy_id int PRIMARY KEY,name text);',
             "\\copy source_stage FROM '/tmp/production_plan_items.csv' WITH(FORMAT csv,DELIMITER '|',HEADER true)",
             "\\copy parent_stage FROM '/tmp/production_plans.csv' WITH(FORMAT csv,DELIMITER '|',HEADER true)",
             "\\copy operator_stage FROM '/tmp/legacy_operators_ref.csv' WITH(FORMAT csv,DELIMITER '|',HEADER true)",
             "\\copy upstream_stage FROM '/tmp/upstream.csv' WITH(FORMAT csv,DELIMITER '|')",
             '''CREATE FUNCTION private_snapshot(p_row jsonb,p_fields text[]) RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
 SELECT COALESCE(jsonb_object_agg(key,CASE WHEN jsonb_typeof(value)='number' THEN to_jsonb(trim_scale((value#>>'{}')::numeric)) ELSE value END),'{}'::jsonb)
 FROM jsonb_each(p_row) WHERE key=ANY(p_fields) $$;''',
             'CREATE INDEX ON parent_stage(legacy_id); ANALYZE parent_stage; ANALYZE source_stage; ANALYZE upstream_stage;',
             'CREATE TEMP TABLE independently_expected AS SELECT s.legacy_id,s.plan_legacy_id,',
             "row_number() OVER(PARTITION BY s.plan_legacy_id ORDER BY s.legacy_id)::int AS line_no,",
             "encode(digest(to_jsonb(s.*)::text,'sha256'),'hex') AS item_row_sha,",
             "encode(digest(to_jsonb(h.*)::text,'sha256'),'hex') AS parent_row_sha,",
             "jsonb_build_object('goods_legacy_id',s.goods_legacy_id,'color_legacy_id',s.color_legacy_id,'mgoods_legacy_id',s.mgoods_legacy_id,'unit_legacy_id',s.unit_legacy_id,'s_order_item_legacy',s.s_order_item_legacy) AS raw_refs,",
             _source_payload_sql()+' AS payload',
             'FROM source_stage s JOIN parent_stage h ON h.legacy_id=s.plan_legacy_id LEFT JOIN upstream_stage upstream ON upstream.legacy_id=NULLIF(s.s_order_item_legacy,0);',
             "SELECT jsonb_build_object('rows',count(*),'parents',(SELECT count(*) FROM parent_stage),",
             "'source_ids_sha256',encode(digest(coalesce(string_agg(legacy_id::text||chr(10),'' ORDER BY legacy_id),''),'sha256'),'hex'),",
             "'typed_source_rows_sha256',encode(digest(coalesce(string_agg(legacy_id::text||'|'||item_row_sha||chr(10),'' ORDER BY legacy_id),''),'sha256'),'hex'),",
             "'typed_parent_bindings_sha256',encode(digest(coalesce(string_agg(legacy_id::text||'|'||plan_legacy_id::text||'|'||parent_row_sha||chr(10),'' ORDER BY legacy_id),''),'sha256'),'hex'),",
             "'source_parent_line_sha256',encode(digest(coalesce(string_agg(legacy_id::text||'|'||plan_legacy_id::text||'|'||line_no::text||chr(10),'' ORDER BY legacy_id),''),'sha256'),'hex'),",
             "'source_reference_rows_sha256',encode(digest(coalesce(string_agg(legacy_id::text||'|'||raw_refs::text||chr(10),'' ORDER BY legacy_id),''),'sha256'),'hex'),",
             "'normalized_business_rows_sha256',encode(digest(coalesce(string_agg(legacy_id::text||'|'||encode(digest("+_snapshot_sql('payload',NORMALIZED_FIELDS)+"::text,'sha256'),'hex')||chr(10),'' ORDER BY legacy_id),''),'sha256'),'hex'),",
             "'counter_rows_sha256',encode(digest(coalesce(string_agg(legacy_id::text||'|'||encode(digest("+_snapshot_sql('payload',COUNTERS)+"::text,'sha256'),'hex')||chr(10),'' ORDER BY legacy_id),''),'sha256'),'hex'),",
             "'header_business_rows_sha256',(SELECT encode(digest(coalesce(string_agg(h.legacy_id::text||'|'||encode(digest("+_snapshot_sql(_source_header_payload_sql(),HEADER_FIELDS)+"::text,'sha256'),'hex')||chr(10),'' ORDER BY h.legacy_id),''),'sha256'),'hex') FROM parent_stage h),",
             "'header_identity_rows_sha256',(SELECT encode(digest(coalesce(string_agg(legacy_id::text||'|'||jsonb_build_object('legacy_id',legacy_id,'bill_no',bill_no,'bill_date',bill_date)::text||chr(10),'' ORDER BY legacy_id),''),'sha256'),'hex') FROM parent_stage)) FROM independently_expected;"]
        result=command(['docker','exec','-i',owned,'psql','-X','-qAt','-U','postgres','-v','ON_ERROR_STOP=1'],('\n'.join(sql)+'\n').encode(),timeout=120)
        check(result.returncode==0);lines=result.stdout.decode().strip().splitlines();check(len(lines)==1);facts=json.loads(lines[0])
        check(facts['rows']==source['rows'] and facts['parents']==source['parent_rows'])
        for key in ('source_ids_sha256','source_parent_line_sha256'):check(facts[key]==source[key])
        check(all(re.fullmatch('[0-9a-f]{64}',value) for key,value in facts.items() if key.endswith('_sha256')))
        return facts
    finally:
        if created:check(command(['docker','rm','-f','-v',owned]).returncode==0)


ZERO_INVARIANTS=(
 'unregistered_proof_routes','foreign_proofs_bound_to_current_targets','duplicate_source_proof_ids',
 'wrong_file_sha','wrong_parent_file_sha','wrong_target_fields','invalid_proof_hashes','invalid_issued_txids',
 'missing_or_mismatched_targets','wrong_target_run','targets_without_exact_proof',
 'changed_initial_snapshots','wrong_parent_identity','invalid_actual_uuid_reference','wrong_run_evidence','wrong_default_allowance',
 'remembered_goods_rate_rows','modern_plan_fields','modern_execution_rows','modern_report_headers',
 'modern_report_items','modern_rate_requests','modern_rate_decisions','modern_stock_production_links',
 'proofs_without_context','wrong_context_issued_txid','wrong_context_evidence','wrong_context_origin','wrong_source_cutoff',
)

def _sql_hash_rows(value,order):
    return "encode(digest(coalesce(string_agg("+value+"||chr(10),'' ORDER BY "+order+"),''),'sha256'),'hex')"


def _run_evidence_sql():
    return """jsonb_build_object('run_id',r.run_id,'target',r.target,'migration_mode',r.migration_mode,
 'database_user',r.database_user,'export_manifest_sha256',r.export_manifest_sha256,
 'checksum_manifest_sha256',r.checksum_manifest_sha256,'migration_repository_commit',r.migration_repository_commit,
 'migration_script_sha256',r.migration_script_sha256,'mapping_version',r.mapping_version,
 'source_backup_sha256',r.source_backup_sha256,'export_approval_reference',r.export_approval_reference,
 'targetDatabase',r.reconciliation_summary->'targetDatabase','targetSystemIdentifier',r.reconciliation_summary->'targetSystemIdentifier',
 'targetApprovalReference',r.reconciliation_summary->'targetApprovalReference','importAtomicity',r.reconciliation_summary->'importAtomicity',
 'sourceSnapshotAsOfUtc',r.reconciliation_summary->'sourceSnapshotAsOfUtc')"""

def acceptance_sql(run_id,source):
    """One aggregate SELECT, embeddable in the generic RR/READ ONLY snapshot.

    Only the existing pure numeric snapshot and default-rate policy are called;
    never registration/source projection/assertions or migration/session flags.
    UUIDs are decoded through actual current master identities before comparing
    an independently generated full source business projection.
    """
    run_id=str(uuid.UUID(run_id))
    for name in ('file_sha256','parent_file_sha256'):
        _require(re.fullmatch('[0-9a-f]{64}',source[name]) is not None,'Invalid production source file SHA identity')
    fields=_fields_sql(TARGET_FIELDS);normalized=_fields_sql(NORMALIZED_FIELDS);counters=_fields_sql(COUNTERS)
    route="(p.source_kind='PRODUCTION_PLAN_ITEM' AND p.target_table='production_plan_items' AND p.source_file='production_plan_items.csv' AND p.source_parent_file='production_plans.csv')"
    run_evidence=_run_evidence_sql()
    cutoff=source['source_snapshot_as_of_utc'].replace("'","''")
    target_normalized="""to_jsonb(t)||jsonb_build_object('plan_id',parent.legacy_id,'goods_id',goods.legacy_id,
 'color_id',color.legacy_id,'mgoods_id',mgoods.legacy_id,'unit_id',unit.legacy_id,'sales_order_item_id',upstream.legacy_id,
 '__parent_bill_no',parent.bill_no,'__parent_bill_date',parent.bill_date)"""
    row_source=_sql_hash_rows("p.source_legacy_id::text||'|'||p.source_row_sha256::text",'p.source_legacy_id')
    row_parent=_sql_hash_rows("p.source_legacy_id::text||'|'||p.source_parent_legacy_id::text||'|'||p.source_parent_row_sha256::text",'p.source_legacy_id')
    row_refs=_sql_hash_rows("p.source_legacy_id::text||'|'||p.source_reference_legacy_ids::text",'p.source_legacy_id')
    row_lines=_sql_hash_rows("p.source_legacy_id::text||'|'||p.source_parent_legacy_id::text||'|'||p.actual_line_no::text",'p.source_legacy_id')
    row_business=_sql_hash_rows("p.source_legacy_id::text||'|'||encode(digest(public.fn_legacy_finance_snapshot(p.normalized_payload,"+normalized+")::text,'sha256'),'hex')",'p.source_legacy_id')
    row_counters=_sql_hash_rows("p.source_legacy_id::text||'|'||encode(digest(public.fn_legacy_finance_snapshot(p.actual_payload,"+counters+")::text,'sha256'),'hex')",'p.source_legacy_id')
    return f"""WITH run_identity AS MATERIALIZED (
 SELECT r.run_id,{run_evidence} evidence FROM public.legacy_migration_runs r WHERE r.run_id='{run_id}'::uuid
), actual_origin AS MATERIALIZED (
 SELECT system_identifier::text system_identifier,(SELECT oid::bigint FROM pg_database WHERE datname=current_database()) database_oid FROM pg_control_system()
), checked_context AS MATERIALIZED (
 SELECT c.*,ri.evidence actual_run_evidence,actual_origin.system_identifier actual_system_identifier,actual_origin.database_oid actual_database_oid
 FROM public.{CONTEXT_TABLE} c JOIN run_identity ri ON ri.run_id=c.run_id CROSS JOIN actual_origin WHERE c.run_id='{run_id}'::uuid
), joined AS MATERIALIZED (
 SELECT p.*,t.id actual_id,t.legacy_id actual_legacy_id,t.{RUN_COLUMN} actual_run,t.plan_id actual_plan_id,t.line_no actual_line_no,
 context.run_id context_run_id,context.issued_txid context_issued_txid,context.evidence_sha256 context_evidence_sha256,
 parent.id actual_parent_id,parent.legacy_id actual_parent_legacy_id,
 to_jsonb(t) actual_payload,{target_normalized} normalized_payload,
 encode(digest(jsonb_build_object('id',parent.id,'legacy_id',parent.legacy_id,'bill_no',parent.bill_no,'bill_date',parent.bill_date)::text,'sha256'),'hex') actual_parent_identity_sha,
 (t.allowed_overproduction_rate IS DISTINCT FROM public.fn_goods_default_overproduction_rate(t.goods_id)
   OR t.allowed_overproduction_rate_source IS DISTINCT FROM 'DEFAULT' OR t.capped_qty IS NOT NULL) bad_default,
 goods.production_overproduction_rate IS NOT NULL remembered_rate,
 ((t.goods_id IS NOT NULL AND (goods.id IS NULL OR goods.legacy_id IS NULL))
   OR (t.color_id IS NOT NULL AND (color.id IS NULL OR color.legacy_id IS NULL))
   OR (t.mgoods_id IS NOT NULL AND (mgoods.id IS NULL OR mgoods.legacy_id IS NULL))
   OR (t.unit_id IS NOT NULL AND (unit.id IS NULL OR unit.legacy_id IS NULL))
   OR (t.sales_order_item_id IS NOT NULL AND (upstream.id IS NULL OR upstream.legacy_id IS NULL))) bad_uuid_reference
 FROM public.{PROOF_TABLE} p
 LEFT JOIN checked_context context ON context.run_id=p.run_id
 LEFT JOIN public.production_plan_items t ON t.id=p.target_id
 LEFT JOIN public.production_plans parent ON parent.id=t.plan_id
 LEFT JOIN public.goods goods ON goods.id=t.goods_id
 LEFT JOIN public.colors color ON color.id=t.color_id
 LEFT JOIN public.goods mgoods ON mgoods.id=t.mgoods_id
 LEFT JOIN public.units unit ON unit.id=t.unit_id
 LEFT JOIN public.sales_order_items upstream ON upstream.id=t.sales_order_item_id
 WHERE p.run_id='{run_id}'::uuid AND {route}
)
SELECT jsonb_build_object(
 'proof_rows',count(*),
 'target_rows',(SELECT count(*) FROM public.production_plan_items),
 'parent_rows',(SELECT count(*) FROM public.production_plans),
 'issued_txid_count',count(DISTINCT p.issued_txid),
 'retained_prior_run_proofs',(SELECT count(*) FROM public.{PROOF_TABLE} WHERE run_id IS DISTINCT FROM '{run_id}'::uuid),
 'target_business_columns',(SELECT jsonb_agg(column_name ORDER BY column_name) FROM information_schema.columns WHERE table_schema='public' AND table_name='production_plan_items' AND column_name NOT IN('created_at','updated_at','created_by','updated_by')),
 'unregistered_proof_routes',(SELECT count(*) FROM public.{PROOF_TABLE} p WHERE p.run_id='{run_id}'::uuid AND {route} IS NOT TRUE),
 'foreign_proofs_bound_to_current_targets',(SELECT count(*) FROM public.{PROOF_TABLE} q JOIN public.production_plan_items t ON t.id=q.target_id WHERE q.run_id IS DISTINCT FROM '{run_id}'::uuid),
 'duplicate_source_proof_ids',(SELECT count(*) FROM(SELECT source_legacy_id FROM public.{PROOF_TABLE} WHERE run_id='{run_id}'::uuid GROUP BY source_legacy_id HAVING count(*)<>1) d),
 'wrong_file_sha',count(*) FILTER(WHERE p.source_file_sha256 IS DISTINCT FROM '{source['file_sha256']}'),
 'wrong_parent_file_sha',count(*) FILTER(WHERE p.source_parent_file_sha256 IS DISTINCT FROM '{source['parent_file_sha256']}'),
 'wrong_target_fields',count(*) FILTER(WHERE p.target_fields IS DISTINCT FROM {fields}),
 'invalid_proof_hashes',count(*) FILTER(WHERE p.source_row_sha256 IS NULL OR p.source_row_sha256 !~ '^[0-9a-f]{{64}}$' OR p.source_parent_row_sha256 IS NULL OR p.source_parent_row_sha256 !~ '^[0-9a-f]{{64}}$' OR p.target_snapshot_sha256 IS NULL OR p.target_snapshot_sha256 !~ '^[0-9a-f]{{64}}$'),
 'invalid_issued_txids',count(*) FILTER(WHERE p.issued_txid IS NULL OR p.issued_txid<=0),
 'missing_or_mismatched_targets',count(*) FILTER(WHERE p.actual_id IS NULL OR p.actual_legacy_id IS DISTINCT FROM p.source_legacy_id OR p.actual_run IS DISTINCT FROM p.run_id),
 'wrong_target_run',(SELECT count(*) FROM public.production_plan_items WHERE {RUN_COLUMN} IS DISTINCT FROM '{run_id}'::uuid),
 'targets_without_exact_proof',(SELECT count(*) FROM public.production_plan_items t WHERE NOT EXISTS(SELECT 1 FROM public.{PROOF_TABLE} q WHERE q.run_id='{run_id}'::uuid AND q.source_kind='PRODUCTION_PLAN_ITEM' AND q.target_table='production_plan_items' AND q.source_file='production_plan_items.csv' AND q.source_parent_file='production_plans.csv' AND q.target_id=t.id AND q.source_legacy_id=t.legacy_id)),
 'changed_initial_snapshots',count(*) FILTER(WHERE p.target_snapshot_sha256 IS DISTINCT FROM encode(digest(public.fn_legacy_finance_snapshot(p.actual_payload,{fields})::text,'sha256'),'hex')),
 'wrong_parent_identity',count(*) FILTER(WHERE p.actual_parent_id IS NULL OR p.target_plan_id IS DISTINCT FROM p.actual_plan_id OR p.source_parent_legacy_id IS DISTINCT FROM p.actual_parent_legacy_id OR p.parent_identity_sha256 IS DISTINCT FROM p.actual_parent_identity_sha),
 'invalid_actual_uuid_reference',count(*) FILTER(WHERE p.bad_uuid_reference),
 'wrong_run_evidence',count(*) FILTER(WHERE p.run_evidence_sha256 IS DISTINCT FROM p.context_evidence_sha256),
 'wrong_default_allowance',count(*) FILTER(WHERE p.bad_default),
 'remembered_goods_rate_rows',count(*) FILTER(WHERE p.remembered_rate),
 'context_rows',(SELECT count(*) FROM checked_context),
 'proofs_without_context',count(*) FILTER(WHERE p.context_run_id IS NULL),
 'wrong_context_issued_txid',count(*) FILTER(WHERE p.context_issued_txid IS DISTINCT FROM p.issued_txid),
 'wrong_context_evidence',(SELECT count(*) FROM checked_context c WHERE c.evidence IS DISTINCT FROM c.actual_run_evidence OR c.evidence_sha256 IS DISTINCT FROM encode(digest(c.evidence::text,'sha256'),'hex')),
 'wrong_context_origin',(SELECT count(*) FROM checked_context c WHERE c.origin_system_identifier IS DISTINCT FROM c.actual_system_identifier OR c.origin_database_oid::bigint IS DISTINCT FROM c.actual_database_oid OR c.origin_database_name IS DISTINCT FROM c.actual_run_evidence->>'targetDatabase' OR c.origin_system_identifier IS DISTINCT FROM c.actual_run_evidence->>'targetSystemIdentifier'),
 'wrong_source_cutoff',(SELECT count(*) FROM checked_context c WHERE c.evidence->>'sourceSnapshotAsOfUtc' IS DISTINCT FROM '{cutoff}'),
 'context_evidence_sha256',(SELECT min(evidence_sha256::text) FROM checked_context),
 'context_origin_system_identifier',(SELECT min(origin_system_identifier) FROM checked_context),
 'context_origin_database_oid',(SELECT min(origin_database_oid::bigint) FROM checked_context),
 'context_origin_database_name',(SELECT min(origin_database_name) FROM checked_context)
)||jsonb_build_object(
 'proof_source_ids_sha256',{_sql_hash_rows('p.source_legacy_id::text','p.source_legacy_id')},
 'target_source_ids_sha256',(SELECT {_sql_hash_rows('legacy_id::text','legacy_id')} FROM public.production_plan_items),
 'parent_source_ids_sha256',(SELECT {_sql_hash_rows('legacy_id::text','legacy_id')} FROM public.production_plans),
 'typed_source_rows_sha256',{row_source},
 'typed_parent_bindings_sha256',{row_parent},
 'source_parent_line_sha256',{row_lines},
 'source_reference_rows_sha256',{row_refs},
 'normalized_business_rows_sha256',{row_business},
 'counter_rows_sha256',{row_counters},
 'header_identity_rows_sha256',(SELECT {_sql_hash_rows("legacy_id::text||'|'||jsonb_build_object('legacy_id',legacy_id,'bill_no',bill_no,'bill_date',bill_date)::text",'legacy_id')} FROM public.production_plans),
 'header_business_rows_sha256',(SELECT {_sql_hash_rows("legacy_id::text||'|'||encode(digest(public.fn_legacy_finance_snapshot(to_jsonb(header),"+_fields_sql(HEADER_FIELDS)+")::text,'sha256'),'hex')",'legacy_id')} FROM public.production_plans header),
 'target_uuid_binding_sha256',{_sql_hash_rows("p.source_legacy_id::text||'|'||p.target_id::text||'|'||p.id::text||'|'||p.target_plan_id::text||'|'||p.issued_txid::text",'p.source_legacy_id')},
 'modern_plan_fields',(SELECT count(*) FROM public.production_plans WHERE auto_generated OR material_analysis_id IS NOT NULL OR material_analysis_item_id IS NOT NULL OR source_daily_report_id IS NOT NULL OR actual_output_supplement_request_id IS NOT NULL),
 'modern_execution_rows',(SELECT count(*) FROM public.production_execution_segments),
 'modern_report_headers',(SELECT count(*) FROM public.production_daily_reports),
 'modern_report_items',(SELECT count(*) FROM public.production_daily_report_items),
 'modern_rate_requests',(SELECT count(*) FROM public.production_overproduction_rate_requests),
 'modern_rate_decisions',(SELECT count(*) FROM public.production_overproduction_rate_decisions),
 'modern_stock_production_links',(SELECT count(*) FROM public.stock_document_items WHERE source_daily_report_item_id IS NOT NULL OR execution_segment_id IS NOT NULL OR execution_segment_sales_allocation_id IS NOT NULL)
) FROM joined p"""


def validate(actual,source,require=_require):
    require(isinstance(actual,dict) and isinstance(source,dict),'Production historical baseline proof or sealed source is absent')
    typed=source.get('typed_source_facts')
    require(isinstance(typed,dict),'Production complete independent typed-source proof is absent')
    require(type(typed.get('rows')) is int and typed['rows']==source['rows']
            and type(typed.get('parents')) is int and typed['parents']==source['parent_rows']
            and typed.get('source_ids_sha256')==source['source_ids_sha256']
            and typed.get('source_parent_line_sha256')==source['source_parent_line_sha256'],
            'Production independently typed source inventory differs')
    for key,value in typed.items():
        if key.endswith('_sha256'):require(isinstance(value,str) and re.fullmatch('[0-9a-f]{64}',value) is not None,'Production typed source digest shape is invalid')
    for key in ('proof_rows','target_rows','parent_rows','issued_txid_count','context_rows'):
        require(type(actual.get(key)) is int and actual[key]>=0,'Production aggregate count shape differs: '+key)
    for fact,expected in (
        ('proof_rows',source['rows']),('target_rows',source['rows']),('parent_rows',source['parent_rows']),
        ('proof_source_ids_sha256',source['source_ids_sha256']),('target_source_ids_sha256',source['source_ids_sha256']),
        ('parent_source_ids_sha256',source['parent_ids_sha256']),
        *[(key,typed[key]) for key in ('typed_source_rows_sha256','typed_parent_bindings_sha256','source_parent_line_sha256',
            'source_reference_rows_sha256','normalized_business_rows_sha256','counter_rows_sha256','header_identity_rows_sha256','header_business_rows_sha256')],
    ):
        require(fact in actual and actual[fact]==expected,'Production historical source invariant differs: '+fact)
    for key in ZERO_INVARIANTS:require(type(actual.get(key)) is int and actual[key]==0,'Production historical baseline invariant failed: '+key)
    require(actual.get('target_business_columns')==list(TARGET_FIELDS),'Production business field schema changed outside the bound protocol')
    require(actual.get('issued_txid_count')==(1 if source['rows'] else 0),'Production proof issued transaction coverage differs')
    require(actual['context_rows']==1 if source['rows'] else actual['context_rows'] in (0,1),'Production immutable context coverage differs')
    origin=None
    if actual['context_rows']:
        require(isinstance(actual.get('context_evidence_sha256'),str) and re.fullmatch('[0-9a-f]{64}',actual['context_evidence_sha256']) is not None,'Production context evidence SHA is absent')
        require(isinstance(actual.get('context_origin_system_identifier'),str) and actual['context_origin_system_identifier']
                and type(actual.get('context_origin_database_oid')) is int and actual['context_origin_database_oid']>0
                and isinstance(actual.get('context_origin_database_name'),str) and re.fullmatch('[A-Za-z_][A-Za-z0-9_]{0,62}',actual['context_origin_database_name']) is not None,
                'Production original database identity is absent')
        origin={'system_identifier':actual['context_origin_system_identifier'],'database_oid':actual['context_origin_database_oid']}
    require(type(actual.get('retained_prior_run_proofs')) is int and actual['retained_prior_run_proofs']>=0,'Production preserved prior proof count is invalid')
    require(isinstance(actual.get('target_uuid_binding_sha256'),str) and re.fullmatch('[0-9a-f]{64}',actual['target_uuid_binding_sha256']) is not None,'Production target UUID continuity proof is absent')
    return {'verified':True,'source_proof_rows':source['rows'],'source_parent_rows':source['parent_rows'],
        'counter_fields_verified':len(COUNTERS),'bound_business_fields_verified':len(TARGET_FIELDS),
        'mapped_parent_fields_verified':len(HEADER_FIELDS),
        'complete_source_and_parent_rows_verified':True,'source_parent_master_unit_and_upstream_relations_verified':True,
        'original_business_projection_unchanged':True,'exact_bidirectional_source_target_coverage':True,
        'source_rows_sha256':typed['typed_source_rows_sha256'],'parent_bindings_sha256':typed['typed_parent_bindings_sha256'],
        'business_projection_sha256':typed['normalized_business_rows_sha256'],'counter_rows_sha256':typed['counter_rows_sha256'],
        'target_uuid_binding_sha256':actual['target_uuid_binding_sha256'],
        'context_rows':actual['context_rows'],'context_evidence_sha256':actual.get('context_evidence_sha256'),
        'origin_database_identity':origin,'recorded_origin_database':actual.get('context_origin_database_name'),
        'retained_prior_run_proofs':actual['retained_prior_run_proofs'],'no_modern_reports_surplus_execution_or_stock_links':True,
        'default_allowance_matches_unchanged_goods_policy':True,'historical_baseline_is_new_capacity':False,'verifier_changed_capacity':False}


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--inputs',type=Path,required=True)
    parser.add_argument('--manifest-sha256',required=True)
    parser.add_argument('--frozen-commit',required=True)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--typed-source-only',action='store_true',help='Explicitly interpret source in owned local network-none PostgreSQL; never query a target')
    args=parser.parse_args(argv)
    try:
        _require(not args.output.exists(),'Refusing to overwrite a previous source receipt')
        directory=args.inputs.resolve();manifest_path=directory/'derived_inputs.json';data=manifest_path.read_bytes()
        _require(hashlib.sha256(data).hexdigest()==args.manifest_sha256,'Production input manifest SHA-256 differs')
        manifest=json.loads(data.decode('utf-8-sig'))
        _require(manifest.get('formatVersion')==4 and manifest.get('target')=='All'
                 and manifest.get('provenance',{}).get('inputKind')=='derived-local-rehearsal-v1','Complete derived source manifest is required')
        _require(re.fullmatch(r'[0-9a-f]{40}|[0-9a-f]{64}',args.frozen_commit) is not None
                 and manifest['provenance']['importerRepositoryCommit']==args.frozen_commit,'Production source frozen commit differs')
        records={record['file']:record for record in manifest['files']}
        _require(len(records)==len(manifest['files']),'Source manifest file is duplicated')
        source=source_inventory(directory,records);_require(source is not None,'Complete production source inventory is required')
        result={'status':'SOURCE_INVENTORY_VERIFIED_TARGET_NOT_QUERIED','source_rows':source['rows'],'source_parent_rows':source['parent_rows'],
                'manifest_sha256':args.manifest_sha256,'frozen_commit':args.frozen_commit,'source_files':source['files'],
                'target_database_queried':False,'secrets_or_application_configuration_read':False,'docker_used':False}
        if args.typed_source_only:
            result.update(status='SOURCE_TYPED_FACTS_VERIFIED_TARGET_NOT_QUERIED',typed_source_facts=typed_source_facts(source),docker_used=True)
        with args.output.open('x',encoding='utf-8') as stream:json.dump(result,stream,indent=2);stream.write('\n')
        print(json.dumps({'status':result['status'],'source_rows':source['rows'],'source_parent_rows':source['parent_rows'],'target_database_queried':False}))
        return 0
    except (OSError,ValueError,KeyError,TypeError,csv.Error):
        print(json.dumps({'status':'FAILED','reason':'Production source verification failed; raw input/server details withheld'}))
        return 1

if __name__=='__main__':raise SystemExit(main())

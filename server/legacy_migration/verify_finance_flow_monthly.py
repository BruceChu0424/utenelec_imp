"""Independent protocol19 typed-source ledger/monthly acceptance. Aggregates only.

No target connection or mutation is performed here. acceptance_sql is embedded
in the generic verifier's RR/READ ONLY snapshot. Source typing owns a pinned,
local network-none PostgreSQL and returns hashes/counts, never business values.
"""
import csv
import hashlib
import io
import json
import os
from pathlib import Path
import re
import subprocess
import time
import uuid

from verify_finance_master_sources import ACCOUNT_COLUMNS, ACCOUNT_DDL, CURRENCY_COLUMNS, CURRENCY_DDL

FLOW_FILE='m_allcheck.csv'
FLOW_COLUMNS=('legacy_id','bill_no','check_no','remark','company','in_total','out_total','bill_date','out_date','acc_id','source','b_style','bill_id')
FLOW_DDL='legacy_id int,bill_no text,check_no text,remark text,company text,in_total numeric(18,4),out_total numeric(18,4),bill_date timestamptz,out_date timestamptz,acc_id int,source text,b_style int,bill_id int'
HEADERS=(('m_get.csv','RECEIPT'),('m_paid.csv','PAYMENT'),('m_dpaid.csv','EXPENSE'),('m_oget.csv','INCOME'))
FILES=(FLOW_FILE,'m_acc.csv','currency.csv',*(name for name,_ in HEADERS))
TARGET_FIELDS=tuple(sorted(('id','legacy_import_run_id','legacy_id','bill_no','source_doc_type','source_doc_id','account_id','check_no','counterpart_name','in_amount','out_amount','bill_date','settled_date','source_remark','remark','legacy_bstyle','entry_kind','account_currency_id','amount_local')))
TARGET_BUSINESS_COLUMNS=tuple(sorted((*TARGET_FIELDS,'is_deleted','deleted_at','posting_seq','reversal_of_id','reversal_reason')))
NORMALIZED_FIELDS=tuple(sorted(('legacy_id','bill_no','bill_date','source_doc_type','source_doc_legacy_id','account_legacy_id','currency_legacy_id','check_no','counterpart_name','in_amount','out_amount','settled_date','source_remark','remark','legacy_bstyle','entry_kind','amount_local')))
MONTH_FIELDS=('account_legacy_id','currency_legacy_id','month_start','in_amount','out_amount','flow_count')
ZERO_INVARIANTS=('wrong_run_status','wrong_mapping','wrong_batch_origin','wrong_proof_issued_txid','wrong_source_files','wrong_archive_metadata','invalid_archive_rows','wrong_proof_route','wrong_proof_file','wrong_proof_fields','proof_target_mismatch','proof_target_snapshot_mismatch','initial_amount_snapshot_mismatch','targets_without_proof','invalid_current_reference','invalid_source_document_reference','wrong_target_defaults','duplicate_posting_sequences','wrong_month_references','monthly_ledger_mismatch','negative_month_groups','wrong_session_timezone')
HASH_KEYS=('active_ids_sha256','archive_ids_sha256','active_typed_rows_sha256','archive_typed_rows_sha256','ledger_business_sha256','monthly_business_sha256')


def _require(value,message):
    if not value:raise ValueError(message)


def digest(path):return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def _array(fields):return 'ARRAY['+','.join("'"+key+"'" for key in sorted(fields))+']::text[]'


def _hash(expression,order):
    return "encode(digest(coalesce(string_agg("+expression+"||chr(10),'' ORDER BY "+order+"),''),'sha256'),'hex')"


def _snapshot(expression):
    return "private_normalize("+expression+")"


def source_inventory(directory,records,*,require=_require):
    if not all(name in records for name in FILES):return None
    directory=Path(directory);files={};ids={}
    exact={FLOW_FILE:FLOW_COLUMNS,'m_acc.csv':ACCOUNT_COLUMNS,'currency.csv':CURRENCY_COLUMNS}
    for name in FILES:
        path=directory/name;record=records[name]
        require(path.is_file() and not path.is_symlink() and path.stat().st_size==record['bytes'] and digest(path)==record['sha256'],'Sealed finance flow source bytes differ: '+name)
        with path.open(encoding='utf-8-sig',newline='') as stream:
            reader=csv.DictReader(stream,delimiter='|',strict=True)
            require(reader.fieldnames and len(reader.fieldnames)==len(set(reader.fieldnames)),'Finance flow source header is invalid')
            require(tuple(reader.fieldnames)==exact[name] if name in exact else {'legacy_id','bill_no'}.issubset(reader.fieldnames),'Finance flow COPY column contract differs: '+name)
            values=[]
            for row in reader:
                require(None not in row and all(value is not None for value in row.values()),'Finance flow source row width differs')
                require(re.fullmatch('[1-9][0-9]*',row['legacy_id']) is not None,'Finance flow source identity is invalid')
                values.append(int(row['legacy_id']))
                if name in {item[0] for item in HEADERS}:require(bool(row['bill_no'].strip()),'Finance source header number is absent')
        require(len(values)==record['rows'] and len(values)==len(set(values)),'Finance flow source identity coverage differs')
        files[name]=dict(record);ids[name]=sorted(values)
    manifest=json.loads((directory/'derived_inputs.json').read_text(encoding='utf-8-sig')) if (directory/'derived_inputs.json').exists() else {}
    return {'files':files,'source_rows':len(ids[FLOW_FILE]),'_input_directory':str(directory.resolve()),
            '_source_cutoff':manifest.get('sourceSnapshotAsOfUtc'),'_manifest_sha256':digest(directory/'derived_inputs.json') if manifest else None,
            '_frozen_commit':manifest.get('provenance',{}).get('importerRepositoryCommit')}


def _local_context():
    # Verify explicit context AND environment override before any payload access;
    # pin every child command, so later global context changes cannot redirect it.
    try:
        require=os.environ.get('DOCKER_HOST')
        if require:raise ValueError()
        context=subprocess.check_output(['docker','context','show'],stderr=subprocess.PIPE,text=True,timeout=15).strip()
        if not re.fullmatch('[A-Za-z0-9_.-]+',context):raise ValueError()
        meta=json.loads(subprocess.check_output(['docker','context','inspect',context],stderr=subprocess.PIPE,text=True,timeout=15))
        if len(meta)!=1 or not meta[0]['Endpoints']['docker']['Host'].startswith(('npipe:','unix:')):raise ValueError()
        return context
    except Exception:raise ValueError('Local Docker context could not be pinned; no source transferred') from None


def _normalized_flow(prefix,account,currency,source_doc):
    """Same independently declared business keys on source and current ledger."""
    return "jsonb_build_object('legacy_id',"+prefix+".legacy_id,'bill_no',"+prefix+".bill_no,'bill_date',"+prefix+".bill_date,'source_doc_type',"+prefix+".source_doc_type,'source_doc_legacy_id',"+source_doc+",'account_legacy_id',"+account+",'currency_legacy_id',"+currency+",'check_no',"+prefix+".check_no,'counterpart_name',"+prefix+".counterpart_name,'in_amount',"+prefix+".in_amount,'out_amount',"+prefix+".out_amount,'settled_date',"+prefix+".settled_date,'source_remark',"+prefix+".source_remark,'remark',"+prefix+".remark,'legacy_bstyle',"+prefix+".legacy_bstyle,'entry_kind',"+prefix+".entry_kind,'amount_local',"+prefix+".amount_local)"


def _source_projection_sql():
    return """CREATE TEMP TABLE expected_flow AS
 SELECT s.*,encode(digest(to_jsonb(s)::text,'sha256'),'hex') typed_row_sha,
 (a.legacy_id IS NOT NULL AND s.b_style IN(20,21,22,23,27)) retained,
 a.legacy_id account_legacy_id,c.legacy_id currency_legacy_id,
 CASE s.b_style WHEN 20 THEN 'RECEIPT' WHEN 21 THEN 'PAYMENT' WHEN 22 THEN 'INCOME' WHEN 23 THEN 'EXPENSE' WHEN 27 THEN 'BANK_TRANSFER' END source_doc_type
 FROM source_flow s LEFT JOIN source_account a ON a.legacy_id=s.acc_id
 LEFT JOIN source_currency c ON c.legacy_id=CASE WHEN a.name LIKE '%香%' THEN 3 ELSE 1 END AND c.status='使用';
 CREATE TEMP TABLE expected_ledger AS
 SELECT e.legacy_id,e.bill_no,e.bill_date,e.source_doc_type,e.account_legacy_id,e.currency_legacy_id,
 h.legacy_id source_doc_legacy_id,NULLIF(e.check_no,'') check_no,NULLIF(e.company,'') counterpart_name,
 e.in_total in_amount,e.out_total out_amount,e.out_date settled_date,NULLIF(e.source,'') source_remark,NULLIF(e.remark,'') remark,
 e.b_style legacy_bstyle,'LEGACY_SNAPSHOT'::text entry_kind,
 CASE WHEN e.currency_legacy_id=1 THEN e.in_total+e.out_total END amount_local
 FROM expected_flow e LEFT JOIN source_headers h ON h.kind=e.source_doc_type AND h.legacy_id=e.bill_id AND h.bill_no=e.bill_no
 WHERE e.retained;
 CREATE TEMP TABLE expected_months AS
 SELECT account_legacy_id,currency_legacy_id,date_trunc('month',bill_date AT TIME ZONE 'Asia/Shanghai')::date month_start,
 sum(coalesce(in_amount,0)) in_amount,sum(coalesce(out_amount,0)) out_amount,count(*) flow_count
 FROM expected_ledger GROUP BY account_legacy_id,currency_legacy_id,date_trunc('month',bill_date AT TIME ZONE 'Asia/Shanghai')::date;
"""


def typed_source_facts(source):
    context=_local_context();directory=Path(source['_input_directory'])
    name='uten-finance-flow-source-'+uuid.uuid4().hex[:12];created=False
    def command(args,data=None,timeout=120):
        try:return subprocess.run(['docker','--context',context,*args],input=data,capture_output=True,timeout=timeout)
        except Exception:raise ValueError('Owned finance flow source PostgreSQL is unavailable; raw details withheld') from None
    def check(ok):_require(ok,'Owned finance flow source verification failed; raw values withheld')
    try:
        check(command(['image','inspect','postgres:16.15-alpine']).returncode==0)
        result=command(['run','--pull=never','-d','--name',name,'--network','none','--mount','type=tmpfs,destination=/var/lib/postgresql/data','-e','POSTGRES_HOST_AUTH_METHOD=trust','postgres:16.15-alpine','-c','log_min_error_statement=panic','-c','log_min_messages=panic']);check(result.returncode==0);created=True
        for _ in range(80):
            if command(['exec',name,'pg_isready','-U','postgres']).returncode==0:break
            time.sleep(.15)
        else:check(False)
        meta=command(['inspect',name]);check(meta.returncode==0);info=json.loads(meta.stdout)[0]
        check(info['HostConfig']['NetworkMode']=='none' and not info['HostConfig']['PortBindings'])
        owned=info['Id'];header_buffer=io.StringIO(newline='');writer=csv.writer(header_buffer,delimiter='|',lineterminator='\n')
        for filename,kind in HEADERS:
            data=(directory/filename).read_bytes();check(hashlib.sha256(data).hexdigest()==source['files'][filename]['sha256'])
            for row in csv.DictReader(io.StringIO(data.decode('utf-8-sig')),delimiter='|',strict=True):writer.writerow((kind,int(row['legacy_id']),row['bill_no']))
        check(command(['exec','-i',owned,'sh','-c','cat > /tmp/headers.csv'],header_buffer.getvalue().encode()).returncode==0)
        sql=["SET TIME ZONE 'Asia/Shanghai'; SET DateStyle='ISO, YMD'; CREATE EXTENSION pgcrypto;",
             'CREATE TEMP TABLE source_flow('+FLOW_DDL+');','CREATE TEMP TABLE source_account('+ACCOUNT_DDL+');','CREATE TEMP TABLE source_currency('+CURRENCY_DDL+');',
             'CREATE TEMP TABLE source_headers(kind text,legacy_id int,bill_no text,PRIMARY KEY(kind,legacy_id));',
             "CREATE FUNCTION private_normalize(j jsonb) RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$ SELECT coalesce(jsonb_object_agg(key,CASE WHEN jsonb_typeof(value)='number' THEN to_jsonb(trim_scale((value#>>'{}')::numeric)) ELSE value END),'{}') FROM jsonb_each(j) $$;",
             "\\copy source_headers FROM '/tmp/headers.csv' WITH(FORMAT csv,DELIMITER '|')"]
        for filename,table in ((FLOW_FILE,'source_flow'),('m_acc.csv','source_account'),('currency.csv','source_currency')):
            data=(directory/filename).read_bytes();check(hashlib.sha256(data).hexdigest()==source['files'][filename]['sha256'])
            check(command(['exec','-i',owned,'sh','-c','cat > /tmp/'+filename],data).returncode==0)
            sql.append("\\copy "+table+" FROM '/tmp/"+filename+"' WITH(FORMAT csv,DELIMITER '|',HEADER true)")
        sql.append(_source_projection_sql())
        business=_normalized_flow('x','x.account_legacy_id','x.currency_legacy_id','x.source_doc_legacy_id')
        sql.append("SELECT jsonb_build_object('source_rows',(SELECT count(*) FROM expected_flow),'active_source_rows',(SELECT count(*) FROM expected_ledger),'archive_only_rows',(SELECT count(*) FROM expected_flow WHERE retained IS NOT TRUE),'monthly_groups',(SELECT count(*) FROM expected_months),"+
         "'signed_active_rows',(SELECT count(*) FROM expected_ledger WHERE in_amount<0 OR out_amount<0),'negative_month_groups',(SELECT count(*) FROM expected_months WHERE in_amount<0 OR out_amount<0),'invalid_source_references',(SELECT count(*) FROM expected_ledger WHERE account_legacy_id IS NULL OR currency_legacy_id IS NULL OR bill_date IS NULL),"+
         "'active_ids_sha256',(SELECT "+_hash('legacy_id::text','legacy_id')+" FROM expected_flow WHERE retained),'archive_ids_sha256',(SELECT "+_hash('legacy_id::text','legacy_id')+" FROM expected_flow WHERE retained IS NOT TRUE),"+
         "'active_typed_rows_sha256',(SELECT "+_hash("legacy_id::text||'|'||typed_row_sha",'legacy_id')+" FROM expected_flow WHERE retained),'archive_typed_rows_sha256',(SELECT "+_hash("legacy_id::text||'|'||typed_row_sha",'legacy_id')+" FROM expected_flow WHERE retained IS NOT TRUE),"+
         "'ledger_business_sha256',(SELECT "+_hash("x.legacy_id::text||'|'||encode(digest("+_snapshot(business)+"::text,'sha256'),'hex')",'x.legacy_id')+" FROM expected_ledger x),'monthly_business_sha256',(SELECT "+_hash("encode(digest(private_normalize(to_jsonb(m))::text,'sha256'),'hex')",'account_legacy_id,currency_legacy_id,month_start')+" FROM expected_months m));")
        result=command(['exec','-i',owned,'psql','-X','-qAt','-U','postgres','-v','ON_ERROR_STOP=1'],('\n'.join(sql)+'\n').encode());check(result.returncode==0)
        lines=result.stdout.decode().strip().splitlines();check(len(lines)==1);facts=json.loads(lines[0])
        check(facts['source_rows']==source['source_rows'] and facts['active_source_rows']+facts['archive_only_rows']==facts['source_rows'])
        check(facts['invalid_source_references']==facts['negative_month_groups']==0)
        check(all(isinstance(facts.get(key),str) and re.fullmatch('[0-9a-f]{64}',facts[key]) is not None for key in HASH_KEYS))
        check(all(digest(directory/name)==source['files'][name]['sha256'] for name in FILES))
        return facts
    finally:
        if created:check(command(['rm','-f','-v',name]).returncode==0)


def acceptance_sql(run_id,source):
    run=str(uuid.UUID(run_id));typed=source['typed_source_facts']
    for name in FILES:_require(re.fullmatch('[0-9a-f]{64}',source['files'][name]['sha256']) is not None,'Invalid finance flow source SHA')
    for key,length in (('_manifest_sha256',64),('_frozen_commit',40)):
        _require(isinstance(source.get(key),str) and re.fullmatch('[0-9a-f]{'+str(length)+'}',source[key]) is not None,'Finance flow source context is incomplete')
    cutoff=source.get('_source_cutoff')
    _require(isinstance(cutoff,str) and re.fullmatch('[0-9TtZz:+. -]{10,40}',cutoff) is not None,'Finance flow source cutoff is absent')
    file_values=','.join("('"+name+"','"+source['files'][name]['sha256']+"')" for name in FILES)
    normalized=_normalized_flow('x','x.account_legacy_id','x.currency_legacy_id','x.source_doc_legacy_id')
    business_hash="encode(digest(public.fn_legacy_finance_snapshot("+normalized+","+_array(NORMALIZED_FIELDS)+")::text,'sha256'),'hex')"
    month_payload="jsonb_build_object('account_legacy_id',a.legacy_id,'currency_legacy_id',c.legacy_id,'month_start',m.month_start,'in_amount',m.in_amount,'out_amount',m.out_amount,'flow_count',m.flow_count)"
    month_hash="encode(digest(public.fn_legacy_finance_snapshot("+month_payload+","+_array(MONTH_FIELDS)+")::text,'sha256'),'hex')"
    return f"""WITH run_identity AS MATERIALIZED (
 SELECT * FROM public.legacy_migration_runs WHERE run_id='{run}'::uuid
), expected_files(name,sha) AS (VALUES {file_values}),
 proofs AS MATERIALIZED (
 SELECT * FROM public.legacy_finance_import_sources WHERE run_id='{run}'::uuid
 AND (source_kind='ACCOUNT_FLOW' OR target_table='finance_reconciliations')
), headers AS MATERIALIZED (
 SELECT 'RECEIPT'::text kind,id,legacy_id,bill_no FROM public.finance_receipts
 UNION ALL SELECT 'PAYMENT',id,legacy_id,bill_no FROM public.finance_payments
 UNION ALL SELECT 'INCOME',id,legacy_id,bill_no FROM public.finance_other_incomes
 UNION ALL SELECT 'EXPENSE',id,legacy_id,bill_no FROM public.finance_expenses
 UNION ALL SELECT 'BANK_TRANSFER',id,legacy_id,bill_no FROM public.finance_bank_transfers
), joined AS MATERIALIZED (
 SELECT t.*,a.legacy_id account_legacy_id,c.legacy_id currency_legacy_id,h.legacy_id source_doc_legacy_id,
 a.id actual_account_id,a.currency_id real_account_currency_id,c.id actual_currency_id,c.is_base_currency,c.status currency_status,c.is_deleted currency_deleted,
 h.id actual_doc_id,h.bill_no actual_doc_bill_no,
 p.id proof_id,p.run_id proof_run,p.source_legacy_id proof_old,p.source_kind proof_kind,p.target_table proof_table,p.source_file proof_file,
 p.source_file_sha256 proof_file_sha,p.source_row_sha256 proof_row_sha,p.target_fields proof_fields,p.target_snapshot_sha256 proof_snapshot,p.initial_state proof_initial,
 to_jsonb(t) target_payload
 FROM public.finance_reconciliations t LEFT JOIN public.accounts a ON a.id=t.account_id
 LEFT JOIN public.currencies c ON c.id=t.account_currency_id
 LEFT JOIN headers h ON h.kind=t.source_doc_type AND h.id=t.source_doc_id
 LEFT JOIN proofs p ON p.target_id=t.id
), archived AS MATERIALIZED (
 SELECT entry FROM run_identity CROSS JOIN LATERAL jsonb_array_elements(coalesce(reconciliation_summary->'financeArchiveOnly'->'entries','[]')) entry
), ledger_months AS MATERIALIZED (
 SELECT account_id,account_currency_id,date_trunc('month',bill_date AT TIME ZONE 'Asia/Shanghai')::date month_start,
 sum(coalesce(in_amount,0)) in_amount,sum(coalesce(out_amount,0)) out_amount,count(*) flow_count,min(posting_seq) first_posting_seq,max(posting_seq) last_posting_seq
 FROM public.finance_reconciliations WHERE NOT is_deleted AND account_id IS NOT NULL AND account_currency_id IS NOT NULL AND bill_date IS NOT NULL
 GROUP BY account_id,account_currency_id,date_trunc('month',bill_date AT TIME ZONE 'Asia/Shanghai')::date
), actual_months AS MATERIALIZED (
 SELECT account_id,account_currency_id,month_start,in_amount,out_amount,flow_count,first_posting_seq,last_posting_seq FROM public.account_flow_monthly_summaries
), month_differences AS MATERIALIZED (
 (SELECT * FROM ledger_months EXCEPT ALL SELECT * FROM actual_months)
 UNION ALL (SELECT * FROM actual_months EXCEPT ALL SELECT * FROM ledger_months)
)
SELECT jsonb_build_object(
 'run_rows',(SELECT count(*) FROM run_identity),
 'wrong_run_status',(SELECT count(*) FROM run_identity WHERE status IS DISTINCT FROM 'SUCCESS' OR reconciliation_status IS DISTINCT FROM 'PASSED'
 OR target IS DISTINCT FROM '--bootstrap-all' OR migration_mode IS DISTINCT FROM 'BOOTSTRAP'
 OR export_manifest_sha256::text IS DISTINCT FROM '{source['_manifest_sha256']}' OR migration_repository_commit IS DISTINCT FROM '{source['_frozen_commit']}'
 OR reconciliation_summary->>'sourceSnapshotAsOfUtc' IS DISTINCT FROM '{cutoff}'),
 'wrong_mapping',(SELECT count(*) FROM run_identity WHERE CASE WHEN mapping_version~'^bootstrap-v[1-9][0-9]*$' THEN substring(mapping_version FROM 12)::numeric<19 ELSE true END),
 'wrong_batch_origin',(SELECT count(*) FROM run_identity WHERE CASE WHEN {typed['active_source_rows']}>0 THEN legacy_account_flow_import_txid IS NULL OR legacy_account_flow_import_txid<=0
 OR legacy_account_flow_origin_system_identifier IS DISTINCT FROM (SELECT system_identifier::text FROM pg_control_system())
 OR legacy_account_flow_origin_system_identifier IS DISTINCT FROM reconciliation_summary->>'targetSystemIdentifier'
 OR legacy_account_flow_origin_database_oid IS DISTINCT FROM (SELECT oid FROM pg_database WHERE datname=current_database())
 ELSE legacy_account_flow_import_txid IS NOT NULL OR legacy_account_flow_origin_system_identifier IS NOT NULL OR legacy_account_flow_origin_database_oid IS NOT NULL END),
 'wrong_proof_issued_txid',(SELECT count(*) FROM proofs WHERE issued_txid IS DISTINCT FROM (SELECT legacy_account_flow_import_txid FROM run_identity)),
 'wrong_source_files',(SELECT count(*) FROM expected_files e LEFT JOIN public.legacy_migration_run_files f ON f.run_id='{run}'::uuid AND f.file_name=e.name WHERE f.sha256::text IS DISTINCT FROM e.sha),
 'source_rows',(SELECT (reconciliation_summary->'financeArchiveOnly'->>'source_count')::bigint FROM run_identity),
 'active_source_rows',(SELECT count(*) FROM joined),'archive_only_rows',(SELECT count(*) FROM archived),'monthly_groups',(SELECT count(*) FROM actual_months),
 'signed_active_rows',(SELECT count(*) FROM joined WHERE in_amount<0 OR out_amount<0),
 'proof_rows',(SELECT count(*) FROM proofs),
 'target_business_columns',(SELECT jsonb_agg(a.attname ORDER BY a.attname) FROM pg_attribute a WHERE a.attrelid='public.finance_reconciliations'::regclass AND a.attnum>0 AND NOT a.attisdropped AND a.attname NOT IN('created_at','updated_at','created_by','updated_by')),
 'wrong_archive_metadata',(SELECT count(*) FROM run_identity WHERE reconciliation_summary->'financeArchiveOnly'->>'format' IS DISTINCT FROM 'finance-source-archive-only-v1'
 OR reconciliation_summary->'financeArchiveOnly'->>'source_file' IS DISTINCT FROM 'm_allcheck.csv'
 OR reconciliation_summary->'financeArchiveOnly'->>'source_file_sha256' IS DISTINCT FROM '{source['files'][FLOW_FILE]['sha256']}'
 OR (reconciliation_summary->'financeArchiveOnly'->>'active_count')::bigint IS DISTINCT FROM {typed['active_source_rows']}
 OR (reconciliation_summary->'financeArchiveOnly'->>'archived_count')::bigint IS DISTINCT FROM {typed['archive_only_rows']}),
 'invalid_archive_rows',(SELECT count(*) FROM archived WHERE entry->>'source_file' IS DISTINCT FROM 'm_allcheck.csv'
 OR entry->>'source_file_sha256' IS DISTINCT FROM '{source['files'][FLOW_FILE]['sha256']}' OR entry->>'disposition' IS DISTINCT FROM 'ARCHIVE_ONLY'
 OR entry->'typed_source'->>'legacy_id' IS DISTINCT FROM entry->>'source_legacy_id'
 OR entry->>'source_row_sha256' IS DISTINCT FROM encode(digest((entry->'typed_source')::text,'sha256'),'hex')
 OR EXISTS(SELECT 1 FROM joined t WHERE t.legacy_id=(entry->>'source_legacy_id')::integer)),
 'wrong_proof_route',(SELECT count(*) FROM proofs WHERE source_kind IS DISTINCT FROM 'ACCOUNT_FLOW' OR target_table IS DISTINCT FROM 'finance_reconciliations' OR source_file IS DISTINCT FROM 'm_allcheck.csv'),
 'wrong_proof_file',(SELECT count(*) FROM proofs WHERE source_file_sha256::text IS DISTINCT FROM '{source['files'][FLOW_FILE]['sha256']}'),
 'wrong_proof_fields',(SELECT count(*) FROM proofs WHERE target_fields IS DISTINCT FROM {_array(TARGET_FIELDS)}),
 'proof_target_mismatch',(SELECT count(*) FROM proofs p LEFT JOIN joined t ON t.id=p.target_id WHERE t.id IS NULL OR t.legacy_id IS DISTINCT FROM p.source_legacy_id OR t.legacy_import_run_id IS DISTINCT FROM p.run_id),
 'proof_target_snapshot_mismatch',(SELECT count(*) FROM joined WHERE proof_snapshot IS DISTINCT FROM encode(digest(public.fn_legacy_finance_snapshot(target_payload,proof_fields)::text,'sha256'),'hex')),
 'initial_amount_snapshot_mismatch',(SELECT count(*) FROM joined WHERE proof_initial->'in_amount' IS DISTINCT FROM coalesce(to_jsonb(in_amount),'null') OR proof_initial->'out_amount' IS DISTINCT FROM coalesce(to_jsonb(out_amount),'null')
 OR proof_initial->'amount_local' IS DISTINCT FROM coalesce(to_jsonb(amount_local),'null') OR proof_initial->>'account_currency_id' IS DISTINCT FROM account_currency_id::text OR proof_initial->>'sourceSnapshotAsOfUtc' IS DISTINCT FROM '{cutoff}'),
 'targets_without_proof',(SELECT count(*) FROM joined WHERE proof_id IS NULL OR proof_run IS DISTINCT FROM '{run}'::uuid OR proof_old IS DISTINCT FROM legacy_id OR legacy_import_run_id IS DISTINCT FROM '{run}'::uuid),
 'invalid_current_reference',(SELECT count(*) FROM joined WHERE account_id IS NULL OR actual_account_id IS NULL OR account_legacy_id IS NULL OR actual_currency_id IS NULL OR currency_legacy_id IS NULL
 OR account_currency_id IS DISTINCT FROM real_account_currency_id OR is_base_currency IS DISTINCT FROM (currency_legacy_id=1) OR currency_status IS DISTINCT FROM '使用' OR currency_deleted IS DISTINCT FROM false),
 'invalid_source_document_reference',(SELECT count(*) FROM joined WHERE source_doc_id IS NOT NULL AND (actual_doc_id IS NULL OR source_doc_legacy_id IS NULL OR actual_doc_bill_no IS DISTINCT FROM bill_no)),
 'wrong_target_defaults',(SELECT count(*) FROM joined WHERE entry_kind IS DISTINCT FROM 'LEGACY_SNAPSHOT' OR is_deleted IS DISTINCT FROM false OR deleted_at IS NOT NULL OR reversal_of_id IS NOT NULL OR reversal_reason IS NOT NULL OR posting_seq IS NULL OR posting_seq<=0),
 'duplicate_posting_sequences',(SELECT count(*)-count(DISTINCT posting_seq) FROM joined),
 'wrong_month_references',(SELECT count(*) FROM public.account_flow_monthly_summaries m LEFT JOIN public.accounts a ON a.id=m.account_id LEFT JOIN public.currencies c ON c.id=m.account_currency_id WHERE a.id IS NULL OR a.legacy_id IS NULL OR c.id IS NULL OR c.legacy_id IS NULL OR a.currency_id IS DISTINCT FROM c.id),
 'monthly_ledger_mismatch',(SELECT count(*) FROM month_differences),
 'negative_month_groups',(SELECT count(*) FROM ledger_months WHERE in_amount<0 OR out_amount<0),
 'wrong_session_timezone',CASE WHEN current_setting('TimeZone')='Asia/Shanghai' AND (SELECT reconciliation_summary->'financeArchiveOnly'->>'session_timezone' FROM run_identity)='Asia/Shanghai' THEN 0 ELSE 1 END,
 'active_ids_sha256',(SELECT {_hash('legacy_id::text','legacy_id')} FROM joined),
 'archive_ids_sha256',(SELECT {_hash("entry->>'source_legacy_id'","(entry->>'source_legacy_id')::integer")} FROM archived),
 'active_typed_rows_sha256',(SELECT {_hash("source_legacy_id::text||'|'||source_row_sha256",'source_legacy_id')} FROM proofs),
 'archive_typed_rows_sha256',(SELECT {_hash("(entry->>'source_legacy_id')||'|'||(entry->>'source_row_sha256')","(entry->>'source_legacy_id')::integer")} FROM archived),
 'ledger_business_sha256',(SELECT {_hash("x.legacy_id::text||'|'||"+business_hash,'x.legacy_id')} FROM joined x),
 'monthly_business_sha256',(SELECT {_hash(month_hash,'a.legacy_id,c.legacy_id,m.month_start')} FROM public.account_flow_monthly_summaries m LEFT JOIN public.accounts a ON a.id=m.account_id LEFT JOIN public.currencies c ON c.id=m.account_currency_id),
 'target_uuid_binding_sha256',(SELECT {_hash("legacy_id::text||'|'||id::text||'|'||proof_id::text||'|'||account_id::text||'|'||account_currency_id::text||'|'||coalesce(source_doc_id::text,'~')",'legacy_id')} FROM joined),
 'source_execution_sha256',(SELECT encode(digest(jsonb_build_array(legacy_account_flow_import_txid,legacy_account_flow_origin_system_identifier,legacy_account_flow_origin_database_oid)::text,'sha256'),'hex') FROM run_identity)
)"""


def validate(actual,source,*,require=_require):
    require(isinstance(actual,dict) and isinstance(source,dict),'Finance flow monthly facts or source inventory are absent')
    typed=source.get('typed_source_facts');require(isinstance(typed,dict),'Independently typed complete finance flow facts are absent')
    require(type(actual.get('run_rows')) is int and actual['run_rows']==1,'Finance flow exact successful run is absent')
    for key in ZERO_INVARIANTS:require(type(actual.get(key)) is int and actual[key]==0,'Finance flow monthly invariant failed: '+key)
    require(actual.get('target_business_columns')==list(TARGET_BUSINESS_COLUMNS),'Finance ledger business schema differs from the independent contract')
    for key in ('source_rows','active_source_rows','archive_only_rows','monthly_groups','signed_active_rows'):
        require(type(typed.get(key)) is int and type(actual.get(key)) is int and actual[key]>=0 and actual[key]==typed.get(key),'Finance flow source coverage differs: '+key)
    require(actual['source_rows']==source['source_rows'] and actual['active_source_rows']+actual['archive_only_rows']==actual['source_rows'],'Finance source/active/archive conservation differs')
    require(type(actual.get('proof_rows')) is int and actual['proof_rows']==typed['active_source_rows'],'Finance flow proof coverage differs')
    for key in HASH_KEYS:
        require(isinstance(typed.get(key),str) and re.fullmatch('[0-9a-f]{64}',typed[key]) is not None and actual.get(key)==typed[key],'Finance flow independent source projection differs: '+key)
    require(isinstance(actual.get('target_uuid_binding_sha256'),str) and re.fullmatch('[0-9a-f]{64}',actual['target_uuid_binding_sha256']) is not None,'Finance flow actual UUID continuity digest is absent')
    require(isinstance(actual.get('source_execution_sha256'),str) and re.fullmatch('[0-9a-f]{64}',actual['source_execution_sha256']) is not None,'Finance flow immutable source execution digest is absent')
    return {'verified':True,**{key:actual[key] for key in ('source_rows','active_source_rows','archive_only_rows','monthly_groups','signed_active_rows',*HASH_KEYS,'target_uuid_binding_sha256','source_execution_sha256')},
            'source_file_sha256':source['files'][FLOW_FILE]['sha256'],
            'source_typed_rows_and_original_signed_amounts_verified':True,'exact_source_account_currency_document_and_uuid_relations_verified':True,
            'monthly_sums_counts_and_posting_ranges_verified':True,'archive_source_and_absence_from_active_ledger_verified':True,
            'existing_rebuild_function_is_not_the_acceptance_oracle':True,'target_writes_performed':False}

"""V21 exact reviewed historical cash-source partition; never invent GL or drafts.

The portable package contains the independent source review, SQL Server facts,
and native PostgreSQL typed-row fingerprints. Unknown/changed nonposted rows
fail during prepare, before any application database is opened.
"""
from pathlib import Path
import csv
from decimal import Decimal
import hashlib
import json
import re
import shutil
from datetime import datetime,timedelta,timezone

FORMAT='finance-cash-source-archive-policy-v1'
POLICY_FILE='finance_cash_source_policy.json'
REVIEW_FILE='finance_cash_reviewed_dispositions.json'
SEMANTICS_FILE='finance_cash_source_semantics.json'
NATIVE_FILE='finance_cash_typed_source_receipt.json'
PACKAGE_FILES=(POLICY_FILE,REVIEW_FILE,SEMANTICS_FILE,NATIVE_FILE)
FAMILIES={'m_get.csv':('RECEIPT','finance_receipts',20,'M_Get'),
          'm_paid.csv':('PAYMENT','finance_payments',21,'M_Paid')}
ALL_HEADERS=('m_get.csv','m_paid.csv','m_dpaid.csv','m_oget.csv')
REASONS=frozenset(('SOURCE_DEFAULT_AND_DICTIONARY_UNAPPROVED',
 'SOURCE_STATUS_EQUALS_STATUS2_MINUS_ONE','NO_SOURCE_APPROVER','NO_SOURCE_CASH_OR_AR_AP_EFFECT',
 'NO_SOURCE_ALLOCATION_ROWS','ONLY_CREATION_IN_AVAILABLE_SOURCE_LOGS',
 'EXACT_HISTORICAL_SOURCE_ROW_REVIEWED_AS_OF_CUTOFF','NO_PROVEN_MODERN_GL_POSTING_OR_REVERSAL'))

def need(ok,message):
    if not ok:raise ValueError(message)
def sha(path):
    with Path(path).open('rb') as stream:return hashlib.file_digest(stream,'sha256').hexdigest()
def load(path):return json.loads(Path(path).read_text(encoding='utf-8-sig'))
def save(path,obj):Path(path).write_bytes(json.dumps(obj,ensure_ascii=False,indent=2).encode('utf-8'))
def ref(path):return {'file':Path(path).name,'sha256':sha(path)}
def ids_sha(values):return hashlib.sha256(''.join(str(i)+'\n' for i in sorted(values)).encode()).hexdigest()
def rows(path):
    with Path(path).open(encoding='utf-8-sig',newline='') as stream:
        reader=csv.DictReader(stream,delimiter='|',strict=True)
        need(reader.fieldnames and len(reader.fieldnames)==len(set(reader.fieldnames)),'Cash source header is malformed')
        result=list(reader)
    need(all(None not in row and all(v is not None for v in row.values()) for row in result),'Cash source row is malformed')
    return result
def false(value):return value is False or str(value).lower()=='false'
def no_approver(row):return row.get('approver_id') in (None,'','0',0) and row.get('approver_name') in (None,'')
def posted(row):
    try:approver=int(row.get('approver_id'))
    except (TypeError,ValueError):return False
    return str(row.get('status'))=='1' and str(row.get('status2'))=='1' and false(row.get('cancel')) and approver>0

def checked_review(review,semantics,native):
    need(review.get('format')=='exact-reviewed-legacy-finance-source-dispositions-v1' and review.get('status')=='EXACT_THREE_SOURCE_ROWS_REVIEWED_ARCHIVE_ONLY','Explicit reviewed source classification is required')
    need(review.get('unknown_or_changed_unapproved_source_policy')=='EARLY_HARD_FAIL_AND_REVIEW' and review.get('target_accessed') is False and review.get('not_execution_authority') is True,'Source review cannot be target execution authority')
    need(semantics.get('physical_read_only') is True and semantics.get('isolation')=='Serializable' and semantics.get('source_business_writes') is False,'Independent physical read-only serializable source facts are required')
    need({(int(row['ID']),row['YesOrNo']) for row in semantics['facts']['dictionary']}=={(-1,'否'),(0,'否'),(1,'是')},'Real source yes/no dictionary differs')
    for table in ('M_Get','M_Paid'):
        columns=[row for row in semantics['facts']['columns'] if row['table_name']==table and row['column_name'] in ('Status','Status2')]
        need(len(columns)==2 and {row['column_name'] for row in columns}=={'Status','Status2'} and all(row['is_nullable'] is False and re.sub(r'[()\s]','',row['default_sql'] or '')=='-1' for row in columns),'Real source status DEFAULT/NOT NULL evidence differs')
    need(native.get('status')=='TYPED_COMPLETE_SOURCE_ROW_FINGERPRINTS_VERIFIED' and native.get('application_target_accessed') is False and native.get('business_data_written') is False,'Native complete typed-source fingerprint proof is required')
    links={(row['table_name'],int(row['header_id'])):row for row in semantics['facts']['negative_header_cash_AR_AP_links']}
    logs=semantics['facts']['three_bill_lifecycles'];seen=set()
    for row in review['rows']:
        key=(row['source_file'],int(row['legacy_id']))
        need(key not in seen and key[0] in FAMILIES,'Duplicate or unregistered archived cash identity');seen.add(key)
        need(row['source_kind']==FAMILIES[key[0]][0] and row['disposition']=='ARCHIVE_ONLY_UNAPPROVED_HISTORICAL_SOURCE','Archive family/disposition differs')
        need(set(row['reason_codes'])==REASONS,'Every historical unapproved classification reason is required')
        need(row['source_status']==row['source_status2']==-1 and row['source_approver_present'] is False and row['source_cancel'] is False,'Reviewed source is not a directly proved unapproved header')
        need(row['exact_source_cash_rows']==row['exact_source_AR_AP_rows']==row['exact_source_allocation_rows']==0,'Source financial execution exists; archive-only is not authorized')
        need(row['source_amounts_or_approval_changed'] is False and row['target_money_document_created'] is False and row['target_GL_voucher_created'] is False and row['current_workflow_claim_created'] is False and row['all_original_source_bytes_retained'] is True,'Source review must not invent current state')
        full=row['typed_full_row_jsonb_text'];typed=json.loads(full,parse_float=Decimal)
        need(hashlib.sha256(full.encode('utf-8')).hexdigest()==row['typed_full_row_pg_sha256'],'Typed complete source fingerprint differs')
        need(int(typed['legacy_id'])==key[1] and typed['status']==typed['status2']==-1 and false(typed['cancel']) and no_approver(typed),'Typed source contradicts the reviewed source state')
        link=links.get((FAMILIES[key[0]][3],key[1]))
        need(link and link['Status']==link['Status2']==-1 and link['exact_cash_rows']==link['exact_AR_rows']==link['exact_allocation_rows']==0,'Independent exact source cash/AR/AP/allocation evidence differs')
        lifecycle=[event for event in logs if row['bill_no'] in event['EContext']]
        need(len(lifecycle)==1 and lifecycle[0]==row['source_creation_and_last_available_activity'] and '增加' in lifecycle[0]['EContext'] and not any(action in lifecycle[0]['EContext'] for action in ('审核','反审','修改','删除','撤销')),'Complete available historical lifecycle is not creation-only')
        need(row['source_activity_age_days_at_cutoff']>0,'Source-specific historical review must precede the real cutoff')
        cutoff=datetime.fromisoformat(review['source_cutoff_utc'].replace('Z','+00:00')).astimezone(timezone(timedelta(hours=8))).date()
        last=datetime.fromisoformat(lifecycle[0]['source_beijing_time']).date()
        need((cutoff-last).days==row['source_activity_age_days_at_cutoff'],'Historical lifecycle age is not calculated from the real source cutoff and Shanghai wall-clock date')
    need(len(seen)==len(review['rows'])==3,'This reviewed source-policy version requires its exact three historical identities')
    return review['rows']

def validate_sources(directory,policy,reviewed,records=None):
    directory=Path(directory);decisions={(r['source_file'],int(r['legacy_id'])):r for r in reviewed};seen=set();inventory={}
    source_data={name:rows(directory/name) for name in ALL_HEADERS+('m_allcheck.csv','m_in.csv','m_out.csv')}
    for name in ALL_HEADERS:
        data=source_data[name];ids=[int(r['legacy_id']) for r in data]
        need(len(ids)==len(set(ids)) and all(i>0 for i in ids),'Cash source identities are missing/duplicated')
        if records is not None:need(len(data)==records[name]['rows'] and sha(directory/name)==records[name]['sha256'],'Cash header differs from sealed CSV inventory')
        expected=policy['source_files'][name]
        need(sha(directory/name)==expected['sha256'] and len(data)==expected['rows'],'Cash policy does not bind the complete original file')
        active=[];archived=[]
        for row_number,row in enumerate(data,2):
            key=(name,int(row['legacy_id']))
            if posted(row):
                need(key not in decisions,'An approved source was incorrectly reviewed as archive-only');active.append(key[1]);continue
            need(key in decisions,'Unknown or changed nonposted finance source: review before importing')
            d=decisions[key];seen.add(key)
            need(row_number==d['source_row_number'],'Reviewed source row ordinal differs from the complete original CSV')
            need(row['status']==row['status2']=='-1' and false(row['cancel']) and no_approver(row),'Nonposted source does not match reviewed unapproved semantics')
            need(d['source_file_sha256']==sha(directory/name),'Reviewed original source file changed')
            style=FAMILIES[name][2]
            need(not any(int(x['b_style'] or 0)==style and int(x['bill_id'] or 0)==key[1] for x in source_data['m_allcheck.csv']),'Archived header has actual original account flow')
            ledger=source_data['m_in.csv' if name=='m_get.csv' else 'm_out.csv']
            need(not any(int(x['b_style'] or 0)==style and int(x['bill_legacy_id'] or 0)==key[1] for x in ledger),'Archived header has actual original AR/AP')
            archived.append(key[1])
        inventory[name]={'rows':len(ids),'sha256':sha(directory/name),'source_ids':sorted(ids),'source_ids_sha256':ids_sha(ids),
          'active_ids':sorted(active),'active_ids_sha256':ids_sha(active),'archive_ids':sorted(archived),'archive_ids_sha256':ids_sha(archived)}
    need(seen==set(decisions),'Reviewed archive identity is absent from its complete source')
    for name in ('m_allcheck.csv','m_in.csv','m_out.csv'):
        need(sha(directory/name)==policy['source_files'][name]['sha256'],'Related actual cash/AR/AP source file changed')
        if records is not None:need(sha(directory/name)==records[name]['sha256'] and len(source_data[name])==records[name]['rows'],'Related cash/AR/AP differs from sealed input')
    return inventory

def load_policy(directory,records=None):
    directory=Path(directory);path=directory/POLICY_FILE;policy=load(path)
    need(policy.get('format')==FORMAT and policy.get('not_execution_authority') is True,'Portable source policy v1 is required')
    evidence={}
    for key in ('reviewed_dispositions','source_semantics','typed_source_native'):
        item=policy[key];need(re.fullmatch('[a-z0-9_]+[.]json',item['file']) is not None,'Policy evidence references must be portable package filenames')
        target=directory/item['file'];need(sha(target)==item['sha256'],'Sealed source-policy evidence changed');evidence[key]=load(target)
    review=evidence['reviewed_dispositions'];semantics=evidence['source_semantics'];native=evidence['typed_source_native']
    need(review['source_semantics_sha256']==native['source_semantics_sha256']==policy['source_semantics']['sha256'],'Independent source-semantic binder differs')
    need(native['decision_sha256']==policy['reviewed_dispositions']['sha256'],'Native typed-row proof is not for this exact reviewed disposition')
    reviewed=checked_review(review,semantics,native)
    need(review['source_cutoff_utc']==policy['source_cutoff_utc'] and review['source_timezone']=='Asia/Shanghai','Source business cutoff/timezone differs')
    for row in reviewed:
        need(row['source_manifest_sha256']==policy['raw_manifest_sha256'] and row['source_backup_sha256']==policy['source_backup_sha256'] and row['source_semantics_sha256']==policy['source_semantics']['sha256'],'Historical review belongs to another original source snapshot')
    inventory=validate_sources(directory,policy,reviewed,records)
    return {'policy':policy,'reviewed':reviewed,'inventory':inventory,'policy_sha256':sha(path),'files':{name:sha(directory/name) for name in PACKAGE_FILES}}

def prepare_package(reviewed,semantics,native,raw,inputs,output):
    raw=Path(raw);inputs=Path(inputs);output=Path(output);output.mkdir(parents=True,exist_ok=False)
    for source,name in ((reviewed,REVIEW_FILE),(semantics,SEMANTICS_FILE),(native,NATIVE_FILE)):shutil.copy2(source,output/name)
    raw_manifest=load(raw/'export_manifest.json');review=load(output/REVIEW_FILE)
    policy={'format':FORMAT,'not_execution_authority':True,'source_cutoff_utc':raw_manifest['sourceSnapshotAsOfUtc'],
      'raw_manifest_sha256':sha(raw/'export_manifest.json'),'source_backup_sha256':raw_manifest['sourceBackupSha256'],
      'reviewed_dispositions':ref(output/REVIEW_FILE),'source_semantics':ref(output/SEMANTICS_FILE),'typed_source_native':ref(output/NATIVE_FILE),
      'source_files':{name:{'sha256':sha(inputs/name),'rows':len(rows(inputs/name))} for name in ALL_HEADERS+('m_allcheck.csv','m_in.csv','m_out.csv')}}
    for row in review['rows']:need(sha(raw/row['source_file'])==row['raw_source_file_sha256'],'Original raw source file changed')
    save(output/POLICY_FILE,policy)
    # Validate against the complete real source without copying or rewriting CSVs.
    for name in ALL_HEADERS+('m_allcheck.csv','m_in.csv','m_out.csv'):
        try:(output/name).hardlink_to(inputs/name)
        except OSError:shutil.copy2(inputs/name,output/name)
    try:result=load_policy(output)
    finally:
        for name in ALL_HEADERS+('m_allcheck.csv','m_in.csv','m_out.csv'):(output/name).unlink()
    save(output/'policy-preparation-receipt.json',{'status':'EXACT_REVIEWED_CASH_SOURCE_POLICY_PREPARED','policy_sha256':result['policy_sha256'],
      'files':result['files'],'source_partitions':result['inventory'],'application_database_accessed':False,'not_execution_authority':True})
    return result

def copy_package(policy_path,output,raw_manifest):
    policy_path=Path(policy_path);output=Path(output)
    need(policy_path.name==POLICY_FILE,'Use the explicit portable finance_cash_source_policy.json package')
    for name in PACKAGE_FILES:
        need(not (output/name).exists(),'Duplicate prepared cash policy input');shutil.copy2(policy_path.parent/name,output/name)
    result=load_policy(output)
    need(result['policy']['raw_manifest_sha256']==sha(raw_manifest) and result['policy']['source_backup_sha256']==load(raw_manifest)['sourceBackupSha256'],'Prepared cash policy belongs to another raw backup/export')
    return {'format':FORMAT,'file':POLICY_FILE,'sha256':result['policy_sha256'],'evidence_files':result['files']}

def expected_metadata(directory,data=None):
    directory=Path(directory);data=data or load_policy(directory);policy=data['policy']
    manifest_path=directory/'derived_inputs.json';manifest_sha=sha(manifest_path) if manifest_path.is_file() else None
    metadata={'format':FORMAT,'policy_sha256':data['policy_sha256'],'source_cutoff_utc':policy['source_cutoff_utc'],
      'raw_manifest_sha256':policy['raw_manifest_sha256'],'source_backup_sha256':policy['source_backup_sha256'],
      'source_semantics_sha256':policy['source_semantics']['sha256'],'reviewed_dispositions_sha256':policy['reviewed_dispositions']['sha256'],
      'native_typed_source_sha256':policy['typed_source_native']['sha256'],'derived_manifest_sha256':manifest_sha,'source_files':policy['source_files']}
    metadata['package_files']={name:{'sha256':sha(directory/name),'bytes':(directory/name).stat().st_size} for name in PACKAGE_FILES}
    metadata['partitions']={name:{'source_rows':item['rows'],'active_rows':len(item['active_ids']),'archive_rows':len(item['archive_ids']),
      'source_ids_sha256':item['source_ids_sha256'],'active_ids_sha256':item['active_ids_sha256'],'archive_ids_sha256':item['archive_ids_sha256']}
      for name,item in data['inventory'].items()}
    return metadata

def render_sql(directory):
    directory=Path(directory);data=load_policy(directory);metadata=expected_metadata(directory,data)
    selected=[]
    for row in data['reviewed']:
        selected.append({'source_file':row['source_file'],'source_kind':row['source_kind'],'source_legacy_id':row['legacy_id'],
          'source_row_number':row['source_row_number'],'source_file_sha256':row['source_file_sha256'],
          'raw_source_file_sha256':row['raw_source_file_sha256'],'source_row_sha256':row['typed_full_row_pg_sha256'],
          'typed_source_jsonb_text':row['typed_full_row_jsonb_text'],'reason_codes':row['reason_codes'],
          'lifecycle':row['source_creation_and_last_available_activity'],'activity_age_days':row['source_activity_age_days_at_cutoff']})
    # The exact jsonb text is decoded separately, never round-tripped through float.
    def literal(obj):return "convert_from(decode('"+json.dumps(obj,ensure_ascii=False,separators=(',',':')).encode().hex()+"','hex'),'UTF8')::jsonb"
    return """SET LOCAL TimeZone='Asia/Shanghai';
SET LOCAL DateStyle='ISO,YMD';
CREATE TEMP TABLE bootstrap_finance_cash_policy_meta(payload jsonb NOT NULL) ON COMMIT DROP;
INSERT INTO bootstrap_finance_cash_policy_meta VALUES("""+literal(metadata)+""");
CREATE TEMP TABLE bootstrap_finance_cash_policy(source_file text,source_kind text,source_legacy_id int,source_row_number int,
 source_file_sha256 text,raw_source_file_sha256 text,source_row_sha256 text,typed_source_jsonb_text text,reason_codes jsonb,lifecycle jsonb,activity_age_days int,
 PRIMARY KEY(source_file,source_legacy_id)) ON COMMIT DROP;
INSERT INTO bootstrap_finance_cash_policy SELECT * FROM jsonb_populate_recordset(NULL::bootstrap_finance_cash_policy,"""+literal(selected)+");\n"

def archived_ids(source):
    return set(source.get('cash_source_policy',{}).get('inventory',{}).get('m_get.csv',{}).get('archive_ids',[]))

def source_inventory(directory,records):
    if not (Path(directory)/POLICY_FILE).is_file():return None
    data=load_policy(directory,records)
    return {**data,'metadata':expected_metadata(directory,data)}

def acceptance_sql(run_id,source):
    need(re.fullmatch('[0-9a-f-]{36}',str(run_id)) is not None,'Canonical source run UUID required')
    family_sql=[]
    for name,(kind,table,_,_) in FAMILIES.items():
        expected=source['inventory'][name]
        version='settlement_authority_version' if kind=='RECEIPT' else 'amount_authority_version'
        family=f"(p.source_kind='{kind}' OR p.target_table='{table}')"
        route=f"(p.source_kind='{kind}' AND p.target_table='{table}' AND p.source_file='{name}')"
        family_sql.append("'"+name+"',jsonb_build_object("+f"""
 'target_rows',(SELECT count(*) FROM public.{table}),
 'target_source_ids_sha256',(SELECT encode(digest(COALESCE(string_agg(legacy_id::text||chr(10),'' ORDER BY legacy_id),''),'sha256'),'hex') FROM public.{table}),
 'proof_rows',(SELECT count(*) FROM public.legacy_finance_import_sources p WHERE {family}),
 'proof_source_ids_sha256',(SELECT encode(digest(COALESCE(string_agg(p.source_legacy_id::text||chr(10),'' ORDER BY p.source_legacy_id),''),'sha256'),'hex') FROM public.legacy_finance_import_sources p WHERE {family}),
 'wrong_proof_route',(SELECT count(*) FROM public.legacy_finance_import_sources p WHERE {family} AND ({route}) IS NOT TRUE),
 'wrong_proof_run',(SELECT count(*) FROM public.legacy_finance_import_sources p WHERE {family} AND p.run_id IS DISTINCT FROM '{run_id}'::uuid),
 'wrong_proof_file_sha',(SELECT count(*) FROM public.legacy_finance_import_sources p WHERE {family} AND p.source_file_sha256 IS DISTINCT FROM '{expected['sha256']}'),
 'bad_target_state',(SELECT count(*) FROM public.{table} t WHERE t.status<>1 OR t.{version}<>0 OR COALESCE(t.is_deleted,FALSE) OR t.legacy_import_run_id IS DISTINCT FROM '{run_id}'::uuid OR t.legacy_id IS NULL),
 'bad_target_proof',(SELECT count(*) FROM public.{table} t LEFT JOIN public.legacy_finance_import_sources p ON p.target_id=t.id AND {route}
    WHERE p.target_id IS NULL OR p.source_legacy_id IS DISTINCT FROM t.legacy_id OR p.target_snapshot_sha256 IS DISTINCT FROM encode(digest(public.fn_legacy_finance_snapshot(to_jsonb(t),p.target_fields)::text,'sha256'),'hex')),
 'legacy_GL_vouchers',(SELECT count(*) FROM public.gl_vouchers v JOIN public.{table} t ON v.source_doc_id=t.id WHERE t.legacy_import_run_id='{run_id}'::uuid),
 'archive_overlap',(SELECT count(*) FROM public.{table} t JOIN jsonb_array_elements(COALESCE((SELECT reconciliation_summary->'financeCashSourceArchive'->'entries' FROM public.legacy_migration_runs WHERE run_id='{run_id}'::uuid),'[]'::jsonb)) a
    ON a->>'source_file'='{name}' AND (a->>'source_legacy_id')::int=t.legacy_id))""")
    return f"""SELECT jsonb_build_object(
 'run_id','{run_id}','database_current_user',current_user,'transaction_read_only',current_setting('transaction_read_only'),
 'archive_format',(SELECT reconciliation_summary->'financeCashSourceArchive'->>'format' FROM public.legacy_migration_runs WHERE run_id='{run_id}'::uuid),
 'source_policy',(SELECT reconciliation_summary->'financeCashSourceArchive'->'source_policy' FROM public.legacy_migration_runs WHERE run_id='{run_id}'::uuid),
 'archive_entries',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
     'source_file',a->>'source_file','source_kind',a->>'source_kind','source_legacy_id',(a->>'source_legacy_id')::int,
     'source_row_number',(a->>'source_row_number')::int,'source_file_sha256',a->>'source_file_sha256',
     'raw_source_file_sha256',a->>'raw_source_file_sha256','source_row_sha256',a->>'source_row_sha256',
     'typed_source_jsonb_text',(a->'typed_source')::text,'typed_source_hash',encode(digest((a->'typed_source')::text,'sha256'),'hex'),
     'reason_codes',a->'reason_codes','lifecycle',a->'lifecycle','activity_age_days',(a->>'activity_age_days')::int,
     'disposition',a->>'disposition') ORDER BY a->>'source_file',(a->>'source_legacy_id')::int),'[]'::jsonb)
   FROM public.legacy_migration_runs r CROSS JOIN LATERAL jsonb_array_elements(COALESCE(r.reconciliation_summary->'financeCashSourceArchive'->'entries','[]'::jsonb)) a WHERE r.run_id='{run_id}'::uuid),
 'audit_entries',(SELECT COALESCE(jsonb_agg(jsonb_build_object('actor_id',actor_id,'actor_account',actor_account,
    'target_id',target_id,'request_id',request_id,'result',result,'after',"after") ORDER BY target_id),'[]'::jsonb)
   FROM public.audit_log WHERE action='legacy_finance_cash_source_archive' AND request_id='{run_id}'::uuid),
 'package_files',(SELECT jsonb_object_agg(file_name,jsonb_build_object('sha256',sha256,'bytes',byte_size)) FROM public.legacy_migration_run_files WHERE run_id='{run_id}'::uuid AND file_name IN({','.join(repr(name) for name in PACKAGE_FILES)})),
 'families',jsonb_build_object({','.join(family_sql)}))"""

def validate(actual,source,run_id,require=need):
    require(isinstance(actual,dict) and actual.get('run_id')==str(run_id) and actual.get('transaction_read_only')=='on','Cash source partition requires the actual requested read-only snapshot')
    require(actual.get('archive_format')=='finance-cash-source-archive-only-v1' and actual.get('source_policy')==source['metadata'],'Cash source archive source/manifest/policy identity differs')
    require(actual.get('package_files')==source['metadata']['package_files'],'Cash source package is not registered with exact SHA and bytes')
    expected={}
    for row in source['reviewed']:
        expected[(row['source_file'],row['legacy_id'])]={
          'source_file':row['source_file'],'source_kind':row['source_kind'],'source_legacy_id':row['legacy_id'],
          'source_row_number':row['source_row_number'],'source_file_sha256':row['source_file_sha256'],
          'raw_source_file_sha256':row['raw_source_file_sha256'],'source_row_sha256':row['typed_full_row_pg_sha256'],
          'typed_source_jsonb_text':row['typed_full_row_jsonb_text'],'typed_source_hash':row['typed_full_row_pg_sha256'],
          'reason_codes':row['reason_codes'],'lifecycle':row['source_creation_and_last_available_activity'],
          'activity_age_days':row['source_activity_age_days_at_cutoff'],'disposition':row['disposition']}
    entries=actual.get('archive_entries',[])
    saved={(row['source_file'],row['source_legacy_id']):row for row in entries}
    require(len(entries)==len(saved) and saved==expected,'Cash archive missing/duplicate/extra identity, complete typed row, fee, amount or source evidence differs')
    audits=actual.get('audit_entries',[])
    require(len(audits)==len(expected) and len({row['target_id'] for row in audits})==len(audits),'Every original archive identity requires exactly one actual ops audit')
    for audit in audits:
        after=audit['after'];key=(after['source_file'],after['source_legacy_id']);row=expected.get(key)
        require(row is not None and audit['actor_id'] is None and audit['actor_account']=='ops:legacy_finance_cash_archive'
          and audit['target_id']==key[0]+':'+str(key[1]) and audit['request_id']==str(run_id) and audit['result']=='success','Cash archive audit actor/identity differs')
        require(after['run_id']==str(run_id) and after['source_kind']==row['source_kind'] and after['source_file_sha256']==row['source_file_sha256']
          and after['raw_source_file_sha256']==row['raw_source_file_sha256'] and after['source_row_sha256']==row['source_row_sha256']
          and after['source_row_number']==row['source_row_number'] and after['reason_codes']==row['reason_codes']
          and after['disposition']==row['disposition'] and after['source_policy_sha256']==source['policy_sha256']
          and after['source_semantics_sha256']==source['policy']['source_semantics']['sha256']
          and after['raw_manifest_sha256']==source['policy']['raw_manifest_sha256'] and after['source_backup_sha256']==source['policy']['source_backup_sha256']
          and after['database_current_user']==after['database_session_user']=='uten_migrator'
          and after['target_money_document_created'] is False and after['target_GL_or_settlement_created'] is False and after['workflow_claim_created'] is False,'Cash archive actual maintenance attribution or original source audit differs')
    for name in FAMILIES:
        expected=source['inventory'][name];facts=actual.get('families',{}).get(name,{})
        require(facts.get('target_rows')==facts.get('proof_rows')==len(expected['active_ids']) and facts.get('target_source_ids_sha256')==facts.get('proof_source_ids_sha256')==expected['active_ids_sha256'],'Cash source active/proof bidirectional identities differ')
        for fact in ('wrong_proof_route','wrong_proof_run','wrong_proof_file_sha','bad_target_state','bad_target_proof','legacy_GL_vouchers','archive_overlap'):
            require(type(facts.get(fact)) is int and facts[fact]==0,'Cash source target/proof/modern-state invariant failed: '+fact)
    return {'verified':True,'format':'finance-cash-source-archive-only-v1','source_policy_sha256':source['policy_sha256'],
      'source_rows':{name:source['inventory'][name]['rows'] for name in FAMILIES},
      'active_rows':{name:len(source['inventory'][name]['active_ids']) for name in FAMILIES},
      'archived_rows':{name:len(source['inventory'][name]['archive_ids']) for name in FAMILIES},
      'exact_active_plus_archive_identity_coverage':True,'full_typed_original_rows_fees_and_amounts_preserved':True,
      'no_archived_row_in_live_target_or_V626_proof':True,'no_invented_GL_or_workflow_claim':True,
      'actual_database_maintenance_audit_verified':True,'historical_classification_is_source_specific_not_an_age_or_amount_filter':True}

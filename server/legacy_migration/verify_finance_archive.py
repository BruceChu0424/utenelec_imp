#!/usr/bin/env python3
"""Independently verify source-only finance archives before/after local cutover.

Sources are typed by isolated PostgreSQL COPY, preserving quotes/NULL/Decimal.
The target connection executes one BEGIN READ ONLY transaction and SELECTs only.
All evidence is private; console output is a data-free status receipt. Existing
output directories are never overwritten. No username, money or text is printed.
"""
from __future__ import annotations
import argparse
import csv
from decimal import Decimal
import hashlib
import json
from pathlib import Path
import re
import subprocess
import time
import uuid

from finance_archive_rules import expected_archive,verify_archive_and_coverage
from rehearse_local_import import Database

HERE=Path(__file__).resolve().parent
IMAGE='postgres:16.15-alpine'
IDENTIFIER=re.compile(r'[a-z_][a-z0-9_]{0,62}')

def digest(path):
    with Path(path).open('rb') as source:return hashlib.file_digest(source,'sha256').hexdigest()

def invoke(arguments,content=None):
    return subprocess.run(arguments,input=content,capture_output=True)

def checked(arguments,content=None):
    result=invoke(arguments,content)
    if result.returncode:raise ValueError('private PostgreSQL operation failed; raw output suppressed')
    return result.stdout

def verify_local_cli_target(container,database,source_only):
    if container!='uten-imp-postgres':
        raise ValueError('archive verification CLI only permits the local development container')
    if not source_only and (not isinstance(database,str) or not IDENTIFIER.fullmatch(database)
            or (database!='uten_imp' and not re.fullmatch(r'uten_imp_rehearsal_[a-z0-9_]+',database))):
        raise ValueError('archive verification CLI only permits uten_imp or a named local rehearsal database')
    # The coordinator constructor deliberately accepts rehearsal names only.
    # This object checks Docker endpoint/environment and never opens its named
    # database; the actual target below is read strictly in READ ONLY mode.
    context_guard=Database('uten-imp-postgres','uten_imp_rehearsal_context_check','uten')
    context_guard.verify_local()

def source_manifest_identity(directory):
    path=directory/'derived_inputs.json'
    manifest=json.loads(path.read_text(encoding='utf-8-sig'))
    commit=manifest.get('provenance',{}).get('importerRepositoryCommit')
    if not isinstance(commit,str) or not re.fullmatch(r'(?:[0-9a-f]{40}|[0-9a-f]{64})',commit):
        raise ValueError('derived input manifest lacks the complete frozen importer commit')
    return {'manifest_sha256':digest(path),'importer_repository_commit':commit}

def verify_run_identity(facts,manifest):
    run=facts['run'];expected_sha=manifest['manifest_sha256']
    if run.get('export_manifest_sha256')!=expected_sha or run.get('checksum_manifest_sha256')!=expected_sha:
        raise ValueError('target run export/checksum manifest SHA differs from the actual derived input manifest')
    if run.get('migration_repository_commit')!=manifest['importer_repository_commit']:
        raise ValueError('target frozen importer commit differs from the derived input provenance')
    system=facts.get('system_identifier');oid=facts.get('database_oid')
    if not isinstance(system,str) or not re.fullmatch(r'[0-9]{1,20}',system) or type(oid) is not int or oid<=0:
        raise ValueError('target system/database identity is unavailable')
    return {'system_identifier':system,'database_oid':oid,'database':facts['database'],
            'export_manifest_sha256':run['export_manifest_sha256'],
            'checksum_manifest_sha256':run['checksum_manifest_sha256'],
            'migration_repository_commit':run['migration_repository_commit']}

def source_inventory(directory):
    manifest=json.loads((directory/'derived_inputs.json').read_text(encoding='utf-8-sig'))
    records={record['file']:record for record in manifest['files']}
    result={}
    for name in ('m_allcheck.csv','m_acc.csv'):
        record=records[name];path=directory/name
        if digest(path)!=record['sha256'] or path.stat().st_size!=record['bytes']:
            raise ValueError('sealed finance source file differs from the derived input manifest')
        with path.open(encoding='utf-8-sig',newline='') as source:
            rows=list(csv.DictReader(source,delimiter='|',strict=True))
        ids=[]
        for row in rows:
            value=row.get('legacy_id')
            if value is None or not re.fullmatch(r'[1-9][0-9]*',value):raise ValueError('source identity is missing or not a positive integer')
            ids.append(int(value))
        if len(ids)!=record['rows'] or len(set(ids))!=len(ids) or ids!=sorted(ids):
            raise ValueError('source count/unique identity/original export order differs')
        result[name]={'sha256':record['sha256'],'rows':record['rows'],'ids':ids}
    return result

def read_target(container,database,run_id,output):
    if not IDENTIFIER.fullmatch(database) or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,100}',container):
        raise ValueError('local target name is invalid')
    run=str(uuid.UUID(run_id))
    sql=f"""\\set VERBOSITY sqlstate
\\set SHOW_CONTEXT never
BEGIN READ ONLY;
SET LOCAL statement_timeout='60s';
SELECT json_build_object('transaction_read_only',current_setting('transaction_read_only'),
'system_identifier',(SELECT system_identifier::text FROM pg_control_system()),
'database_oid',(SELECT oid::bigint FROM pg_database WHERE datname=current_database()),
'database',current_database(),'run',(SELECT json_build_object('run_id',run_id,'status',status,
'export_manifest_sha256',export_manifest_sha256::text,'checksum_manifest_sha256',checksum_manifest_sha256::text,
'migration_repository_commit',migration_repository_commit,
'reconciliation_status',reconciliation_status,'finance_archive',reconciliation_summary->'financeArchiveOnly')
FROM legacy_migration_runs WHERE run_id='{run}'::uuid),
'run_files',(SELECT json_object_agg(file_name,sha256::text) FROM legacy_migration_run_files
WHERE run_id='{run}'::uuid AND file_name IN('m_acc.csv','m_allcheck.csv')),
'target_ids',(SELECT COALESCE(json_agg(legacy_id ORDER BY legacy_id),'[]'::json) FROM finance_reconciliations WHERE legacy_id IS NOT NULL),
'proof_ids',(SELECT COALESCE(json_agg(source_legacy_id ORDER BY source_legacy_id),'[]'::json) FROM legacy_finance_import_sources
WHERE run_id='{run}'::uuid AND source_kind='ACCOUNT_FLOW'),
'account_ids',(SELECT COALESCE(json_agg(legacy_id ORDER BY legacy_id),'[]'::json) FROM accounts WHERE legacy_id IS NOT NULL),
'all_account_count',(SELECT count(*) FROM accounts));
COMMIT;
"""
    raw=checked(['docker','exec','-i',container,'psql','-X','-qAt','-U','uten','-d',database,'-v','ON_ERROR_STOP=1'],sql.encode())
    (output/'target-readonly-facts.private.json').write_bytes(raw)
    facts=json.loads(raw,parse_float=Decimal)
    if facts.get('transaction_read_only')!='on' or facts.get('database')!=database:raise ValueError('target facts were not read in the required read-only database transaction')
    run_data=facts.get('run')
    if not run_data or run_data['run_id']!=run or run_data['status']!='SUCCESS' or run_data['reconciliation_status']!='PASSED':
        raise ValueError('target has no exact successful reconciled requested migration run')
    return facts

def extract_typed_source(directory,timezone,output):
    # Use the exact loader stage DDL. A protocol shape/type change requires
    # review instead of silently interpreting new source semantics.
    loader=(HERE/'migrate_finance.sql').read_text(encoding='utf-8')
    match=re.search(r'CREATE TEMP TABLE m_allcheck_stage\s*\(.*?\);',loader,re.S|re.I)
    if not match:raise ValueError('reviewed typed account-flow stage is unavailable')
    ddl=match.group(0)
    expected='''CREATE TEMP TABLE m_allcheck_stage (legacy_id int, bill_no text, check_no text, remark text, company text,
    in_total numeric(18,4), out_total numeric(18,4), bill_date timestamptz,
    out_date timestamptz, acc_id int, source text, b_style int, bill_id int);'''
    normalize=lambda value:re.sub(r'\s+','',value).lower()
    if normalize(ddl)!=normalize(expected):raise ValueError('account-flow typed stage changed; review verifier protocol')
    if not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_+./-]{0,100}',timezone):raise ValueError('archive source timezone is invalid')
    name='uten-finance-source-verify-'+uuid.uuid4().hex[:12]
    removed=False
    try:
        checked(['docker','run','--detach','--rm','--network','none','--name',name,
                 '-e','POSTGRES_HOST_AUTH_METHOD=trust','--mount',f'type=bind,source={directory.as_posix()},target=/inputs,readonly',
                 IMAGE,'postgres','-c','log_min_messages=panic','-c','log_min_error_statement=panic',
                 '-c','log_statement=none','-c','log_parameter_max_length=0','-c','log_parameter_max_length_on_error=0'])
        for _ in range(60):
            if invoke(['docker','exec',name,'pg_isready','-U','postgres']).returncode==0:break
            time.sleep(.5)
        else:raise ValueError('isolated source verifier did not become ready')
        info=json.loads(checked(['docker','inspect',name]))[0]
        if info['HostConfig']['NetworkMode']!='none' or info['HostConfig']['PortBindings']:
            raise ValueError('source verifier isolation differs from the required no-network/no-port contract')
        if not any(m['Destination']=='/inputs' and not m['RW'] for m in info['Mounts']):raise ValueError('source verifier input mount is not read-only')
        sql=("\\set VERBOSITY sqlstate\n\\set SHOW_CONTEXT never\nBEGIN;\n"
             +f"SET LOCAL timezone='{timezone}';\nCREATE EXTENSION pgcrypto;\n"+ddl+"\n"
             +"\\copy m_allcheck_stage FROM '/inputs/m_allcheck.csv' WITH(FORMAT csv,DELIMITER '|',HEADER true)\n"
             +"SELECT json_build_object('typed_source',to_jsonb(s.*),'source_row_number',row_number() OVER(ORDER BY legacy_id)+1,"
             +"'source_row_sha256',encode(digest(to_jsonb(s.*)::text,'sha256'),'hex')) FROM m_allcheck_stage s ORDER BY legacy_id;\nROLLBACK;\n")
        raw=checked(['docker','exec','-i',name,'psql','-X','-qAt','-U','postgres','-d','postgres','-v','ON_ERROR_STOP=1'],sql.encode())
        (output/'source-typed-extraction.private.jsonl').write_bytes(raw)
        rows=[json.loads(line,parse_float=Decimal) for line in raw.splitlines() if line.strip()]
        return rows
    finally:
        removed=invoke(['docker','rm','-f','-v',name]).returncode==0
        (output/'source-isolation-receipt.json').write_text(json.dumps({'container':name,'network':'none',
            'ports':False,'input_readonly':True,'business_database_access':False,'container_removed':removed}),encoding='utf-8')
        if not removed:raise ValueError('isolated source verifier cleanup failed')

def verify_target(facts,inventory,expected):
    archive=facts['run']['finance_archive']
    if not archive or archive.get('format')!='finance-source-archive-only-v1' or archive.get('source_file')!='m_allcheck.csv':raise ValueError('target archive summary format/source differs')
    for name in ('m_acc.csv','m_allcheck.csv'):
        if facts['run_files'].get(name)!=inventory[name]['sha256']:raise ValueError('target migration file SHA differs from the current sealed source')
    if archive.get('source_file_sha256')!=inventory['m_allcheck.csv']['sha256']:raise ValueError('archive source file SHA differs')
    if archive.get('source_count')!=inventory['m_allcheck.csv']['rows'] or archive.get('archived_count')!=len(expected) or archive.get('active_count')!=len(facts['target_ids']):raise ValueError('summary source/active/archive counts differ from independently recomputed facts')
    if facts['all_account_count']!=len(inventory['m_acc.csv']['ids']):raise ValueError('target includes an unproved or missing original account identity')
    return verify_archive_and_coverage(expected,archive['entries'],inventory['m_allcheck.csv']['ids'],
        facts['target_ids'],facts['proof_ids'],inventory['m_acc.csv']['ids'],facts['account_ids'])

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input-dir',type=Path,required=True)
    parser.add_argument('--output-directory',type=Path,required=True)
    parser.add_argument('--database')
    parser.add_argument('--expected-run-id')
    parser.add_argument('--container',default='uten-imp-postgres')
    parser.add_argument('--source-only',action='store_true')
    parser.add_argument('--source-timezone',default='Asia/Shanghai')
    args=parser.parse_args()
    if not args.source_only and (not args.database or not args.expected_run_id):parser.error('--database and --expected-run-id are required unless --source-only')
    if args.source_only and (args.database or args.expected_run_id):parser.error('--source-only cannot read a target database')
    directory=args.input_dir.resolve(strict=True);output=args.output_directory.resolve()
    if output.exists() or output==directory or directory in output.parents:parser.error('use a new private output directory outside sealed inputs')
    output.mkdir(parents=True,exist_ok=False)
    receipt={'format':'finance-archive-independent-verification-v1','status':'FAILED',
             'scope':'SOURCE_ONLY' if args.source_only else 'SOURCE_AND_READONLY_TARGET',
             'database':args.database,'expected_run_id':args.expected_run_id,
             'verifier_sha256':digest(__file__),'rules_sha256':digest(HERE/'finance_archive_rules.py'),
             'loader_sha256':digest(HERE/'migrate_finance.sql')}
    try:
        verify_local_cli_target(args.container,args.database,args.source_only)
        manifest_identity=source_manifest_identity(directory)
        inventory=source_inventory(directory)
        facts=None if args.source_only else read_target(args.container,args.database,args.expected_run_id,output)
        target_identity=None if facts is None else verify_run_identity(facts,manifest_identity)
        timezone=args.source_timezone if facts is None else facts['run']['finance_archive']['session_timezone']
        rows=extract_typed_source(directory,timezone,output)
        if [r['typed_source']['legacy_id'] for r in rows]!=inventory['m_allcheck.csv']['ids']:raise ValueError('typed source identities differ from the sealed CSV')
        expected=expected_archive(rows,inventory['m_acc.csv']['ids'],inventory['m_allcheck.csv']['sha256'])
        result={'source_count':len(rows),'active_expected_count':len(rows)-len(expected),'archive_only_count':len(expected)}
        if facts is not None:result.update(verify_target(facts,inventory,expected))
        receipt.update({'status':'PASSED','source_inventory':{n:{k:v for k,v in x.items() if k!='ids'} for n,x in inventory.items()},
                        'source_manifest_identity':manifest_identity,'target_identity':target_identity,
                        'source_timezone':timezone,'result':result,
                        'archive_source_ids':[r['source_legacy_id'] for r in expected],
                        'target_writes_performed':False,'source_business_values_printed':False})
    except Exception as error:
        receipt['error']=str(error)
    (output/'finance-archive-verification-receipt.json').write_text(json.dumps(receipt,ensure_ascii=False,indent=2),encoding='utf-8')
    print(json.dumps({k:receipt[k] for k in ('format','status','scope')}))
    return 0 if receipt['status']=='PASSED' else 66

if __name__=='__main__':raise SystemExit(main())

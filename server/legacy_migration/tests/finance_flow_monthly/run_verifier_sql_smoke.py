"""Owned synthetic verifier SQL tests; original V626 projection/V408 rebuild.

This is a read-only acceptance-query fixture, not a replacement for the separate
full840/916 protocol guard tests. Its schema has no legacy write guards: none
are disabled. Target baseline is built by original functions, not the verifier's
source projection. No actual business database or original company data is used.
"""
import csv,hashlib,importlib.util,io,json,pathlib,re,sys,tempfile,time,uuid

HERE=pathlib.Path(__file__).resolve().parent
STAGE=HERE.parents[1]
import argparse
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--schema-baseline',type=pathlib.Path,required=True,help='Explicit saved PostgreSQL schema-only dump containing original V626/V408 definitions; never a live database')
parser.add_argument('--output',type=pathlib.Path,required=True,help='New output directory; no existing evidence is overwritten')
args=parser.parse_args()
SCHEMA=args.schema_baseline.resolve()
ROOT=args.output.resolve()
if not SCHEMA.is_file() or ROOT.exists() or not ROOT.parent.is_dir():
    raise SystemExit('Saved schema and fresh output directory are required')
ROOT.mkdir()
sys.path.insert(0,str(STAGE))
import verify_finance_flow_monthly as gate

schema=SCHEMA.read_text(encoding='utf-8-sig')
def extract(start,end):
    i=schema.index(start);return schema[i:schema.index(end,i)+len(end)]
def function(name):
    start=schema.index('CREATE FUNCTION public.'+name+'(')
    tag=re.search(r'\bAS\s+(\$[A-Za-z_0-9]*\$)',schema[start:])
    if tag is None:raise RuntimeError('ORIGINAL_FUNCTION_DELIMITER_UNAVAILABLE')
    end=schema.index(tag[1],start+tag.end())+len(tag[1])
    return schema[start:schema.index(';',end)+1]
def table(name):return extract('CREATE TABLE public.'+name+' (','\n);')
run='00000000-0000-0000-0000-000000000099';cutoff='2026-03-01T00:00:00Z';created=False
context=gate._local_context();name='uten-monthly-verifier-'+uuid.uuid4().hex[:12]
def cmd(args,data=None,timeout=60):
    import subprocess
    r=subprocess.run(['docker','--context',context,*args],input=data,capture_output=True,timeout=timeout)
    if r.returncode:raise RuntimeError('OWN_FIXTURE_COMMAND_FAILED_STDERR_SHA_'+hashlib.sha256(r.stderr).hexdigest())
    return r.stdout
def sql(text):return cmd(['exec','-i',name,'psql','-X','-qAt','-v','ON_ERROR_STOP=1','-U','postgres'],text.encode())
def write_csv(path,columns,rows):
    with path.open('w',encoding='utf-8',newline='') as f:
        w=csv.writer(f,delimiter='|',lineterminator='\n');w.writerow(columns);w.writerows(rows)
    return {'file':path.name,'sha256':hashlib.sha256(path.read_bytes()).hexdigest(),'bytes':path.stat().st_size,'rows':len(rows)}

with tempfile.TemporaryDirectory(prefix='finance-monthly-synthetic-') as temporary:
    directory=pathlib.Path(temporary);records={}
    flow=[
      (1,'R1','','','',10,0,'2026-01-01T00:00:00+08:00','',101,'',20,5),
      (2,'R1','','','',-1,0,'2026-01-15T00:00:00+08:00','',101,'',20,5),
      (3,'P1','','','',0,3,'2026-01-31T20:00:00+00:00','',102,'',21,6),
      (4,'ARCHIVE','','','',2,0,'2026-01-01T00:00:00+08:00','',999,'',20,5),
      # Raw empty numerics are SQL NULL, not zero; preserve both in proof.
      (5,'UNKNOWN','','','','','','2026-01-10T00:00:00+08:00','',101,'',20,999),
    ]
    records[gate.FLOW_FILE]=write_csv(directory/gate.FLOW_FILE,gate.FLOW_COLUMNS,flow)
    accounts=[(101,'a','fixture-main','',0,0,0,0,'',0,'使用',0,1),(102,'b','香港fixture','',0,0,0,0,'',0,'使用',0,1)]
    records['m_acc.csv']=write_csv(directory/'m_acc.csv',gate.ACCOUNT_COLUMNS,accounts)
    records['currency.csv']=write_csv(directory/'currency.csv',gate.CURRENCY_COLUMNS,[(1,'CNY','fixture-base',1,'使用'),(3,'USD','fixture-other',7,'使用')])
    for filename,kind in gate.HEADERS:
        rows=[(5,'R1')] if kind=='RECEIPT' else [(6,'P1')] if kind=='PAYMENT' else []
        records[filename]=write_csv(directory/filename,('legacy_id','bill_no'),rows)
    manifest={'formatVersion':1,'sourceSnapshotAsOfUtc':cutoff,'files':list(records.values()),'provenance':{'importerRepositoryCommit':'b'*40}}
    (directory/'derived_inputs.json').write_text(json.dumps(manifest)+'\n',encoding='utf-8')
    source=gate.source_inventory(directory,records);source['typed_source_facts']=gate.typed_source_facts(source)
    try:
        cmd(['run','--pull=never','-d','--name',name,'--network','none','--mount','type=tmpfs,destination=/var/lib/postgresql/data','-e','POSTGRES_HOST_AUTH_METHOD=trust','postgres:16.15-alpine','-c','log_min_error_statement=panic','-c','log_min_messages=panic']);created=True
        import subprocess
        for _ in range(80):
            r=subprocess.run(['docker','--context',context,'exec',name,'pg_isready','-U','postgres'],capture_output=True)
            if r.returncode==0:break
            time.sleep(.15)
        else:raise RuntimeError('OWN_FIXTURE_NOT_READY')
        for filename in (gate.FLOW_FILE,'m_acc.csv'):
            cmd(['exec','-i',name,'sh','-c','cat > /tmp/'+filename],(directory/filename).read_bytes())
        original_functions='\n'.join(function(n) for n in ('fn_financial_amount_is_exact','fn_financial_book_amount_is_exact','fn_legacy_finance_snapshot','fn_legacy_finance_cash_projection','fn_rebuild_account_flow_monthly_summaries','fn_assert_account_flow_monthly_integrity'))
        # The integrity assertion depends on this actual original view.
        start=schema.index('CREATE VIEW public.v_account_flow_monthly_integrity AS')
        view=schema[start:schema.index(';',start)+1]
        setup="SET TIME ZONE 'Asia/Shanghai'; CREATE EXTENSION pgcrypto;\n"+original_functions+'\n'+table('finance_reconciliations')+'\n'+table('account_flow_monthly_summaries')+"""
CREATE TABLE public.currencies(id uuid PRIMARY KEY,legacy_id int, is_base_currency boolean,status text,is_deleted boolean DEFAULT false);
CREATE TABLE public.accounts(id uuid PRIMARY KEY,legacy_id int,currency_id uuid);
CREATE TABLE public.finance_receipts(id uuid PRIMARY KEY,legacy_id int,bill_no text);
CREATE TABLE public.finance_payments(LIKE public.finance_receipts INCLUDING ALL);
CREATE TABLE public.finance_other_incomes(LIKE public.finance_receipts INCLUDING ALL);
CREATE TABLE public.finance_expenses(LIKE public.finance_receipts INCLUDING ALL);
CREATE TABLE public.finance_bank_transfers(LIKE public.finance_receipts INCLUDING ALL);
CREATE TABLE public.legacy_migration_runs(run_id uuid PRIMARY KEY,status text,reconciliation_status text,target text,migration_mode text,mapping_version text,export_manifest_sha256 text,migration_repository_commit text,reconciliation_summary jsonb,legacy_account_flow_import_txid bigint,legacy_account_flow_origin_system_identifier text,legacy_account_flow_origin_database_oid oid);
CREATE TABLE public.legacy_migration_run_files(run_id uuid,file_name text,sha256 text);
CREATE TABLE public.legacy_finance_import_sources(id uuid DEFAULT gen_random_uuid(),run_id uuid,source_kind text,source_legacy_id int,target_table text,target_id uuid,source_file text,source_file_sha256 text,source_row_sha256 text,target_fields text[],target_snapshot_sha256 text,initial_state jsonb,issued_txid bigint);
ALTER TABLE public.account_flow_monthly_summaries ADD PRIMARY KEY(account_id,account_currency_id,month_start);
CREATE SEQUENCE public.fixture_posting_sequence;
ALTER TABLE public.finance_reconciliations ALTER COLUMN posting_seq SET DEFAULT nextval('public.fixture_posting_sequence');
INSERT INTO public.currencies VALUES('00000000-0000-0000-0000-000000000001',1,true,'使用',false),('00000000-0000-0000-0000-000000000003',3,false,'使用',false);
INSERT INTO public.accounts VALUES('00000000-0000-0000-0000-000000000101',101,'00000000-0000-0000-0000-000000000001'),('00000000-0000-0000-0000-000000000102',102,'00000000-0000-0000-0000-000000000003');
INSERT INTO public.finance_receipts VALUES('00000000-0000-0000-0000-000000000005',5,'R1');
INSERT INTO public.finance_payments VALUES('00000000-0000-0000-0000-000000000006',6,'P1');
CREATE TEMP TABLE source_flow("""+gate.FLOW_DDL+");\n\\copy source_flow FROM '/tmp/m_allcheck.csv' WITH(FORMAT csv,DELIMITER '|',HEADER true)\n"+"CREATE TEMP TABLE source_account("+gate.ACCOUNT_DDL+");\n\\copy source_account FROM '/tmp/m_acc.csv' WITH(FORMAT csv,DELIMITER '|',HEADER true)\n"+view+"\nBEGIN;\n"
        summary={'sourceSnapshotAsOfUtc':cutoff,'financeArchiveOnly':{'format':'finance-source-archive-only-v1','source_file':gate.FLOW_FILE,'source_file_sha256':records[gate.FLOW_FILE]['sha256'],'source_count':5,'active_count':4,'archived_count':1,'session_timezone':'Asia/Shanghai','entries':[]}}
        # Only synthetic metadata is embedded; no original company rows used.
        setup+="INSERT INTO public.legacy_migration_runs SELECT '"+run+"','SUCCESS','PASSED','--bootstrap-all','BOOTSTRAP','bootstrap-v19','"+source['_manifest_sha256']+"','"+'b'*40+"','"+json.dumps(summary).replace("'","''")+"'::jsonb,txid_current(),system_identifier::text,(SELECT oid FROM pg_database WHERE datname=current_database()) FROM pg_control_system();\n"
        setup+='\n'.join("INSERT INTO public.legacy_migration_run_files VALUES('"+run+"','"+n+"','"+r['sha256']+"');" for n,r in records.items())
        setup+="UPDATE public.legacy_migration_runs SET reconciliation_summary=reconciliation_summary||jsonb_build_object('targetSystemIdentifier',(SELECT system_identifier::text FROM pg_control_system()));\n"
        setup+="""
CREATE TEMP TABLE original_payload AS SELECT s.legacy_id,to_jsonb(s) original_row,
 public.fn_legacy_finance_cash_projection('ACCOUNT_FLOW',to_jsonb(s),NULL)||jsonb_build_object('id',gen_random_uuid(),'legacy_import_run_id','"""+run+"""'::uuid) payload
 FROM source_flow s WHERE EXISTS(SELECT 1 FROM source_account a WHERE a.legacy_id=s.acc_id);
DO $$ DECLARE r record;cols text;fields text[];BEGIN FOR r IN SELECT * FROM original_payload ORDER BY legacy_id LOOP
 SELECT string_agg(format('%I',key),',' ORDER BY key),array_agg(key ORDER BY key) INTO cols,fields FROM jsonb_object_keys(r.payload) key;
 EXECUTE format('INSERT INTO public.finance_reconciliations(%s) SELECT %s FROM jsonb_populate_record(NULL::public.finance_reconciliations,$1)',cols,cols) USING r.payload;
 INSERT INTO public.legacy_finance_import_sources(run_id,source_kind,source_legacy_id,target_table,target_id,source_file,source_file_sha256,source_row_sha256,target_fields,target_snapshot_sha256,initial_state,issued_txid)
 SELECT '"""+run+"""','ACCOUNT_FLOW',r.legacy_id,'finance_reconciliations',(r.payload->>'id')::uuid,'m_allcheck.csv','"""+records[gate.FLOW_FILE]['sha256']+"""',encode(digest(r.original_row::text,'sha256'),'hex'),fields,encode(digest(public.fn_legacy_finance_snapshot(r.payload,fields)::text,'sha256'),'hex'),
 jsonb_build_object('in_amount',r.payload->'in_amount','out_amount',r.payload->'out_amount','amount_local',r.payload->'amount_local','account_currency_id',r.payload->'account_currency_id','sourceSnapshotAsOfUtc','"""+cutoff+"""'),txid_current();
END LOOP;END $$;
UPDATE public.legacy_migration_runs SET reconciliation_summary=jsonb_set(reconciliation_summary,'{financeArchiveOnly,entries}',(SELECT jsonb_agg(jsonb_build_object('source_file','m_allcheck.csv','source_file_sha256','"""+records[gate.FLOW_FILE]['sha256']+"""','source_legacy_id',s.legacy_id,'typed_source',to_jsonb(s),'source_row_sha256',encode(digest(to_jsonb(s)::text,'sha256'),'hex'),'disposition','ARCHIVE_ONLY')) FROM source_flow s WHERE s.legacy_id=4));
SELECT public.fn_rebuild_account_flow_monthly_summaries(NULL);
SELECT public.fn_assert_account_flow_monthly_integrity(NULL);
COMMIT;
"""
        sql(setup)
        query=gate.acceptance_sql(run,source)
        def evaluate(mutation=''):
            script="BEGIN ISOLATION LEVEL REPEATABLE READ "+('READ WRITE' if mutation else 'READ ONLY')+"; SET LOCAL TimeZone='Asia/Shanghai'; SET LOCAL DateStyle='ISO, YMD';\n"+mutation+"\nSELECT ("+query+");\nROLLBACK;\n"
            result=sql(script).decode().strip().splitlines()
            return json.loads(result[-1])
        baseline=evaluate();gate.validate(baseline,source)
        cases=[]
        def attack(name,mutation):
            actual=evaluate(mutation)
            try:gate.validate(actual,source)
            except ValueError:cases.append({'case':name,'rejected':True});return
            raise AssertionError('VERIFIER_ACCEPTED_MUTATION_'+name)
        resign="UPDATE public.legacy_finance_import_sources p SET target_snapshot_sha256=encode(digest(public.fn_legacy_finance_snapshot(to_jsonb(t),p.target_fields)::text,'sha256'),'hex') FROM public.finance_reconciliations t WHERE t.id=p.target_id;"
        rebuild="SELECT public.fn_rebuild_account_flow_monthly_summaries(NULL);"
        attack('raw_amount_changed_and_proof_resigned_and_month_rebuilt',"UPDATE public.finance_reconciliations SET in_amount=in_amount+1 WHERE legacy_id=1;"+resign+rebuild)
        attack('raw_signed_value_clamped_and_all_cached_values_resigned',"UPDATE public.finance_reconciliations SET in_amount=0 WHERE legacy_id=2;"+resign+rebuild)
        attack('monthly_amount_changed',"UPDATE public.account_flow_monthly_summaries SET in_amount=in_amount+1;")
        attack('monthly_count_changed',"UPDATE public.account_flow_monthly_summaries SET flow_count=flow_count+1;")
        attack('monthly_posting_range_changed',"UPDATE public.account_flow_monthly_summaries SET last_posting_seq=last_posting_seq+1;")
        attack('missing_monthly_rebuild',"DELETE FROM public.account_flow_monthly_summaries;")
        attack('proof_typed_row_sha_forged',"UPDATE public.legacy_finance_import_sources SET source_row_sha256=repeat('0',64) WHERE source_legacy_id=1;")
        attack('archive_typed_value_changed_and_hash_resigned',"UPDATE public.legacy_migration_runs SET reconciliation_summary=jsonb_set(reconciliation_summary,'{financeArchiveOnly,entries,0,typed_source,in_total}','9'); UPDATE public.legacy_migration_runs SET reconciliation_summary=jsonb_set(reconciliation_summary,'{financeArchiveOnly,entries,0,source_row_sha256}',to_jsonb(encode(digest((reconciliation_summary#>'{financeArchiveOnly,entries,0,typed_source}')::text,'sha256'),'hex')));")
        attack('source_file_sha_changed',"UPDATE public.legacy_migration_run_files SET sha256=repeat('0',64) WHERE file_name='m_allcheck.csv';")
        attack('origin_oid_changed',"UPDATE public.legacy_migration_runs SET legacy_account_flow_origin_database_oid=1;")
        attack('proof_issued_txid_changed',"UPDATE public.legacy_finance_import_sources SET issued_txid=issued_txid+1;")
        attack('future_business_column',"ALTER TABLE public.finance_reconciliations ADD COLUMN future_capacity numeric;")
        attack('dangling_document_uuid_resigned',"UPDATE public.finance_reconciliations SET source_doc_id=gen_random_uuid() WHERE legacy_id=5;"+resign)
        attack('wrong_real_account_resigned_and_rebuilt',"UPDATE public.finance_reconciliations SET account_id='00000000-0000-0000-0000-000000000102',account_currency_id='00000000-0000-0000-0000-000000000003' WHERE legacy_id IN(1,2,5);"+resign+rebuild)
        result={'state':'SYNTHETIC_READONLY_VERIFIER_SQL_SMOKE_PASSED_NOT_PROTOCOL_GUARD_TEST','positive_original_projection_and_rebuild':True,'cases':cases,'source_counts':{k:v for k,v in source['typed_source_facts'].items() if not k.endswith('_sha256')},'raw_values_printed':False,'actual_databases_connected':0,'business_guards_disabled':0}
    finally:
        if created:cmd(['rm','-f','-v',name]);created=False
    result['owned_containers_removed']=True
    p=ROOT/'native-verifier-sql-smoke.json';p.write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
    print(json.dumps({'receipt':str(p),'sha256':hashlib.sha256(p.read_bytes()).hexdigest(),'negative_cases':len(result['cases']),'positive':True}))

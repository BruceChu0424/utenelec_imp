"""Independent typed-source acceptance for finance masters (protocol 18).

Default CLI is offline. Explicit source typing owns a local network-none PG;
target SQL is only embedded in the generic repeatable-read/read-only verifier.
No source names, bank numbers, original amounts or full rows are emitted.
"""
import argparse
import csv
from decimal import Decimal, InvalidOperation
import hashlib
import io
import json
from pathlib import Path
import re
import subprocess
import time
import uuid

from verify_stock_typed_source_hashes import verify_local_docker

STYLE_FILE='m_style.csv';ACCOUNT_FILE='m_acc.csv';CURRENCY_FILE='currency.csv'
BASELINE_FILE='finance_seed_baseline.json'
STYLE_COLUMNS=('legacy_id','style_class_id','code','name','parent_legacy','remark','status','dept_status','next_number','init_total','q_status','orient_status1','orient_status2','unit','item_id')
ACCOUNT_COLUMNS=('legacy_id','code','name','bank_account_no','init_balance','receipts_total','payments_total','balance_current','remark','parent_legacy_id','status','style_legacy_id','a_style')
CURRENCY_COLUMNS=('legacy_id','code','name','exchange_rate','status')
STYLE_DDL='legacy_id int,style_class_id int,code text,name text,parent_legacy int,remark text,status int,dept_status boolean,next_number text,init_total numeric(18,4),q_status boolean,orient_status1 boolean,orient_status2 boolean,unit text,item_id int'
ACCOUNT_DDL='legacy_id int,code text,name text,bank_account_no text,init_balance numeric(18,4),receipts_total numeric(18,4),payments_total numeric(18,4),balance_current numeric(18,4),remark text,parent_legacy_id int,status text,style_legacy_id int,a_style int'
CURRENCY_DDL='legacy_id int,code text,name text,exchange_rate numeric(18,6),status text'
STYLE_FIELDS=tuple(sorted(('code','name','category','parent_id','level','sort_order','path','is_departmental','is_receipt','is_payment','linked_account_legacy_id','linked_account_id','init_balance','status','auto_created','is_deleted','deleted_at','legacy_source_code','legacy_source_item_id')))
ACCOUNT_FIELDS=tuple(sorted(('code','name','bank_account_no','account_type','currency_id','style_id','init_balance','receipts_total','payments_total','balance_current','parent_legacy_id','style_legacy_id','status','is_deleted','auto_created','deleted_at','balance_adjustments_total','balance_floor')))
SEED_STYLE_FIELDS=tuple(sorted((*STYLE_FIELDS,'id','legacy_id','legacy_source_import_run_id')))
ROLE_FIELDS=tuple(sorted(('id','role_key','style_id','required_category','description')))
REPORT_ROOT_POLICY={**{code:'ACCOUNT' for code in ('101','102','113','123','139','151','172','173')},
                    **{code:'LIABILITY' for code in ('203','204','205','221')},
                    **{code:'EQUITY' for code in ('301','321')},
                    **{code:'INCOME' for code in ('031','032','033')},
                    **{code:'EXPENSE' for code in ('041','042','043')}}

def _require(value,message):
    if not value:raise ValueError(message)

def digest(path):return hashlib.sha256(Path(path).read_bytes()).hexdigest()

def _positive(value,label):
    _require(type(value) in (str,int) and re.fullmatch('[1-9][0-9]*',str(value)) is not None,label+' is invalid')
    return int(value)

def load_seed_baseline(path,expected_sha,*,require=_require,minimum_schema=914,migration_directory=None):
    path=Path(path)
    require(re.fullmatch('[0-9a-f]{64}',expected_sha or '') is not None,'Finance seed baseline SHA is absent')
    require(path.is_file() and not path.is_symlink() and digest(path)==expected_sha,'Finance seed baseline bytes differ')
    data=json.loads(path.read_text(encoding='utf-8-sig'))
    require(data.get('format')=='finance-seed-baseline-v1' and data.get('status')=='CAPTURED_READONLY','Finance seed baseline is not an actual read-only capture')
    schema=_positive(data.get('schema_version'),'Finance baseline schema')
    require(schema>=minimum_schema and _positive(data.get('successful_migration_count'),'Finance baseline migration count')==len(data.get('applied_sql',[])),'Finance seed baseline schema/SQL inventory differs')
    require(data.get('failed_migration_count')==0 and type(data.get('failed_migration_count')) is int,'Finance baseline contains failed migration history')
    zero_keys={'goods','users','accounts','gl_entries','ar_ap_ledger','finance_expenses','finance_payments','finance_receipts',
               'source_legacy_styles','finance_other_incomes','finance_bank_transfers','finance_reconciliations'}
    require(isinstance(data.get('business_counts'),dict) and zero_keys<=set(data['business_counts'])
            and all(type(n) is int and n==0 for n in data['business_counts'].values()),'Finance baseline must precede business or source-master import')
    require(isinstance(data.get('payment_styles'),list) and isinstance(data.get('posting_roles'),list),'Finance baseline full masters/roles are absent')
    identity=data.get('database_identity',{})
    system=str(_positive(identity.get('system_identifier'),'Finance baseline system identifier'))
    oid=_positive(identity.get('database_oid'),'Finance baseline database OID')
    styles=data['payment_styles'];roles=data['posting_roles']
    if schema>=914:require(all(sorted(row)==list(SEED_STYLE_FIELDS) for row in styles),'Finance baseline master business fields do not match the captured new schema')
    require(all(sorted(row)==list(ROLE_FIELDS) for row in roles),'Finance baseline role business fields are incomplete')
    try:
        for row in styles:uuid.UUID(row['id'])
        for row in roles:
            uuid.UUID(row['id'])
            if row.get('style_id') is not None:uuid.UUID(row['style_id'])
    except (ValueError,KeyError,TypeError,AttributeError):require(False,'Finance baseline UUID identity is invalid')
    require(len({row.get('id') for row in styles})==len(styles) and all(row.get('legacy_id') is None for row in styles),'Finance baseline source-free seed identities differ')
    require(all(row.get('legacy_source_import_run_id') is None and row.get('legacy_source_code') is None
                and row.get('legacy_source_item_id') is None for row in styles),'Finance baseline must contain only original system seed rows')
    require(len({row.get('role_key') for row in roles})==len(roles),'Finance baseline role identities are duplicated')
    require(all(row.get('style_id') is None or row['style_id'] in {s['id'] for s in styles} for row in roles),'Finance baseline configured role has no exact seed UUID')
    inventory=data.get('migration_sources')
    require(isinstance(inventory,list) and len(inventory)==len(data['applied_sql']),'Finance baseline complete SQL source inventory is absent')
    canonical=hashlib.sha256(json.dumps(inventory,sort_keys=True,separators=(',',':'),ensure_ascii=False).encode()).hexdigest()
    require(canonical==data.get('applied_sql_sha256'),'Finance baseline SQL-set SHA differs')
    directory=Path(migration_directory) if migration_directory is not None else Path(__file__).resolve().parent.parent/'src/main/resources/db/migration'
    files={file.name:file for file in directory.glob('V*__*.sql')}
    require(set(files)=={item.get('file') for item in inventory} and len(files)==len(inventory),'Finance baseline SQL inventory differs from the frozen complete schema')
    from verify_candidate import flyway_checksum
    checksums={item.get('script'):item.get('checksum') for item in data['applied_sql']}
    require(set(checksums)==set(files) and len(checksums)==len(data['applied_sql']),'Finance baseline native migration checksum inventory differs')
    for item in inventory:
        file=files[item['file']]
        require(file.is_file() and not file.is_symlink() and digest(file)==item.get('sha256')
                and flyway_checksum(file.read_bytes())==checksums[file.name], 'Finance baseline actual SQL checksum/source bytes differ')
    require(max(int(re.match(r'V([0-9]+)__',name).group(1)) for name in files)==schema,'Finance baseline highest SQL version differs from its actual captured schema')
    return {'sha256':expected_sha,'path':str(path.resolve()),'data':data,
            'schema_version':schema,'database_identity':{'system_identifier':system,'database_oid':oid}}

def sealed_seed_baseline(directory,provenance,external_path=None,external_sha=None,*,require=_require,minimum_schema=914):
    filename=provenance.get('financeSeedBaselineFile');sha=provenance.get('financeSeedBaselineSha256')
    require(filename==BASELINE_FILE,'Sealed finance baseline filename is absent or unsafe')
    baseline=load_seed_baseline(Path(directory)/filename,sha,require=require,minimum_schema=minimum_schema)
    if external_path is not None or external_sha is not None:
        require(external_path is not None and external_sha==sha,'External finance baseline anchor differs from the sealed provenance')
        require(digest(external_path)==sha,'External finance baseline file differs from the sealed bytes')
    return baseline

def source_inventory(directory,records,*,require=_require):
    needed=(STYLE_FILE,ACCOUNT_FILE,CURRENCY_FILE)
    if not all(name in records for name in needed):return None
    directory=Path(directory);files={};ids={};styles={};accounts=[]
    for name,columns in ((STYLE_FILE,STYLE_COLUMNS),(ACCOUNT_FILE,ACCOUNT_COLUMNS),(CURRENCY_FILE,CURRENCY_COLUMNS)):
        path=directory/name;record=records[name]
        require(path.is_file() and not path.is_symlink() and path.stat().st_size==record['bytes'] and digest(path)==record['sha256'],'Sealed finance master source bytes differ: '+name)
        with path.open(encoding='utf-8-sig',newline='') as stream:
            reader=csv.DictReader(stream,delimiter='|',strict=True)
            require(tuple(reader.fieldnames or ())==columns,'Finance master COPY column positions differ: '+name)
            rows=list(reader)
        values=[]
        for row in rows:
            require(None not in row and all(value is not None for value in row.values()),'Finance master source row width differs')
            old=_positive(row['legacy_id'],'Finance master source identity');values.append(old)
            if name==STYLE_FILE:styles[old]=row
            if name==ACCOUNT_FILE:accounts.append(row)
            numeric_columns=('init_total',) if name==STYLE_FILE else ('init_balance','receipts_total','payments_total','balance_current') if name==ACCOUNT_FILE else ('exchange_rate',)
            for column in numeric_columns:
                if row[column]!='':
                    try:finite=Decimal(row[column]).is_finite()
                    except InvalidOperation:finite=False
                    require(finite,'Finance master source contains a non-finite or invalid numeric value')
        require(len(values)==record['rows'] and len(set(values))==len(values),'Finance master source identity count differs')
        if name in (STYLE_FILE,ACCOUNT_FILE):require(len(values)<=999999,'Finance master source exceeds the six-digit code namespace')
        files[name]=dict(record);ids[name]=sorted(values)
    # Detect cycles independently of the loader; absent old parents retain the
    # original root fallback and are separately reported by the typed projection.
    for old in styles:
        seen=set();current=old
        while current in styles:
            require(current not in seen,'Finance master source hierarchy is cyclic')
            seen.add(current);raw=styles[current]['parent_legacy']
            current=int(raw) if raw else 0
            if current==0:break
    bank_roots=[row for row in styles.values() if (row['parent_legacy'] or '0')=='0'
                and row['style_class_id']=='1' and row['code'].strip()=='102' and row['name'].strip()=='银行存款']
    for account in accounts:
        current=int(account['style_legacy_id'] or '0')
        while current:
            require(current in styles,'Finance account positive source ancestry is missing')
            row=styles[current];parent=int(row['parent_legacy'] or '0')
            if not parent and row['style_class_id']=='1' and row['code'].strip()=='102':
                require(len(bank_roots)==1,'Finance account source bank root is missing or ambiguous')
            current=parent
    context={}
    manifest_file=directory/'derived_inputs.json'
    if manifest_file.exists():
        manifest=json.loads(manifest_file.read_text(encoding='utf-8-sig'))
        context={'_manifest_sha256':digest(manifest_file),'_frozen_commit':manifest.get('provenance',{}).get('importerRepositoryCommit')}
    elif (directory/'export_manifest.json').exists():
        manifest_file=directory/'export_manifest.json';manifest=json.loads(manifest_file.read_text(encoding='utf-8-sig'))
        context={'_manifest_sha256':digest(manifest_file),'_frozen_commit':manifest.get('repositoryCommit')}
    return {'style_rows':len(ids[STYLE_FILE]),'account_rows':len(ids[ACCOUNT_FILE]),
            'files':files,'_input_directory':str(directory.resolve()),'_ids':ids,**context}

def _array(fields):return 'ARRAY['+','.join("'"+field+"'" for field in fields)+']::text[]'

def _snapshot(payload,fields):return 'private_snapshot('+payload+','+_array(fields)+')'

def _hash(expression,order):
    return "encode(digest(coalesce(string_agg("+expression+"||chr(10),'' ORDER BY "+order+"),''),'sha256'),'hex')"

def _account_type_sql():
    # Independent expression of the reviewed source rules. Source hierarchy is
    # consulted only after every known-name rule, including both generic aliases.
    return """CASE WHEN a.name LIKE '%香%' THEN 'OFFSHORE'
 WHEN a.name LIKE '%微%' OR a.name LIKE '%支付宝%' THEN 'THIRD_PARTY'
 WHEN a.name LIKE '%现金%' THEN 'CASH'
 WHEN a.name='支票' AND a.status='禁用' THEN 'CHECK'
 WHEN a.name='支票' THEN 'FOREIGN_CHECK'
 WHEN a.name IN('一般账户','一般帐户') THEN 'GENERAL'
 WHEN a.name LIKE ANY(ARRAY['%农%','%工商%','%工行%','%建设%','%建行%','%交通%','%交行%','%招商%','%招行%','%邮政%','%信用社%','%兴业%','%中行%','%广发%'])
   OR a.name IN('中国银行','基本户') THEN 'BANK'
 WHEN EXISTS(SELECT 1 FROM source_account_ancestry root WHERE root.account_legacy_id=a.legacy_id
        AND coalesce(root.parent_legacy,0)=0 AND root.style_class_id=1
        AND btrim(root.code)='102' AND btrim(root.name)='银行存款')
  AND NOT EXISTS(SELECT 1 FROM source_account_ancestry ancestor
        WHERE ancestor.account_legacy_id=a.legacy_id AND ancestor.style_class_id IS DISTINCT FROM 1)
 THEN 'BANK' ELSE 'GENERAL' END"""

def _expected_sql():
    category="CASE s.style_class_id WHEN 1 THEN 'ACCOUNT' WHEN 2 THEN 'LIABILITY' WHEN 3 THEN 'EQUITY' WHEN 4 THEN 'EXPENSE' WHEN 5 THEN 'INCOME' ELSE 'METHOD' END"
    live="s.item_id>0 AND s.style_class_id=1 AND coalesce(nullif(a.status,''),'使用')='使用' AND a.legacy_id IS NOT NULL"
    reason="CASE WHEN s.item_id IS NULL OR s.item_id=0 THEN 'NO_SOURCE_REFERENCE' WHEN s.item_id<0 THEN 'INVALID_SOURCE_REFERENCE' WHEN s.style_class_id IS DISTINCT FROM 1 THEN 'NON_ACCOUNT_CLASS' WHEN a.legacy_id IS NULL THEN 'MISSING_ACCOUNT' WHEN coalesce(nullif(a.status,''),'使用')<>'使用' THEN 'ACCOUNT_DISABLED' ELSE 'BOUND' END"
    style_payload="""jsonb_build_object('code',tree.current_code,'name',s.name,'category',"""+category+""",'parent_id',tree.target_parent_legacy,'level',tree.depth,'sort_order',coalesce(nullif(regexp_replace(coalesce(s.next_number,''),'[^0-9]','','g'),'')::int,0),
 'path',tree.current_path,'is_departmental',coalesce(s.dept_status,false),'is_receipt',coalesce(s.orient_status1,false),'is_payment',coalesce(s.orient_status2,false),
 'linked_account_legacy_id',CASE WHEN """+live+""" THEN a.legacy_id END,'linked_account_id',CASE WHEN """+live+""" THEN a.legacy_id END,
 'init_balance',s.init_total,'status','使用','auto_created',false,'is_deleted',false,'deleted_at',NULL,'legacy_source_code',s.code,'legacy_source_item_id',s.item_id)"""
    account_payload="""jsonb_build_object('code','ZH'||lpad(row_number() OVER(ORDER BY a.legacy_id)::text,6,'0'),'name',a.name,'bank_account_no',nullif(a.bank_account_no,''),'account_type',"""+_account_type_sql()+""",
 'currency_id',(SELECT legacy_id FROM source_currency WHERE legacy_id=CASE WHEN a.name LIKE '%香%' THEN 3 ELSE 1 END AND status='使用'),
 'style_id',(SELECT legacy_id FROM source_style WHERE legacy_id=nullif(a.style_legacy_id,0)),
 'init_balance',coalesce(a.init_balance,0),'receipts_total',coalesce(a.receipts_total,0),'payments_total',coalesce(a.payments_total,0),'balance_current',coalesce(a.balance_current,0),
 'parent_legacy_id',nullif(a.parent_legacy_id,0),'style_legacy_id',nullif(a.style_legacy_id,0),'status',coalesce(nullif(a.status,''),'使用'),
 'is_deleted',false,'auto_created',false,'deleted_at',NULL,'balance_adjustments_total',0,'balance_floor',NULL)"""
    return """CREATE TEMP TABLE source_style_tree AS WITH RECURSIVE ranked AS (
 SELECT s.*,'SK'||lpad(row_number() OVER(ORDER BY legacy_id)::text,6,'0') current_code FROM source_style s
), tree AS (
 SELECT r.legacy_id,r.current_code,NULL::int target_parent_legacy,0 depth,'/'||r.current_code||'/' current_path
 FROM ranked r WHERE coalesce(parent_legacy,0)=0 OR NOT EXISTS(SELECT 1 FROM ranked p WHERE p.legacy_id=r.parent_legacy)
 UNION ALL SELECT c.legacy_id,c.current_code,p.legacy_id,p.depth+1,p.current_path||c.current_code||'/'
 FROM ranked c JOIN tree p ON c.parent_legacy=p.legacy_id
) SELECT * FROM tree;
CREATE TEMP TABLE source_account_ancestry AS WITH RECURSIVE ancestry AS (
 SELECT a.legacy_id account_legacy_id,s.*,ARRAY[s.legacy_id] visited,false cycle FROM source_account a
 LEFT JOIN source_style s ON s.legacy_id=nullif(a.style_legacy_id,0) WHERE nullif(a.style_legacy_id,0) IS NOT NULL
 UNION ALL SELECT w.account_legacy_id,s.*,w.visited||s.legacy_id,s.legacy_id=ANY(w.visited)
 FROM ancestry w LEFT JOIN source_style s ON s.legacy_id=w.parent_legacy
 WHERE w.legacy_id IS NOT NULL AND NOT w.cycle AND coalesce(w.parent_legacy,0)<>0
) SELECT * FROM ancestry;
CREATE TEMP TABLE independently_expected_styles AS
SELECT s.legacy_id,to_jsonb(s) typed_source,"""+style_payload+" payload,"+reason+" reference_reason FROM source_style s JOIN source_style_tree tree USING(legacy_id) LEFT JOIN source_account a ON a.legacy_id=s.item_id;\n"+"CREATE TEMP TABLE independently_expected_accounts AS SELECT a.legacy_id,to_jsonb(a) typed_source,"+account_payload+" payload FROM source_account a;"

def typed_source_facts(source,baseline=None):
    verify_local_docker() # Before reading payload or starting the owned helper.
    directory=Path(source['_input_directory']);name='uten-finance-master-source-'+uuid.uuid4().hex[:12]
    owned=name;created=False
    def command(args,data=None,timeout=120):
        try:return subprocess.run(args,input=data,capture_output=True,timeout=timeout)
        except (OSError,subprocess.SubprocessError):raise ValueError('Owned finance master source PostgreSQL is unavailable') from None
    def check(ok):_require(ok,'Owned finance master source verification failed; raw values withheld')
    try:
        result=command(['docker','run','-d','--name',name,'--network','none','-e','POSTGRES_HOST_AUTH_METHOD=trust','postgres:16-alpine']);check(result.returncode==0);created=True
        for _ in range(80):
            if command(['docker','exec',name,'pg_isready','-U','postgres']).returncode==0:break
            time.sleep(.15)
        else:check(False)
        result=command(['docker','inspect',name]);check(result.returncode==0);meta=json.loads(result.stdout)[0]
        check(meta['Name']=='/'+name and re.fullmatch('[0-9a-f]{64}',meta['Id']) is not None and meta['HostConfig']['NetworkMode']=='none' and not meta['HostConfig']['PortBindings']);owned=meta['Id']
        sql=['CREATE EXTENSION pgcrypto;',f'CREATE TEMP TABLE source_style({STYLE_DDL});',f'CREATE TEMP TABLE source_account({ACCOUNT_DDL});',f'CREATE TEMP TABLE source_currency({CURRENCY_DDL});',
            """CREATE FUNCTION private_snapshot(row_data jsonb,fields text[]) RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
 SELECT coalesce(jsonb_object_agg(key,CASE WHEN jsonb_typeof(value)='number' THEN to_jsonb(trim_scale((value#>>'{}')::numeric)) ELSE value END),'{}'::jsonb)
 FROM jsonb_each(row_data) WHERE key=ANY(fields) $$;"""]
        for filename,table in ((STYLE_FILE,'source_style'),(ACCOUNT_FILE,'source_account'),(CURRENCY_FILE,'source_currency')):
            data=(directory/filename).read_bytes();check(hashlib.sha256(data).hexdigest()==source['files'][filename]['sha256'])
            check(command(['docker','exec','-i',owned,'sh','-c','cat > /tmp/'+filename],data).returncode==0)
            sql.append("\\copy "+table+" FROM '/tmp/"+filename+"' WITH(FORMAT csv,DELIMITER '|',HEADER true)")
        sql.extend([_expected_sql(),"SELECT jsonb_build_object('style_rows',(SELECT count(*) FROM independently_expected_styles),'account_rows',(SELECT count(*) FROM independently_expected_accounts),",
            "'typed_style_rows_sha256',(SELECT "+_hash("legacy_id::text||'|'||encode(digest(typed_source::text,'sha256'),'hex')",'legacy_id')+" FROM independently_expected_styles),",
            "'typed_account_rows_sha256',(SELECT "+_hash("legacy_id::text||'|'||encode(digest(typed_source::text,'sha256'),'hex')",'legacy_id')+" FROM independently_expected_accounts),",
            "'style_business_sha256',(SELECT "+_hash("legacy_id::text||'|'||encode(digest("+_snapshot('payload',STYLE_FIELDS)+"::text,'sha256'),'hex')",'legacy_id')+" FROM independently_expected_styles),",
            "'account_business_sha256',(SELECT "+_hash("legacy_id::text||'|'||encode(digest("+_snapshot('payload',ACCOUNT_FIELDS)+"::text,'sha256'),'hex')",'legacy_id')+" FROM independently_expected_accounts),",
            "'reason_counts',(SELECT jsonb_object_agg(reference_reason,n) FROM(SELECT reference_reason,count(*) n FROM independently_expected_styles GROUP BY reference_reason) x),",
            "'reference_rows_sha256',(SELECT "+_hash("legacy_id::text||'|'||reference_reason",'legacy_id')+" FROM independently_expected_styles),",
            "'source_roots',(SELECT coalesce(jsonb_agg(jsonb_build_object('legacy_id',s.legacy_id,'raw_code',s.code,'category',CASE s.style_class_id WHEN 1 THEN 'ACCOUNT' WHEN 2 THEN 'LIABILITY' WHEN 3 THEN 'EQUITY' WHEN 4 THEN 'EXPENSE' WHEN 5 THEN 'INCOME' ELSE 'METHOD' END) ORDER BY s.legacy_id),'[]') FROM source_style s WHERE coalesce(s.parent_legacy,0)=0),",
            "'role_candidates',(SELECT coalesce(jsonb_object_agg(role_key,legacy_id),'{}') FROM(SELECT policy.role_key,min(s.legacy_id) legacy_id FROM(VALUES('INVENTORY_ASSET','ACCOUNT','123'),('SALES_COST','EXPENSE','041'),('SALES_REVENUE','INCOME','031'))policy(role_key,category,raw_code) JOIN independently_expected_styles s ON s.payload->>'category'=policy.category AND btrim(s.typed_source->>'code')=policy.raw_code AND coalesce((s.typed_source->>'parent_legacy')::int,0)=0 GROUP BY policy.role_key HAVING count(*)=1)x));"])
        if baseline is not None:
            data=Path(baseline['path']).read_bytes();check(hashlib.sha256(data).hexdigest()==baseline['sha256'])
            check(command(['docker','exec','-i',owned,'sh','-c','cat > /tmp/seed-baseline.json'],data).returncode==0)
            sql.extend(["CREATE TEMP TABLE source_seed_baseline AS SELECT pg_read_file('/tmp/seed-baseline.json')::jsonb data;",
                "CREATE TEMP TABLE expected_role_candidates AS SELECT policy.role_key,policy.category,min(s.legacy_id) legacy_id FROM(VALUES('INVENTORY_ASSET','ACCOUNT','123'),('SALES_COST','EXPENSE','041'),('SALES_REVENUE','INCOME','031'))policy(role_key,category,raw_code) JOIN independently_expected_styles s ON s.payload->>'category'=policy.category AND btrim(s.typed_source->>'code')=policy.raw_code AND coalesce((s.typed_source->>'parent_legacy')::int,0)=0 GROUP BY policy.role_key,policy.category HAVING count(*)=1;",
                "SELECT jsonb_build_object('seed_business_sha256',(SELECT "+_hash("(value->>'id')||'|'||encode(digest("+_snapshot("value||jsonb_build_object('legacy_source_code',NULL,'legacy_source_item_id',NULL,'legacy_source_import_run_id',NULL)",SEED_STYLE_FIELDS)+"::text,'sha256'),'hex')","value->>'id'")+" FROM source_seed_baseline CROSS JOIN LATERAL jsonb_array_elements(data->'payment_styles')),"])
            role_payload="role.value||jsonb_build_object('style_id',CASE WHEN role.value->>'style_id' IS NULL THEN to_jsonb(candidate.legacy_id) ELSE role.value->'style_id' END)"
            sql.append("'seed_roles_before_sha256',(SELECT "+_hash("(value->>'role_key')||'|'||encode(digest("+_snapshot('value',ROLE_FIELDS)+"::text,'sha256'),'hex')","value->>'role_key'")+" FROM source_seed_baseline CROSS JOIN LATERAL jsonb_array_elements(data->'posting_roles')),")
            sql.append("'role_business_sha256',(SELECT "+_hash("(role.value->>'role_key')||'|'||encode(digest("+_snapshot(role_payload,ROLE_FIELDS)+"::text,'sha256'),'hex')","role.value->>'role_key'")+" FROM source_seed_baseline CROSS JOIN LATERAL jsonb_array_elements(data->'posting_roles') role(value) LEFT JOIN expected_role_candidates candidate ON candidate.role_key=role.value->>'role_key' AND candidate.category=role.value->>'required_category' AND role.value->>'style_id' IS NULL));")
        result=command(['docker','exec','-i',owned,'psql','-X','-qAt','-U','postgres','-v','ON_ERROR_STOP=1'],('\n'.join(sql)+'\n').encode());check(result.returncode==0)
        lines=result.stdout.decode().strip().splitlines();check(len(lines)==(2 if baseline is not None else 1));facts=json.loads(lines[0])
        if baseline is not None:facts.update(json.loads(lines[1]))
        check(facts['style_rows']==source['style_rows'] and facts['account_rows']==source['account_rows'])
        check(all(re.fullmatch('[0-9a-f]{64}',value) for key,value in facts.items() if key.endswith('_sha256')))
        return facts
    finally:
        if created:check(command(['docker','rm','-f','-v',owned]).returncode==0)

ZERO_INVARIANTS=('wrong_source_run','wrong_run_status','invalid_current_uuid_reference','wrong_evidence_metadata',
 'invalid_style_entry_hashes','invalid_account_entry_hashes','unknown_seed_rows',
 'source_target_style_identity_mismatch','source_target_account_identity_mismatch',
 'invalid_new_role_binding','wrong_master_code_reservations')

def acceptance_sql(run_id,source,baseline):
    run_id=str(uuid.UUID(run_id));typed=source['typed_source_facts']
    _require(digest(baseline['path'])==baseline['sha256'],'Finance seed anchor changed during verification')
    # Encode the actual captured bytes: no SQL quoting ambiguity, float
    # roundtrip, executable interpolation, or re-serialized seed amount.
    seed_hex=Path(baseline['path']).read_bytes().hex()
    candidates=json.dumps(typed['role_candidates'],sort_keys=True,separators=(',',':')).encode().hex()
    expected_context=''
    if source.get('_manifest_sha256') is not None:
        _require(re.fullmatch('[0-9a-f]{64}',source['_manifest_sha256']) is not None,'Finance source manifest identity is invalid')
        expected_context+=" OR r.export_manifest_sha256::text IS DISTINCT FROM '"+source['_manifest_sha256']+"' OR r.checksum_manifest_sha256::text IS DISTINCT FROM '"+source['_manifest_sha256']+"'"
    if source.get('_frozen_commit') is not None:
        _require(re.fullmatch('[0-9a-f]{40}|[0-9a-f]{64}',source['_frozen_commit']) is not None,'Finance source frozen identity is invalid')
        expected_context+=" OR r.migration_repository_commit IS DISTINCT FROM '"+source['_frozen_commit']+"'"
    current_style="to_jsonb(s)||jsonb_build_object('parent_id',parent.legacy_id,'linked_account_id',account.legacy_id)"
    current_account="to_jsonb(a)||jsonb_build_object('currency_id',currency.legacy_id,'style_id',style.legacy_id)"
    role_payload="to_jsonb(role)||jsonb_build_object('style_id',CASE WHEN original.value->>'style_id' IS NULL THEN to_jsonb(style.legacy_id) ELSE to_jsonb(role.style_id) END)"
    def snapshot(payload,fields):return 'public.fn_legacy_finance_snapshot('+payload+','+_array(fields)+')'
    style_hash=_hash("legacy_id::text||'|'||encode(digest("+snapshot('payload',STYLE_FIELDS)+"::text,'sha256'),'hex')",'legacy_id')
    account_hash=_hash("legacy_id::text||'|'||encode(digest("+snapshot('payload',ACCOUNT_FIELDS)+"::text,'sha256'),'hex')",'legacy_id')
    seed_hash=_hash("s.id::text||'|'||encode(digest("+snapshot('to_jsonb(s)',SEED_STYLE_FIELDS)+"::text,'sha256'),'hex')",'s.id')
    role_hash=_hash("role.role_key||'|'||encode(digest("+snapshot(role_payload,ROLE_FIELDS)+"::text,'sha256'),'hex')",'role.role_key')
    return f"""WITH expected_seed AS MATERIALIZED (
 SELECT convert_from(decode('{seed_hex}','hex'),'UTF8')::jsonb data,
        convert_from(decode('{candidates}','hex'),'UTF8')::jsonb role_candidates
), seed_styles AS MATERIALIZED (
 SELECT value FROM expected_seed CROSS JOIN LATERAL jsonb_array_elements(data->'payment_styles')
), seed_roles AS MATERIALIZED (
 SELECT value FROM expected_seed CROSS JOIN LATERAL jsonb_array_elements(data->'posting_roles')
), run_source AS MATERIALIZED (
 SELECT r.*,r.reconciliation_summary->'financeMasterSources' evidence
 FROM public.legacy_migration_runs r WHERE run_id='{run_id}'::uuid
), style_entries AS MATERIALIZED (
 SELECT key,value FROM run_source CROSS JOIN LATERAL jsonb_each(coalesce(evidence->'styles','{{}}'::jsonb))
), account_entries AS MATERIALIZED (
 SELECT key,value FROM run_source CROSS JOIN LATERAL jsonb_each(coalesce(evidence->'accounts','{{}}'::jsonb))
), current_styles AS MATERIALIZED (
 SELECT s.legacy_id,s.id,s.legacy_source_import_run_id,{current_style} payload,
   ((s.parent_id IS NOT NULL AND (parent.id IS NULL OR parent.legacy_id IS NULL))
    OR (s.linked_account_id IS NOT NULL AND (account.id IS NULL OR account.legacy_id IS NULL))) bad_reference
 FROM public.payment_styles s LEFT JOIN public.payment_styles parent ON parent.id=s.parent_id
 LEFT JOIN public.accounts account ON account.id=s.linked_account_id WHERE s.legacy_id IS NOT NULL
), current_accounts AS MATERIALIZED (
 SELECT a.legacy_id,a.id,{current_account} payload,
   ((a.style_id IS NOT NULL AND (style.id IS NULL OR style.legacy_id IS NULL))
    OR (a.currency_id IS NOT NULL AND (currency.id IS NULL OR currency.legacy_id IS NULL OR currency.status IS DISTINCT FROM '使用' OR currency.is_deleted))) bad_reference
 FROM public.accounts a LEFT JOIN public.payment_styles style ON style.id=a.style_id
 LEFT JOIN public.currencies currency ON currency.id=a.currency_id
)
SELECT jsonb_build_object(
 'run_rows',(SELECT count(*) FROM run_source),
 'actual_system_identifier',(SELECT system_identifier::text FROM pg_control_system()),
 'actual_database_oid',(SELECT oid::bigint FROM pg_database WHERE datname=current_database()),
 'recorded_import_database',(SELECT reconciliation_summary->>'targetDatabase' FROM run_source),
 'wrong_run_status',(SELECT count(*) FROM run_source WHERE status IS DISTINCT FROM 'SUCCESS' OR reconciliation_status IS DISTINCT FROM 'PASSED'
   OR CASE WHEN mapping_version ~ '^bootstrap-v[1-9][0-9]*$' THEN substring(mapping_version FROM 12)::numeric<18 ELSE true END),
 'style_rows',(SELECT count(*) FROM current_styles),'account_rows',(SELECT count(*) FROM current_accounts),
 'total_style_rows',(SELECT count(*) FROM public.payment_styles),
 'seed_style_rows',(SELECT count(*) FROM public.payment_styles s JOIN seed_styles original ON s.id::text=original.value->>'id'),
 'role_rows',(SELECT count(*) FROM public.system_posting_style_roles),
 'style_business_columns',(SELECT jsonb_agg(column_name ORDER BY column_name) FROM information_schema.columns WHERE table_schema='public' AND table_name='payment_styles' AND column_name NOT IN('created_at','updated_at','created_by','updated_by')),
 'account_business_columns',(SELECT jsonb_agg(column_name ORDER BY column_name) FROM information_schema.columns WHERE table_schema='public' AND table_name='accounts' AND column_name NOT IN('created_at','updated_at','created_by','updated_by')),
 'wrong_source_run',(SELECT count(*) FROM current_styles WHERE legacy_source_import_run_id IS DISTINCT FROM '{run_id}'::uuid),
 'invalid_current_uuid_reference',(SELECT count(*) FROM current_styles WHERE bad_reference)+(SELECT count(*) FROM current_accounts WHERE bad_reference),
 'unknown_seed_rows',(SELECT count(*) FROM public.payment_styles s WHERE s.legacy_id IS NULL AND NOT EXISTS(SELECT 1 FROM seed_styles original WHERE original.value->>'id'=s.id::text)),
 'wrong_evidence_metadata',(SELECT count(*) FROM run_source r WHERE evidence IS NULL OR evidence->>'format' IS DISTINCT FROM 'finance-master-sources-v1'
   OR evidence->>'run_id' IS DISTINCT FROM r.run_id::text OR evidence->>'manifest_sha256' IS DISTINCT FROM r.export_manifest_sha256::text
   OR evidence->>'frozen_commit' IS DISTINCT FROM r.migration_repository_commit OR evidence->>'seed_baseline_sha256' IS DISTINCT FROM '{baseline['sha256']}'
   OR evidence->>'seed_baseline_sha256' IS DISTINCT FROM r.reconciliation_summary->>'financeSeedBaselineSha256'
   OR evidence->>'style_file_sha256' IS DISTINCT FROM '{source['files'][STYLE_FILE]['sha256']}'
   OR evidence->>'account_file_sha256' IS DISTINCT FROM '{source['files'][ACCOUNT_FILE]['sha256']}'
   OR evidence->>'style_file_sha256' IS DISTINCT FROM (SELECT sha256::text FROM public.legacy_migration_run_files WHERE run_id=r.run_id AND file_name='m_style.csv')
   OR evidence->>'account_file_sha256' IS DISTINCT FROM (SELECT sha256::text FROM public.legacy_migration_run_files WHERE run_id=r.run_id AND file_name='m_acc.csv')
   OR evidence->>'style_source_count' IS DISTINCT FROM '{source['style_rows']}'
   OR evidence->>'account_source_count' IS DISTINCT FROM '{source['account_rows']}' {expected_context}),
 'invalid_style_entry_hashes',(SELECT count(*) FROM style_entries WHERE value->>'source_row_sha256' IS DISTINCT FROM encode(digest((value->'typed_source')::text,'sha256'),'hex') OR value->'typed_source'->>'legacy_id' IS DISTINCT FROM key),
 'invalid_account_entry_hashes',(SELECT count(*) FROM account_entries WHERE value->>'source_row_sha256' IS DISTINCT FROM encode(digest((value->'typed_source')::text,'sha256'),'hex') OR value->'typed_source'->>'legacy_id' IS DISTINCT FROM key),
 'source_target_style_identity_mismatch',(SELECT count(*) FROM style_entries e FULL JOIN current_styles s ON s.legacy_id::text=e.key WHERE s.id IS NULL OR e.key IS NULL OR e.value->>'target_id' IS DISTINCT FROM s.id::text OR e.value->>'target_code' IS DISTINCT FROM s.payload->>'code'),
 'source_target_account_identity_mismatch',(SELECT count(*) FROM account_entries e FULL JOIN current_accounts a ON a.legacy_id::text=e.key WHERE a.id IS NULL OR e.key IS NULL OR e.value->>'target_id' IS DISTINCT FROM a.id::text OR e.value->>'target_code' IS DISTINCT FROM a.payload->>'code'),
 'invalid_new_role_binding',(SELECT count(*) FROM public.system_posting_style_roles role JOIN seed_roles original ON role.role_key=original.value->>'role_key'
  LEFT JOIN public.payment_styles style ON style.id=role.style_id CROSS JOIN expected_seed
  WHERE original.value->>'style_id' IS NULL AND role.style_id IS NOT NULL AND
   (style.legacy_id::text IS DISTINCT FROM expected_seed.role_candidates->>role.role_key
    OR style.legacy_source_import_run_id IS DISTINCT FROM '{run_id}'::uuid OR style.category IS DISTINCT FROM role.required_category)),
 'wrong_master_code_reservations',(SELECT count(*) FROM(
   SELECT 'PAYMENT_STYLE' domain,id,payload->>'code' code FROM current_styles UNION ALL SELECT 'ACCOUNT',id,payload->>'code' FROM current_accounts) master
   WHERE NOT EXISTS(SELECT 1 FROM public.master_code_reservation_members member WHERE member.master_domain=master.domain AND member.normalized_code=upper(btrim(master.code)) AND member.entity_id=master.id)
      OR NOT EXISTS(SELECT 1 FROM public.business_identifier_reservation_members member WHERE member.normalized_identifier=upper(btrim(master.code)) AND member.owner_domain=master.domain AND member.entity_id=master.id))
)||jsonb_build_object(
 'style_business_sha256',(SELECT {style_hash} FROM current_styles),
 'account_business_sha256',(SELECT {account_hash} FROM current_accounts),
 'typed_style_rows_sha256',(SELECT {_hash("key||'|'||encode(digest((value->'typed_source')::text,'sha256'),'hex')",'key::integer')} FROM style_entries),
 'typed_account_rows_sha256',(SELECT {_hash("key||'|'||encode(digest((value->'typed_source')::text,'sha256'),'hex')",'key::integer')} FROM account_entries),
 'reference_rows_sha256',(SELECT {_hash("key||'|'||(value->>'reference_reason')",'key::integer')} FROM style_entries),
 'reason_counts',(SELECT jsonb_object_agg(reason,n) FROM(SELECT value->>'reference_reason' reason,count(*) n FROM style_entries GROUP BY value->>'reference_reason')x),
 'seed_business_sha256',(SELECT {seed_hash} FROM public.payment_styles s JOIN seed_styles original ON s.id::text=original.value->>'id'),
 'role_business_sha256',(SELECT {role_hash} FROM public.system_posting_style_roles role JOIN seed_roles original ON role.role_key=original.value->>'role_key' LEFT JOIN public.payment_styles style ON style.id=role.style_id),
 'seed_before_rows',(SELECT jsonb_array_length(evidence->'seed_before') FROM run_source),
 'seed_before_styles_sha256',(SELECT {_hash("(value->>'identity')||'|'||encode(digest("+snapshot("value->'payload'",SEED_STYLE_FIELDS)+"::text,'sha256'),'hex')","value->>'identity'")} FROM run_source CROSS JOIN LATERAL jsonb_array_elements(evidence->'seed_before') WHERE value->>'source_kind'='PAYMENT_STYLE'),
 'seed_roles_before_sha256',(SELECT {_hash("(value->>'identity')||'|'||encode(digest("+snapshot("value->'payload'",ROLE_FIELDS)+"::text,'sha256'),'hex')","value->>'identity'")} FROM run_source CROSS JOIN LATERAL jsonb_array_elements(evidence->'seed_before') WHERE value->>'source_kind'='POSTING_ROLE'),
 'target_uuid_binding_sha256',(SELECT {_hash("source_kind||'|'||legacy_id::text||'|'||id::text",'source_kind,legacy_id')} FROM(SELECT 'M_STYLE' source_kind,legacy_id,id FROM current_styles UNION ALL SELECT 'M_ACC',legacy_id,id FROM current_accounts)x),
 'source_roots',(SELECT coalesce(jsonb_agg(jsonb_build_object('legacy_id',s.legacy_id,'raw_code',s.legacy_source_code,'category',s.category,
   'identity_verified',public.fn_legacy_payment_style_source_root_matches(s.id,s.category,btrim(s.legacy_source_code))) ORDER BY s.legacy_id),'[]')
  FROM public.payment_styles s WHERE s.legacy_source_import_run_id='{run_id}'::uuid AND s.parent_id IS NULL),
 'master_code_sequences',(SELECT jsonb_object_agg(prefix,last_seq) FROM public.master_code_sequences WHERE prefix IN('SK','ZH'))
)"""

def validate(actual,source,baseline,*,require=_require):
    require(isinstance(actual,dict) and isinstance(source,dict),'Finance master acceptance or source inventory is absent')
    typed=source.get('typed_source_facts');require(isinstance(typed,dict),'Complete independently typed finance master source facts are absent')
    require(type(typed.get('style_rows')) is int and typed['style_rows']==source['style_rows']
            and type(typed.get('account_rows')) is int and typed['account_rows']==source['account_rows'],'Finance master typed source count differs')
    require(type(actual.get('run_rows')) is int and actual['run_rows']==1,'Finance master exact run identity is absent')
    for key in ZERO_INVARIANTS:require(type(actual.get(key)) is int and actual[key]==0,'Finance master invariant failed: '+key)
    seed=baseline['data'];expected_counts={'style_rows':source['style_rows'],'account_rows':source['account_rows'],
       'seed_style_rows':len(seed['payment_styles']),'total_style_rows':source['style_rows']+len(seed['payment_styles']),
       'role_rows':len(seed['posting_roles']),'seed_before_rows':len(seed['payment_styles'])+len(seed['posting_roles'])}
    for key,value in expected_counts.items():require(type(actual.get(key)) is int and actual[key]==value,'Finance master coverage differs: '+key)
    require(actual.get('style_business_columns')==list(SEED_STYLE_FIELDS),'Finance classification business schema differs from the independent contract')
    require(actual.get('account_business_columns')==sorted((*ACCOUNT_FIELDS,'id','legacy_id')),'Finance account business schema differs from the independent contract')
    for key in ('style_business_sha256','account_business_sha256','typed_style_rows_sha256','typed_account_rows_sha256',
                'reference_rows_sha256','seed_business_sha256','role_business_sha256','seed_roles_before_sha256'):
        require(isinstance(typed.get(key),str) and re.fullmatch('[0-9a-f]{64}',typed[key]) is not None
                and actual.get(key)==typed[key],'Finance master independent typed projection differs: '+key)
    require(actual.get('seed_before_styles_sha256')==typed['seed_business_sha256'],'Finance original system-master snapshot differs from the actual fresh seed anchor')
    require(actual.get('reason_counts')==typed.get('reason_counts'),'Finance source review reasons differ from independently recomputed source')
    counts=typed['reason_counts']
    require(isinstance(counts,dict) and all(type(value) is int and value>=0 for value in counts.values())
            and sum(counts.values())==source['style_rows'],'Finance source reason partition is incomplete')
    origin={'system_identifier':actual.get('actual_system_identifier'),'database_oid':actual.get('actual_database_oid')}
    require(origin==baseline['database_identity'] and actual.get('recorded_import_database')==seed['database'],
            'Finance master seed anchor belongs to a different cluster, physical database or recorded rename origin')
    require(isinstance(actual.get('target_uuid_binding_sha256'),str) and re.fullmatch('[0-9a-f]{64}',actual['target_uuid_binding_sha256']) is not None,'Finance master actual UUID continuity hash is absent')
    sequence=actual.get('master_code_sequences')
    require(isinstance(sequence,dict) and all(type(sequence.get(prefix)) is int and sequence[prefix]>=source[key]
            for prefix,key in (('SK','style_rows'),('ZH','account_rows'))),'Finance master next-number metadata is below the imported source inventory')
    roots=actual.get('source_roots');require(isinstance(roots,list),'Finance source-root identity inventory is absent')
    projected=[{key:row.get(key) for key in ('legacy_id','raw_code','category')} for row in roots]
    require(projected==typed.get('source_roots'),'Finance actual source-root identities differ from the complete typed source')
    coverage=[];unmapped=[]
    for code,category in sorted(REPORT_ROOT_POLICY.items()):
        matches=[row for row in roots if row.get('category')==category and (row.get('raw_code') or '').strip()==code]
        require(len(matches)<=1,'Finance fixed report semantic has ambiguous source roots')
        require(all(row.get('identity_verified') is True for row in matches),'Finance report root has no complete successful source identity proof')
        coverage.append({'raw_code':code,'category':category,'source_root_count':len(matches)})
    for row in projected:
        if REPORT_ROOT_POLICY.get((row.get('raw_code') or '').strip())!=row.get('category'):unmapped.append(row)
    pending=sum(value for reason,value in counts.items() if reason not in ('BOUND','NO_SOURCE_REFERENCE'))
    return {'verified':True,'seed_baseline_sha256':baseline['sha256'],
        'source_style_rows':source['style_rows'],'source_account_rows':source['account_rows'],
        'current_link_rows':counts.get('BOUND',0),'pending_rows':pending,'no_reference_rows':counts.get('NO_SOURCE_REFERENCE',0),
        'pending_reason_counts':{key:value for key,value in counts.items() if key not in ('BOUND','NO_SOURCE_REFERENCE')},
        'complete_typed_source_rows_verified':True,'exact_legacy_identity_and_uuid_relations_verified':True,
        'original_account_status_and_amounts_preserved':True,'canonical_display_codes_verified':True,
        'system_seed_and_configured_roles_preserved':True,'system_seed_rows':len(seed['payment_styles']),
        'configured_role_rows_preserved':sum(row['style_id'] is not None for row in seed['posting_roles']),
        'source_style_rows_sha256':typed['typed_style_rows_sha256'],'source_account_rows_sha256':typed['typed_account_rows_sha256'],
        'style_business_sha256':typed['style_business_sha256'],'account_business_sha256':typed['account_business_sha256'],
        'seed_business_sha256':typed['seed_business_sha256'],'role_business_sha256':typed['role_business_sha256'],
        'target_uuid_binding_sha256':actual['target_uuid_binding_sha256'],'origin_database_identity':origin,
        'report_root_coverage':coverage,'source_root_rows':len(roots),'unmapped_report_roots':unmapped,
        'unmapped_root_handling':'Preserve original category and explicit UUID report bindings; do not guess a fixed report group',
        'target_writes_performed':False,'historical_source_reference_is_current_approval':False}

def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--inputs',type=Path,required=True);parser.add_argument('--manifest-sha256',required=True)
    parser.add_argument('--frozen-commit',required=True);parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--finance-seed-baseline',type=Path,required=True)
    parser.add_argument('--finance-seed-baseline-sha256',required=True)
    parser.add_argument('--typed-source-only',action='store_true')
    args=parser.parse_args(argv)
    try:
        _require(not args.output.exists(),'Refusing to overwrite previous finance source evidence')
        directory=args.inputs.resolve();manifest_file=directory/'derived_inputs.json'
        _require(digest(manifest_file)==args.manifest_sha256,'Finance source manifest SHA differs')
        manifest=json.loads(manifest_file.read_text(encoding='utf-8-sig'))
        _require(manifest.get('formatVersion')==4 and manifest.get('target')=='All'
                 and manifest.get('provenance',{}).get('inputKind')=='derived-local-rehearsal-v1'
                 and manifest['provenance'].get('importerRepositoryCommit')==args.frozen_commit,'Finance complete source manifest/provenance differs')
        baseline=sealed_seed_baseline(directory,manifest['provenance'],args.finance_seed_baseline,args.finance_seed_baseline_sha256)
        records={row['file']:row for row in manifest['files']};_require(len(records)==len(manifest['files']),'Finance source manifest file is duplicated')
        source=source_inventory(directory,records);_require(source is not None,'Complete finance master source files are absent')
        report={'status':'SOURCE_INVENTORY_VERIFIED_TARGET_NOT_QUERIED','manifest_sha256':args.manifest_sha256,'frozen_commit':args.frozen_commit,
                'seed_baseline_sha256':baseline['sha256'],'source_style_rows':source['style_rows'],'source_account_rows':source['account_rows'],
                'target_database_queried':False,'docker_used':False,'secrets_or_application_configuration_read':False}
        if args.typed_source_only:
            report.update(status='SOURCE_TYPED_FACTS_VERIFIED_TARGET_NOT_QUERIED',docker_used=True,typed_source_facts=typed_source_facts(source,baseline))
        with args.output.open('x',encoding='utf-8') as stream:json.dump(report,stream,indent=2);stream.write('\n')
        print(json.dumps({key:report[key] for key in ('status','source_style_rows','source_account_rows','target_database_queried')}));return 0
    except (OSError,ValueError,KeyError,TypeError,csv.Error):
        print(json.dumps({'status':'FAILED','reason':'Finance master source verification failed; raw values withheld'}));return 1

if __name__=='__main__':raise SystemExit(main())

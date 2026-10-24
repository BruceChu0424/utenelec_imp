"""Real full-schema PostgreSQL adversarial cases; synthetic source rows only.

No candidate/original connection, no host ports, no disabled production guard.
Only test labels, SQLSTATE, constraint/function names, counts and hashes leave PG.
"""
from pathlib import Path
import argparse,csv,hashlib,json,re,subprocess,sys,time,uuid

HERE=Path(__file__).resolve().parent
REPOSITORY_DEFAULT=HERE.parents[3]


def local_docker_guard(repository):
    # Resolve the repository's common local-only guard explicitly; importing this
    # harness or asking for --help never loads source payloads or starts Docker.
    import importlib.util
    path=repository/'server/legacy_migration/verify_stock_typed_source_hashes.py'
    spec=importlib.util.spec_from_file_location('_production_test_local_guard',path)
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    module.verify_local_docker()

TABLE='legacy_production_plan_counter_import_sources'
REGISTER='fn_register_legacy_production_plan_counter_source'
COUNTERS=('oqty','qty','lqty','iqty','fqty','rqty','bqty','tqty','paqty','isrqty','cpqty','poqty','piqty')


def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()


def insert_block(script,table):
    start=script.index('INSERT INTO '+table+' (');i=start;state=None;depth=0
    while i<len(script):
        if state=='line':
            if script[i]=='\n':state=None
        elif state=='block':
            if script.startswith('/*',i):depth+=1;i+=1
            elif script.startswith('*/',i):
                depth-=1;i+=1
                if not depth:state=None
        elif state in ("'",'"'):
            if script[i]==state:
                if i+1<len(script) and script[i+1]==state:i+=1
                else:state=None
        elif state is not None:
            if script.startswith(state,i):i+=len(state)-1;state=None
        elif script.startswith('--',i):state='line';i+=1
        elif script.startswith('/*',i):state='block';depth=1;i+=1
        elif script[i] in ("'",'"'):state=script[i]
        elif script[i]=='$':
            tag=re.match(r'\$(?:[A-Za-z_][A-Za-z0-9_]*)?\$',script[i:])
            if tag:state=tag[0];i+=len(state)-1
        elif script[i]==';':return script[start:i+1]
        i+=1
    raise ValueError('Frozen original INSERT statement terminator absent')


def business_insert(script):
    """Read current loader business SQL independently of source projection code.

    Remove only the known V913 UUID/run prefix and source-proof join. Refuse an
    unfamiliar wrapper instead of quietly changing the native business mapping.
    This supports both pre-V913 diagnostics and the integrated current loader.
    """
    block=insert_block(script,'production_plan_items')
    columns=block[:block.index('SELECT')]
    if 'legacy_production_import_run_id' not in columns:return block
    replacements=(
      (r'(INSERT INTO production_plan_items\s*\()\s*id\s*,\s*legacy_production_import_run_id\s*,',r'\1'),
      (r'\bSELECT\s+COALESCE\(source_proof\.target_id,\s*gen_random_uuid\(\)\),\s*source_proof\.run_id,\s*','SELECT '),
      (r'\s+LEFT JOIN production_counter_source_stage source_proof ON source_proof\.legacy_id\s*=\s*s\.legacy_id\s*;',';'))
    for pattern,replacement in replacements:
        block,count=re.subn(pattern,replacement,block,count=1)
        if count!=1:raise ValueError('Current production source-proof wrapper changed; review the harness extractor')
    if 'source_proof.' in block or 'legacy_production_import_run_id' in block:
        raise ValueError('Unreviewed production source-proof wrapper remains')
    return block


class OwnedPg:
    def __init__(self,args):
        self.args=args;self.name='uten-production-protocol-'+uuid.uuid4().hex[:10];self.created=False;self.database='postgres'
    def command(self,args,data=None,timeout=60):
        return subprocess.run(args,input=data,capture_output=True,timeout=timeout)
    def execute(self,sql,timeout=90):
        r=self.command(['docker','exec','-i',self.name,'psql','-X','-q','-At','-U','postgres','-d',self.database,
            '-v','ON_ERROR_STOP=1','-v','VERBOSITY=verbose','-v','SHOW_CONTEXT=always'],sql.encode(),timeout)
        return {'ok':r.returncode==0,'stdout':r.stdout,'stderr':r.stderr,
            'sqlstates':sorted(set(x.decode() for x in re.findall(rb'ERROR:\s+([0-9A-Z]{5})',r.stderr))),
            'functions':sorted(set(x.decode() for x in re.findall(rb'function (fn_[a-z0-9_]+)\(',r.stderr))),
            'constraints':sorted(set(x.decode() for x in re.findall(rb'CONSTRAINT NAME:\s*([a-z0-9_]+)',r.stderr)))}
    def checked(self,sql,timeout=90):
        r=self.execute(sql,timeout)
        if not r['ok']:raise RuntimeError(json.dumps({k:r[k] for k in ('sqlstates','functions','constraints')}))
        return r
    def __enter__(self):
        local_docker_guard(self.args.repository_root)
        r=self.command(['docker','run','-d','--name',self.name,'--network','none','-e','POSTGRES_HOST_AUTH_METHOD=trust','postgres:16-alpine'])
        assert r.returncode==0;self.created=True
        for _ in range(75):
            # Only the final server listens on TCP; the initialization server is socket-only.
            if self.command(['docker','exec',self.name,'pg_isready','-h','127.0.0.1','-U','postgres']).returncode==0:break
            time.sleep(.15)
        else:raise RuntimeError('Owned PostgreSQL did not become ready')
        meta=json.loads(self.command(['docker','inspect',self.name]).stdout)[0]
        assert meta['HostConfig']['NetworkMode']=='none' and not meta['HostConfig'].get('PortBindings')
        self.checked("CREATE ROLE uten LOGIN NOSUPERUSER; CREATE ROLE uten_migrator LOGIN NOSUPERUSER;CREATE DATABASE baseline912;")
        self.database='baseline912'
        self.checked('BEGIN;\n'+self.args.schema.read_text(encoding='utf-8')+'\nCOMMIT;',timeout=300)
        self.checked("SET search_path=public;SET app.legacy_import='on';SET app.business_identifier_legacy_import='on';"+self.reference_seeds())
        self.load_candidate(self.args.candidate_sql)
        return self
    def load_candidate(self,path):
        self.database='postgres'
        self.checked('DROP DATABASE IF EXISTS candidate913 WITH(FORCE);CREATE DATABASE candidate913 TEMPLATE baseline912;')
        self.database='candidate913'
        self.checked('SET search_path=public;'+path.read_text(encoding='utf-8'),timeout=60)
        self.checked("""GRANT SELECT,INSERT,UPDATE,DELETE ON ALL TABLES IN SCHEMA public TO uten_migrator;
GRANT USAGE,SELECT ON ALL SEQUENCES IN SCHEMA public TO uten_migrator;
REVOKE UPDATE,DELETE,TRUNCATE ON legacy_production_plan_counter_import_sources FROM uten_migrator;
DO $$ BEGIN IF to_regclass('public.legacy_production_plan_counter_import_contexts') IS NOT NULL THEN
 REVOKE UPDATE,DELETE,TRUNCATE ON legacy_production_plan_counter_import_contexts FROM uten_migrator;END IF;END $$;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO uten;
GRANT INSERT,UPDATE,DELETE ON production_plan_items TO uten;
""")
    def reference_seeds(self):
        pieces=[]
        for filename,tables in [
            ('V279__global_business_identifier_registry.sql',('business_identifier_namespaces',)),
            ('V272__uncategorized_master_categories.sql',('client_categories','mould_categories','supplier_categories')),
            ('V275__production_daily_report_source_uuid_guards.sql',('material_categories','system_master_category_registry'))]:
            s=self.args.reference_seed_sql[filename]
            for table in tables:pieces.append(insert_block(s,table))
        return '\n'.join(pieces)
    def __exit__(self,*exc):
        if self.created:
            assert re.fullmatch('uten-production-protocol-[0-9a-f]{10}',self.name)
            assert self.command(['docker','rm','-f',self.name]).returncode==0
            self.created=False


def context_sql(run):
    return f"""SET LOCAL search_path=public;SET LOCAL app.legacy_import='on';
SET LOCAL app.business_identifier_legacy_import='on';SET LOCAL uten.legacy_reference_import='on';
INSERT INTO legacy_migration_runs(run_id,target,status,migration_mode,mapping_version,migration_repository_commit,
export_manifest_sha256,checksum_manifest_sha256,migration_script_sha256,source_backup_sha256,export_approval_reference,reconciliation_summary)
VALUES('{run}','--bootstrap-all','RUNNING','BOOTSTRAP','bootstrap-v17',repeat('a',40),repeat('b',64),repeat('b',64),repeat('d',64),repeat('e',64),
'synthetic-reviewed-source',jsonb_build_object('importAtomicity','single-transaction-v1','targetDatabase',current_database(),
'targetApprovalReference','synthetic-reviewed-target','sourceSnapshotAsOfUtc','2025-01-31T15:59:59Z',
'targetSystemIdentifier',(SELECT system_identifier::text FROM pg_control_system())));
INSERT INTO legacy_migration_run_files(run_id,file_name,sha256,byte_size) VALUES
('{run}','production_plan_items.csv',repeat('f',64),500),('{run}','production_plans.csv',repeat('e',64),400);
SELECT set_config('uten.bootstrap_run_id','{run}',true);
SET LOCAL uten.bootstrap_mapping_version='bootstrap-v17';SET LOCAL uten.bootstrap_repository_commit='{40*'a'}';
SET LOCAL uten.bootstrap_manifest_sha='{64*'b'}';
SELECT pg_advisory_xact_lock(hashtextextended('uten:legacy-bootstrap:'||current_database(),0));
"""


def fixture_sql(identity):
    zeros=','.join(COUNTERS)
    values=','.join('10' if c=='qty' else '20' if c=='fqty' else '30' if c=='iqty' else '0' for c in COUNTERS)
    return f"""
INSERT INTO units(legacy_id,code,name) VALUES(900301,'LEGACY-UNIT-900301','SYNTHETIC ONLY') ON CONFLICT(legacy_id) DO NOTHING;
INSERT INTO colors(legacy_id,code,name) VALUES(900401,'LEGACY-COLOR-900401','SYNTHETIC ONLY') ON CONFLICT(legacy_id) DO NOTHING;
INSERT INTO goods(legacy_id,code,name,unit_id,code_managed,code_sequence)
SELECT g,'LEGACY-G-'||g,'SYNTHETIC ONLY',u.id,false,g FROM(VALUES(900101),(900102))x(g)
CROSS JOIN units u WHERE u.legacy_id=900301 ON CONFLICT(legacy_id) DO NOTHING;
CREATE TEMP TABLE plan_stage OF public.legacy_production_plan_counter_parent_row;
INSERT INTO plan_stage(legacy_id,bill_no,bill_date,status,fulfill_bit,stop_bit,cancel_bit)
VALUES(990001,'SJ202501020001','2025-01-02',1,false,false,false);
CREATE TEMP TABLE item_stage OF public.legacy_production_plan_counter_source_row;
INSERT INTO item_stage(legacy_id,plan_legacy_id,product_no,goods_legacy_id,color_legacy_id,mgoods_legacy_id,unit_legacy_id,unit_rate,s_order_item_legacy,{zeros})
VALUES({identity},990001,'SYN-PROD-{identity}',900101,900401,900102,900301,1,0,{values});
INSERT INTO production_plans(legacy_id,bill_no,bill_date,status,is_closed,is_stopped,is_canceled)
SELECT legacy_id,bill_no,bill_date,status,false,false,false FROM plan_stage ON CONFLICT(legacy_id) DO NOTHING;
CREATE TEMP TABLE fixture_proof(target_id uuid);
"""


def register_sql(run,source='to_jsonb(s)',parent='to_jsonb(h)',line='1'):
    return f"INSERT INTO fixture_proof SELECT {REGISTER}('{run}'::uuid,{source},{parent},{line}) FROM item_stage s CROSS JOIN plan_stage h;"


def original_insert(script,run,changes=None,proof=True):
    s=business_insert(script)
    if proof:
        s=s.replace('INSERT INTO production_plan_items (','INSERT INTO production_plan_items (id,legacy_production_import_run_id,',1)
        s=s.replace('SELECT s.legacy_id,','SELECT (SELECT target_id FROM fixture_proof),\''+run+"'::uuid,s.legacy_id,",1)
    for old,new in (changes or {}).items():
        assert old in s;s=s.replace(old,new)
    return s


def expect_denied(statement,states=('23514',)):
    quoted='$operation$'+statement+'$operation$'
    expected='ARRAY['+','.join("'"+s+"'" for s in states)+']'
    return f"""DO $denied$ DECLARE actual text; BEGIN
 BEGIN EXECUTE {quoted}; EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS actual=RETURNED_SQLSTATE; END;
 IF actual IS NULL THEN RAISE EXCEPTION 'operation unexpectedly accepted' USING ERRCODE='ZX001'; END IF;
 IF NOT(actual=ANY({expected})) THEN RAISE EXCEPTION 'unexpected rejection SQLSTATE %',actual USING ERRCODE='ZX002'; END IF;
END $denied$;"""


def assert_sql(expression):
    return "DO $assert$ BEGIN IF ("+expression+") IS DISTINCT FROM true THEN RAISE EXCEPTION 'synthetic invariant failed' USING ERRCODE='ZX003'; END IF;END $assert$;"


def run_suite(pg,args):
    script=args.loader.read_text(encoding='utf-8')
    results=[]
    def case(label,body,commit=False,prepare=True):
        run=str(uuid.uuid4());identity=980000+len(results)+1
        raw='BEGIN;'+context_sql(run)+(fixture_sql(identity) if prepare else '')+body(run,identity)+('\nCOMMIT;' if commit else '\nROLLBACK;')
        started=time.monotonic();r=pg.execute(raw)
        fact={'name':label,'status':'PASS' if r['ok'] else 'FAIL','milliseconds':round((time.monotonic()-started)*1000),
              **{k:r[k] for k in ('sqlstates','constraints','functions') if r[k]}}
        results.append(fact);print(json.dumps(fact),flush=True)
        (args.output/'cases.json').write_text(json.dumps(results,indent=2)+'\n',encoding='utf-8')
        return r
    pos=lambda run:register_sql(run)+original_insert(script,run)
    case('exact_original_overage_first_insert_and_deferred',lambda run,i:pos(run)+"SET CONSTRAINTS ALL IMMEDIATE;"+
         assert_sql('(SELECT count(*)=1 AND min(qty)=10 AND min(fqty)=20 AND min(iqty)=30 FROM production_plan_items)')+
         assert_sql('(SELECT count(*)=0 FROM production_daily_reports) AND (SELECT count(*)=0 FROM stock_movements) AND (SELECT count(*)=0 FROM ar_ap_ledger)'))
    case('without_proof_legacy_flags_do_not_allow_overage',lambda run,i:expect_denied(original_insert(script,run,proof=False)))
    case('orphan_registered_proof_cannot_finish',lambda run,i:register_sql(run)+expect_denied('SET CONSTRAINTS ALL IMMEDIATE'))
    case('same_tx_success_passed_and_finished_at_before_deferred',lambda run,i:pos(run)+f"UPDATE legacy_migration_runs SET status='SUCCESS',reconciliation_status='PASSED',finished_at=now(),exit_code=0 WHERE run_id='{run}';SET CONSTRAINTS ALL IMMEDIATE;")
    for status in ('FAILED','CANCELLED'):
        case('terminal_'+status.lower()+'_rejected',lambda run,i,status=status:pos(run)+expect_denied(f"UPDATE legacy_migration_runs SET status='{status}' WHERE run_id='{run}';SET CONSTRAINTS ALL IMMEDIATE"))
    case('success_without_passed_reconciliation_rejected',lambda run,i:pos(run)+f"UPDATE legacy_migration_runs SET status='SUCCESS' WHERE run_id='{run}';"+expect_denied('SET CONSTRAINTS ALL IMMEDIATE'))
    for field in ('qty','fqty','iqty'):
        case('source_negative_'+field+'_rejected',lambda run,i,field=field:expect_denied(register_sql(run,"jsonb_set(to_jsonb(s),'{"+field+"}','-1')")))
        for special in ('NaN','Infinity','-Infinity'):
            case('source_nonfinite_'+field+'_'+special,lambda run,i,field=field,special=special:
                 expect_denied("UPDATE item_stage SET "+field+"='"+special+"'::numeric;"+register_sql(run),('23514','22003')))
    for source in ("to_jsonb(s)-'qty'","to_jsonb(s)||jsonb_build_object('unknown_field',1)","jsonb_set(to_jsonb(s),'{qty}','\"10\"')"):
        case('incomplete_extra_or_untyped_item_'+str(len(results)),lambda run,i,source=source:expect_denied(register_sql(run,source)))
    for parent in ("to_jsonb(h)-'status'","to_jsonb(h)||jsonb_build_object('maker_name','SYNTHETIC ONLY')", "jsonb_set(to_jsonb(h),'{bill_no}','\"WRONG\"')"):
        case('incomplete_extra_or_wrong_parent_'+str(len(results)),lambda run,i,parent=parent:expect_denied(register_sql(run,parent=parent)))
    for field in ('goods_legacy_id','color_legacy_id','mgoods_legacy_id','unit_legacy_id'):
        case('unresolved_positive_master_'+field,lambda run,i,field=field:expect_denied(register_sql(run,"jsonb_set(to_jsonb(s),'{"+field+"}','999999')")))
    case('line_number_zero_rejected',lambda run,i:expect_denied(register_sql(run,line='0')))
    case('target_uuid_changed_rejected',lambda run,i:register_sql(run)+expect_denied(original_insert(script,run).replace('(SELECT target_id FROM fixture_proof)','gen_random_uuid()',1)))
    for old,new in [('COALESCE(s.qty,0),','COALESCE(s.qty,0)+1,'),('COALESCE(s.fqty,0),','COALESCE(s.fqty,0)+1,'),('COALESCE(s.iqty,0),','COALESCE(s.iqty,0)+1,'),('COALESCE(s.unit_rate, 1),','2,'),('s.product_no,',"'WRONG-PRODUCT',")]:
        case('target_original_projection_changed_'+str(len(results)),lambda run,i,old=old,new=new:register_sql(run)+expect_denied(original_insert(script,run,{old:new})))
    for field,value in [('qty','11'),('fqty','21'),('iqty','31'),('unit_rate','2'),('line_no','2'),('remark',"'SYNTHETIC CHANGED'")]:
        case('initial_bound_update_'+field,lambda run,i,field=field,value=value:pos(run)+expect_denied('UPDATE production_plan_items SET '+field+'='+value))
        case('initial_after_early_constraints_update_'+field,lambda run,i,field=field,value=value:pos(run)+'SET CONSTRAINTS ALL IMMEDIATE;'+expect_denied('UPDATE production_plan_items SET '+field+'='+value))
    for field,value in [('fqty','19'),('iqty','29')]:
        case('initial_corrective_decrease_still_changes_bound_source_'+field,lambda run,i,field=field,value=value:
             pos(run)+'SET CONSTRAINTS ALL IMMEDIATE;'+expect_denied('UPDATE production_plan_items SET '+field+'='+value))
        case('initial_guc_clear_cannot_hide_source_freeze_'+field,lambda run,i,field=field,value=value:
             pos(run)+"SELECT set_config('uten.bootstrap_run_id','',true);"+expect_denied('UPDATE production_plan_items SET '+field+'='+value))
    case('other_signed_cache_no_new_sign_policy',lambda run,i:"UPDATE item_stage SET lqty=-1,rqty=-2;"+pos(run)+'SET CONSTRAINTS ALL IMMEDIATE;'+
         assert_sql('(SELECT min(lqty)=-1 AND min(rqty)=-2 FROM production_plan_items)'))
    case('initial_delete_rejected',lambda run,i:pos(run)+expect_denied('DELETE FROM production_plan_items',('55000',)))
    for field in ('legacy_production_import_run_id','id','legacy_id'):
        value='NULL' if field=='legacy_production_import_run_id' else 'gen_random_uuid()' if field=='id' else 'legacy_id+1'
        case('provenance_rebinding_'+field,lambda run,i,field=field,value=value:pos(run)+expect_denied('UPDATE production_plan_items SET '+field+'='+value))
    case('evidence_update_immutable',lambda run,i:register_sql(run)+expect_denied('UPDATE '+TABLE+' SET target_fields=array_remove(target_fields,\'qty\')',('55000',)))
    case('evidence_delete_immutable',lambda run,i:register_sql(run)+expect_denied('DELETE FROM '+TABLE,('55000',)))
    for file in ('production_plan_items.csv','production_plans.csv'):
        case('file_sha_changed_'+file,lambda run,i,file=file:register_sql(run)+expect_denied(f"UPDATE legacy_migration_run_files SET sha256=repeat('0',64) WHERE run_id='{run}' AND file_name='{file}';"+original_insert(script,run)))
        case('file_bytes_changed_after_early_flush_'+file,lambda run,i,file=file:pos(run)+'SET CONSTRAINTS ALL IMMEDIATE;'+
             expect_denied(f"UPDATE legacy_migration_run_files SET byte_size=byte_size+1 WHERE run_id='{run}' AND file_name='{file}'"))
    for setting,value in [('uten.bootstrap_run_id',str(uuid.uuid4())),('uten.bootstrap_mapping_version','bootstrap-v18'),('uten.bootstrap_repository_commit','0'*40),('uten.bootstrap_manifest_sha','0'*64)]:
        case('bootstrap_setting_changed_'+setting,lambda run,i,setting=setting,value=value:register_sql(run)+f"SELECT set_config('{setting}','{value}',true);"+expect_denied(original_insert(script,run)))
    case('register_runtime_role_without_authority_denied',lambda run,i:"SET SESSION AUTHORIZATION uten;"+expect_denied(register_sql(run),('42501','23514')))
    for field,value in [('mapping_version',"'bootstrap-v18'"),('migration_mode',"'STANDARD'"),
        ('migration_repository_commit',"repeat('0',40)"),('export_manifest_sha256',"repeat('0',64)"),
        ('checksum_manifest_sha256',"repeat('0',64)"),('source_backup_sha256',"repeat('0',64)")]:
        case('admitted_run_identity_change_'+field,lambda run,i,field=field,value=value:
             pos(run)+expect_denied(f"UPDATE legacy_migration_runs SET {field}={value} WHERE run_id='{run}';SET CONSTRAINTS ALL IMMEDIATE"))
    for key,value in [('targetDatabase','WRONG_DATABASE'),('targetSystemIdentifier','WRONG_SYSTEM'),
                      ('importAtomicity','WRONG_ATOMICITY'),('targetApprovalReference','WRONG_APPROVAL')]:
        case('admitted_summary_identity_change_'+key,lambda run,i,key=key,value=value:
             pos(run)+expect_denied(f"UPDATE legacy_migration_runs SET reconciliation_summary=jsonb_set(reconciliation_summary,'{{{key}}}',to_jsonb('{value}'::text)) WHERE run_id='{run}';SET CONSTRAINTS ALL IMMEDIATE"))
    case('large_summary_and_terminal_lifecycle_do_not_invalidate_identity',lambda run,i:pos(run)+
         f"UPDATE legacy_migration_runs SET reconciliation_summary=reconciliation_summary||jsonb_build_object('synthetic_large_payload',repeat('x',2097152)),status='SUCCESS',reconciliation_status='PASSED',finished_at=now(),exit_code=0 WHERE run_id='{run}';SET CONSTRAINTS ALL IMMEDIATE;")
    case('small_context_immutable',lambda run,i:register_sql(run)+expect_denied('UPDATE legacy_production_plan_counter_import_contexts SET issued_txid=issued_txid+1',('55000',)))
    case('parent_descriptive_followup_not_frozen_as_identity',lambda run,i:pos(run)+
         "UPDATE production_plans SET worker_name='SYNTHETIC FOLLOWUP';SET CONSTRAINTS ALL IMMEDIATE;")
    case('parent_bill_date_identity_changed_rejected',lambda run,i:pos(run)+
         expect_denied("UPDATE production_plans SET bill_date=bill_date+1;SET CONSTRAINTS ALL IMMEDIATE"))
    case('master_old_identity_changed_before_terminal_rejected',lambda run,i:pos(run)+
         expect_denied("UPDATE goods SET legacy_id=legacy_id+10 WHERE legacy_id=900101;SET CONSTRAINTS ALL IMMEDIATE"))
    case('parent_identity_after_early_flush_rejected',lambda run,i:pos(run)+'SET CONSTRAINTS ALL IMMEDIATE;'+
         expect_denied('UPDATE production_plans SET bill_date=bill_date+1'))
    case('master_identity_after_early_flush_rejected',lambda run,i:pos(run)+'SET CONSTRAINTS ALL IMMEDIATE;'+
         expect_denied('UPDATE goods SET legacy_id=legacy_id+10 WHERE legacy_id=900101'))
    case('native_first_insert_with_new_future_column_unchanged',lambda run,i:"ALTER TABLE production_plan_items ADD COLUMN synthetic_future_capacity numeric DEFAULT 0;UPDATE item_stage SET fqty=1,iqty=1;"+original_insert(script,run,proof=False)+'SET CONSTRAINTS ALL IMMEDIATE;')
    case('proof_first_insert_with_new_future_column_rejected',lambda run,i:"ALTER TABLE production_plan_items ADD COLUMN synthetic_future_capacity numeric DEFAULT 0;"+register_sql(run)+expect_denied(original_insert(script,run)))
    saved={}
    def admitted_commit(run,identity):
        saved.update(run=run,identity=identity)
        return pos(run)+f"UPDATE legacy_migration_runs SET status='SUCCESS',reconciliation_status='PASSED',finished_at=now(),exit_code=0 WHERE run_id='{run}';SET CONSTRAINTS ALL IMMEDIATE;"
    committed=case('committed_historical_baseline_for_future_controls',admitted_commit,commit=True)
    if committed['ok']:
        def plain_case(label,sql):
            started=time.monotonic();r=pg.execute(sql)
            results.append({'name':label,'status':'PASS' if r['ok'] else 'FAIL','milliseconds':round((time.monotonic()-started)*1000),
                **{k:r[k] for k in ('sqlstates','constraints','functions') if r[k]}})
            print(json.dumps(results[-1]),flush=True)
        native="BEGIN;SET LOCAL search_path=public;"
        identity=saved['identity'];where=f' WHERE legacy_id={identity}'
        plain_case('postcommit_corrective_decreases_use_original_rules',native+
            'UPDATE production_plan_items SET iqty=29'+where+';UPDATE production_plan_items SET fqty=19'+where+';SET CONSTRAINTS ALL IMMEDIATE;'+
            assert_sql(f'(SELECT iqty=29 AND fqty=19 AND qty=10 FROM production_plan_items WHERE legacy_id={identity})')+'ROLLBACK;')
        plain_case('postcommit_inbound_growth_still_rejected',native+expect_denied('UPDATE production_plan_items SET iqty=31'+where)+'ROLLBACK;')
        plain_case('postcommit_finished_growth_still_rejected',native+expect_denied('UPDATE production_plan_items SET fqty=21'+where+';SET CONSTRAINTS ALL IMMEDIATE')+'ROLLBACK;')
        plain_case('postcommit_negative_inbound_still_rejected',native+expect_denied('UPDATE production_plan_items SET iqty=-1'+where)+'ROLLBACK;')
        plain_case('postcommit_delete_cannot_replay_proof',native+expect_denied('DELETE FROM production_plan_items'+where,('55000',))+'ROLLBACK;')
        plain_case('postcommit_run_pointer_cannot_detach',native+expect_denied('UPDATE production_plan_items SET legacy_production_import_run_id=NULL'+where)+'ROLLBACK;')
        plain_case('proof_cannot_be_reused_in_later_transaction',native+context_sql(str(uuid.uuid4()))+
            expect_denied(f"SELECT fn_assert_legacy_production_plan_counter(to_jsonb(p),true) FROM production_plan_items p WHERE legacy_id={identity}")+'ROLLBACK;')
        plain_case('source_evidence_preserved_across_authorized_synthetic_reset',
            'BEGIN;TRUNCATE production_plan_items CASCADE;TRUNCATE business_identifier_reservation_members,business_identifier_reservations CASCADE;'+
            assert_sql('(SELECT count(*)=1 FROM '+TABLE+')')+'COMMIT;')
        old_identity=identity
        def reimport(run,identity):
            return (f"UPDATE item_stage SET legacy_id={old_identity},product_no='SYN-PROD-{old_identity}';"+pos(run)+
                'SET CONSTRAINTS ALL IMMEDIATE;'+assert_sql('(SELECT count(*)=2 FROM '+TABLE+')'))
        case('new_run_new_uuid_can_reimport_after_reset',reimport)
    return results


def nested_plans(raw):
    text=raw.decode('utf-8',errors='replace');decoder=json.JSONDecoder();plans=[]
    for position in (m.end() for m in re.finditer(r'plan:\s*',text)):
        try:obj,_=decoder.raw_decode(text[position:])
        except (ValueError,TypeError):continue
        plans.append(obj)
    nodes=[]
    def visit(value):
        if isinstance(value,dict):
            if 'Node Type' in value and value.get('Relation Name') in (
                TABLE,'legacy_production_plan_counter_import_contexts','production_plan_items','legacy_migration_runs'):
                nodes.append({k:value[k] for k in ('Node Type','Relation Name','Index Name','Plan Rows','Actual Rows','Actual Loops') if k in value})
            for child in value.values():visit(child)
        elif isinstance(value,list):
            for child in value:visit(child)
    for plan in plans:visit(plan)
    return nodes


def benchmark(pg,args):
    original=args.loader.read_text(encoding='utf-8')
    results=[]
    for count in (1000,5000):
        pg.checked('VACUUM(ANALYZE) production_plan_items;VACUUM(ANALYZE) '+TABLE+';')
        run=str(uuid.uuid4());sql='BEGIN;'+context_sql(run)+fixture_sql(1200000)
        sql+=f"""
CREATE TEMP TABLE original_template AS SELECT * FROM item_stage;
TRUNCATE item_stage;
INSERT INTO item_stage SELECT (jsonb_populate_record(NULL::legacy_production_plan_counter_source_row,
 to_jsonb(t)||jsonb_build_object('legacy_id',1200000+n,'product_no','SYN-BENCH-'||(1200000+n)))).*
 FROM original_template t CROSS JOIN generate_series(1,{count}) n;
CREATE TEMP TABLE bench_times(stage text,milliseconds numeric);
DO $register_bench$ DECLARE started timestamptz:=clock_timestamp(); BEGIN
 CREATE TEMP TABLE bench_proof AS SELECT s.legacy_id,{REGISTER}('{run}',to_jsonb(s),to_jsonb(h),s.legacy_id-1200000)target_id
 FROM item_stage s CROSS JOIN plan_stage h ORDER BY s.legacy_id;
 INSERT INTO bench_times VALUES('register',1000*extract(epoch FROM clock_timestamp()-started));
END $register_bench$;
CREATE UNIQUE INDEX bench_proof_legacy_id ON bench_proof(legacy_id);
ANALYZE bench_proof;ANALYZE legacy_production_plan_counter_import_sources;ANALYZE item_stage;
DO $insert_bench$ DECLARE started timestamptz:=clock_timestamp(); BEGIN
"""
        inserted=original_insert(original,run).replace('(SELECT target_id FROM fixture_proof)',
                  '(SELECT target_id FROM bench_proof bp WHERE bp.legacy_id=s.legacy_id)')
        sql+=inserted+"""
 INSERT INTO bench_times VALUES('insert',1000*extract(epoch FROM clock_timestamp()-started));
END $insert_bench$;
"""
        # The real coordinator appends a large summary and marks success before
        # COMMIT. Terminal row checks must not repeatedly detoast that payload.
        sql+=f"UPDATE legacy_migration_runs SET reconciliation_summary=reconciliation_summary||jsonb_build_object('synthetic_large_payload',repeat('x',2097152)),status='SUCCESS',reconciliation_status='PASSED',finished_at=now(),exit_code=0 WHERE run_id='{run}';"
        sql+="""DO $deferred_bench$ DECLARE started timestamptz:=clock_timestamp(); BEGIN
 SET CONSTRAINTS ALL IMMEDIATE;
 INSERT INTO bench_times VALUES('deferred',1000*extract(epoch FROM clock_timestamp()-started));
END $deferred_bench$;
LOAD 'auto_explain';SET LOCAL auto_explain.log_min_duration=0;
SET LOCAL auto_explain.log_nested_statements=on;SET LOCAL auto_explain.log_analyze=on;
SET LOCAL auto_explain.log_timing=off;SET LOCAL auto_explain.log_buffers=on;
SET LOCAL auto_explain.log_format='json';SET LOCAL auto_explain.log_level='notice';
DO $point$ BEGIN PERFORM fn_assert_legacy_production_plan_counter(to_jsonb(p),false)
 FROM production_plan_items p WHERE legacy_id=(SELECT max(legacy_id) FROM item_stage);END $point$;
SET LOCAL auto_explain.log_min_duration=-1;
"""
        sql+=f"""SELECT jsonb_build_object('rows',{count},'phases',(SELECT jsonb_object_agg(stage,milliseconds) FROM bench_times),
 'targets',(SELECT count(*) FROM production_plan_items WHERE legacy_id>1200000),
 'proofs',(SELECT count(*) FROM {TABLE} WHERE run_id='{run}'),
 'reports',(SELECT count(*) FROM production_daily_reports),'movements',(SELECT count(*) FROM stock_movements),
 'disabled_triggers',(SELECT count(*) FROM pg_trigger WHERE NOT tgisinternal AND tgenabled='D'));
ROLLBACK;"""
        started=time.monotonic();r=pg.execute(sql,timeout=300)
        row={'rows':count,'status':'FAIL','wall_seconds':round(time.monotonic()-started,3),
             **{k:r[k] for k in ('sqlstates','functions','constraints') if r[k]}}
        if r['ok']:
            facts=json.loads(next(line for line in reversed(r['stdout'].decode().splitlines()) if line.startswith('{')))
            plans=nested_plans(r['stderr']);row.update(facts=facts,nested_lookup_plans=plans)
            assert facts['targets']==count and facts['proofs']==count and facts['reports']==0 and facts['movements']==0 and facts['disabled_triggers']==0
            assert any(node['Relation Name']==TABLE and 'Index' in node['Node Type'] for node in plans),'No real nested proof index plan was captured'
            row['status']='PASS'
        (args.output/f'benchmark-{count}-nested.plans.log').write_bytes(r['stderr'])
        results.append(row);print(json.dumps({'benchmark':row}),flush=True)
        (args.output/'benchmarks.json').write_text(json.dumps(results,indent=2)+'\n',encoding='utf-8')
    return results


def main(argv=None):
    parser=argparse.ArgumentParser()
    parser.add_argument('--repository-root',type=Path,default=REPOSITORY_DEFAULT)
    parser.add_argument('--schema-baseline',dest='schema',type=Path,required=True,
        help='Explicit clean PostgreSQL 16 schema-only baseline immediately before V913; never exported by this harness')
    parser.add_argument('--migration-sql',dest='candidate_sql',type=Path,
        help='Optional unintegrated V913 candidate; default is the current repository migration')
    parser.add_argument('--output',type=Path,required=True,help='A new evidence directory; existing directories are refused')
    parser.add_argument('--benchmark',action='store_true',help='Also run 1k/5k normal guards with large summary and nested plans')
    args=parser.parse_args(argv);args.repository_root=args.repository_root.resolve()
    args.loader=args.repository_root/'server/legacy_migration/migrate_production.sql'
    args.candidate_sql=args.candidate_sql or args.repository_root/'server/src/main/resources/db/migration/V913__legacy_production_plan_counter_provenance.sql'
    args.skip_benchmark=not args.benchmark
    args.output.mkdir(parents=True)
    copied=args.output/'V913-tested.sql';copied.write_bytes(args.candidate_sql.read_bytes());args.candidate_sql=copied
    loader_copy=args.output/'tested-migrate-production.sql';loader_copy.write_bytes(args.loader.read_bytes());args.loader=loader_copy
    args.reference_seed_sql={}
    for name in ('V279__global_business_identifier_registry.sql','V272__uncategorized_master_categories.sql','V275__production_daily_report_source_uuid_guards.sql'):
        value=(args.repository_root/'server/src/main/resources/db/migration'/name).read_text(encoding='utf-8')
        args.reference_seed_sql[name]=value
        (args.output/name).write_text(value,encoding='utf-8')
    evidence={'synthetic_only':True,'candidate_or_original_connected':False,'network_mode':'none','host_ports':False,
       'schema_sha256':digest(args.schema),'candidate_sql_sha256':digest(copied),'container_removed':False,
       'loader_sha256':digest(args.loader),
       'reference_seed_sha256':{name:hashlib.sha256(value.encode()).hexdigest() for name,value in args.reference_seed_sql.items()},
       'schema_scope':'User-provided full schema-only pre-V913 baseline; not fresh Flyway or application/UAT evidence'}
    pg=OwnedPg(args)
    try:
        with pg:
            results=run_suite(pg,args)
            performance=[] if args.skip_benchmark else benchmark(pg,args)
        evidence.update(status='PASSED' if all(r['status']=='PASS' for r in results) else 'FAILED',cases=results,
            passed=sum(r['status']=='PASS' for r in results),failed=sum(r['status']!='PASS' for r in results),benchmarks=performance)
        if not all(r['status']=='PASS' for r in performance):evidence['status']='FAILED'
    finally:
        if pg.created:pg.__exit__()
        evidence['container_removed']=not pg.created
        (args.output/'receipt.json').write_text(json.dumps(evidence,indent=2)+'\n',encoding='utf-8')
    print(json.dumps({'status':evidence.get('status'),'passed':evidence.get('passed'),'failed':evidence.get('failed'),'receipt':str(args.output/'receipt.json'),'container_removed':evidence['container_removed']}))
    if evidence.get('status')!='PASSED':raise SystemExit(1)


if __name__=='__main__':main()

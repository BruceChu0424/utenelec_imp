"""Read-only, source-ID employee audit. Never changes import inputs or database rows.

ROOTS mirrors the reviewed legacy goods-owner mapping, not a universal ERP rule.
Revalidate that mapping against the next source and its frozen import scripts.
"""
from pathlib import Path
from collections import Counter, defaultdict
import argparse, csv, hashlib, json, re, subprocess, uuid

CURRENT = {'active', 'probation', 'onLeave'}
ROOTS = {2978:545,2953:513,3334:549,2891:545,2942:549,2969:513}
STOCK = {'transfer':'TRANSFER','other_in':'OTHER_IN','other_out':'OTHER_OUT','draw':'DRAW',
         'wdraw':'WDRAW','finished_in':'FINISHED_IN','finished_out':'FINISHED_OUT','check':'CHECK'}

def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()
def number(value, zero_null=True):
    if value is None or str(value).strip() == '': return None
    result = int(value)
    return None if zero_null and result == 0 else result
def digest(value): return hashlib.sha256((value or '').encode()).hexdigest()
def write_csv(path, rows, fields):
    with path.open('w',encoding='utf-8',newline='') as stream:
        writer=csv.DictWriter(stream,fields);writer.writeheader();writer.writerows(rows)
def dump(path,value): path.write_text(json.dumps(value,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')

def unique_by(records,key,label):
    result={}
    for row in records:
        identity=key(row)
        assert identity is not None and identity not in result,'Missing or duplicate identity in '+label
        result[identity]=row
    return result

def pin_inputs(args, manifest, manifest_sha):
    """Bind this audit to the final inputs, independently of any previous attempt."""
    expected_manifest=getattr(args,'manifest_sha256',None)
    expected_mapper=getattr(args,'sales_owner_mapper_sha256',None)
    admin_user_id=getattr(args,'admin_user_id',None)
    if getattr(args,'verify',False):
        assert expected_manifest and expected_mapper,'Database verification requires explicit final manifest and sales owner mapper SHA locks'
        assert admin_user_id,'Database verification requires the preserved administrator user UUID'
    if admin_user_id:admin_user_id=str(uuid.UUID(admin_user_id))
    if expected_manifest:
        assert manifest_sha==expected_manifest,'Explicit final manifest SHA mismatch'
    mapper=manifest['provenance']['scripts'].get('migrate_sales_owner.sql')
    if expected_mapper:
        assert mapper==expected_mapper,'Explicit final sales owner mapper SHA mismatch'
    frozen_commit=getattr(args,'frozen_commit',None)
    if frozen_commit:
        assert manifest['provenance'].get('importerRepositoryCommit')==frozen_commit,'Explicit final importer commit mismatch'
    return dict(run_id=str(uuid.UUID(args.run_id)),database=args.database,
        frozen_commit=frozen_commit,inputs=str(args.inputs.resolve()),
        derived_manifest_sha256=manifest_sha,sales_owner_mapper_sha256=mapper,
        custody_helper_sha256=manifest['provenance']['scripts'].get('migrate_owner_custody.sql'),
        admin_user_id=admin_user_id,
        generator=str(Path(__file__).resolve()),generator_sha256=sha(Path(__file__)))

def sales_owner_graph(read, resolve, admin):
    """Same source graph for offline preflight and post-commit UUID validation."""
    expected={};initial={};headers={};conflicts={};missing=Counter()
    for suffix in ('orders','shipments','other_shipments','returns'):
        table='sales_'+suffix
        for row in read(table+'.csv'):
            identity=number(row['legacy_id']);reference=row['seller_legacy'] or None
            key=(table,identity);headers[key]=row
            expected[key]=initial[key]=(*resolve(reference),reference)
    orderitems={number(row['legacy_id']):row for row in read('sales_order_items.csv')}
    shipitems={number(row['legacy_id']):row for row in read('sales_shipment_items.csv')}
    def reference(target, row, kind, upstream_table, item, parent):
        return dict(target_item_legacy_id=number(row['legacy_id']),upstream_kind=kind,
            upstream_document_table=upstream_table,upstream_document_legacy_id=parent,
            upstream_item_legacy_id=number(item['legacy_id']),
            source_seller_legacy_id=number(headers[(upstream_table,parent)]['seller_legacy'],False),
            resolved_owner_employee_id=expected[(upstream_table,parent)][0])
    def inherit(table,refs):
        for identity,relationships in refs.items():
            key=(table,identity);owners={r['resolved_owner_employee_id'] for r in relationships if r['resolved_owner_employee_id']}
            if not owners:continue
            old=initial[key]
            if len(owners)>1:
                expected[key]=(admin,old[1],'MIXED_UPSTREAM_OWNER_CUSTODY',old[3])
                conflicts[key]=dict(target_table=table,target_legacy_id=identity,
                    assigned_employee_id=admin,reason='MIXED_UPSTREAM_OWNER_CUSTODY',
                    resolved_owner_ids=sorted(owners),upstream_references=relationships)
            else:expected[key]=(next(iter(owners)),old[1],old[2],old[3])
    links=defaultdict(list)
    for row in shipitems.values():
        ref=number(row['order_item_legacy']);item=orderitems.get(ref)
        if ref is None:continue
        parent=number(item['bill_legacy']) if item else None
        if parent is None or ('sales_orders',parent) not in expected:missing['shipment_order_reference']+=1;continue
        links[number(row['bill_legacy'])].append(reference('sales_shipments',row,'ORDER_ITEM','sales_orders',item,parent))
    inherit('sales_shipments',links);links=defaultdict(list)
    for row in read('sales_return_items.csv'):
        for column,items,kind,table in [('out_item_legacy',shipitems,'SHIPMENT_ITEM','sales_shipments'),
                                        ('order_item_legacy',orderitems,'ORDER_ITEM','sales_orders')]:
            ref=number(row[column]);item=items.get(ref)
            if ref is None:continue
            parent=number(item['bill_legacy']) if item else None
            if parent is None or (table,parent) not in expected:missing['return_'+kind.lower()+'_reference']+=1;continue
            links[number(row['bill_legacy'])].append(reference('sales_returns',row,kind,table,item,parent))
    inherit('sales_returns',links)
    return expected,conflicts,dict(missing)

def rules():
    result=[]
    def add(file,table,source,legacy,actor,mode='LEGACY_ONLY',namespace='B_WORKER',zero_null=True,**extra):
        result.append(dict(file=file+'.csv',table=table,source=source,legacy=legacy,actor=actor,
                           mode=mode,namespace=namespace,zero_null=zero_null,**extra))
    def makers(file,table,zero_null=True,snapshots=True,**extra):
        for role in ('maker','approver'):
            add(file,table,role+'_legacy',role+'_legacy_id',role+'_id','NULL_UUID','SYS_OPERATOR',
                zero_null=zero_null,snapshot=role+'_name' if snapshots else None,**extra)
    for file,table,source,legacy,actor in [
        ('purchase_applications','purchase_requests','applicant_legacy','applicant_legacy_id','applicant_id'),
        ('purchase_orders','purchase_orders','purchaser_legacy','purchaser_legacy_id','purchaser_id'),
        ('purchase_receipts','purchase_receipts','sender_legacy','sender_legacy_id','sender_id'),
        ('purchase_receipts','purchase_receipts','receiver_legacy','receiver_legacy_id','receiver_id'),
        ('purchase_receipts','purchase_receipts','salesman_legacy','purchaser_legacy_id','purchaser_id')]:
        add(file,table,source,legacy,actor,'BOUND' if source=='salesman_legacy' else 'LEGACY_ONLY')
    for file,table in [('purchase_applications','purchase_requests'),('purchase_orders','purchase_orders'),
                       ('purchase_receipts','purchase_receipts'),('purchase_returns','purchase_returns')]: makers(file,table)
    for suffix in ('orders','shipments','other_shipments','returns'):
        file=table='sales_'+suffix
        add(file,table,'seller_legacy','seller_legacy_id','seller_id',zero_null=False)
        if 'shipments' in suffix: add(file,table,'sender_legacy','sender_legacy_id','sender_id',zero_null=False)
        makers(file,table,zero_null=False,snapshots=False)
    for file,table in [('m_get','finance_receipts'),('m_paid','finance_payments'),
                       ('m_dpaid','finance_expenses'),('m_oget','finance_other_incomes')]:
        add(file,table,'work_id','operator_legacy_id','operator_id','BOUND',snapshot='operator_name',
            snapshot_source='jsr' if file=='m_paid' else 'work_name')
        for role,source in [('maker','make_id'),('approver','approver_id')]:
            add(file,table,source,role+'_legacy_id',role+'_id','NULL_UUID','SYS_OPERATOR',
                snapshot=role+'_name',snapshot_source=role+'_name')
    for suffix,doc_type in STOCK.items():
        file='stock_'+suffix+'_m'
        add(file,'stock_documents','worker_legacy','worker_legacy_id','worker_id','BOUND',doc_type=doc_type)
        for role in ('maker','approver'):
            add(file,'stock_documents',role+'_legacy',role+'_legacy_id',role+'_id','NULL_UUID','SYS_OPERATOR',
                snapshot=role+'_name_snapshot',doc_type=doc_type)
    for file,table,source,legacy,actor in [
        ('subcontract_sout_m','subcontract_material_issues','worker_legacy','operator_legacy_id','worker_id'),
        ('subcontract_in_m','subcontract_receipts','sender_legacy','receiver_legacy_id','sender_id'),
        ('subcontract_swithdraw_m','subcontract_material_returns','worker_legacy','operator_legacy_id','worker_id')]:
        add(file,table,source,legacy,actor,snapshot='receiver_name' if file=='subcontract_in_m' else 'operator_name')
        makers(file,table)
    makers('subcontract_withdraw_m','subcontract_returns')
    makers('production_plans','production_plans',zero_null=False)
    for field in ('worker_name','seller_name','workshop_name'):
        add('production_plans','production_plans',field,None,None,'TEXT_ONLY','SOURCE_TEXT',snapshot=field,snapshot_source=field)
    for file,table,role,source in [
        ('subcontract_order_m','subcontract_orders','purchaser','send_legacy'),
        ('subcontract_swaste_m','subcontract_wastes','worker','worker_legacy')]:
        add(file,table,source,None,role+'_id','SOURCE_ONLY','SOURCE_UNCLASSIFIED')
        for actor in ('maker','approver'):add(file,table,actor+'_legacy',None,actor+'_id','SOURCE_ONLY','SYS_OPERATOR')
    return result

class Audit:
    def __init__(self,args):
        self.args=args;self.inputs={};self.cache={};self.issues=[];self.pending=[];self.details=[]
        self.manifest=json.loads((args.inputs/'derived_inputs.json').read_text(encoding='utf-8'))
        self.manifest_sha=sha(args.inputs/'derived_inputs.json')
        self.binding=pin_inputs(args,self.manifest,self.manifest_sha)
        self.inputs[str(args.inputs/'derived_inputs.json')]={'sha256':self.manifest_sha}
        hr_layers=[value for directory,value in self.manifest['provenance']['layers'].items() if Path(directory).resolve()==args.hr.resolve()]
        assert len(hr_layers)==1 and hr_layers[0]['hr_rehearsal_manifest.json']==sha(args.hr/'hr_rehearsal_manifest.json'),'HR parent manifest is not the sealed input layer'
        self.declared={entry['file']:entry for entry in self.manifest['files']}
        self.rules=rules();self.out=args.output;self.out.mkdir(parents=True,exist_ok=True)
        binding_path=self.out/'run_binding.json'
        if binding_path.exists():
            assert json.loads(binding_path.read_text(encoding='utf-8'))==self.binding,'Refusing to overwrite evidence bound to a different run, input or audit generator'
        else:dump(binding_path,self.binding)
    def read(self,name,hr=False):
        path=(self.args.hr if hr else self.args.inputs)/name
        if str(path) in self.cache: return self.cache[str(path)]
        actual=sha(path)
        if not hr and name in self.declared:
            assert actual==self.declared[name]['sha256'], 'Sealed CSV SHA mismatch: '+name
        elif not hr:
            assert self.manifest['provenance']['extraInputs'].get(name)==actual,'Unbound runtime input: '+name
        if hr:
            h=json.loads((self.args.hr/'hr_rehearsal_manifest.json').read_text(encoding='utf-8'))
            expected=h[name];expected=expected['sha256'] if isinstance(expected,dict) else expected
            assert actual==expected,'Sealed HR SHA mismatch: '+name
        self.inputs[str(path)]={'sha256':actual,'bytes':path.stat().st_size}
        with path.open(encoding='utf-8-sig',newline='') as stream: rows=list(csv.DictReader(stream,delimiter='|'))
        self.cache[str(path)]=rows
        return rows
    def issue(self,kind,**data): self.issues.append(dict(kind=kind,**data))
    def prepare(self):
        self.workers=unique_by(self.read('legacy_workers.csv'),lambda row:number(row['legacy_id']),'source workers')
        self.crosswalk=unique_by(self.read('hr_rehearsal_crosswalk.csv',True),lambda row:number(row['legacy_id']),'HR crosswalk')
        self.hr=unique_by(self.read('hr_rehearsal.csv',True),lambda row:row['emp_code'] or None,'HR employee codes')
        assert self.workers and set(self.workers)==set(self.crosswalk),'Source identity set differs from HR crosswalk'
        self.hr_by_legacy=unique_by((row for row in self.hr.values() if number(row['legacy_id']) is not None),lambda row:number(row['legacy_id']),'actual HR legacy bindings')
        assert set(self.hr_by_legacy)==set(self.workers),'Source identity set differs from actual HR legacy bindings'
        self.worker_count=len(self.workers)
        expected_count=getattr(self.args,'expected_worker_count',None)
        if expected_count is not None:assert self.worker_count==expected_count,'Reviewed source worker count mismatch'
        write_csv(self.out/'expected_worker_crosswalk.csv',[
            dict(worker_legacy_id=identity,employee_code=self.hr_by_legacy[identity]['emp_code'],
                 expected_status=self.hr_by_legacy[identity]['status'],canonical_person_alias=row['canonical_code'],method=row['method'])
            for identity,row in sorted(self.crosswalk.items())],
            ['worker_legacy_id','employee_code','expected_status','canonical_person_alias','method'])
        coverage=[];missing=Counter()
        for rule in self.rules:
            rows=self.read(rule['file']);references=[]
            if rule['namespace']=='B_WORKER':
                references=[number(row[rule['source']]) for row in rows]
                for ref in references:
                    if ref is not None and ref not in self.workers:missing[(rule['file'],rule['source'],ref)]+=1
            coverage.append({**rule,'source_rows':len(rows),'nonzero_worker_references':sum(v is not None for v in references),
                             'unknown_worker_rows':sum(v not in self.workers for v in references if v is not None)})
        # Source-only exported actors have no corresponding legacy/name target columns today.
        for file,fields in [('subcontract_order_m.csv',['send_legacy','maker_legacy','approver_legacy']),
                            ('subcontract_swaste_m.csv',['worker_legacy','maker_legacy','approver_legacy'])]:
            rows=self.read(file)
            for field in fields:
                coverage.append(dict(file=file,source=field,mode='SOURCE_ONLY_NO_TARGET_SNAPSHOT',source_rows=len(rows),
                                     nonzero_references=sum(number(row[field]) is not None for row in rows)))
        self.coverage=coverage
        dump(self.out/'prepared_coverage.json',{'databaseVerification':'NOT_RUN','run_id':self.args.run_id,
            'worker_identities':self.worker_count,'rules':coverage,'inputs':self.inputs,
            'source_only_fields_are_not_counted_as_structurally_migrated':True})
        write_csv(self.out/'unresolved_worker_references.csv',[
            dict(source_file=f,source_field=c,worker_legacy_id=i,source_rows=n) for (f,c,i),n in sorted(missing.items())],
            ['source_file','source_field','worker_legacy_id','source_rows'])
        return dict(worker_identities=self.worker_count,rules=len(self.rules),unknown_worker_reference_groups=len(missing),
                    unknown_worker_reference_rows=sum(missing.values()),databaseVerification='NOT_RUN')
    def sql(self,text):
        command=['docker','exec','-i',self.args.container,'psql','-X','-q','-A','-t','-v','ON_ERROR_STOP=1',
                 '-U',self.args.user,'-d',self.args.database]
        actual=subprocess.run(command,input=('BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;\n'
            "SET LOCAL statement_timeout='120s';\n"+text+'\nROLLBACK;\n').encode(),
            stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        if actual.returncode: raise RuntimeError(actual.stderr.decode(errors='replace'))
        return [json.loads(line) for line in actual.stdout.decode().splitlines() if line.strip()]
    def snapshot(self):
        run_id=str(uuid.UUID(self.args.run_id))
        gate=self.sql("SELECT jsonb_build_object('status',status,'reconciliation_status',reconciliation_status,'manifest_sha',export_manifest_sha256,"+
            "'summary',reconciliation_summary) FROM legacy_migration_runs WHERE run_id='"+run_id+"'::uuid;")
        assert len(gate)==1 and gate[0]['status']=='SUCCESS' and gate[0]['reconciliation_status']=='PASSED', \
            'Refusing employee verification before this exact run is committed SUCCESS/PASSED'
        self.run=gate[0]
        assert self.run['manifest_sha']==self.manifest_sha,'Run sealed input manifest SHA mismatch'
        assert self.run['summary'].get('targetDatabase')==self.args.database,'Run database lineage mismatch'
        assert self.run['summary'].get('rawManifestSha256')==self.manifest['provenance']['rawManifestSha256'],'Run raw source lineage mismatch'
        fields=defaultdict(set)
        for rule in self.rules:
            fields[rule['table']].update(x for x in (rule['legacy'],rule['actor']) if x)
            if rule.get('snapshot'):fields[rule['table']].add(rule['snapshot']+'__sha')
            if rule.get('doc_type'):fields[rule['table']].add('doc_type')
        for table in ('clients','suppliers','goods','sales_orders','sales_shipments','sales_other_shipments','sales_returns'):
            fields[table].add('owner_employee_id')
        for table in ('clients','suppliers'):fields[table].add('emp_id')
        fields['sales_order_items'].add('order_id')
        fields['sales_shipment_items'].update(('shipment_id','order_item_id'))
        fields['sales_return_items'].update(('return_id','out_item_id','order_item_id'))
        statements=["SELECT jsonb_build_object('table','employees','data',jsonb_build_object('id',id,'legacy_id',legacy_id,'code',code,'status',status,'is_deleted',is_deleted)) FROM employees;",
            "SELECT jsonb_build_object('table','admin','data',jsonb_build_object('employee_id',employee_id,'is_super_admin',is_super_admin,'status',status,'is_deleted',is_deleted)) FROM users WHERE id='"+self.binding['admin_user_id']+"'::uuid;",
            "SELECT jsonb_build_object('table','departments','data',jsonb_build_object('id',id,'code',code,'manager_id',manager_id)) FROM departments;",
            """SELECT jsonb_build_object('table','employee_fk_catalog','data',jsonb_build_object(
                'table',r.relname,'column',a.attname,'constraint',c.conname,
                'has_legacy_id',EXISTS(SELECT 1 FROM pg_attribute la WHERE la.attrelid=r.oid AND la.attname='legacy_id' AND NOT la.attisdropped)))
                FROM pg_constraint c JOIN pg_class r ON r.oid=c.conrelid JOIN pg_namespace n ON n.oid=r.relnamespace
                JOIN LATERAL unnest(c.conkey) ck(attnum) ON true JOIN pg_attribute a ON a.attrelid=r.oid AND a.attnum=ck.attnum
                WHERE c.contype='f' AND c.confrelid='public.employees'::regclass AND n.nspname='public';"""]
        for table,columns in sorted(fields.items()):
            pairs=["'id',id","'legacy_id',legacy_id"]
            for col in sorted(columns):
                if col.endswith('__sha'):
                    real=col[:-5];pairs.append("'"+col+"',encode(digest(COALESCE("+real+",''),'sha256'),'hex')")
                else:pairs.append("'"+col+"',"+col)
            statements.append("SELECT jsonb_build_object('table','"+table+"','data',jsonb_build_object("+
                              ','.join(pairs)+")) FROM "+table+" WHERE legacy_id IS NOT NULL;")
        records=self.sql('\n'.join(statements));self.target=defaultdict(list)
        for record in records:self.target[record['table']].append(record['data'])
        self.employees={row['id']:row for row in self.target['employees']}
        self.by_legacy=defaultdict(list)
        for row in self.target['employees']:
            if row['legacy_id'] is not None:self.by_legacy[row['legacy_id']].append(row)
        admins=self.target['admin'];assert len(admins)==1 and admins[0]['is_super_admin'] and admins[0]['status']=='active' and not admins[0]['is_deleted']
        self.admin=admins[0]['employee_id'];admin=self.employees[self.admin]
        assert admin['code']=='ADMIN' and admin['status']=='active' and not admin['is_deleted']
    def employee(self,old):
        matches=self.by_legacy.get(old,[])
        return matches[0] if len(matches)==1 else None
    def verify_crosswalk(self):
        rows=[]
        for old,expected in sorted(self.crosswalk.items()):
            matches=self.by_legacy.get(old,[])
            if len(matches)!=1:self.issue('WORKER_IDENTITY_NOT_UNIQUE',worker_legacy_id=old,matches=len(matches));continue
            actual=matches[0];hr=self.hr_by_legacy[old]
            if actual['code']!=hr['emp_code'] or actual['status']!=hr['status'] or actual['is_deleted']:
                self.issue('WORKER_CROSSWALK_MISMATCH',worker_legacy_id=old,employee_id=actual['id'])
            rows.append(dict(worker_legacy_id=old,employee_id=actual['id'],employee_code=actual['code'],status=actual['status'],
                             canonical_person_alias=expected['canonical_code'],canonical_method=expected['method']))
        extra=set(self.by_legacy)-set(self.workers)
        if extra:self.issue('UNEXPECTED_EMPLOYEE_LEGACY_IDS',worker_legacy_ids=sorted(extra))
        write_csv(self.out/'actual_employee_crosswalk.csv',rows,
                  ['worker_legacy_id','employee_id','employee_code','status','canonical_person_alias','canonical_method'])
    def verify_actors(self):
        self.operators={number(row['legacy_id']):row['name'] for row in self.read('legacy_operators_ref.csv')}
        drop={number(row['legacy_id']) for row in self.read('warehouse_crosswalk.csv') if row['action']=='DROP'}
        statistics=[]
        for rule in self.rules:
            actuals={row['legacy_id']:row for row in self.target[rule['table']]
                     if not rule.get('doc_type') or row['doc_type']==rule['doc_type']}
            stats=Counter()
            for source in self.read(rule['file']):
                old_id=number(source['legacy_id']);target=actuals.get(old_id)
                warehouse_fields=['stock_legacy_id','to_stock_legacy_id'] if rule.get('doc_type') else ['warehouse_legacy_id']
                excluded=(rule.get('doc_type') or rule['file']=='purchase_receipts.csv') and any(number(source.get(c)) in drop for c in warehouse_fields)
                if excluded:
                    stats['excluded_drop_warehouse']+=1
                    if target:self.issue('EXCLUDED_DOCUMENT_PRESENT',table=rule['table'],legacy_id=old_id)
                    continue
                if not target:self.issue('SOURCE_DOCUMENT_MISSING',table=rule['table'],legacy_id=old_id,doc_type=rule.get('doc_type'));continue
                stats['source_rows_checked']+=1
                if rule['mode']=='SOURCE_ONLY':
                    if target[rule['actor']] is not None:self.issue('SOURCE_ONLY_UNPROVEN_UUID',table=rule['table'],legacy_id=old_id,field=rule['actor'])
                    stats['source_only_not_structurally_migrated']+=number(source[rule['source']]) is not None
                    continue
                if rule['mode']=='TEXT_ONLY':
                    if target[rule['snapshot']+'__sha']!=digest(source[rule['source']]):
                        self.issue('SOURCE_TEXT_MISMATCH',table=rule['table'],legacy_id=old_id,field=rule['source'])
                    continue
                old=number(source[rule['source']],rule['zero_null'])
                common=dict(table=rule['table'],legacy_id=old_id,field=rule['actor'],worker_legacy_id=old,doc_type=rule.get('doc_type'))
                if target[rule['legacy']]!=old:self.issue('ACTOR_LEGACY_ID_MISMATCH',**common)
                employee=self.employee(number(source[rule['source']]))
                if rule['namespace']=='B_WORKER' and old not in (None,0) and employee is None:
                    self.pending.append(dict(**common,expected_employee_id=None,mode='UNRESOLVED_SOURCE_IDENTITY'))
                    stats['unresolved_source_identity']+=1
                expected=employee['id'] if employee and rule['namespace']=='B_WORKER' else None
                actual=target[rule['actor']]
                if rule['mode']=='BOUND' and actual!=expected:self.issue('ACTOR_UUID_MISMATCH',expected_employee_id=expected,actual_employee_id=actual,**common)
                if rule['mode']=='NULL_UUID' and actual is not None:self.issue('SYS_OPERATOR_BOUND_AS_EMPLOYEE',actual_employee_id=actual,**common)
                if rule['mode']=='LEGACY_ONLY':
                    if actual is not None and actual!=expected:self.issue('LEGACY_ACTOR_WRONG_UUID',expected_employee_id=expected,actual_employee_id=actual,**common)
                    if expected and actual is None:
                        stats['resolvable_history_uuid_not_materialized']+=1
                        self.pending.append(dict(**common,expected_employee_id=expected,mode='LEGACY_ONLY'))
                if rule.get('snapshot'):
                    if rule.get('snapshot_source'):value=source[rule['snapshot_source']]
                    elif rule['namespace']=='B_WORKER':value=self.workers.get(number(source[rule['source']]),{}).get('name','')
                    else:value=self.operators.get(number(source[rule['source']],False),'')
                    if target[rule['snapshot']+'__sha']!=digest(value):self.issue('OPERATOR_FROZEN_NAME_MISMATCH',**common)
            statistics.append({**rule,**stats})
        dump(self.out/'actor_binding_summary.json',statistics)
    def verify_other_employee_fks(self):
        managers={row['code']:row for row in self.target['departments']}
        by_code={row['code']:row for row in self.target['employees']}
        for row in self.read('hr_managers.csv',True):
            if managers.get(row['dept_code'],{}).get('manager_id')!=by_code.get(row['emp_code'],{}).get('id'):
                self.issue('HR_DEPARTMENT_MANAGER_MISMATCH',department_code=row['dept_code'],employee_code=row['emp_code'])
        covered={(rule['table'],rule['actor']) for rule in self.rules if rule['actor']}
        covered|={(table,'owner_employee_id') for table in ('clients','suppliers','goods','sales_orders','sales_shipments','sales_other_shipments','sales_returns')}
        inventory=[];queries=[]
        for fk in self.target['employee_fk_catalog']:
            classified='COVERED_SOURCE_RULE' if (fk['table'],fk['column']) in covered else 'NO_LEGACY_ENTITY_KEY' if not fk['has_legacy_id'] else 'CHECK_UNCOVERED_LEGACY_FK'
            inventory.append({**fk,'coverage':classified})
            if classified=='CHECK_UNCOVERED_LEGACY_FK':
                table,column=fk['table'],fk['column']
                assert re.fullmatch('[a-z_0-9]+',table) and re.fullmatch('[a-z_0-9]+',column)
                queries.append("SELECT jsonb_build_object('table','"+table+"','column','"+column+"','populated_legacy_rows',count(*)) FROM \""+table+"\" WHERE legacy_id IS NOT NULL AND \""+column+"\" IS NOT NULL;")
        for count in self.sql('\n'.join(queries)) if queries else []:
            if count['populated_legacy_rows']:self.issue('UNCOVERED_POPULATED_EMPLOYEE_FK',**count)
            inventory.append(count)
        dump(self.out/'employee_fk_inventory.json',inventory)
    def resolve_owner(self,reference):
        text=(reference or '').strip()
        if not text or re.fullmatch('0+',text):return None,None,'PUBLIC_SOURCE'
        old=int(text) if re.fullmatch(r'[0-9]{1,10}',text) and 0<int(text)<=2147483647 else None
        employee=self.employee(old)
        if employee and not employee['is_deleted'] and employee['status'] in CURRENT:
            return employee['id'],employee['id'],'CURRENT_EMPLOYEE'
        reason='UNRESOLVED_SOURCE_REFERENCE' if old is None else 'SOURCE_EMPLOYEE_MISSING' if not employee else 'SOURCE_EMPLOYEE_DELETED' if employee['is_deleted'] else 'SOURCE_EMPLOYEE_NOT_CURRENT'
        return self.admin,employee['id'] if employee else None,reason
    def verify_owners(self):
        expected={};initial={};self.custody=[]
        for file,table in [('client.csv','clients'),('supplier.csv','suppliers')]:
            actual={row['legacy_id']:row for row in self.target[table]}
            for source in self.read(file):
                key=(table,number(source['legacy_id']));reference=source['emp_id']
                expected[key]=initial[key]=(*self.resolve_owner(reference),reference)
                if (actual.get(key[1],{}).get('emp_id') or '')!=(reference or ''):self.issue('MASTER_HISTORICAL_EMP_REFERENCE_CHANGED',table=table,legacy_id=key[1])
        categories={number(row['legacy_id']):number(row['parent_legacy']) for row in self.read('goods_categories.csv')}
        for source in self.read('goods.csv'):
            cat=number(source['parent_legacy']);seen=set();roots=set()
            while cat and cat not in seen:
                seen.add(cat)
                if cat in ROOTS:roots.add(ROOTS[cat])
                cat=categories.get(cat)
            if len(roots)>1:self.issue('GOODS_MULTIPLE_OLD_OWNERS',legacy_id=number(source['legacy_id']));continue
            reference=str(next(iter(roots))) if roots else None
            key=('goods',number(source['legacy_id']));expected[key]=initial[key]=(*self.resolve_owner(reference),reference)
        sales_expected,conflicts,missing=sales_owner_graph(self.read,self.resolve_owner,self.admin)
        expected.update(sales_expected)
        self.verify_sales_conflict_evidence(conflicts)
        evidence=defaultdict(list)
        helper=self.manifest['provenance']['scripts'].get('migrate_owner_custody.sql')
        for module,section in self.run['summary'].get('currentOwnerCustody',{}).items():
            if section.get('helperSha256')!=helper:self.issue('CUSTODY_HELPER_SHA_MISMATCH',module=module)
            if section.get('pendingHandoverCount')!=len(section.get('entries',[])):self.issue('CUSTODY_COUNT_MISMATCH',module=module)
            for entry in section.get('entries',[]):evidence[(entry['target_table'],entry['target_legacy_id'])].append(entry)
        for key,(owner,original,reason,reference) in expected.items():
            table,identity=key;targets=self.owner_index.get(key,[])
            if len(targets)!=1:self.issue('OWNER_TARGET_NOT_UNIQUE',table=table,legacy_id=identity,matches=len(targets));continue
            target=targets[0]
            if target['owner_employee_id']!=owner:self.issue('CURRENT_OWNER_MISMATCH',table=table,legacy_id=identity,expected_employee_id=owner,actual_employee_id=target['owner_employee_id'])
            if owner==self.admin:
                allowed_reason='UPSTREAM_DOCUMENT_CUSTODY' if reason in ('PUBLIC_SOURCE','CURRENT_EMPLOYEE') else reason
                ref=str(reference) if reference is not None else 'upstream_document'
                valid=[entry for entry in evidence[key] if entry['target_id']==target['id'] and entry['assigned_employee_id']==self.admin
                       and entry.get('original_employee_id')==original and entry['reason']==allowed_reason and entry['source_reference']==ref]
                if not valid:self.issue('ADMIN_CUSTODY_EVIDENCE_MISSING_OR_WRONG',table=table,legacy_id=identity)
                self.custody.append(dict(table=table,legacy_id=identity,original_employee_id=original,assigned_employee_id=owner,reason=allowed_reason,evidence_matches=len(valid)))
        for key,targets in self.owner_index.items():
            if key not in expected and any(row['owner_employee_id'] is not None for row in targets):
                self.issue('UNEXPLAINED_OWNER_OUTSIDE_DECLARED_SOURCE',table=key[0],legacy_id=key[1])
        dump(self.out/'current_owner_custody_validation.json',self.custody)
    def verify_sales_conflict_evidence(self,expected):
        section=self.run['summary'].get('salesOwnerConflicts',{})
        objects=section.get('objects',[])
        if section.get('mappingVersion')!='mixed-upstream-owner-custody-v1' or section.get('objectCount')!=len(objects):
            self.issue('SALES_CONFLICT_EVIDENCE_PROTOCOL_MISMATCH')
        if section.get('helperSha256')!=self.manifest['provenance']['scripts'].get('migrate_owner_custody.sql'):
            self.issue('SALES_CONFLICT_HELPER_SHA_MISMATCH')
        actual=defaultdict(list)
        for obj in objects:actual[(obj.get('target_table'),obj.get('target_legacy_id'))].append(obj)
        if set(actual)!=set(expected):self.issue('SALES_CONFLICT_OBJECT_SET_MISMATCH',expected_objects=len(expected),actual_objects=len(actual))
        items={table:{row['legacy_id']:row for row in self.target[table]}
               for table in ('sales_order_items','sales_shipment_items','sales_return_items')}
        checks=[]
        for key,source in expected.items():
            entries=actual.get(key,[])
            if len(entries)!=1:self.issue('SALES_CONFLICT_OBJECT_NOT_UNIQUE',table=key[0],legacy_id=key[1]);continue
            obj=entries[0];targets=self.owner_index.get(key,[])
            target_id=targets[0]['id'] if len(targets)==1 else None
            for field,value in [('target_id',target_id),('assigned_employee_id',self.admin),('reason','MIXED_UPSTREAM_OWNER_CUSTODY')]:
                if obj.get(field)!=value:self.issue('SALES_CONFLICT_HEADER_MISMATCH',table=key[0],legacy_id=key[1],field=field)
            if obj.get('resolved_owner_ids')!=source['resolved_owner_ids']:
                self.issue('SALES_CONFLICT_OWNER_SET_MISMATCH',table=key[0],legacy_id=key[1])
            expected_refs=[]
            for ref in source['upstream_references']:
                target_table='sales_shipment_items' if key[0]=='sales_shipments' else 'sales_return_items'
                upstream_table='sales_order_items' if ref['upstream_kind']=='ORDER_ITEM' else 'sales_shipment_items'
                target_item=items[target_table].get(ref['target_item_legacy_id'])
                upstream_item=items[upstream_table].get(ref['upstream_item_legacy_id'])
                parents=self.owner_index.get((ref['upstream_document_table'],ref['upstream_document_legacy_id']),[])
                if not target_item or not upstream_item or len(parents)!=1:
                    self.issue('SALES_CONFLICT_SOURCE_RELATION_TARGET_MISSING',table=key[0],legacy_id=key[1]);continue
                target_parent='shipment_id' if key[0]=='sales_shipments' else 'return_id'
                link='out_item_id' if ref['upstream_kind']=='SHIPMENT_ITEM' else 'order_item_id'
                upstream_parent='order_id' if upstream_table=='sales_order_items' else 'shipment_id'
                if target_item[target_parent]!=target_id or target_item[link]!=upstream_item['id'] or upstream_item[upstream_parent]!=parents[0]['id']:
                    self.issue('SALES_CONFLICT_REAL_FK_MISMATCH',table=key[0],legacy_id=key[1],target_item_legacy_id=ref['target_item_legacy_id'])
                expected_refs.append({**ref,'target_item_id':target_item['id'],'upstream_item_id':upstream_item['id'],'upstream_document_id':parents[0]['id']})
            canonical=lambda rows:Counter(json.dumps(row,sort_keys=True) for row in rows)
            if canonical(obj.get('upstream_references',[]))!=canonical(expected_refs):
                self.issue('SALES_CONFLICT_UPSTREAM_EVIDENCE_MISMATCH',table=key[0],legacy_id=key[1])
            checks.append(dict(target_table=key[0],target_legacy_id=key[1],expected_owners=source['resolved_owner_ids'],expected_references=len(expected_refs)))
        dump(self.out/'sales_owner_conflict_validation.json',checks)
    def verify(self):
        self.snapshot();self.verify_crosswalk();self.verify_actors();self.verify_other_employee_fks()
        self.owner_index=defaultdict(list)
        for table in ('clients','suppliers','goods','sales_orders','sales_shipments','sales_other_shipments','sales_returns'):
            for row in self.target[table]:self.owner_index[(table,row['legacy_id'])].append(row)
        self.verify_owners()
        write_csv(self.out/'resolvable_history_uuid_pending.csv',self.pending,
                  ['table','legacy_id','field','worker_legacy_id','doc_type','expected_employee_id','mode'])
        dump(self.out/'employee_binding_issues.json',self.issues)
        report=dict(run_id=self.args.run_id,database=self.args.database,status='PASSED_WITH_PENDING' if not self.issues else 'FAILED',
            binding=self.binding,
            employee_crosswalk_count=self.worker_count,blocking_issues=len(self.issues),
            resolvable_history_uuid_not_materialized=sum(row['mode']=='LEGACY_ONLY' for row in self.pending),
            unresolved_source_identity_rows=sum(row['mode']=='UNRESOLVED_SOURCE_IDENTITY' for row in self.pending),
            source_only_fields_are_not_counted_as_structurally_migrated=True,custody_objects=len(self.custody),
            executed_database_statements='BEGIN REPEATABLE READ READ ONLY; SELECT only; ROLLBACK',inputs=self.inputs,generator_sha256=sha(Path(__file__)))
        dump(self.out/'employee_binding_verification.json',report)
        return report

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--inputs',type=Path,required=True);parser.add_argument('--hr',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True);parser.add_argument('--run-id',required=True)
    parser.add_argument('--database',default='uten_imp_rehearsal_20261022_v2')
    parser.add_argument('--container',default='uten-imp-postgres');parser.add_argument('--user',default='uten')
    parser.add_argument('--manifest-sha256',help='Exact final derived_inputs.json SHA256; required with --verify')
    parser.add_argument('--sales-owner-mapper-sha256',help='Exact final migrate_sales_owner.sql SHA256; required with --verify')
    parser.add_argument('--frozen-commit',help='Frozen worktree commit recorded in the audit evidence')
    parser.add_argument('--admin-user-id',help='Preserved original administrator user UUID; required with --verify')
    parser.add_argument('--expected-worker-count',type=int,help='Optional independently reviewed source identity count')
    parser.add_argument('--verify',action='store_true',help='Only after committed exact run SUCCESS/PASSED')
    args=parser.parse_args();uuid.UUID(args.run_id)
    audit=Audit(args);prepared=audit.prepare();report=audit.verify() if args.verify else prepared
    print(json.dumps({key:value for key,value in report.items() if key!='inputs'},ensure_ascii=True))
    return 1 if report.get('status')=='FAILED' else 0
if __name__=='__main__': raise SystemExit(main())

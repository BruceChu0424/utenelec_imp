"""Explicit isolated local scope; no reset, process control or source rewriting."""
import contextlib,hashlib,io,json,os,re,subprocess
from pathlib import Path
from split_production import split_production

SCOPE='plans-no-productioncost-no-finance'
CONTAINER='uten-imp-postgres-dev-5434-20261023'
CONTAINER_ID='06d5fbc4e06ae998ba34e248c8265b711904375626c13742a3fb6e4c7dcbbaef'
SYSTEM_ID='7700008130976600103'
DATABASE_OID=19699
ZERO_TABLES=('production_plan_costs','finance_receipts','finance_receipt_lines','finance_payments','finance_payment_lines','finance_expenses','finance_expense_items',
 'finance_other_incomes','finance_other_income_items','finance_bank_transfers','finance_bank_transfer_lines','finance_check_register','ar_ap_ledger','finance_reconciliations',
 'legacy_finance_import_sources','accounts','account_flow_monthly_summaries','finance_receipt_source_allocations','gl_entries')


def require(value,message):
    if not value:raise ValueError(message)


def verify_transport(db):
    context=subprocess.check_output(['docker','context','show'],text=True).strip()
    require(re.fullmatch('[A-Za-z0-9_.-]+',context),'Invalid local Docker context')
    endpoint=subprocess.check_output(['docker','context','inspect',context,'--format','{{.Endpoints.docker.Host}}'],text=True).strip()
    require(all(x.startswith(('npipe:','unix:')) for x in (endpoint,os.environ.get('DOCKER_HOST',endpoint))),'Remote Docker refused')
    os.environ['DOCKER_CONTEXT']=context;os.environ.pop('DOCKER_HOST',None)
    value=json.loads(subprocess.check_output(['docker','--context',context,'inspect',db.container],text=True))[0]
    require(value['Id']==CONTAINER_ID and value['Config']['Labels'].get('uten.local.isolated')=='5434-20261023','Unapproved isolated container')
    ports=value['NetworkSettings']['Ports'].get('5432/tcp')
    require(ports==[{'HostIp':'127.0.0.1','HostPort':'5434'}],'Isolated port binding differs')
    require(db.name=='uten_imp' and db.user=='uten_migrator' and db.expected_system_identifier==SYSTEM_ID and db.expected_database_oid==DATABASE_OID,'Explicit isolated canonical target required')
    result=db.sql("SELECT (SELECT system_identifier::text FROM pg_control_system())||'|'||(SELECT oid::text FROM pg_database WHERE datname=current_database())||'|'||current_user||'|'||(SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname=current_database());")
    require(result==SYSTEM_ID+'|'+str(DATABASE_OID)+'|uten_migrator|uten_migrator','Actual isolated physical/owner identity differs')
    flags=db.sql("SELECT (NOT rolsuper AND NOT rolcreatedb AND NOT rolcreaterole AND NOT rolreplication AND NOT rolbypassrls)::int FROM pg_roles WHERE rolname=current_user;")
    require(flags=='1','Trusted issuer must be the non-superuser owner')
    require(db.sql("SELECT (NOT rolsuper AND NOT rolinherit AND NOT rolcreatedb AND NOT rolcreaterole AND NOT rolbypassrls AND NOT pg_has_role('uten','uten_migrator','SET'))::int FROM pg_roles WHERE rolname='uten';")=='1','Runtime role must be separated and non-superuser')
    require(db.sql("SELECT CASE WHEN to_regprocedure('public.business_data_reset()') IS NULL THEN 1 ELSE (NOT has_function_privilege('uten',to_regprocedure('public.business_data_reset()'),'EXECUTE'))::int END;")=='1','Runtime reset is not retired')
    require(db.sql("SELECT (current_setting('log_min_error_statement')='panic' AND current_setting('log_statement')='none' AND current_setting('log_parameter_max_length')='0' AND current_setting('log_parameter_max_length_on_error')='0')::int;")=='1','Configure protected daemon logging before source payload')


def production(content):return split_production(content)


TARGETS={
 'migrate_hr_rehearsal.sql':('employees','employee_sensitive','employee_phones','departments','positions'),
 'migrate_goods.sql':('material_categories',),'migrate_mould.sql':('mould_categories',),'migrate_client.sql':('client_categories',),'migrate_supplier.sql':('supplier_categories',),
 'migrate_color.sql':('colors',),'migrate_unit.sql':('units',),'migrate_currency.sql':('currencies',),'migrate_warehouse.sql':('warehouses',),
 'migrate_mould_data.sql':('moulds',),'migrate_client_data.sql':('clients',),'migrate_supplier_data.sql':('suppliers',),'migrate_goods_data.sql':('goods',),
 'migrate_goods_bom.sql':('goods_bom_items',),'goods_material_identity.sql':('goods_material_identity_evidence',),
 'migrate_purchase.sql':('purchase_requests','purchase_request_items','purchase_orders','purchase_order_items','purchase_receipts','purchase_receipt_items','purchase_returns','purchase_return_items','legacy_procurement_receipt_import_sources','legacy_quantity_counter_import_sources'),
 'migrate_stock_docs.sql':('stock_documents','stock_document_items','stock_movements','stock_balances','business_record_history','plan_draw_links','production_planning_package_documents','production_planning_package_document_items','production_material_stock_events','production_material_stock_postings'),
 'migrate_sales.sql':('sales_quotes','sales_quote_items','sales_orders','sales_order_items','sales_order_cost_items','sales_shipments','sales_shipment_items','sales_other_shipments','sales_other_shipment_items','sales_returns','sales_return_items','legacy_quantity_counter_import_sources'),
 'migrate_subcontract.sql':('subcontract_orders','subcontract_order_items','subcontract_order_cost_items','subcontract_receipts','subcontract_receipt_items','subcontract_material_issues','subcontract_material_issue_items','subcontract_returns','subcontract_return_items','subcontract_material_returns','subcontract_material_return_items','subcontract_wastes','subcontract_waste_items','legacy_procurement_receipt_import_sources'),
 'migrate_production.sql':('production_plans','production_plan_items','legacy_production_plan_counter_import_sources','legacy_production_plan_counter_import_contexts')}


def analyze_targets_sql(module):
    tables=(*TARGETS.get(module,()),'master_code_reservations','master_code_reservation_members')
    names=','.join("'%s'"%name for name in dict.fromkeys(tables))
    return "\nDO $fresh_target_stats$ DECLARE t text;BEGIN FOREACH t IN ARRAY ARRAY[%s] LOOP IF to_regclass('public.'||t) IS NOT NULL THEN EXECUTE format('ANALYZE public.%%I',t);END IF;END LOOP;END $fresh_target_stats$;\n"%names


def finish_sql(directory,manifest,run_id,baseline,approval):
    import reconcile_modules
    from verify_finance_master_sources import SEED_STYLE_FIELDS,ROLE_FIELDS
    records={r['file']:r for r in manifest['files']};run=str(__import__('uuid').UUID(run_id));sql=''
    for table in ZERO_TABLES:sql+="DO $$ BEGIN IF EXISTS(SELECT 1 FROM public.%s) THEN RAISE EXCEPTION 'Excluded scoped domain contains rows: %s';END IF;END $$;\n"%(table,table)
    data=baseline['data'];payload=json.dumps({'payment_styles':data['payment_styles'],'posting_roles':data['posting_roles']},ensure_ascii=False,separators=(',',':')).encode().hex()
    fields=lambda items:'ARRAY['+','.join("'%s'"%x for x in items)+']::text[]'
    sql+="""DO $seed$ DECLARE b jsonb:=convert_from(decode('%s','hex'),'UTF8')::jsonb;a jsonb;r jsonb;BEGIN
 SELECT COALESCE(jsonb_agg(public.fn_legacy_finance_snapshot(to_jsonb(p),%s) ORDER BY p.id),'[]'::jsonb) INTO a FROM payment_styles p;
 SELECT COALESCE(jsonb_agg(public.fn_legacy_finance_snapshot(to_jsonb(p),%s) ORDER BY p.role_key),'[]'::jsonb) INTO r FROM system_posting_style_roles p;
 IF a IS DISTINCT FROM (SELECT jsonb_agg(value ORDER BY value->>'id') FROM jsonb_array_elements(b->'payment_styles'))
 OR r IS DISTINCT FROM (SELECT jsonb_agg(value ORDER BY value->>'role_key') FROM jsonb_array_elements(b->'posting_roles')) THEN RAISE EXCEPTION 'Scoped native financial seed changed';END IF;
 END $seed$;
CREATE TEMP TABLE scoped_module_row_checks(source text,target text,expected bigint,actual bigint,excluded bigint,archived bigint) ON COMMIT DROP;
"""%(payload,fields(SEED_STYLE_FIELDS),fields(ROLE_FIELDS))
    queries={k:v for k,v in reconcile_modules.document_queries().items() if k!='production_plan_costs.csv' and not k.startswith('m_')}
    for source,(table,query) in queries.items():sql+="INSERT INTO scoped_module_row_checks SELECT '%s','%s',%d,(%s),%s,0;\n"%(source,table,records[source]['rows'],query,reconcile_modules.excluded_rows(source))
    out=io.StringIO()
    with contextlib.redirect_stdout(out):reconcile_modules.emit_master_identity_checks()
    sql+=out.getvalue()
    sql+="""DO $$ BEGIN IF EXISTS(SELECT 1 FROM scoped_module_row_checks WHERE expected<>actual+excluded+archived)
 OR EXISTS(SELECT 1 FROM legacy_migration_runs WHERE run_id='%s' AND legacy_account_flow_import_txid IS NOT NULL)
 THEN RAISE EXCEPTION 'Scoped conservation or excluded monthly origin failed';END IF;END $$;
SET CONSTRAINTS ALL IMMEDIATE;
UPDATE legacy_migration_runs SET status='SUCCESS',reconciliation_status='WAIVED',exit_code=0,finished_at=clock_timestamp(),
 reconciliation_summary=reconciliation_summary||jsonb_build_object('fullBootstrap',false,'automatedCheckCount',0,'scopedReconciliationStatus','PASSED',
 'warehouseExclusions',(SELECT COALESCE(jsonb_agg(to_jsonb(exclusion) ORDER BY source_file,source_row_id),'[]'::jsonb)
   FROM bootstrap_warehouse_exclusions exclusion),
 'source',COALESCE(reconciliation_summary->'source','{}'::jsonb)||jsonb_build_object('full_bootstrap',false),
 'scope',jsonb_build_object('fullBootstrap',false,'reconciliation','PASSED','scopeAuthorityReference','%s',
  'executionTailSha256',:'scoped_execution_template_sha256','executionTemplateKind','ENTIRE_SCOPED_IMPORT_EXCLUDING_EXTERNAL_DIGEST_BINDER',
  'productionPlans',%d,'productionPlanItems',%d,'productionPlanCosts',0,'financeLegacyRows',0,'nativeFinanceSeedUnchanged',true,
  'productionCostsStatus','SKIPPED_USER','financeStatus','SKIPPED_USER','scopedMasterIdentityChecksPassed',true,
  'scopedModuleRowCheckCount',(SELECT count(*) FROM scoped_module_row_checks),'scopedModuleRowChecks',(SELECT jsonb_agg(jsonb_build_object(
   'source',source,'target',target,'expected',expected,'actual',actual,'excluded',excluded,'archived',archived,'passed',expected=actual+excluded+archived) ORDER BY source) FROM scoped_module_row_checks),
  'full23AndSevenGates','NOT_RUN_NOT_CLAIMED'),'productionAcceptance',false)
WHERE run_id='%s' AND status='RUNNING';
DO $$ BEGIN IF NOT EXISTS(SELECT 1 FROM legacy_migration_runs WHERE run_id='%s' AND status='SUCCESS' AND reconciliation_status='WAIVED')
 THEN RAISE EXCEPTION 'Scoped completion did not update its running claim';END IF;END $$;
"""%(run,approval,records['production_plans.csv']['rows'],records['production_plan_items.csv']['rows'],run,run)
    audit=Path(__file__).with_name('migrate_audit_summary.sql').read_text(encoding='utf-8')
    audit=audit.replace("'target', run.target,","'fullBootstrap',false,'scope',run.reconciliation_summary->'scope','target', run.target,")
    return sql+audit+'\n'

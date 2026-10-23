"""Synthetic full-schema PG regression for historical other-shipment settlement placement."""
from pathlib import Path
import argparse,hashlib,importlib.util,json,re

REPOSITORY_DEFAULT=Path(__file__).resolve().parents[4]
SEEDS=('V279__global_business_identifier_registry.sql',
       'V272__uncategorized_master_categories.sql',
       'V275__production_daily_report_source_uuid_guards.sql')
OLD_COLUMNS='payment_style_id, seller_id'
NEW_COLUMNS='payment_style_id, settlement_method_id, seller_id'
NEW_VALUE='s.p_style, (SELECT id FROM settlement_methods WHERE legacy_id=s.p_style),\n'
OLD_TAIL="""UPDATE sales_other_shipments d SET settlement_method_id = m.id
FROM settlement_methods m WHERE m.legacy_id = d.payment_style_id;"""


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def original_header(fixed):
    """Reverse only the reviewed two-token loader change; no business rewrite."""
    if fixed.count(NEW_COLUMNS)!=1 or fixed.count(NEW_VALUE)!=1:
        raise ValueError('Current other-shipment INSERT needs an explicit settlement-placement review')
    return fixed.replace(NEW_COLUMNS,OLD_COLUMNS,1).replace(NEW_VALUE,'s.p_style,\n',1)


def assert_removed_tail(script):
    if re.search(r'UPDATE\s+sales_other_shipments\s+d\s+SET\s+settlement_method_id',script):
        raise ValueError('Read-only other shipments must resolve settlement UUID on first INSERT')


def load_harness(repository):
    path=repository/'server/legacy_migration/tests/production_counter/run_adversarial.py'
    spec=importlib.util.spec_from_file_location('sales_owned_full_schema',path)
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    return module


def source_fixture(script):
    definitions='\n'.join(re.search(r'CREATE TEMP TABLE '+stage+r'\s*\(.*?\);',script,re.S)[0]
        for stage in ('ship_stage','ship_item_stage','oship_stage','oship_item_stage'))
    return """BEGIN;SET LOCAL search_path=public;SET LOCAL app.legacy_import='on';
SET LOCAL app.business_identifier_legacy_import='on';SET LOCAL uten.legacy_reference_import='legacy-sales-v273';
""" + definitions + """
INSERT INTO warehouses(code,name) VALUES('SYN-WH-OTHER','SYNTHETIC ONLY');
CREATE TEMP TABLE warehouse_target_stage(legacy_id int,warehouse_id uuid);
INSERT INTO warehouse_target_stage SELECT 900701,id FROM warehouses WHERE code='SYN-WH-OTHER';
INSERT INTO clients(legacy_id,code,name,code_managed,code_sequence)
VALUES(900501,'LEGACY-C-900501','SYNTHETIC ONLY',false,900501);
INSERT INTO goods(legacy_id,code,name,code_managed,code_sequence)
VALUES(900101,'LEGACY-G-900101','SYNTHETIC ONLY',false,900101);
INSERT INTO colors(legacy_id,code,name) VALUES(900401,'LEGACY-COLOR-900401','SYNTHETIC ONLY');
INSERT INTO units(legacy_id,code,name) VALUES(900301,'LEGACY-UNIT-900301','SYNTHETIC ONLY');
INSERT INTO currencies(legacy_id,code,name,exchange_rate) VALUES(900601,'SYN-CUR-900601','SYNTHETIC ONLY',1);
INSERT INTO oship_stage(legacy_id,bill_no,bill_date,client_legacy,warehouse_legacy,p_style,
    total_original,status,exchange_rate,cur_legacy,remark,maker_legacy,approver_legacy)
VALUES(990001,'SYN-OTHER-990001','2025-01-02',900501,900701,1,70,1,1,900601,'SYNTHETIC ONLY',42,43);
INSERT INTO oship_item_stage(legacy_id,bill_legacy,goods_legacy,color_legacy,unit_legacy,
    unit_rate,qty,price,amount_original,returned_qty,returned_amount)
VALUES(990101,990001,900101,900401,900301,1,10,7,70,3,21);
"""


def run_suite(pg,h,script):
    fixed=h.insert_block(script,'sales_other_shipments')
    original=original_header(fixed)
    item=h.insert_block(script,'sales_other_shipment_items')
    assert_removed_tail(script)
    fixture=source_fixture(script)
    results=[]
    unchanged=h.assert_sql("""(SELECT count(*)=1 FROM sales_other_shipments WHERE
       payment_style_id=1 AND maker_legacy_id=42 AND approver_legacy_id=43
       AND bill_date='2025-01-02' AND status=1 AND total_original=70 AND total_local=70)
       AND (SELECT count(*)=1 FROM sales_other_shipment_items WHERE qty=10 AND price=7
            AND amount_original=70 AND amount_local=70 AND returned_qty=3 AND returned_amount=21)
       AND (SELECT count(*)=0 FROM stock_movements) AND (SELECT count(*)=0 FROM ar_ap_ledger)
       AND (SELECT count(*)=0 FROM pg_trigger WHERE NOT tgisinternal AND tgenabled='D')""")
    def case(name,body,denied=None):
        result=pg.execute(fixture+body+'\nSET CONSTRAINTS ALL IMMEDIATE;\nROLLBACK;')
        passed=(result['ok'] if denied is None else
                not result['ok'] and '23514' in result['sqlstates'] and denied in result['functions'])
        results.append({'name':name,'status':'PASS' if passed else 'FAIL',
            **{k:result[k] for k in ('sqlstates','functions','constraints') if result[k]}})
        print(json.dumps(results[-1]),flush=True)
    case('original_tail_update_rejected_by_real_retirement_guard',
         original+item+OLD_TAIL,'fn_guard_retired_sales_other_shipment_write')
    case('matching_method_on_first_insert_preserves_original_facts_no_posting',
         fixed+item+unchanged+h.assert_sql("""(SELECT count(*)=1 FROM sales_other_shipments d
         JOIN settlement_methods m ON m.id=d.settlement_method_id AND m.legacy_id=d.payment_style_id)"""))
    case('later_settlement_unbind_still_rejected',
         fixed+"UPDATE sales_other_shipments SET settlement_method_id=NULL;",
         'fn_guard_retired_sales_other_shipment_write')
    case('ordinary_new_other_shipment_still_rejected',
         "SET LOCAL uten.legacy_reference_import='';"+fixed,'fn_guard_retired_sales_other_shipment_write')
    for label,value in (('null','NULL'),('zero','0'),('unknown','999999')):
        mutate='UPDATE oship_stage SET p_style='+value+';'
        expected=h.assert_sql("""(SELECT count(*)=1 FROM sales_other_shipments
            WHERE settlement_method_id IS NULL) AND
            (SELECT payment_style_id IS NOT DISTINCT FROM """+value+""" FROM sales_other_shipments)""")
        case(label+'_old_intended_backfill_preserves_raw_and_null_uuid',mutate+original+OLD_TAIL+expected)
        case(label+'_initial_binding_preserves_same_raw_and_null_uuid',mutate+fixed+expected)
    for label,mutation in (('inactive',"status='禁用'"),('deleted','is_deleted=true')):
        before='UPDATE settlement_methods SET '+mutation+' WHERE legacy_id=1;'
        case(label+'_old_post_insert_path_is_rejected',before+original+OLD_TAIL,
             'fn_guard_retired_sales_other_shipment_write')
        case(label+'_first_insert_keeps_original_method_authority_rejection',before+fixed,
             'fn_sync_settlement_method_reference')
    wrong=fixed.replace('legacy_id=s.p_style','legacy_id=6')
    case('wrong_real_dictionary_uuid_cannot_conflict_with_raw_style',wrong,
         'fn_sync_settlement_method_reference')
    return results


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repository-root',type=Path,default=REPOSITORY_DEFAULT)
    parser.add_argument('--schema-baseline',dest='schema',type=Path,required=True,
        help='Explicit complete PG16 schema-only baseline immediately before V913, with no business data')
    parser.add_argument('--loader',type=Path,help='Reviewed corrected migrate_sales.sql; defaults to current repository')
    parser.add_argument('--output',type=Path,required=True,help='Fresh private result directory; no overwrite')
    args=parser.parse_args(argv);args.repository_root=args.repository_root.resolve()
    loader=args.loader or args.repository_root/'server/legacy_migration/migrate_sales.sql'
    script=loader.read_text(encoding='utf-8')
    assert_removed_tail(script)
    if args.output.exists():parser.error('--output must be a fresh directory')
    args.output.mkdir(parents=True)
    copied=args.output/'tested-migrate-sales.sql';copied.write_bytes(loader.read_bytes())
    migration=args.repository_root/'server/src/main/resources/db/migration'
    args.reference_seed_sql={name:(migration/name).read_text(encoding='utf-8') for name in SEEDS}
    args.candidate_sql=migration/'V913__legacy_production_plan_counter_provenance.sql'
    h=load_harness(args.repository_root)
    seed=(migration/'V273__settlement_method_uuid_authority.sql').read_text(encoding='utf-8')
    seed=re.search(r'INSERT INTO settlement_methods\s*\(.*?;',seed,re.S)[0]
    evidence={'status':'RUNNING_SYNTHETIC_TEST','schema_sha256':digest(args.schema),
       'v913_sha256':digest(args.candidate_sql),'loader_sha256':digest(copied),
       'source_csv_read':False,'application_database_connected':False,'container_removed':False}
    pg=h.OwnedPg(args)
    try:
        with pg:
            pg.checked('SET search_path=public;'+seed)
            results=run_suite(pg,h,script)
            evidence.update(cases=results,passed=sum(r['status']=='PASS' for r in results),
                failed=sum(r['status']=='FAIL' for r in results))
            evidence['status']='PASSED' if evidence['failed']==0 else 'FAILED'
    finally:
        if pg.created:
            pg.__exit__(None,None,None)
        evidence['container_removed']=not pg.created
        (args.output/'receipt.json').write_text(json.dumps(evidence,indent=2)+'\n',encoding='utf-8')
    print(json.dumps({k:evidence.get(k) for k in ('status','passed','failed','container_removed')}))
    return 0 if evidence['status']=='PASSED' else 1


if __name__=='__main__':
    raise SystemExit(main())

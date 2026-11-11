"""Read-only, one repeatable-read snapshot; never logs credentials or bodies.

Usage: python snapshot.py --config PRIVATE.json --seed b.json --out NEW.json
Works for Root preparation and the independent old-program upgrade fixture.
"""
from pathlib import Path
import argparse, json, re
from datetime import datetime, timezone
import psycopg2
from psycopg2.extras import RealDictCursor
p=argparse.ArgumentParser();p.add_argument('--config',required=True);p.add_argument('--seed',required=True);p.add_argument('--out',required=True)
a=p.parse_args();out=Path(a.out)
if out.exists():raise SystemExit('Preserve the previous snapshot; choose a new path')
c=json.loads(Path(a.config).read_text(encoding='utf-8-sig'));seed=json.loads(Path(a.seed).read_text(encoding='utf-8-sig'))
m=re.fullmatch(r'jdbc:postgresql://127\.0\.0\.1:(\d+)/([a-z0-9_]+)',c['jdbcUrl'])
if not m:raise SystemExit('Only an explicit isolated loopback database is supported')
with psycopg2.connect(host='127.0.0.1',port=int(m[1]),dbname=m[2],user=c['username'],password=c['password']) as db:
    db.set_session(readonly=True,isolation_level='REPEATABLE READ')
    with db.cursor(cursor_factory=RealDictCursor) as cursor:
        def rows(sql,*params):cursor.execute(sql,params);return list(cursor.fetchall())
        result={'status':'prep; SQL evidence alone is not real Web acceptance','capturedAtUtc':datetime.now(timezone.utc).isoformat(),'database':m[0], 'transaction':rows('SELECT current_setting(\'transaction_read_only\') AS read_only,current_setting(\'transaction_isolation\') AS isolation')}
        for kind in ['purchase','subcontract']:
            s=seed[kind];prefix=kind
            result[kind]={
                'source':rows(f'''SELECT r.id receipt_id,r.bill_no receipt_no,r.bill_date,r.status receipt_status,
                    i.id receipt_item_id,i.order_item_id,i.goods_id,i.qty,i.returned_qty receipt_returned_qty,i.price,i.amount_local,
                    o.id order_id,o.bill_no order_no,o.status order_status,oi.price order_price,oi.returned_qty order_returned_qty,
                    s.id supplier_id,s.code supplier_code,s.name supplier_name,w.id warehouse_id,w.code warehouse_code,w.name warehouse_name,
                    g.code goods_code,g.name goods_name
                    FROM {prefix}_receipts r JOIN {prefix}_receipt_items i ON i.receipt_id=r.id
                    JOIN {prefix}_order_items oi ON oi.id=i.order_item_id JOIN {prefix}_orders o ON o.id=oi.order_id
                    JOIN suppliers s ON s.id=r.supplier_id JOIN warehouses w ON w.id=r.warehouse_id JOIN goods g ON g.id=i.goods_id
                    WHERE i.id=%s''',s['receiptItemId']),
                'returns':rows(f'''SELECT r.id,r.bill_no,r.bill_date,r.status,r.maker_id,r.approver_id,r.created_by,r.updated_by,r.total_local,
                    i.id item_id,i.receipt_item_id,i.order_item_id,i.goods_id,i.qty,i.price,i.amount_local,
                    i.is_deleted item_deleted,r.is_deleted document_deleted
                    FROM {prefix}_return_items i JOIN {prefix}_returns r ON r.id=i.return_id WHERE i.receipt_item_id=%s ORDER BY r.created_at,i.line_no''',s['receiptItemId']),
                'stock':rows('SELECT warehouse_id,goods_id,color_id,qty,amount_local FROM stock_balances WHERE warehouse_id=%s AND goods_id=%s ORDER BY color_id NULLS FIRST',s['warehouseId'],s['goodsId']),
            }
            ids=[s['receiptId']]+[str(r['id']) for r in result[kind]['returns']]
            result[kind]['movements']=rows('SELECT id,source_doc_type,source_doc_id,source_item_id,direction,qty,amount_local,movement_type,created_by FROM stock_movements WHERE source_doc_id::text=ANY(%s) ORDER BY ledger_seq',ids)
            result[kind]['ap']=rows('SELECT id,source_doc_type,source_doc_id,status,direction,currency_id,amount_original,amount_original_local,amount_balance,is_deleted FROM ar_ap_ledger WHERE source_doc_id::text=ANY(%s) ORDER BY created_at,id',ids)
            result[kind]['gl']=rows('''SELECT v.id,v.source_type,v.source_doc_id,v.status,v.is_deleted,e.style_id,p.code style_code,e.direction,e.amount,e.created_by
                FROM gl_vouchers v LEFT JOIN gl_entries e ON e.voucher_id=v.id LEFT JOIN payment_styles p ON p.id=e.style_id
                WHERE v.source_doc_id::text=ANY(%s) ORDER BY v.created_at,v.id,e.line_no''',ids)
        for role in ['maker','approver','planner']:
            if role in seed:result[role]=rows('SELECT id,employee_id,login_account,is_super_admin,status,is_deleted FROM users WHERE id=%s',seed[role]['userId'])
        if 'materialOrder' in seed:
            aid=seed['materialOrder']['analysisId']
            result['materialOrder']={
                'header':rows('SELECT id,analysis_no,status,version,fingerprint,maker_id FROM production_material_analyses WHERE id=%s',aid),
                'commands':rows('SELECT id,operation,idempotency_key,request_hash,result_payload,created_by,created_at FROM production_material_analysis_commands WHERE analysis_id=%s ORDER BY created_at,id',aid),
                'batches':rows('SELECT id,action_id,route,row_version,created_by FROM preplan_aggregate_batches WHERE analysis_id=%s ORDER BY created_at,id',aid),
                'actions':rows('SELECT id,requested_qty,public_surplus_qty,safety_replenishment_qty,route,status,external_document_type,external_document_id,external_document_no,idempotency_key,request_hash,created_by FROM preplan_supply_actions WHERE analysis_id=%s ORDER BY created_at,id',aid),
                'allocations':rows('SELECT action_id,analysis_material_id,allocated_qty,external_item_id,created_by FROM preplan_supply_action_allocations WHERE analysis_id=%s ORDER BY action_id,analysis_material_id',aid),
                'purchaseRequests':rows('SELECT r.id,r.bill_no,r.status,i.id item_id,i.goods_id,i.qty FROM purchase_requests r JOIN purchase_request_items i ON i.request_id=r.id JOIN preplan_supply_actions a ON a.external_document_id=r.id AND a.external_document_type=\'PURCHASE_REQUEST\' WHERE a.analysis_id=%s AND NOT r.is_deleted AND NOT i.is_deleted ORDER BY r.id,i.line_no',aid),
                'events':rows('SELECT e.batch_id,e.event_type,e.idempotency_key,e.request_hash,e.expected_version,e.resulting_version,e.public_delta,e.safety_delta,e.created_by FROM preplan_aggregate_batch_events e JOIN preplan_aggregate_batches b ON b.id=e.batch_id WHERE b.analysis_id=%s ORDER BY e.created_at,e.id',aid)}
out.parent.mkdir(parents=True,exist_ok=True);out.write_text(json.dumps(result,ensure_ascii=False,indent=2,default=str),encoding='utf8')
print('Wrote read-only snapshot: '+str(out))

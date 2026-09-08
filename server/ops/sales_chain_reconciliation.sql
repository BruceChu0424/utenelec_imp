-- Read-only reconciliation for an isolated acceptance copy.
-- Run after the intended business step. Missing GL coverage is expected before
-- explicit period posting; after posting it must be zero, with nonempty vouchers.
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;

SELECT current_database() AS database_name, now() AS snapshot_at,
       (SELECT count(*) FROM sales_orders WHERE NOT is_deleted) AS sales_orders,
       (SELECT count(*) FROM sales_shipments WHERE status=1 AND warehouse_work_status='SHIPPED' AND NOT is_deleted) AS shipped_documents,
       (SELECT count(*) FROM finance_receipts WHERE status=1 AND NOT is_deleted) AS approved_receipts;

WITH shipped AS (
    SELECT item.order_item_id, SUM(item.qty) AS qty
    FROM sales_shipment_items item JOIN sales_shipments document ON document.id=item.shipment_id
    WHERE document.status=1 AND document.warehouse_work_status='SHIPPED'
      AND NOT document.is_deleted AND NOT item.is_deleted
      AND item.order_item_id IS NOT NULL GROUP BY item.order_item_id
), returned AS (
    SELECT item.order_item_id, SUM(item.qty) AS qty
    FROM sales_return_items item JOIN sales_returns document ON document.id=item.return_id
    WHERE document.status=1 AND NOT document.is_deleted AND NOT item.is_deleted
      AND item.order_item_id IS NOT NULL GROUP BY item.order_item_id
), reserved AS (
    SELECT order_item_id, SUM(qty-consumed_qty-released_qty) AS base_qty
    FROM stock_reservations WHERE status=0 AND NOT is_deleted AND order_item_id IS NOT NULL
    GROUP BY order_item_id
)
SELECT 'order_quantity' AS check_name, item.order_id, item.id AS order_item_id,
       item.shipped_qty, COALESCE(shipped.qty,0) AS source_shipped_qty,
       item.returned_qty, COALESCE(returned.qty,0) AS source_returned_qty,
       item.reserved_qty*COALESCE(NULLIF(item.unit_rate,0),1) AS stored_reserved_base,
       COALESCE(reserved.base_qty,0) AS reservation_base
FROM sales_order_items item
LEFT JOIN shipped ON shipped.order_item_id=item.id
LEFT JOIN returned ON returned.order_item_id=item.id
LEFT JOIN reserved ON reserved.order_item_id=item.id
WHERE NOT item.is_deleted AND (
    COALESCE(item.shipped_qty,0)<>COALESCE(shipped.qty,0)
    OR COALESCE(item.returned_qty,0)<>COALESCE(returned.qty,0)
    OR (item.chain_status>0 AND COALESCE(item.reserved_qty,0)*COALESCE(NULLIF(item.unit_rate,0),1)
        <>COALESCE(reserved.base_qty,0)))
ORDER BY item.order_id,item.id;

WITH movement AS (
    SELECT warehouse_id,goods_id,color_id,SUM(qty*direction) AS qty,SUM(COALESCE(amount_local,0)*direction) AS amount
    FROM stock_movements GROUP BY warehouse_id,goods_id,color_id
), balance AS (
    SELECT warehouse_id,goods_id,color_id,SUM(qty) AS qty,SUM(COALESCE(amount_local,0)) AS amount
    FROM stock_balances GROUP BY warehouse_id,goods_id,color_id
)
SELECT 'stock_vs_movement' AS check_name, COALESCE(balance.warehouse_id,movement.warehouse_id) AS warehouse_id,
       COALESCE(balance.goods_id,movement.goods_id) AS goods_id, COALESCE(balance.color_id,movement.color_id) AS color_id,
       COALESCE(balance.qty,0)-COALESCE(movement.qty,0) AS quantity_difference,
       COALESCE(balance.amount,0)-COALESCE(movement.amount,0) AS amount_difference
FROM balance FULL JOIN movement ON movement.warehouse_id=balance.warehouse_id
 AND movement.goods_id=balance.goods_id AND movement.color_id IS NOT DISTINCT FROM balance.color_id
WHERE COALESCE(balance.qty,0)<>COALESCE(movement.qty,0)
   OR COALESCE(balance.amount,0)<>COALESCE(movement.amount,0);

SELECT 'ar_source_uniqueness' AS check_name,source_doc_type,source_doc_id,COUNT(*) AS rows
FROM ar_ap_ledger WHERE direction='AR' AND status=1 AND NOT is_deleted
GROUP BY source_doc_type,source_doc_id HAVING COUNT(*)<>1;

SELECT 'ar_original_balance' AS check_name,id,source_doc_type,source_doc_id,
       amount_original,amount_received_original,amount_write_off_original,amount_offset_original,amount_balance_original
FROM ar_ap_ledger WHERE direction='AR' AND status=1 AND NOT is_deleted AND (
    amount_balance_original IS NULL OR amount_received_original IS NULL OR amount_write_off_original IS NULL
    OR amount_balance_original<>amount_original-amount_received_original-amount_write_off_original-COALESCE(amount_offset_original,0));

SELECT 'ar_local_balance' AS check_name,id,source_doc_type,source_doc_id,
       amount_original_local,amount_settled,amount_offset_local,amount_balance
FROM ar_ap_ledger WHERE direction='AR' AND status=1 AND NOT is_deleted
 AND amount_balance IS DISTINCT FROM amount_original_local-COALESCE(amount_settled,0)-COALESCE(amount_offset_local,0);

WITH movements AS (
    SELECT account_id,SUM(in_amount-out_amount) AS net_amount
    FROM finance_reconciliations WHERE NOT is_deleted GROUP BY account_id
)
SELECT 'account_vs_register' AS check_name,account.id,account.code,account.currency_id,
       account.init_balance,account.balance_current,COALESCE(movements.net_amount,0) AS register_net,
       account.balance_current-account.init_balance-COALESCE(movements.net_amount,0) AS difference
FROM accounts account LEFT JOIN movements ON movements.account_id=account.id
WHERE NOT account.is_deleted
 AND account.balance_current IS DISTINCT FROM account.init_balance+COALESCE(movements.net_amount,0);

WITH sources AS (
    SELECT id,'SALES_SHIPMENT'::text AS source_type,total_original,total_local
    FROM sales_shipments WHERE status=1 AND warehouse_work_status='SHIPPED' AND NOT is_deleted
    UNION ALL
    SELECT id,'SALES_RETURN',-total_original,-total_local
    FROM sales_returns WHERE status=1 AND NOT is_deleted
)
SELECT 'ar_vs_document' AS check_name,sources.*,ledger.amount_original,ledger.amount_original_local
FROM sources LEFT JOIN ar_ap_ledger ledger ON ledger.source_doc_id=sources.id
 AND ledger.source_doc_type=sources.source_type AND ledger.status=1 AND NOT ledger.is_deleted
WHERE ledger.id IS NULL OR ledger.amount_original IS DISTINCT FROM sources.total_original
   OR ledger.amount_original_local IS DISTINCT FROM sources.total_local;

SELECT 'return_quarantine' AS check_name,id,received_base_qty,released_base_qty,scrapped_base_qty,rework_base_qty,status
FROM sales_return_quality_items
WHERE released_base_qty<0 OR scrapped_base_qty<0 OR rework_base_qty<0
   OR released_base_qty+scrapped_base_qty+rework_base_qty>received_base_qty
   OR (status='DISPOSED' AND released_base_qty+scrapped_base_qty+rework_base_qty<>received_base_qty);

SELECT 'gl_nonempty_balanced' AS check_name,voucher.id,voucher.voucher_no,voucher.source_type,voucher.source_doc_id,
       COUNT(entry.id) AS entry_count,COALESCE(SUM(entry.direction*entry.amount),0) AS debit_credit_difference
FROM gl_vouchers voucher LEFT JOIN gl_entries entry ON entry.voucher_id=voucher.id
GROUP BY voucher.id,voucher.voucher_no,voucher.source_type,voucher.source_doc_id
HAVING COUNT(entry.id)=0 OR COALESCE(SUM(entry.direction*entry.amount),0)<>0;

SELECT 'missing_ar_gl_after_posting' AS check_name,ledger.id,ledger.source_doc_type,ledger.source_doc_id
FROM ar_ap_ledger ledger WHERE ledger.direction='AR' AND ledger.status=1 AND NOT ledger.is_deleted
 AND ledger.source_doc_type IN ('SALES_SHIPMENT','SALES_RETURN')
 AND NOT EXISTS(SELECT 1 FROM gl_vouchers voucher WHERE voucher.source='AUTO' AND voucher.source_type='AR_POST'
                AND voucher.source_doc_id=ledger.source_doc_id AND voucher.period=to_char(ledger.bill_date,'YYYY-MM'));

SELECT 'missing_receipt_gl' AS check_name,receipt.id,receipt.bill_no
FROM finance_receipts receipt WHERE receipt.status=1 AND NOT receipt.is_deleted AND receipt.settlement_authority_version=1
 AND NOT EXISTS(SELECT 1 FROM gl_vouchers voucher WHERE voucher.source_type='RECEIPT' AND voucher.source_doc_id=receipt.id);

COMMIT;

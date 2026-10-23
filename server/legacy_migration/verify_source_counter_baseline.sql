\set ON_ERROR_STOP on
-- Read-only post-success evidence. Invoke psql -v run_id=<successful UUID> -f ...
BEGIN READ ONLY;
WITH matched AS (
    SELECT proof.source_kind,proof.id,
        target.id IS NOT NULL AS target_exists,
        proof.target_snapshot_sha256=encode(public.digest(public.fn_legacy_finance_snapshot(to_jsonb(target),proof.target_fields)::text,'sha256'),'hex') AS original_projection_unchanged
    FROM public.legacy_quantity_counter_import_sources proof
    LEFT JOIN public.purchase_order_items target ON proof.target_table='purchase_order_items' AND target.id=proof.target_id
    WHERE proof.run_id=:'run_id'::uuid AND proof.target_table='purchase_order_items'
    UNION ALL
    SELECT proof.source_kind,proof.id,target.id IS NOT NULL,
        proof.target_snapshot_sha256=encode(public.digest(public.fn_legacy_finance_snapshot(to_jsonb(target),proof.target_fields)::text,'sha256'),'hex')
    FROM public.legacy_quantity_counter_import_sources proof
    LEFT JOIN public.sales_order_items target ON proof.target_table='sales_order_items' AND target.id=proof.target_id
    WHERE proof.run_id=:'run_id'::uuid AND proof.target_table='sales_order_items'
    UNION ALL
    SELECT proof.source_kind,proof.id,target.id IS NOT NULL,
        proof.target_snapshot_sha256=encode(public.digest(public.fn_legacy_finance_snapshot(to_jsonb(target),proof.target_fields)::text,'sha256'),'hex')
    FROM public.legacy_quantity_counter_import_sources proof
    LEFT JOIN public.sales_shipment_items target ON proof.target_table='sales_shipment_items' AND target.id=proof.target_id
    WHERE proof.run_id=:'run_id'::uuid AND proof.target_table='sales_shipment_items'
)
SELECT source_kind,count(*) AS source_proofs,
    count(*) FILTER(WHERE NOT target_exists) AS missing_targets,
    count(*) FILTER(WHERE original_projection_unchanged IS DISTINCT FROM true) AS changed_original_projections
FROM matched GROUP BY source_kind ORDER BY source_kind;

SELECT 'purchase_order_received_gt_qty_plus_returned' AS historical_review_case,count(*) AS original_rows
FROM public.purchase_order_items WHERE legacy_counter_import_run_id=:'run_id'::uuid AND received_qty>qty+returned_qty
UNION ALL SELECT 'purchase_order_returned_gt_received',count(*)
FROM public.purchase_order_items WHERE legacy_counter_import_run_id=:'run_id'::uuid AND returned_qty>received_qty
UNION ALL SELECT 'purchase_receipt_returned_gt_qty',count(*)
FROM public.purchase_receipt_items WHERE legacy_import_run_id=:'run_id'::uuid AND returned_qty>qty
UNION ALL SELECT 'sales_order_shipped_gt_qty_plus_returned',count(*)
FROM public.sales_order_items WHERE legacy_counter_import_run_id=:'run_id'::uuid AND shipped_qty>qty+returned_qty
UNION ALL SELECT 'sales_order_returned_gt_shipped',count(*)
FROM public.sales_order_items WHERE legacy_counter_import_run_id=:'run_id'::uuid AND returned_qty>shipped_qty
UNION ALL SELECT 'sales_shipment_returned_gt_qty',count(*)
FROM public.sales_shipment_items WHERE legacy_counter_import_run_id=:'run_id'::uuid AND returned_qty>qty;
ROLLBACK;

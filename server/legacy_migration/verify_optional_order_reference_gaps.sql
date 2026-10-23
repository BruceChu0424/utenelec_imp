\set ON_ERROR_STOP on
BEGIN READ ONLY;
WITH items AS (
    SELECT 'PURCHASE_ITEM'::text AS source_kind,id,legacy_id,legacy_import_run_id,order_item_id,order_item_legacy_id
    FROM public.purchase_receipt_items WHERE legacy_import_run_id=:'run_id'::uuid
    UNION ALL
    SELECT 'SUBCONTRACT_ITEM',id,legacy_id,legacy_import_run_id,order_item_id,order_item_legacy_id
    FROM public.subcontract_receipt_items WHERE legacy_import_run_id=:'run_id'::uuid
)
SELECT item.source_kind,count(*) AS imported_items,
    count(*) FILTER(WHERE item.order_item_legacy_id>0) AS original_positive_order_ids,
    count(*) FILTER(WHERE item.order_item_legacy_id>0 AND item.order_item_id IS NULL) AS unresolved_original_orders,
    count(*) FILTER(WHERE proof.target_id IS NULL OR proof.source_legacy_id IS DISTINCT FROM item.legacy_id
        OR NOT ('order_item_legacy_id'=ANY(proof.target_fields))) AS missing_complete_new_field_proofs
FROM items item LEFT JOIN public.legacy_procurement_receipt_import_sources proof
    ON proof.run_id=item.legacy_import_run_id AND proof.target_id=item.id AND proof.source_kind=item.source_kind
GROUP BY item.source_kind ORDER BY item.source_kind;

-- IDs and immutable hashes only; no names, contacts or source remarks.
SELECT 'PURCHASE_ITEM' AS source_kind,item.legacy_id AS receipt_item_legacy_id,
    item.order_item_legacy_id,proof.target_id,proof.source_file,
    proof.source_row_sha256,proof.source_file_sha256
FROM public.purchase_receipt_items item JOIN public.legacy_procurement_receipt_import_sources proof
    ON proof.run_id=item.legacy_import_run_id AND proof.target_id=item.id
WHERE item.legacy_import_run_id=:'run_id'::uuid AND item.order_item_legacy_id>0 AND item.order_item_id IS NULL
UNION ALL
SELECT 'SUBCONTRACT_ITEM',item.legacy_id,item.order_item_legacy_id,proof.target_id,proof.source_file,
    proof.source_row_sha256,proof.source_file_sha256
FROM public.subcontract_receipt_items item JOIN public.legacy_procurement_receipt_import_sources proof
    ON proof.run_id=item.legacy_import_run_id AND proof.target_id=item.id
WHERE item.legacy_import_run_id=:'run_id'::uuid AND item.order_item_legacy_id>0 AND item.order_item_id IS NULL
ORDER BY source_kind,receipt_item_legacy_id;
ROLLBACK;

-- V263: preserve the goods identities displayed on historical subcontract documents.
--
-- goods_id, parent_goods_id and every upstream *_item_id remain UUID relations and
-- continue to drive business logic.  Snapshot columns are display/provenance data
-- only; renumbering or renaming goods must not rewrite approved subcontract history.

ALTER TABLE subcontract_inquiry_items
    ADD COLUMN goods_code_snapshot TEXT,
    ADD COLUMN goods_name_snapshot TEXT,
    ADD COLUMN goods_snapshot_source TEXT,
    ADD COLUMN goods_snapshot_locked_at TIMESTAMPTZ;

ALTER TABLE subcontract_application_items
    ADD COLUMN goods_code_snapshot TEXT,
    ADD COLUMN goods_name_snapshot TEXT,
    ADD COLUMN goods_snapshot_source TEXT,
    ADD COLUMN goods_snapshot_locked_at TIMESTAMPTZ;

ALTER TABLE subcontract_order_items
    ADD COLUMN goods_code_snapshot TEXT,
    ADD COLUMN goods_name_snapshot TEXT,
    ADD COLUMN goods_snapshot_source TEXT,
    ADD COLUMN goods_snapshot_locked_at TIMESTAMPTZ;

ALTER TABLE subcontract_receipt_items
    ADD COLUMN goods_code_snapshot TEXT,
    ADD COLUMN goods_name_snapshot TEXT,
    ADD COLUMN goods_snapshot_source TEXT,
    ADD COLUMN goods_snapshot_locked_at TIMESTAMPTZ;

ALTER TABLE subcontract_material_issue_items
    ADD COLUMN goods_code_snapshot TEXT,
    ADD COLUMN goods_name_snapshot TEXT,
    ADD COLUMN goods_snapshot_source TEXT,
    ADD COLUMN goods_snapshot_locked_at TIMESTAMPTZ,
    ADD COLUMN parent_goods_code_snapshot TEXT,
    ADD COLUMN parent_goods_name_snapshot TEXT,
    ADD COLUMN parent_goods_snapshot_source TEXT,
    ADD COLUMN parent_goods_snapshot_locked_at TIMESTAMPTZ;

ALTER TABLE subcontract_return_items
    ADD COLUMN goods_code_snapshot TEXT,
    ADD COLUMN goods_name_snapshot TEXT,
    ADD COLUMN goods_snapshot_source TEXT,
    ADD COLUMN goods_snapshot_locked_at TIMESTAMPTZ;

ALTER TABLE subcontract_material_return_items
    ADD COLUMN goods_code_snapshot TEXT,
    ADD COLUMN goods_name_snapshot TEXT,
    ADD COLUMN goods_snapshot_source TEXT,
    ADD COLUMN goods_snapshot_locked_at TIMESTAMPTZ,
    ADD COLUMN parent_goods_code_snapshot TEXT,
    ADD COLUMN parent_goods_name_snapshot TEXT,
    ADD COLUMN parent_goods_snapshot_source TEXT,
    ADD COLUMN parent_goods_snapshot_locked_at TIMESTAMPTZ;

ALTER TABLE subcontract_waste_items
    ADD COLUMN goods_code_snapshot TEXT,
    ADD COLUMN goods_name_snapshot TEXT,
    ADD COLUMN goods_snapshot_source TEXT,
    ADD COLUMN goods_snapshot_locked_at TIMESTAMPTZ;

ALTER TABLE subcontract_order_cost_items
    ADD COLUMN goods_code_snapshot TEXT,
    ADD COLUMN goods_name_snapshot TEXT,
    ADD COLUMN goods_snapshot_source TEXT,
    ADD COLUMN goods_snapshot_locked_at TIMESTAMPTZ,
    ADD COLUMN parent_goods_code_snapshot TEXT,
    ADD COLUMN parent_goods_name_snapshot TEXT,
    ADD COLUMN parent_goods_snapshot_source TEXT,
    ADD COLUMN parent_goods_snapshot_locked_at TIMESTAMPTZ;

-- Existing rows did not capture document-time labels.  Use the current master
-- value, but mark that limitation explicitly.  Existing non-draft documents are
-- frozen immediately; draft rows will be refreshed and frozen by approval code.
UPDATE subcontract_inquiry_items item
SET goods_code_snapshot = goods.code,
    goods_name_snapshot = goods.name,
    goods_snapshot_source = 'BACKFILL_V263',
    goods_snapshot_locked_at = CASE WHEN document.status <> 0 THEN now() ELSE NULL END
FROM goods, subcontract_inquiries document
WHERE goods.id = item.goods_id AND document.id = item.inquiry_id;

UPDATE subcontract_application_items item
SET goods_code_snapshot = goods.code,
    goods_name_snapshot = goods.name,
    goods_snapshot_source = 'BACKFILL_V263',
    goods_snapshot_locked_at = CASE WHEN document.status <> 0 THEN now() ELSE NULL END
FROM goods, subcontract_applications document
WHERE goods.id = item.goods_id AND document.id = item.application_id;

UPDATE subcontract_order_items item
SET goods_code_snapshot = goods.code,
    goods_name_snapshot = goods.name,
    goods_snapshot_source = 'BACKFILL_V263',
    goods_snapshot_locked_at = CASE WHEN document.status <> 0 THEN now() ELSE NULL END
FROM goods, subcontract_orders document
WHERE goods.id = item.goods_id AND document.id = item.order_id;

UPDATE subcontract_receipt_items item
SET goods_code_snapshot = goods.code,
    goods_name_snapshot = goods.name,
    goods_snapshot_source = 'BACKFILL_V263',
    goods_snapshot_locked_at = CASE WHEN document.status <> 0 THEN now() ELSE NULL END
FROM goods, subcontract_receipts document
WHERE goods.id = item.goods_id AND document.id = item.receipt_id;

UPDATE subcontract_material_issue_items item
SET goods_code_snapshot = goods.code,
    goods_name_snapshot = goods.name,
    goods_snapshot_source = 'BACKFILL_V263',
    goods_snapshot_locked_at = CASE WHEN document.status <> 0 THEN now() ELSE NULL END
FROM goods, subcontract_material_issues document
WHERE goods.id = item.goods_id AND document.id = item.issue_id;

UPDATE subcontract_return_items item
SET goods_code_snapshot = goods.code,
    goods_name_snapshot = goods.name,
    goods_snapshot_source = 'BACKFILL_V263',
    goods_snapshot_locked_at = CASE WHEN document.status <> 0 THEN now() ELSE NULL END
FROM goods, subcontract_returns document
WHERE goods.id = item.goods_id AND document.id = item.return_id;

UPDATE subcontract_material_return_items item
SET goods_code_snapshot = goods.code,
    goods_name_snapshot = goods.name,
    goods_snapshot_source = 'BACKFILL_V263',
    goods_snapshot_locked_at = CASE WHEN document.status <> 0 THEN now() ELSE NULL END
FROM goods, subcontract_material_returns document
WHERE goods.id = item.goods_id AND document.id = item.material_return_id;

UPDATE subcontract_waste_items item
SET goods_code_snapshot = goods.code,
    goods_name_snapshot = goods.name,
    goods_snapshot_source = 'BACKFILL_V263',
    goods_snapshot_locked_at = CASE WHEN document.status <> 0 THEN now() ELSE NULL END
FROM goods, subcontract_wastes document
WHERE goods.id = item.goods_id AND document.id = item.waste_id;

UPDATE subcontract_order_cost_items item
SET goods_code_snapshot = goods.code,
    goods_name_snapshot = goods.name,
    goods_snapshot_source = 'BACKFILL_V263',
    goods_snapshot_locked_at = CASE WHEN document.status <> 0 THEN now() ELSE NULL END
FROM goods, subcontract_orders document
WHERE goods.id = item.goods_id AND document.id = item.order_id;

-- Parent and child identities are deliberately separate.  A component code must
-- never be shown in the parent/finished-goods slot (or vice versa).
UPDATE subcontract_material_issue_items item
SET parent_goods_code_snapshot = goods.code,
    parent_goods_name_snapshot = goods.name,
    parent_goods_snapshot_source = 'BACKFILL_V263',
    parent_goods_snapshot_locked_at = CASE WHEN document.status <> 0 THEN now() ELSE NULL END
FROM goods, subcontract_material_issues document
WHERE goods.id = item.parent_goods_id AND document.id = item.issue_id;

UPDATE subcontract_material_return_items item
SET parent_goods_code_snapshot = goods.code,
    parent_goods_name_snapshot = goods.name,
    parent_goods_snapshot_source = 'BACKFILL_V263',
    parent_goods_snapshot_locked_at = CASE WHEN document.status <> 0 THEN now() ELSE NULL END
FROM goods, subcontract_material_returns document
WHERE goods.id = item.parent_goods_id AND document.id = item.material_return_id;

UPDATE subcontract_order_cost_items item
SET parent_goods_code_snapshot = goods.code,
    parent_goods_name_snapshot = goods.name,
    parent_goods_snapshot_source = 'BACKFILL_V263',
    parent_goods_snapshot_locked_at = CASE WHEN document.status <> 0 THEN now() ELSE NULL END
FROM goods, subcontract_orders document
WHERE goods.id = item.parent_goods_id AND document.id = item.order_id;

DO $constraints$
DECLARE
    table_name TEXT;
    source_values CONSTANT TEXT :=
        $$'BACKFILL_V263', 'LEGACY_IMPORT', 'MASTER_AT_SAVE', 'MASTER_AT_APPROVAL',
           'APPLICATION_ITEM_AT_SAVE', 'APPLICATION_ITEM_AT_APPROVAL',
           'ORDER_ITEM_AT_SAVE', 'ORDER_ITEM_AT_APPROVAL',
           'RECEIPT_ITEM_AT_SAVE', 'RECEIPT_ITEM_AT_APPROVAL',
           'MATERIAL_ISSUE_ITEM_AT_SAVE', 'MATERIAL_ISSUE_ITEM_AT_APPROVAL'$$;
BEGIN
    FOREACH table_name IN ARRAY ARRAY[
        'subcontract_inquiry_items',
        'subcontract_application_items',
        'subcontract_order_items',
        'subcontract_receipt_items',
        'subcontract_material_issue_items',
        'subcontract_return_items',
        'subcontract_material_return_items',
        'subcontract_waste_items',
        'subcontract_order_cost_items'
    ] LOOP
        EXECUTE format('ALTER TABLE %I ALTER COLUMN goods_snapshot_source SET NOT NULL', table_name);
        EXECUTE format(
            'ALTER TABLE %I ADD CONSTRAINT %I CHECK (goods_snapshot_source IN (%s))',
            table_name,
            'ck_' || table_name || '_goods_snapshot_source',
            source_values);
    END LOOP;
END
$constraints$;

ALTER TABLE subcontract_material_issue_items
    ADD CONSTRAINT ck_subcontract_material_issue_items_parent_goods_snapshot CHECK (
        (parent_goods_id IS NULL
            AND parent_goods_code_snapshot IS NULL
            AND parent_goods_name_snapshot IS NULL
            AND parent_goods_snapshot_source IS NULL
            AND parent_goods_snapshot_locked_at IS NULL)
        OR
        (parent_goods_id IS NOT NULL
            AND parent_goods_snapshot_source IN (
                'BACKFILL_V263', 'LEGACY_IMPORT', 'MASTER_AT_SAVE', 'MASTER_AT_APPROVAL',
                'ORDER_ITEM_AT_SAVE', 'ORDER_ITEM_AT_APPROVAL'))
    );

ALTER TABLE subcontract_material_return_items
    ADD CONSTRAINT ck_subcontract_material_return_items_parent_goods_snapshot CHECK (
        (parent_goods_id IS NULL
            AND parent_goods_code_snapshot IS NULL
            AND parent_goods_name_snapshot IS NULL
            AND parent_goods_snapshot_source IS NULL
            AND parent_goods_snapshot_locked_at IS NULL)
        OR
        (parent_goods_id IS NOT NULL
            AND parent_goods_snapshot_source IN (
                'BACKFILL_V263', 'LEGACY_IMPORT', 'MASTER_AT_SAVE', 'MASTER_AT_APPROVAL',
                'ORDER_ITEM_AT_SAVE', 'ORDER_ITEM_AT_APPROVAL',
                'MATERIAL_ISSUE_ITEM_AT_SAVE', 'MATERIAL_ISSUE_ITEM_AT_APPROVAL'))
    );

ALTER TABLE subcontract_order_cost_items
    ADD CONSTRAINT ck_subcontract_order_cost_items_parent_goods_snapshot CHECK (
        (parent_goods_id IS NULL
            AND parent_goods_code_snapshot IS NULL
            AND parent_goods_name_snapshot IS NULL
            AND parent_goods_snapshot_source IS NULL
            AND parent_goods_snapshot_locked_at IS NULL)
        OR
        (parent_goods_id IS NOT NULL
            AND parent_goods_snapshot_source IN (
                'BACKFILL_V263', 'LEGACY_IMPORT', 'MASTER_AT_SAVE', 'MASTER_AT_APPROVAL'))
    );

COMMENT ON COLUMN subcontract_order_items.goods_snapshot_source IS
    'Snapshot provenance; linked order lines inherit the application-item label.';
COMMENT ON COLUMN subcontract_receipt_items.goods_snapshot_source IS
    'Snapshot provenance; linked receipt lines inherit the order-item label.';
COMMENT ON COLUMN subcontract_return_items.goods_snapshot_source IS
    'Snapshot provenance; returns prefer receipt item, then order item, then master.';
COMMENT ON COLUMN subcontract_material_issue_items.goods_snapshot_source IS
    'Component-goods snapshot provenance; parent goods has a separate snapshot quartet.';
COMMENT ON COLUMN subcontract_material_return_items.goods_snapshot_source IS
    'Returned-component snapshot provenance; linked material issue is authoritative.';
COMMENT ON COLUMN subcontract_order_cost_items.goods_snapshot_source IS
    'BOM child-goods snapshot provenance; parent goods has a separate snapshot quartet.';

-- The old monthly MV grouped by goods UUID only, which would merge rows from
-- before and after a renumber/rename.  Rebuild it with the frozen identity as
-- part of the grain.  The UUID remains present for drill-through and relations.
DROP MATERIALIZED VIEW IF EXISTS subcontract_monthly_mv;

CREATE MATERIALIZED VIEW subcontract_monthly_mv AS
SELECT 'INQUIRY'::TEXT AS doc_type,
       date_trunc('month', item.bill_date)::DATE AS ym,
       item.goods_id, item.goods_code_snapshot, item.goods_name_snapshot,
       COALESCE(document.supplier_id, '00000000-0000-0000-0000-000000000000'::UUID) AS supplier_id,
       COALESCE(document.currency_id, '00000000-0000-0000-0000-000000000000'::UUID) AS currency_id,
       SUM(item.qty) AS qty_sum, SUM(item.amount_local) AS amt_local,
       SUM(item.amount_original) AS amt_original, COUNT(*) AS line_cnt
FROM subcontract_inquiry_items item
JOIN subcontract_inquiries document ON document.id = item.inquiry_id
WHERE item.is_deleted = FALSE AND document.is_deleted = FALSE AND document.status = 1
GROUP BY 1, 2, item.goods_id, item.goods_code_snapshot, item.goods_name_snapshot,
         document.supplier_id, document.currency_id
UNION ALL
SELECT 'APPLICATION'::TEXT, date_trunc('month', item.bill_date)::DATE,
       item.goods_id, item.goods_code_snapshot, item.goods_name_snapshot,
       COALESCE(document.supplier_id, '00000000-0000-0000-0000-000000000000'::UUID),
       '00000000-0000-0000-0000-000000000000'::UUID,
       SUM(item.qty), SUM(item.amount_local), SUM(item.amount_original), COUNT(*)
FROM subcontract_application_items item
JOIN subcontract_applications document ON document.id = item.application_id
WHERE item.is_deleted = FALSE AND document.is_deleted = FALSE AND document.status = 1
GROUP BY 1, 2, item.goods_id, item.goods_code_snapshot, item.goods_name_snapshot,
         document.supplier_id
UNION ALL
SELECT 'ORDER'::TEXT, date_trunc('month', item.bill_date)::DATE,
       item.goods_id, item.goods_code_snapshot, item.goods_name_snapshot,
       COALESCE(document.supplier_id, '00000000-0000-0000-0000-000000000000'::UUID),
       COALESCE(document.currency_id, '00000000-0000-0000-0000-000000000000'::UUID),
       SUM(item.qty), SUM(item.amount_local), SUM(item.amount_original), COUNT(*)
FROM subcontract_order_items item
JOIN subcontract_orders document ON document.id = item.order_id
WHERE item.is_deleted = FALSE AND document.is_deleted = FALSE AND document.status = 1
GROUP BY 1, 2, item.goods_id, item.goods_code_snapshot, item.goods_name_snapshot,
         document.supplier_id, document.currency_id
UNION ALL
SELECT 'RECEIPT'::TEXT, date_trunc('month', item.bill_date)::DATE,
       item.goods_id, item.goods_code_snapshot, item.goods_name_snapshot,
       COALESCE(document.supplier_id, '00000000-0000-0000-0000-000000000000'::UUID),
       COALESCE(document.currency_id, '00000000-0000-0000-0000-000000000000'::UUID),
       SUM(item.qty), SUM(item.amount_local), SUM(item.amount_original), COUNT(*)
FROM subcontract_receipt_items item
JOIN subcontract_receipts document ON document.id = item.receipt_id
WHERE item.is_deleted = FALSE AND document.is_deleted = FALSE AND document.status = 1
GROUP BY 1, 2, item.goods_id, item.goods_code_snapshot, item.goods_name_snapshot,
         document.supplier_id, document.currency_id
UNION ALL
SELECT 'RETURN'::TEXT, date_trunc('month', item.bill_date)::DATE,
       item.goods_id, item.goods_code_snapshot, item.goods_name_snapshot,
       COALESCE(document.supplier_id, '00000000-0000-0000-0000-000000000000'::UUID),
       COALESCE(document.currency_id, '00000000-0000-0000-0000-000000000000'::UUID),
       SUM(item.qty), SUM(item.amount_local), SUM(item.amount_original), COUNT(*)
FROM subcontract_return_items item
JOIN subcontract_returns document ON document.id = item.return_id
WHERE item.is_deleted = FALSE AND document.is_deleted = FALSE AND document.status = 1
GROUP BY 1, 2, item.goods_id, item.goods_code_snapshot, item.goods_name_snapshot,
         document.supplier_id, document.currency_id
UNION ALL
SELECT 'MATERIAL_ISSUE'::TEXT, date_trunc('month', item.bill_date)::DATE,
       item.goods_id, item.goods_code_snapshot, item.goods_name_snapshot,
       COALESCE(document.supplier_id, '00000000-0000-0000-0000-000000000000'::UUID),
       '00000000-0000-0000-0000-000000000000'::UUID,
       SUM(item.qty), SUM(item.amount_local), SUM(item.amount_local), COUNT(*)
FROM subcontract_material_issue_items item
JOIN subcontract_material_issues document ON document.id = item.issue_id
WHERE item.is_deleted = FALSE AND document.is_deleted = FALSE AND document.status = 1
GROUP BY 1, 2, item.goods_id, item.goods_code_snapshot, item.goods_name_snapshot,
         document.supplier_id
UNION ALL
SELECT 'MATERIAL_RETURN'::TEXT, date_trunc('month', item.bill_date)::DATE,
       item.goods_id, item.goods_code_snapshot, item.goods_name_snapshot,
       COALESCE(document.supplier_id, '00000000-0000-0000-0000-000000000000'::UUID),
       '00000000-0000-0000-0000-000000000000'::UUID,
       SUM(item.qty), SUM(item.amount_local), SUM(item.amount_local), COUNT(*)
FROM subcontract_material_return_items item
JOIN subcontract_material_returns document ON document.id = item.material_return_id
WHERE item.is_deleted = FALSE AND document.is_deleted = FALSE AND document.status = 1
GROUP BY 1, 2, item.goods_id, item.goods_code_snapshot, item.goods_name_snapshot,
         document.supplier_id
UNION ALL
SELECT 'WASTE'::TEXT, date_trunc('month', item.bill_date)::DATE,
       item.goods_id, item.goods_code_snapshot, item.goods_name_snapshot,
       COALESCE(document.supplier_id, '00000000-0000-0000-0000-000000000000'::UUID),
       '00000000-0000-0000-0000-000000000000'::UUID,
       SUM(item.qty), SUM(item.amount_local), SUM(item.amount_local), COUNT(*)
FROM subcontract_waste_items item
JOIN subcontract_wastes document ON document.id = item.waste_id
WHERE item.is_deleted = FALSE AND document.is_deleted = FALSE AND document.status = 1
GROUP BY 1, 2, item.goods_id, item.goods_code_snapshot, item.goods_name_snapshot,
         document.supplier_id;

CREATE UNIQUE INDEX mv_subcontract_monthly_uidx
    ON subcontract_monthly_mv (
        doc_type, ym, goods_id,
        goods_code_snapshot, goods_name_snapshot,
        supplier_id, currency_id) NULLS NOT DISTINCT;
CREATE INDEX mv_subcontract_monthly_goods ON subcontract_monthly_mv (goods_id);
CREATE INDEX mv_subcontract_monthly_supplier ON subcontract_monthly_mv (supplier_id);
CREATE INDEX mv_subcontract_monthly_ym ON subcontract_monthly_mv (ym);
CREATE INDEX mv_subcontract_monthly_type ON subcontract_monthly_mv (doc_type);

COMMENT ON MATERIALIZED VIEW subcontract_monthly_mv IS
    'Subcontract monthly totals grouped by goods UUID and frozen code/name era.';

-- V257: preserve the goods code/name shown on historical sales documents.
--
-- Business relations continue to use goods_id UUID foreign keys. These columns are
-- display snapshots only: renumbering or renaming goods must not rewrite approved
-- order, shipment, other-shipment, or return history.

ALTER TABLE sales_order_items
    ADD COLUMN goods_code_snapshot TEXT,
    ADD COLUMN goods_name_snapshot TEXT,
    ADD COLUMN goods_snapshot_source TEXT,
    ADD COLUMN goods_snapshot_locked_at TIMESTAMPTZ;

ALTER TABLE sales_shipment_items
    ADD COLUMN goods_code_snapshot TEXT,
    ADD COLUMN goods_name_snapshot TEXT,
    ADD COLUMN goods_snapshot_source TEXT,
    ADD COLUMN goods_snapshot_locked_at TIMESTAMPTZ;

ALTER TABLE sales_other_shipment_items
    ADD COLUMN goods_code_snapshot TEXT,
    ADD COLUMN goods_name_snapshot TEXT,
    ADD COLUMN goods_snapshot_source TEXT,
    ADD COLUMN goods_snapshot_locked_at TIMESTAMPTZ;

ALTER TABLE sales_return_items
    ADD COLUMN goods_code_snapshot TEXT,
    ADD COLUMN goods_name_snapshot TEXT,
    ADD COLUMN goods_snapshot_source TEXT,
    ADD COLUMN goods_snapshot_locked_at TIMESTAMPTZ;

-- Existing rows did not capture a contemporaneous value. Backfill the current
-- master value, but mark that provenance explicitly instead of presenting it as
-- an original document-time fact. Non-draft documents are frozen immediately.
UPDATE sales_order_items item
SET goods_code_snapshot = goods.code,
    goods_name_snapshot = goods.name,
    goods_snapshot_source = 'BACKFILL_V257',
    goods_snapshot_locked_at = CASE WHEN document.status <> 0 THEN now() ELSE NULL END
FROM goods, sales_orders document
WHERE goods.id = item.goods_id
  AND document.id = item.order_id;

UPDATE sales_shipment_items item
SET goods_code_snapshot = goods.code,
    goods_name_snapshot = goods.name,
    goods_snapshot_source = 'BACKFILL_V257',
    goods_snapshot_locked_at = CASE WHEN document.status <> 0 THEN now() ELSE NULL END
FROM goods, sales_shipments document
WHERE goods.id = item.goods_id
  AND document.id = item.shipment_id;

UPDATE sales_other_shipment_items item
SET goods_code_snapshot = goods.code,
    goods_name_snapshot = goods.name,
    goods_snapshot_source = 'BACKFILL_V257',
    goods_snapshot_locked_at = CASE WHEN document.status <> 0 THEN now() ELSE NULL END
FROM goods, sales_other_shipments document
WHERE goods.id = item.goods_id
  AND document.id = item.shipment_id;

UPDATE sales_return_items item
SET goods_code_snapshot = goods.code,
    goods_name_snapshot = goods.name,
    goods_snapshot_source = 'BACKFILL_V257',
    goods_snapshot_locked_at = CASE WHEN document.status <> 0 THEN now() ELSE NULL END
FROM goods, sales_returns document
WHERE goods.id = item.goods_id
  AND document.id = item.return_id;

ALTER TABLE sales_order_items
    ALTER COLUMN goods_snapshot_source SET NOT NULL,
    ADD CONSTRAINT ck_sales_order_items_goods_snapshot_source CHECK (
        goods_snapshot_source IN (
            'BACKFILL_V257', 'LEGACY_IMPORT', 'MASTER_AT_SAVE', 'MASTER_AT_APPROVAL',
            'ORDER_ITEM_AT_SAVE', 'ORDER_ITEM_AT_APPROVAL',
            'SHIPMENT_ITEM_AT_SAVE', 'SHIPMENT_ITEM_AT_APPROVAL'
        )
    );

ALTER TABLE sales_shipment_items
    ALTER COLUMN goods_snapshot_source SET NOT NULL,
    ADD CONSTRAINT ck_sales_shipment_items_goods_snapshot_source CHECK (
        goods_snapshot_source IN (
            'BACKFILL_V257', 'LEGACY_IMPORT', 'MASTER_AT_SAVE', 'MASTER_AT_APPROVAL',
            'ORDER_ITEM_AT_SAVE', 'ORDER_ITEM_AT_APPROVAL',
            'SHIPMENT_ITEM_AT_SAVE', 'SHIPMENT_ITEM_AT_APPROVAL'
        )
    );

ALTER TABLE sales_other_shipment_items
    ALTER COLUMN goods_snapshot_source SET NOT NULL,
    ADD CONSTRAINT ck_sales_other_shipment_items_goods_snapshot_source CHECK (
        goods_snapshot_source IN (
            'BACKFILL_V257', 'LEGACY_IMPORT', 'MASTER_AT_SAVE', 'MASTER_AT_APPROVAL',
            'ORDER_ITEM_AT_SAVE', 'ORDER_ITEM_AT_APPROVAL',
            'SHIPMENT_ITEM_AT_SAVE', 'SHIPMENT_ITEM_AT_APPROVAL'
        )
    );

ALTER TABLE sales_return_items
    ALTER COLUMN goods_snapshot_source SET NOT NULL,
    ADD CONSTRAINT ck_sales_return_items_goods_snapshot_source CHECK (
        goods_snapshot_source IN (
            'BACKFILL_V257', 'LEGACY_IMPORT', 'MASTER_AT_SAVE', 'MASTER_AT_APPROVAL',
            'ORDER_ITEM_AT_SAVE', 'ORDER_ITEM_AT_APPROVAL',
            'SHIPMENT_ITEM_AT_SAVE', 'SHIPMENT_ITEM_AT_APPROVAL'
        )
    );

COMMENT ON COLUMN sales_order_items.goods_snapshot_source IS
    'Snapshot provenance. BACKFILL_V257 is a migration-time master value, not an original document-time fact.';
COMMENT ON COLUMN sales_order_items.goods_snapshot_locked_at IS
    'Non-null once approval freezes the goods code/name snapshot.';
COMMENT ON COLUMN sales_shipment_items.goods_snapshot_source IS
    'Snapshot provenance; linked shipments inherit the approved sales-order item snapshot.';
COMMENT ON COLUMN sales_other_shipment_items.goods_snapshot_source IS
    'Snapshot provenance; linked rows prefer their sales-order item snapshot.';
COMMENT ON COLUMN sales_return_items.goods_snapshot_source IS
    'Snapshot provenance; returns prefer shipment item, then order item, then goods master.';

-- V260: preserve the goods code/name shown on historical purchase documents.
--
-- Business relations continue to use goods_id UUID foreign keys. These columns
-- are display snapshots only: renumbering or renaming goods must not rewrite
-- approved request, order, receipt, or return history.

ALTER TABLE purchase_request_items
    ADD COLUMN goods_code_snapshot TEXT,
    ADD COLUMN goods_name_snapshot TEXT,
    ADD COLUMN goods_snapshot_source TEXT,
    ADD COLUMN goods_snapshot_locked_at TIMESTAMPTZ;

ALTER TABLE purchase_order_items
    ADD COLUMN goods_code_snapshot TEXT,
    ADD COLUMN goods_name_snapshot TEXT,
    ADD COLUMN goods_snapshot_source TEXT,
    ADD COLUMN goods_snapshot_locked_at TIMESTAMPTZ;

ALTER TABLE purchase_receipt_items
    ADD COLUMN goods_code_snapshot TEXT,
    ADD COLUMN goods_name_snapshot TEXT,
    ADD COLUMN goods_snapshot_source TEXT,
    ADD COLUMN goods_snapshot_locked_at TIMESTAMPTZ;

ALTER TABLE purchase_return_items
    ADD COLUMN goods_code_snapshot TEXT,
    ADD COLUMN goods_name_snapshot TEXT,
    ADD COLUMN goods_snapshot_source TEXT,
    ADD COLUMN goods_snapshot_locked_at TIMESTAMPTZ;

-- Existing rows did not capture a contemporaneous value. Backfill the current
-- master value, but mark that provenance explicitly instead of presenting it as
-- an original document-time fact. Non-draft documents are frozen immediately.
UPDATE purchase_request_items item
SET goods_code_snapshot = goods.code,
    goods_name_snapshot = goods.name,
    goods_snapshot_source = 'BACKFILL_V260',
    goods_snapshot_locked_at = CASE WHEN document.status <> 0 THEN now() ELSE NULL END
FROM goods, purchase_requests document
WHERE goods.id = item.goods_id
  AND document.id = item.request_id;

UPDATE purchase_order_items item
SET goods_code_snapshot = goods.code,
    goods_name_snapshot = goods.name,
    goods_snapshot_source = 'BACKFILL_V260',
    goods_snapshot_locked_at = CASE WHEN document.status <> 0 THEN now() ELSE NULL END
FROM goods, purchase_orders document
WHERE goods.id = item.goods_id
  AND document.id = item.order_id;

UPDATE purchase_receipt_items item
SET goods_code_snapshot = goods.code,
    goods_name_snapshot = goods.name,
    goods_snapshot_source = 'BACKFILL_V260',
    goods_snapshot_locked_at = CASE WHEN document.status <> 0 THEN now() ELSE NULL END
FROM goods, purchase_receipts document
WHERE goods.id = item.goods_id
  AND document.id = item.receipt_id;

UPDATE purchase_return_items item
SET goods_code_snapshot = goods.code,
    goods_name_snapshot = goods.name,
    goods_snapshot_source = 'BACKFILL_V260',
    goods_snapshot_locked_at = CASE WHEN document.status <> 0 THEN now() ELSE NULL END
FROM goods, purchase_returns document
WHERE goods.id = item.goods_id
  AND document.id = item.return_id;

-- purchase_order_items and purchase_receipt_items have unconditional deferred
-- provenance constraint triggers.  Their backfill events must be evaluated
-- before ALTER TABLE takes stronger locks on the same relations.  This executes
-- the guards early; it does not disable or bypass them.
SET CONSTRAINTS ALL IMMEDIATE;

ALTER TABLE purchase_request_items
    ALTER COLUMN goods_snapshot_source SET NOT NULL,
    ADD CONSTRAINT ck_purchase_request_items_goods_snapshot_source CHECK (
        goods_snapshot_source IN (
            'BACKFILL_V260', 'LEGACY_IMPORT', 'MASTER_AT_SAVE', 'MASTER_AT_APPROVAL',
            'REQUEST_ITEM_AT_SAVE', 'REQUEST_ITEM_AT_APPROVAL',
            'ORDER_ITEM_AT_SAVE', 'ORDER_ITEM_AT_APPROVAL',
            'RECEIPT_ITEM_AT_SAVE', 'RECEIPT_ITEM_AT_APPROVAL'
        )
    );

ALTER TABLE purchase_order_items
    ALTER COLUMN goods_snapshot_source SET NOT NULL,
    ADD CONSTRAINT ck_purchase_order_items_goods_snapshot_source CHECK (
        goods_snapshot_source IN (
            'BACKFILL_V260', 'LEGACY_IMPORT', 'MASTER_AT_SAVE', 'MASTER_AT_APPROVAL',
            'REQUEST_ITEM_AT_SAVE', 'REQUEST_ITEM_AT_APPROVAL',
            'ORDER_ITEM_AT_SAVE', 'ORDER_ITEM_AT_APPROVAL',
            'RECEIPT_ITEM_AT_SAVE', 'RECEIPT_ITEM_AT_APPROVAL'
        )
    );

ALTER TABLE purchase_receipt_items
    ALTER COLUMN goods_snapshot_source SET NOT NULL,
    ADD CONSTRAINT ck_purchase_receipt_items_goods_snapshot_source CHECK (
        goods_snapshot_source IN (
            'BACKFILL_V260', 'LEGACY_IMPORT', 'MASTER_AT_SAVE', 'MASTER_AT_APPROVAL',
            'REQUEST_ITEM_AT_SAVE', 'REQUEST_ITEM_AT_APPROVAL',
            'ORDER_ITEM_AT_SAVE', 'ORDER_ITEM_AT_APPROVAL',
            'RECEIPT_ITEM_AT_SAVE', 'RECEIPT_ITEM_AT_APPROVAL'
        )
    );

ALTER TABLE purchase_return_items
    ALTER COLUMN goods_snapshot_source SET NOT NULL,
    ADD CONSTRAINT ck_purchase_return_items_goods_snapshot_source CHECK (
        goods_snapshot_source IN (
            'BACKFILL_V260', 'LEGACY_IMPORT', 'MASTER_AT_SAVE', 'MASTER_AT_APPROVAL',
            'REQUEST_ITEM_AT_SAVE', 'REQUEST_ITEM_AT_APPROVAL',
            'ORDER_ITEM_AT_SAVE', 'ORDER_ITEM_AT_APPROVAL',
            'RECEIPT_ITEM_AT_SAVE', 'RECEIPT_ITEM_AT_APPROVAL'
        )
    );

COMMENT ON COLUMN purchase_request_items.goods_snapshot_source IS
    'Snapshot provenance. BACKFILL_V260 is a migration-time master value, not an original document-time fact.';
COMMENT ON COLUMN purchase_request_items.goods_snapshot_locked_at IS
    'Non-null once approval freezes the goods code/name snapshot.';
COMMENT ON COLUMN purchase_order_items.goods_snapshot_source IS
    'Snapshot provenance; linked orders prefer their purchase-request item snapshot.';
COMMENT ON COLUMN purchase_receipt_items.goods_snapshot_source IS
    'Snapshot provenance; linked receipts prefer their purchase-order item snapshot.';
COMMENT ON COLUMN purchase_return_items.goods_snapshot_source IS
    'Snapshot provenance; returns prefer receipt item, then order item, then goods master.';

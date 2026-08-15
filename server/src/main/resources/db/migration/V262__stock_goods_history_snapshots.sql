-- V262: preserve the goods code/name shown on historical stock documents.
--
-- Business relations continue to use goods_id UUID foreign keys. These columns
-- are display snapshots only: renumbering or renaming goods must not rewrite
-- approved transfer, inbound, outbound, material, finished-goods, or count history.

ALTER TABLE stock_document_items
    ADD COLUMN goods_code_snapshot TEXT,
    ADD COLUMN goods_name_snapshot TEXT,
    ADD COLUMN goods_snapshot_source TEXT,
    ADD COLUMN goods_snapshot_locked_at TIMESTAMPTZ;

-- Existing rows did not capture a contemporaneous value. Backfill the current
-- master value, but mark that provenance explicitly instead of presenting it as
-- an original document-time fact. Non-draft documents are frozen immediately.
UPDATE stock_document_items item
SET goods_code_snapshot = goods.code,
    goods_name_snapshot = goods.name,
    goods_snapshot_source = 'BACKFILL_V262',
    goods_snapshot_locked_at = CASE WHEN document.status <> 0 THEN now() ELSE NULL END
FROM goods, stock_documents document
WHERE goods.id = item.goods_id
  AND document.id = item.doc_id;

-- stock_document_items is protected by several deferred provenance/conservation
-- constraint triggers.  Evaluate the queued backfill events before ALTER TABLE
-- touches the relation again; the guards still fail closed on any violation.
SET CONSTRAINTS ALL IMMEDIATE;

ALTER TABLE stock_document_items
    ALTER COLUMN goods_snapshot_source SET NOT NULL,
    ADD CONSTRAINT ck_stock_document_items_goods_snapshot_source CHECK (
        goods_snapshot_source IN (
            'BACKFILL_V262', 'LEGACY_IMPORT',
            'MASTER_AT_SAVE', 'MASTER_AT_APPROVAL'
        )
    );

COMMENT ON COLUMN stock_document_items.goods_snapshot_source IS
    'Snapshot provenance. BACKFILL_V262 is a migration-time master value, not an original document-time fact.';
COMMENT ON COLUMN stock_document_items.goods_snapshot_locked_at IS
    'Non-null once approval freezes the goods code/name snapshot.';

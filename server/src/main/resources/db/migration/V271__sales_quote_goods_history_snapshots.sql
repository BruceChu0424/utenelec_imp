-- V271: freeze goods identity labels on sales quotations.
--
-- goods_id remains the only business relationship. These columns are display
-- snapshots so category-prefix renumbering cannot rewrite an approved quote.

ALTER TABLE sales_quote_items
    ADD COLUMN goods_code_snapshot TEXT,
    ADD COLUMN goods_name_snapshot TEXT,
    ADD COLUMN goods_snapshot_source TEXT,
    ADD COLUMN goods_snapshot_locked_at TIMESTAMPTZ;

UPDATE sales_quote_items item
SET goods_code_snapshot = goods.code,
    goods_name_snapshot = goods.name,
    goods_snapshot_source = 'BACKFILL_V271',
    goods_snapshot_locked_at = CASE WHEN document.status <> 0 THEN now() ELSE NULL END
FROM goods, sales_quotes document
WHERE goods.id = item.goods_id
  AND document.id = item.quote_id;

ALTER TABLE sales_quote_items
    ALTER COLUMN goods_snapshot_source SET NOT NULL,
    ADD CONSTRAINT ck_sales_quote_items_goods_snapshot_source CHECK (
        goods_snapshot_source IN (
            'BACKFILL_V271', 'LEGACY_IMPORT', 'MASTER_AT_SAVE', 'MASTER_AT_APPROVAL'
        )
    );

COMMENT ON COLUMN sales_quote_items.goods_snapshot_source IS
    'Display snapshot provenance. BACKFILL_V271 is a migration-time master value, not an original quote-time fact.';
COMMENT ON COLUMN sales_quote_items.goods_snapshot_locked_at IS
    'Non-null once quotation approval freezes the goods code/name snapshot.';

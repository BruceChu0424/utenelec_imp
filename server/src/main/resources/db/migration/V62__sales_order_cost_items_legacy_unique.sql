-- =====================================================================
-- V62: sales_return_items missing columns + cost_items unique legacy_id
-- =====================================================================
-- Two V51 gaps surfaced when running migrate_sales.sql:
--
-- 1) sales_return_items is missing parcel_qty / carton_count. The migrate
--    SQL maps S_WithdrawItem.KQTY (件数) and Boxs (箱数) to these columns
--    (the same mapping the ship/oship item tables already use). V51 added
--    them to sales_shipment_items / sales_other_shipment_items but skipped
--    the return-items table.
--
-- 2) sales_order_cost_items.legacy_id has only a non-unique idx_soci_legacy
--    but migrate_sales.sql uses `INSERT ... ON CONFLICT (legacy_id) DO
--    NOTHING` for idempotent re-runs. Without a UNIQUE constraint PG errors
--    "no unique or exclusion constraint matching the ON CONFLICT specification".
--
-- Both changes are additive (column adds + NULLable UNIQUE) — safe on a DB
-- where V51 has already been applied. legacy_id remains nullable; PG UNIQUE
-- allows multiple NULLs.
-- =====================================================================

ALTER TABLE sales_return_items
    ADD COLUMN IF NOT EXISTS parcel_qty   NUMERIC(18,4),
    ADD COLUMN IF NOT EXISTS carton_count NUMERIC(18,4);

ALTER TABLE sales_order_cost_items
    DROP CONSTRAINT IF EXISTS sales_order_cost_items_legacy_id_key;
ALTER TABLE sales_order_cost_items
    ADD CONSTRAINT sales_order_cost_items_legacy_id_key UNIQUE (legacy_id);

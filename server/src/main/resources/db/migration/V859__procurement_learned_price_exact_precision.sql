-- Remembered prices must retain the same 14 integer / 10 fractional digits as
-- FinancialExactAmount.unitPrice. Widen only; never reconstruct rounded history.
-- The existing helper preserves dependent views, triggers, grants and owners.
SELECT fn_migrate_financial_amount_columns('[
  {"table":"goods","column":"default_purchase_price"},
  {"table":"goods","column":"default_subcontract_price"}
]'::jsonb);

ALTER TABLE goods
    ADD CONSTRAINT ck_goods_default_purchase_price_precision CHECK (
        default_purchase_price IS NULL OR (abs(default_purchase_price)<100000000000000
            AND scale(trim_scale(default_purchase_price))<=10)),
    ADD CONSTRAINT ck_goods_default_subcontract_price_precision CHECK (
        default_subcontract_price IS NULL OR (abs(default_subcontract_price)<100000000000000
            AND scale(trim_scale(default_subcontract_price))<=10));

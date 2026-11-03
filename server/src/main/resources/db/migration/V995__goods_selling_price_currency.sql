-- The master selling price has no historical currency evidence. Do not infer
-- it from purchasing prices, a customer's currency, or the functional currency.
ALTER TABLE goods ADD COLUMN currency_id uuid REFERENCES currencies(id);
COMMENT ON COLUMN goods.currency_id IS 'Currency of goods.price; NULL means not registered. Never inferred from procurement or base currency.';
CREATE INDEX idx_goods_currency_id ON goods(currency_id) WHERE NOT is_deleted;

-- Extend the existing history compatibility authority (V903/V906). Missing
-- currency keys compare as the new NULL default; evidence and tokens stay raw.
-- A later non-null currency still breaks CAS even without a version increment.
CREATE OR REPLACE FUNCTION fn_goods_bom_history_schema(p_row JSONB,p_table TEXT) RETURNS JSONB
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN p_row IS NULL THEN NULL
        WHEN p_table='goods' THEN jsonb_build_object('client_goods_name',NULL,'currency_id',NULL)||p_row
        WHEN p_table='goods_bom_items' THEN
            jsonb_build_object('retirement_reason',NULL,'retirement_resolved_at',NULL)||p_row
        ELSE p_row END
$$;

-- V620: preserve the commercial dimensions of learned procurement prices.
-- Existing numeric defaults remain intact. Their original unit/currency/vendor cannot
-- be proven, so leave context NULL and require a new explicit order save before prefill.
-- No historical order, inventory quantity or monetary amount is rewritten.
ALTER TABLE goods
    ADD COLUMN default_purchase_price_supplier_id UUID REFERENCES suppliers(id) ON DELETE RESTRICT,
    ADD COLUMN default_purchase_price_color_id UUID REFERENCES colors(id) ON DELETE RESTRICT,
    ADD COLUMN default_purchase_price_unit_id UUID REFERENCES units(id) ON DELETE RESTRICT,
    ADD COLUMN default_purchase_price_currency_id UUID REFERENCES currencies(id) ON DELETE RESTRICT,
    ADD COLUMN default_purchase_price_tax_rate NUMERIC(18, 4),
    ADD COLUMN default_subcontract_price_supplier_id UUID REFERENCES suppliers(id) ON DELETE RESTRICT,
    ADD COLUMN default_subcontract_price_color_id UUID REFERENCES colors(id) ON DELETE RESTRICT,
    ADD COLUMN default_subcontract_price_unit_id UUID REFERENCES units(id) ON DELETE RESTRICT,
    ADD COLUMN default_subcontract_price_currency_id UUID REFERENCES currencies(id) ON DELETE RESTRICT,
    ADD COLUMN default_subcontract_price_tax_rate NUMERIC(18, 4);

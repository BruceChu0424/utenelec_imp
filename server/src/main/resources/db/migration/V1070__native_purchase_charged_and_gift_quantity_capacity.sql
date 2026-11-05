-- Retain V843's charged/free identities and positivity rules. Native finite
-- quantities now use the shared 40-integer/24-fraction capacity for their whole
-- physical sum, rather than the former NUMERIC(18,4) fourteen-digit ceiling.
-- The original recorded-history branch and all existing rows remain unchanged.
ALTER TABLE purchase_request_items DROP CONSTRAINT purchase_request_items_gift_semantics_qty_chk;
ALTER TABLE purchase_request_items ADD CONSTRAINT purchase_request_items_gift_semantics_qty_chk CHECK (
    quantity_semantics='LEGACY_RECORDED' OR
    (qty>=0 AND gift_qty>=0 AND qty+gift_qty>0 AND fn_financial_amount_is_exact(qty+gift_qty)));

ALTER TABLE purchase_order_items DROP CONSTRAINT purchase_order_items_gift_semantics_qty_chk;
ALTER TABLE purchase_order_items ADD CONSTRAINT purchase_order_items_gift_semantics_qty_chk CHECK (
    quantity_semantics='LEGACY_RECORDED' OR
    (qty>=0 AND gift_qty>=0 AND qty+gift_qty>0 AND fn_financial_amount_is_exact(qty+gift_qty)));

ALTER TABLE purchase_receipt_items DROP CONSTRAINT purchase_receipt_items_gift_semantics_qty_chk;
ALTER TABLE purchase_receipt_items ADD CONSTRAINT purchase_receipt_items_gift_semantics_qty_chk CHECK (
    quantity_semantics='LEGACY_RECORDED' OR
    (qty>=0 AND gift_qty>=0 AND qty+gift_qty>0 AND fn_financial_amount_is_exact(qty+gift_qty)));

ALTER TABLE purchase_return_items DROP CONSTRAINT purchase_return_items_gift_semantics_qty_chk;
ALTER TABLE purchase_return_items ADD CONSTRAINT purchase_return_items_gift_semantics_qty_chk CHECK (
    quantity_semantics='LEGACY_RECORDED' OR
    (qty>=0 AND gift_qty>=0 AND qty+gift_qty>0 AND fn_financial_amount_is_exact(qty+gift_qty)));

-- V516: add replacement intent field required by updated inbound receipt item entities.

ALTER TABLE purchase_receipt_items
    ADD COLUMN IF NOT EXISTS replacement_intent VARCHAR(24);

ALTER TABLE subcontract_receipt_items
    ADD COLUMN IF NOT EXISTS replacement_intent VARCHAR(24);

COMMENT ON COLUMN purchase_receipt_items.replacement_intent IS
    '退换货意图标记，NORMAL | RETURN_REPLACEMENT';
COMMENT ON COLUMN subcontract_receipt_items.replacement_intent IS
    '退换货意图标记，NORMAL | RETURN_REPLACEMENT';

-- V363: a supplier may replace company-owned material at the supplier site.
-- This is an inbound movement to the supplier-held subledger, not a purchase/AP
-- and not a warehouse receipt. Preserve the original loss and add compensation.

ALTER TABLE subcontract_material_issue_items
    ADD COLUMN compensated_qty NUMERIC(18,4) NOT NULL DEFAULT 0
        CHECK (compensated_qty >= 0);

ALTER TABLE subcontract_material_issue_items
    DROP CONSTRAINT IF EXISTS subcontract_material_issue_items_supplier_ending_chk;
ALTER TABLE subcontract_material_issue_items
    DROP COLUMN supplier_ending;
ALTER TABLE subcontract_material_issue_items
    ADD COLUMN supplier_ending NUMERIC(18,4)
    GENERATED ALWAYS AS (
        at_supplier_qty + compensated_qty
        - consumed_qty - COALESCE(returned_qty,0) - COALESCE(wasted_qty,0)
    ) STORED;
ALTER TABLE subcontract_material_issue_items
    ADD CONSTRAINT subcontract_material_issue_items_supplier_ending_chk
    CHECK (supplier_ending >= 0);

COMMENT ON COLUMN subcontract_material_issue_items.compensated_qty IS
    'Supplier replacement of company-owned material confirmed by an excess-loss resolution; increases supplier-held stock and never AP';
COMMENT ON COLUMN subcontract_material_issue_items.supplier_ending IS
    'at_supplier + compensated - consumed - returned - wasted; generated supplier-held balance';

ALTER TABLE subcontract_loss_fulfillment_allocations
    DROP CONSTRAINT IF EXISTS subcontract_loss_fulfillment_allocations_document_type_check;
ALTER TABLE subcontract_loss_fulfillment_allocations
    ALTER COLUMN document_id DROP NOT NULL,
    ALTER COLUMN document_item_id DROP NOT NULL,
    ADD CONSTRAINT subcontract_loss_fulfillment_document_type_chk CHECK (document_type IN (
        'SUPPLIER_MATERIAL_REPLACEMENT', 'SUBCONTRACT_RECEIPT',
        'SUBCONTRACT_MATERIAL_RETURN')),
    ADD CONSTRAINT subcontract_loss_fulfillment_document_shape_chk CHECK (
        (document_type='SUPPLIER_MATERIAL_REPLACEMENT'
            AND document_id IS NULL AND document_item_id IS NULL)
        OR (document_type<>'SUPPLIER_MATERIAL_REPLACEMENT'
            AND document_id IS NOT NULL AND document_item_id IS NOT NULL));

-- V334: database-final derivation for AR/AP business/open-item classification.
-- Service code also sets these snapshots, but native SQL and older application
-- binaries must not be able to insert an unclassified payable.

CREATE OR REPLACE FUNCTION fn_derive_ar_ap_open_item_metadata()
RETURNS TRIGGER AS $$
BEGIN
    NEW.business_type := CASE
        WHEN NEW.direction = 'AR' THEN 'SALES'
        WHEN NEW.source_doc_type IN ('PURCHASE_RECEIPT', 'PURCHASE_RETURN') THEN 'PURCHASE'
        WHEN NEW.source_doc_type IN (
            'SUBCONTRACT_RECEIPT', 'SUBCONTRACT_RETURN', 'SUBCONTRACT_WASTE',
            'SUBCONTRACT_LOSS_OFFSET') THEN 'SUBCONTRACT'
        ELSE 'DIRECT'
    END;

    NEW.open_item_kind := CASE
        WHEN NEW.direction = 'AR' THEN 'RECEIVABLE'
        WHEN NEW.source_doc_type = 'DIRECT_PAYMENT' THEN 'PREPAYMENT'
        WHEN NEW.source_doc_type IN ('SUBCONTRACT_WASTE', 'SUBCONTRACT_LOSS_OFFSET')
            THEN 'CLAIM_CREDIT'
        WHEN COALESCE(NEW.amount_original_local, 0) < 0 THEN 'CREDIT'
        ELSE 'PAYABLE'
    END;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_derive_ar_ap_open_item_metadata
    BEFORE INSERT OR UPDATE OF direction, source_doc_type,
        amount_original_local, business_type, open_item_kind
    ON ar_ap_ledger
    FOR EACH ROW EXECUTE FUNCTION fn_derive_ar_ap_open_item_metadata();

COMMENT ON FUNCTION fn_derive_ar_ap_open_item_metadata() IS
    'Canonical AP/AR classification from stable source type and amount sign; names/codes are never identities';

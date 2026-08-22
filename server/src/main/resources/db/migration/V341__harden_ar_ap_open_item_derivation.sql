-- V341: V334 derivation must also defeat direct attempts to write classification
-- columns themselves. Re-run it on every UPDATE and add sign/shape guards.

DROP TRIGGER IF EXISTS trg_derive_ar_ap_open_item_metadata ON ar_ap_ledger;
CREATE TRIGGER trg_derive_ar_ap_open_item_metadata
    BEFORE INSERT OR UPDATE ON ar_ap_ledger
    FOR EACH ROW EXECUTE FUNCTION fn_derive_ar_ap_open_item_metadata();

ALTER TABLE ar_ap_ledger
    ADD CONSTRAINT ar_ap_ledger_ap_open_item_shape_chk CHECK (
        direction <> 'AP'
        OR (
            (open_item_kind = 'PAYABLE'
                AND amount_original_local >= 0 AND amount_balance >= 0)
            OR (open_item_kind IN ('CREDIT', 'CLAIM_CREDIT')
                AND amount_original_local <= 0 AND amount_balance <= 0)
            OR (open_item_kind = 'PREPAYMENT'
                AND source_doc_type = 'DIRECT_PAYMENT'
                AND amount_original_local = 0 AND amount_balance <= 0)
        )) NOT VALID;

ALTER TABLE ar_ap_ledger
    VALIDATE CONSTRAINT ar_ap_ledger_ap_open_item_shape_chk;

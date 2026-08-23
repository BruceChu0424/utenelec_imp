-- V364: AP sign/shape must agree in both book and original currency. Historical
-- rows whose whole original-currency breakdown is unknown remain explicitly NULL.

ALTER TABLE ar_ap_ledger
    ADD CONSTRAINT ar_ap_ledger_ap_original_open_item_shape_chk CHECK (
        direction<>'AP'
        OR amount_balance_original IS NULL
        OR (
            (open_item_kind='PAYABLE'
                AND amount_original>=0 AND amount_balance_original>=0)
            OR (open_item_kind IN ('CREDIT','CLAIM_CREDIT')
                AND amount_original<=0 AND amount_balance_original<=0)
            OR (open_item_kind='PREPAYMENT'
                AND source_doc_type='DIRECT_PAYMENT'
                AND amount_original=0 AND amount_balance_original<=0)
        )) NOT VALID;

ALTER TABLE ar_ap_ledger
    VALIDATE CONSTRAINT ar_ap_ledger_ap_original_open_item_shape_chk;

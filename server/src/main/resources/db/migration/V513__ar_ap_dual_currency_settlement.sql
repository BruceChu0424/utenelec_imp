-- Forward-only correction of derived metadata. Original invoice, payment,
-- write-off, offset and balance amounts are unchanged and audit before-images remain.
ALTER TABLE ar_ap_ledger DROP CONSTRAINT ar_ap_ledger_settled_consistency_chk;

CREATE OR REPLACE FUNCTION fn_derive_ar_ap_open_item_metadata()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    NEW.business_type:=CASE
        WHEN NEW.direction='AR' THEN 'SALES'
        WHEN NEW.source_doc_type IN('PURCHASE_RECEIPT','PURCHASE_RETURN','PURCHASE_IQC_CREDIT','PURCHASE_BILLING_CORRECTION') THEN 'PURCHASE'
        WHEN NEW.source_doc_type IN('SUBCONTRACT_RECEIPT','SUBCONTRACT_RETURN','SUBCONTRACT_WASTE',
            'SUBCONTRACT_LOSS_OFFSET','SUBCONTRACT_IQC_CREDIT','SUBCONTRACT_BILLING_CORRECTION') THEN 'SUBCONTRACT'
        ELSE 'DIRECT' END;
    NEW.open_item_kind:=CASE
        WHEN NEW.direction='AR' AND NEW.source_doc_type='DIRECT_RECEIPT' THEN 'CUSTOMER_PREPAYMENT'
        WHEN NEW.direction='AR' THEN 'RECEIVABLE'
        WHEN NEW.source_doc_type='DIRECT_PAYMENT' THEN 'PREPAYMENT'
        WHEN NEW.source_doc_type IN('SUBCONTRACT_WASTE','SUBCONTRACT_LOSS_OFFSET') THEN 'CLAIM_CREDIT'
        WHEN COALESCE(NEW.amount_original,0)<0 OR COALESCE(NEW.amount_original_local,0)<0 THEN 'CREDIT'
        ELSE 'PAYABLE' END;
    RETURN NEW;
END;
$$;
ALTER TABLE ar_ap_ledger ENABLE ALWAYS TRIGGER trg_derive_ar_ap_open_item_metadata;

UPDATE ar_ap_ledger
SET is_settled=(amount_balance=0 AND (amount_balance_original IS NULL OR amount_balance_original=0)),
    settled_date=CASE WHEN amount_balance=0 AND (amount_balance_original IS NULL OR amount_balance_original=0)
        THEN settled_date ELSE NULL END
WHERE is_settled IS DISTINCT FROM (amount_balance=0 AND (amount_balance_original IS NULL OR amount_balance_original=0));

-- A negative original-currency credit must remain a credit when its local value
-- rounds to zero. The derivation trigger supplies the new metadata; no money changes.
UPDATE ar_ap_ledger SET open_item_kind='CREDIT'
WHERE direction='AP' AND open_item_kind='PAYABLE' AND amount_original<0 AND amount_original_local=0;

ALTER TABLE ar_ap_ledger ADD CONSTRAINT ar_ap_ledger_settled_consistency_chk CHECK(
    (is_settled AND amount_balance=0 AND (amount_balance_original IS NULL OR amount_balance_original=0) AND settled_date IS NOT NULL)
    OR (NOT is_settled AND (amount_balance<>0 OR COALESCE(amount_balance_original,0)<>0) AND settled_date IS NULL));

COMMENT ON CONSTRAINT ar_ap_ledger_settled_consistency_chk ON ar_ap_ledger IS
    'Both original and local balances must be zero; legacy unknown original keeps its original single-currency shape.';

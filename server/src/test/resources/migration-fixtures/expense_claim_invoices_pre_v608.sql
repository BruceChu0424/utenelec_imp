-- Observed partial schema before V608. Intentionally lacks later V617 fields.
-- Used only by real V607 -> current-head recovery tests; do not modernize this snapshot.
CREATE TABLE expense_claim_invoices (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    claim_id UUID NOT NULL REFERENCES expense_claims(id) ON DELETE CASCADE,
    line_no INTEGER NOT NULL,invoice_type TEXT NOT NULL DEFAULT 'GENERAL',
    invoice_code TEXT,invoice_no TEXT NOT NULL,issue_date DATE,seller_name TEXT,
    seller_tax_no TEXT,buyer_name TEXT,amount_excl_tax NUMERIC(18,2),tax_amount NUMERIC(18,2),
    total_amount NUMERIC(18,2) NOT NULL,check_state TEXT NOT NULL DEFAULT 'UNCHECKED',
    attachment_id UUID REFERENCES attachments(id) ON DELETE SET NULL,remark TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,created_by UUID,updated_by UUID,
    CONSTRAINT expense_claim_invoices_line_uk UNIQUE(claim_id,line_no),
    CONSTRAINT expense_claim_invoices_line_chk CHECK(line_no>0),
    CONSTRAINT expense_claim_invoices_type_chk CHECK(invoice_type IN
        ('GENERAL','SPECIAL','DIGITAL','PAPER_GENERAL','PAPER_SPECIAL','OTHER')),
    CONSTRAINT expense_claim_invoices_no_chk CHECK(invoice_no ~ '^[0-9]{8}$' OR invoice_no ~ '^[0-9]{20}$'),
    CONSTRAINT expense_claim_invoices_code_chk CHECK(invoice_code IS NULL OR char_length(invoice_code) IN (10,12)),
    CONSTRAINT expense_claim_invoices_code_shape_chk CHECK(
        (invoice_no ~ '^[0-9]{20}$' AND invoice_code IS NULL)
        OR (invoice_no ~ '^[0-9]{8}$' AND invoice_code IS NOT NULL)),
    CONSTRAINT expense_claim_invoices_amounts_chk CHECK(total_amount>0
        AND (amount_excl_tax IS NULL OR amount_excl_tax>=0) AND (tax_amount IS NULL OR tax_amount>=0)),
    CONSTRAINT expense_claim_invoices_text_len_chk CHECK(
        (seller_name IS NULL OR char_length(seller_name)<=200)
        AND (buyer_name IS NULL OR char_length(buyer_name)<=200)
        AND (remark IS NULL OR char_length(remark)<=500)),
    CONSTRAINT expense_claim_invoices_tax_no_len_chk CHECK(seller_tax_no IS NULL OR char_length(seller_tax_no)<=20)
);

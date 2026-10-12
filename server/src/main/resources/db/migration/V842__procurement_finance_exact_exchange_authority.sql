-- FinancialExactAmount.book: abs(value)<1e40 and at most 30 significant fraction digits.
-- V835's 10-decimal typmod cannot retain a quantity4 * price10 * rate6 product.
-- Widen only. Existing posted financial facts, including already rounded values, are not rewritten.
ALTER TABLE procurement_order_approval_cases ALTER COLUMN finance_total_local TYPE NUMERIC;
ALTER TABLE procurement_order_approval_cases ADD CONSTRAINT ck_procurement_finance_local_exact
    CHECK (public.fn_financial_book_amount_is_exact(finance_total_local));

ALTER TABLE purchase_receipt_items ADD COLUMN finance_approval_case_id UUID
    REFERENCES procurement_order_approval_cases(id);
ALTER TABLE subcontract_receipt_items ADD COLUMN finance_approval_case_id UUID
    REFERENCES procurement_order_approval_cases(id);
CREATE INDEX idx_purchase_receipt_item_finance_case ON purchase_receipt_items(finance_approval_case_id);
CREATE INDEX idx_subcontract_receipt_item_finance_case ON subcontract_receipt_items(finance_approval_case_id);
COMMENT ON COLUMN purchase_receipt_items.finance_approval_case_id IS
    'Financial approval used when this receipt line was posted; historical posted rows retain NULL and their existing currency/rate/amount facts';
COMMENT ON COLUMN subcontract_receipt_items.finance_approval_case_id IS
    'Financial approval used when this receipt line was posted; historical posted rows retain NULL and their existing currency/rate/amount facts';

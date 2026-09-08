-- V515: add bank-basis / book-balance snapshot columns required by
-- FinanceReceiptLine entity (V2 settlement metadata alignment).

ALTER TABLE finance_receipt_lines
    ADD COLUMN IF NOT EXISTS bank_basis_before_original NUMERIC(18,4),
    ADD COLUMN IF NOT EXISTS bank_basis_before_local NUMERIC(18,4),
    ADD COLUMN IF NOT EXISTS bank_basis_after_original NUMERIC(18,4),
    ADD COLUMN IF NOT EXISTS bank_basis_after_local NUMERIC(18,4),
    ADD COLUMN IF NOT EXISTS book_balance_before_local NUMERIC(18,4),
    ADD COLUMN IF NOT EXISTS book_balance_after_local NUMERIC(18,4);

COMMENT ON COLUMN finance_receipt_lines.bank_basis_before_original IS
    '核销前银行本位入账基准（原币）';
COMMENT ON COLUMN finance_receipt_lines.bank_basis_before_local IS
    '核销前银行本位入账基准（本币）';
COMMENT ON COLUMN finance_receipt_lines.bank_basis_after_original IS
    '核销后银行本位入账基准（原币）';
COMMENT ON COLUMN finance_receipt_lines.bank_basis_after_local IS
    '核销后银行本位入账基准（本币）';
COMMENT ON COLUMN finance_receipt_lines.book_balance_before_local IS
    '核销前账面余额（本币）';
COMMENT ON COLUMN finance_receipt_lines.book_balance_after_local IS
    '核销后账面余额（本币）';

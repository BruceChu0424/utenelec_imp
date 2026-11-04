-- 补正 SchemaIndexHygieneContractTest 的热点引用列领头索引契约(ADR-106 / V676)：
-- 本批 V999_2/V999_7/V999_10/V1006/V1007/V1009/V1023 新建表里指向总账凭证
-- (gl_vouchers)的外键列没有以该列开头的索引，守卫触发器（如 V999_2 已核凭证
-- 不可变、V1006 清偿历史守卫按 entry/voucher 回查）与服务查询会退化为顺序扫描。
-- 已应用迁移字节不可改，此处统一补 CREATE INDEX IF NOT EXISTS；只加单列普通索引，
-- 不与既有任何索引前缀重叠，不改变约束语义。V1025 在估值图热表
-- (stock_value_nodes/tasks/edges/events/…)上加的 restores_*/precision_source_*
-- 恢复游标列维持有意不建索引（按白名单登记理由，保住 HOT 更新），不在本迁移范围。
CREATE INDEX IF NOT EXISTS idx_finance_payroll_attempt_accrual_voucher
    ON finance_payroll_payment_attempts(accrual_voucher_id);
CREATE INDEX IF NOT EXISTS idx_finance_payroll_attempt_non_cash_voucher
    ON finance_payroll_payment_attempts(non_cash_voucher_id);
CREATE INDEX IF NOT EXISTS idx_supplier_advance_application_voucher
    ON finance_supplier_advance_applications(voucher_id);
CREATE INDEX IF NOT EXISTS idx_supplier_advance_application_reversal
    ON finance_supplier_advance_applications(reversal_voucher_id);
CREATE INDEX IF NOT EXISTS idx_supplier_advance_refund_voucher
    ON finance_supplier_advance_refunds(voucher_id);
CREATE INDEX IF NOT EXISTS idx_supplier_advance_refund_reversal
    ON finance_supplier_advance_refunds(reversal_voucher_id);
CREATE INDEX IF NOT EXISTS idx_native_debt_entry_ref_voucher
    ON finance_native_debt_entry_refs(voucher_id);
CREATE INDEX IF NOT EXISTS idx_native_supplier_offset_journal_voucher
    ON finance_native_supplier_offset_journals(voucher_id);
CREATE INDEX IF NOT EXISTS idx_native_supplier_offset_journal_reversal
    ON finance_native_supplier_offset_journals(reversal_voucher_id);
CREATE INDEX IF NOT EXISTS idx_payable_adjustment_line_voucher
    ON finance_payable_statement_adjustment_lines(voucher_id);
CREATE INDEX IF NOT EXISTS idx_payable_adjustment_line_reversal
    ON finance_payable_statement_adjustment_lines(reversal_voucher_id);
CREATE INDEX IF NOT EXISTS idx_procurement_candidate_pending_voucher
    ON finance_procurement_payable_candidates(pending_voucher_id);
CREATE INDEX IF NOT EXISTS idx_procurement_candidate_pending_reversal
    ON finance_procurement_payable_candidates(pending_reversal_voucher_id);
CREATE INDEX IF NOT EXISTS idx_procurement_recognition_line_voucher
    ON finance_procurement_ap_recognition_lines(voucher_id);
CREATE INDEX IF NOT EXISTS idx_procurement_recognition_line_reversal
    ON finance_procurement_ap_recognition_lines(reversal_voucher_id);
CREATE INDEX IF NOT EXISTS idx_finance_gl_evidence_reversed_voucher
    ON finance_gl_voucher_evidence(reversed_voucher_id);
CREATE INDEX IF NOT EXISTS idx_finance_asset_opening_source_voucher
    ON finance_asset_opening_groups(source_voucher_id);

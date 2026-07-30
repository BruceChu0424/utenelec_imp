-- V124 · C6：客户发货财务审核 + 报销(费用)单总账过账状态。
-- sales_shipments.finance_audit：0 未审 / 1 财务已审发货（现金结算客户 price_style=1 须审，仓库见「已审」才可审核出货）。
ALTER TABLE sales_shipments
    ADD COLUMN finance_audit       smallint NOT NULL DEFAULT 0,
    ADD COLUMN finance_auditor_id  uuid,
    ADD COLUMN finance_audited_at  timestamptz;
CREATE INDEX idx_sship_finaudit ON sales_shipments (finance_audit);

-- finance_expenses.gl_status：0 未过账 / 1 已过账待财务确认 / 2 财务已确认。
ALTER TABLE finance_expenses
    ADD COLUMN gl_status      smallint NOT NULL DEFAULT 0,
    ADD COLUMN gl_voucher_id  uuid;

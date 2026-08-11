-- V210: 销售退货主表新增「退货原因」列（销售录入，可为空）。
-- 与 solution/responsible（明细级，V51 已有）不同，退货原因记录在主表，描述整单退货事由。
ALTER TABLE sales_returns
    ADD COLUMN IF NOT EXISTS return_reason VARCHAR(255);

COMMENT ON COLUMN sales_returns.return_reason IS
    '退货原因（销售退货专属，由销售录入；可为空）';

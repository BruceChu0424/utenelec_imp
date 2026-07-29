-- =====================================================================
-- V91：销售单据归属授权（每个销售只看自己的单据）
-- =====================================================================
-- 背景：客户/货品归属隔离（V85/V86）+ 数据范围授权（V89）落地后，
--   用户要求销售单据同模式：老库 S_Order/S_Out/S_OtherOut/S_Withdraw.Emp_ID
--   已迁为 seller_legacy_id，业务员只见自己的单。
-- ① 四张销售主表加 owner_employee_id（报价单老库无归属字段，本期不隔离）。
-- ② user_data_scopes.scope 放开 'sales'（客户/货品之外的第三个范围）。
-- ③ 权限点 sales:view:all「查看全部销售单据」（三档：本人 / 数据范围加看 / 全部）。
-- =====================================================================

ALTER TABLE sales_orders          ADD COLUMN IF NOT EXISTS owner_employee_id UUID REFERENCES employees(id);
ALTER TABLE sales_shipments       ADD COLUMN IF NOT EXISTS owner_employee_id UUID REFERENCES employees(id);
ALTER TABLE sales_other_shipments ADD COLUMN IF NOT EXISTS owner_employee_id UUID REFERENCES employees(id);
ALTER TABLE sales_returns         ADD COLUMN IF NOT EXISTS owner_employee_id UUID REFERENCES employees(id);

CREATE INDEX IF NOT EXISTS idx_so_owner    ON sales_orders(owner_employee_id)          WHERE owner_employee_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_ss_owner    ON sales_shipments(owner_employee_id)       WHERE owner_employee_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_sos_owner   ON sales_other_shipments(owner_employee_id) WHERE owner_employee_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_sr_owner    ON sales_returns(owner_employee_id)         WHERE owner_employee_id IS NOT NULL;

ALTER TABLE user_data_scopes DROP CONSTRAINT IF EXISTS user_data_scopes_scope_check;
ALTER TABLE user_data_scopes ADD CONSTRAINT user_data_scopes_scope_check
    CHECK (scope IN ('goods', 'client', 'sales'));

INSERT INTO permissions (code, name, category, sort_order) VALUES
    ('sales:view:all', '查看全部销售单据', '销售管理', 282)
ON CONFLICT (code) DO NOTHING;

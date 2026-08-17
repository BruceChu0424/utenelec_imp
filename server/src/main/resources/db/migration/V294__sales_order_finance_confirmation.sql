-- V294：销售订货单「财务确认」闸门——订单审核后须财务确认，计划部才可见/可排产。
--
-- 背景（业务流程变更）：销售订货单审核后原直接进计划部待排产/物料分析；现改为
--   销售审核 → 财务确认（受权人员）→ 计划部接收（物料分析/排产/MRP/计划关联）。
-- 财务确认只放行"计划可见性"，不改变库存语义：审核时的库存检查+软预留照旧在审核落点
-- 发生（销售侧现货承诺），未确认订单的预留仍然生效，避免确认前现货被他人抢走。
--
-- 设计：
--   ① sales_orders 增加 finance_confirmed 事实列（确认人/时刻/备注）；
--   ② 计划部全部取单口径加 o.finance_confirmed = TRUE 谓词（待排产列表、物料分析候选、
--      MRP 展开、计划-订单行关联写入校验、BOM 缺口转发、工作台徽标计数）；
--   ③ 权限 sales_order_finance:view / sales_order_finance:confirm，默认授予财务部
--      （DEPT_FIN），GM 只读查看；服务层再叠加「财务部门树在职 + 持有 confirm 权限」的
--      资格判定（镜像 ADR-027 审核组模型）；
--   ④ 存量非草稿订单回填为已确认，不阻断存量业务链；历史红冲单仅记事实。

ALTER TABLE sales_orders
    ADD COLUMN IF NOT EXISTS finance_confirmed BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE sales_orders
    ADD COLUMN IF NOT EXISTS finance_confirmed_at TIMESTAMPTZ;
ALTER TABLE sales_orders
    ADD COLUMN IF NOT EXISTS finance_confirmed_by UUID REFERENCES employees(id);
ALTER TABLE sales_orders
    ADD COLUMN IF NOT EXISTS finance_confirm_remark TEXT;

COMMENT ON COLUMN sales_orders.finance_confirmed IS
    '财务确认（V294）：已审订单须财务确认后才对计划部可见/可排产；审核落点不变（库存检查+软预留照旧）';
COMMENT ON COLUMN sales_orders.finance_confirmed_by IS
    '财务确认人（employees.id；资格=财务部门树在职 + sales_order_finance:confirm）';

-- 存量已审/已红冲订单视为已确认：历史单据的商业与链路事实已发生，不回堵。
UPDATE sales_orders
SET finance_confirmed = TRUE,
    finance_confirmed_at = COALESCE(finance_confirmed_at, now())
WHERE status <> 0 AND finance_confirmed = FALSE;

-- 计划侧取单索引：财务确认 + 审核态 + 未结案（待排产/物料分析候选的主过滤组合）。
CREATE INDEX IF NOT EXISTS idx_sales_orders_finance_pending
    ON sales_orders(finance_confirmed, status)
    WHERE is_deleted = FALSE;

-- 权限种子（模块/分类口径对齐 V228：财税管理 / 订货审批）。
INSERT INTO permissions(code, name, module, category, sort_order) VALUES
    ('sales_order_finance:view',    '查看销售订单财务确认任务', '财税管理', '订货审批', 596),
    ('sales_order_finance:confirm', '销售订单财务确认',         '财税管理', '订货审批', 597)
ON CONFLICT (code) DO NOTHING;

-- 默认授权：财务部全权（查看+确认）；GM 只读查看。其余部门在权限设置中按需加授。
INSERT INTO department_permissions(department_id, permission_id)
SELECT d.id, p.id
FROM departments d
JOIN permissions p ON p.code IN ('sales_order_finance:view', 'sales_order_finance:confirm')
WHERE d.code = 'DEPT_FIN' AND d.is_deleted = FALSE
ON CONFLICT DO NOTHING;

INSERT INTO department_permissions(department_id, permission_id)
SELECT d.id, p.id
FROM departments d
JOIN permissions p ON p.code = 'sales_order_finance:view'
WHERE d.code = 'GM' AND d.is_deleted = FALSE
ON CONFLICT DO NOTHING;

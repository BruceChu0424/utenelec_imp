-- =====================================================================
-- V96：业务链 · 出货驳回（仓库备货异常：货损/丢失/找不到）
-- =====================================================================
-- 依据 docs/07-业务链路/02 §三「出货驳回（仓库）」：
--   草稿出货单（=仓库待备货）可驳回：逐行释放对应预留（部分释放 FIFO），
--   订单行 reserved_qty 回减、行状态回退（可发→7 / 已排产→4 / 否则→2 待排产），
--   缺口自动回到调度待排产列表（pending 查询 need>0 即出现），无需另写重触发。
--   驳回单保持草稿态 + rejected 标记（不可编辑/审核，销售删除后重开）；
--   实物损耗由仓库另行开报损单（WASTE），本动作只管预留与链路状态。
-- 权限点 sales_shipment:reject：PMC（仓库）+ 综合营销部均可驳回；超管恒有。
-- =====================================================================

ALTER TABLE sales_shipments ADD COLUMN IF NOT EXISTS rejected      BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE sales_shipments ADD COLUMN IF NOT EXISTS reject_reason TEXT;

COMMENT ON COLUMN sales_shipments.rejected IS
    '仓库驳回标记（V96）：备货发现货损/丢失/找不到；草稿态终态，不可编辑/审核';
COMMENT ON COLUMN sales_shipments.reject_reason IS
    '驳回原因（V96），销售详情页可见';

CREATE INDEX IF NOT EXISTS idx_ss_rejected ON sales_shipments(rejected) WHERE rejected = TRUE;

INSERT INTO permissions (code, name, category, sort_order) VALUES
    ('sales_shipment:reject', '驳回销售出货单', '销售管理', 222)
ON CONFLICT (code) DO NOTHING;

INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id FROM departments d, permissions p
WHERE d.code IN ('DEPT_PMC', 'DEPT_SALES')
  AND p.code = 'sales_shipment:reject'
ON CONFLICT DO NOTHING;

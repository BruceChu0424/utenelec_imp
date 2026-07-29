-- =====================================================================
-- V100：业务链 · 订单改量/取消的生产确认权限点
-- =====================================================================
-- 依据 docs/07-业务链路/01 SOP 异常段：
--   订单已排产/生产中后，改量或取消需生产部确认（避免打乱在产计划）。
--   落地方式：权限点代替审批流——涉及已排产/已产行的改量与取消，
--   必须由持 sales_order:change_planned 的账号执行（生产部），销售无此点
--   只能处理未排产部分；全程审计日志留痕。后续通知/审批中心上线后可
--   升级为「销售发起 → 生产确认」两段流，数据口径不变。
-- =====================================================================

INSERT INTO permissions (code, name, category, sort_order) VALUES
    ('sales_order:change_planned', '改量/取消已排产订单', '销售管理', 214)
ON CONFLICT (code) DO NOTHING;

-- 仅生产部（确认方）；综合营销部不授予（业务员需找生产确认）；超管恒有
INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id FROM departments d, permissions p
WHERE d.code = 'DEPT_PROD'
  AND p.code = 'sales_order:change_planned'
ON CONFLICT DO NOTHING;

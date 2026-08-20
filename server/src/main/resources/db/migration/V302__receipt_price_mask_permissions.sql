-- V302：收货单价格脱敏权限点（采购收货单 / 委外进仓单）。
--
-- 背景：仓库（SUB_WH）经 V296 获得收货单录入/审核权限后，收货单详情/列表的
-- 单价与金额族字段对仓库全量可见，违背「价格只给采购/财务看」的口径（ADR-038 配套）。
-- 仿 V90 sales_order:price:view 机制：无权限角色看收货单时 price/amountOriginal/
-- amountLocal/totalOriginal/totalLocal 一律置 null + priceMasked 标记，前端渲染 ***。
-- 服务端置 null 是脱敏底线；前端掩码只是呈现层。
--
-- 授权集（只追加不回收，幂等可重复执行）：
--   DEPT_PMC（PMC 运营部）、SUB_PURCHASE（采购部）、DEPT_FIN（财税部）、GM（总经理）。
--   仓库 SUB_WH 与生产等部门不授予 → 看收货单时价格列打码。

INSERT INTO permissions (code, name, module, category, sort_order) VALUES
    ('purchase_receipt:price:view',    '查看采购收货单价格', '采购管理', '采购收货', 230),
    ('subcontract_receipt:price:view', '查看委外进仓单价格', '委外管理', '委外进仓', 230)
ON CONFLICT (code) DO NOTHING;

INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id
FROM departments d
JOIN permissions p ON p.code IN (
    'purchase_receipt:price:view',
    'subcontract_receipt:price:view'
)
WHERE d.code IN ('DEPT_PMC', 'SUB_PURCHASE', 'DEPT_FIN', 'GM')
  AND d.is_deleted = FALSE
ON CONFLICT DO NOTHING;

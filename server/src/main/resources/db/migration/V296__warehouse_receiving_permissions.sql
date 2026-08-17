-- V296：补 PMC运营仓储部（SUB_WH）的采购/委外收货单录入与审核权限。
--
-- 背景：仓库管理 hub 已挂「采购收货单」「委外进仓单」卡（到货登记历史与审核），
-- 17 号文档 §十一 明确「仓库仍在采购收货/委外进仓单中录入实物数量并执行最终审核」。
-- 但 V212 矩阵里 SUB_WH 只有 stock/stock_doc/warehouse 的 edit 与报表权限；
-- 视图经上级 DEPT_PMC 继承（stock:view、stock_doc:view、warehouse:view、
-- purchase_receipt:view 均已覆盖），唯独：
--   ① purchase_receipt:edit  未授 → 仓库无法在收货单录入实物数量/审核（POST/PUT/approve 403）；
--   ② subcontract_receipt:view/edit 均未授（DEPT_PMC 也只有 subcontract_order:view）
--      → 委外进仓单列表/详情对仓库 403，hub 卡成死入口。
-- 本迁移按「谁执行收货谁有权」补齐（幂等，可重复执行；只追加不回收）。

INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id
FROM departments d
JOIN permissions p ON p.code IN (
    'purchase_receipt:edit',
    'subcontract_receipt:view',
    'subcontract_receipt:edit'
)
WHERE d.code = 'SUB_WH' AND d.is_deleted = FALSE
ON CONFLICT DO NOTHING;

-- V541 车间负责人/车间岗位默认权限收紧（2026-09-09 用户口径）。
--
-- 背景：V212 起生产部（DEPT_PROD，6 车间继承）默认挂了一大堆供应链查看权限
-- （生产计划/物料分析/生产报表/仓库三码/员工档案），随后 V222（采购IQC）、
-- V234（物料分析）继续追加。实际运营中车间岗位只需要：
--   我的车间任务（production_execution:view，V470）
--   生产日报报工（production_daily_report:view/edit，车间本职）
--   FQC 成品质检送检（production_quality_inspection:view，V410）
-- 其余入口（生产计划单、物料分析、生产报表、仓库、品质IQC、员工档案/人事）
-- 一律不再默认授予车间——需要个别人看，走 /admin/permissions 个人加授或
-- 单独挂科室（显式授权优先于本次收回）。
--
-- 收回范围（从 DEPT_PROD 删除部门行；不触碰 user_permission_overrides，
-- 已有个人加授/收回不受影响；其他部门（SUB_PLAN/DEPT_QA/仓库科）不受影响）：
--   生产计划族：production_plan:view/edit/forward_rd、production_plan_cost:view
--   生产报表族：production_report:view/export、production_where_used:view
--   物料分析：production_material_analysis:view（V234 曾授）
--   仓库族：stock:view、inventory:view、stock_doc:view、planning_supply_request:view
--   品质IQC：procurement_inspection:view（V222 曾授；FQC 送检保留）
--   人事：employee:view
--   基础资料编辑：mould:edit、mould_category:edit（只读 goods/mould 查看保留，
--     车间日报/报工选货品仍需要）
-- 保留：production_execution:view、production_daily_report:view/edit、
--   production_quality_inspection:view、mould:view、mould_category:view、
--   goods:view、material_category:view。
DELETE FROM department_permissions dp
USING departments d, permissions p
WHERE dp.department_id = d.id
  AND dp.permission_id = p.id
  AND d.code = 'DEPT_PROD'
  AND d.is_deleted = FALSE
  AND p.code IN (
    'production_plan:view', 'production_plan:edit', 'production_plan:forward_rd',
    'production_plan_cost:view',
    'production_report:view', 'production_report:export', 'production_where_used:view',
    'production_material_analysis:view',
    'stock:view', 'inventory:view', 'stock_doc:view', 'planning_supply_request:view',
    'procurement_inspection:view',
    'employee:view',
    'mould:edit', 'mould_category:edit'
  );

-- 幂等性说明：DELETE 天然可重放；收回后若日后需要恢复，由新的部门权限迁移
-- 或管理页重新授予，本迁移不承担恢复职责。

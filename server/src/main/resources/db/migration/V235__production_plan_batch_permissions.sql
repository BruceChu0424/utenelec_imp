-- =====================================================================
-- V235：生产计划「批量审核 / 批量删除草稿」两个独立权限点
-- =====================================================================
-- 注：V234 已被并行任务（生产物料分析 production_material_analysis）占用，本迁移顺延 V235。
-- 背景：生产计划列表接入表格多选后，批量审核（草稿→已审）与批量删除草稿属于
--   敏感操作，按「敏感操作独立权限点」铁律各设独立权限点，在权限设置里可配、
--   仅授权用户可见可用。
--
-- 说明：底层单条 approve 由 production_plan:approve 把关，delete 仍由
--   production_plan:edit 把关。本权限点与底层操作权限必须同时满足，避免用户
--   看得到批量入口却逐条 403，也避免批量权限意外放大单据操作权限。
--
-- 注：V228 module/category 两级分类已应用；本迁移 INSERT 必须带 module 列，
--   否则新权限点落入「其他」兜底。授权页目录后端动态下发，前端零改（仅加 Perm 常量）。
-- =====================================================================

-- ---------------------------------------------------------------------
-- ① 两个批量权限点（带 module/category，照 V233 ON CONFLICT DO UPDATE 幂等）
-- ---------------------------------------------------------------------
INSERT INTO permissions (code, name, module, category, sort_order) VALUES
    ('production_plan:batchApprove', '批量审核生产计划',     '生产管理', '生产计划', 281),
    ('production_plan:batchDelete',  '批量删除生产计划草稿', '生产管理', '生产计划', 282)
ON CONFLICT (code) DO UPDATE
SET name = EXCLUDED.name,
    module = EXCLUDED.module,
    category = EXCLUDED.category,
    sort_order = EXCLUDED.sort_order;

-- ---------------------------------------------------------------------
-- ② 部门默认授权（V212 已应用不可改；本迁移追加。ON CONFLICT DO NOTHING 幂等）
--   审核默认授权面与 V234 production_plan:approve 保持一致：GM / SUB_PLAN。
--   batchDelete 较敏感，管理员可在权限设置里按需收紧（如仅留 GM/SUB_PLAN）。
-- ---------------------------------------------------------------------

-- production_plan:batchApprove → GM, SUB_PLAN（还必须同时具备 production_plan:approve）
INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id
FROM departments d CROSS JOIN permissions p
WHERE p.code = 'production_plan:batchApprove'
  AND d.code IN ('GM', 'SUB_PLAN')
  AND d.is_deleted = FALSE
ON CONFLICT DO NOTHING;

-- production_plan:batchDelete → GM, DEPT_PROD, SUB_PLAN
INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id
FROM departments d CROSS JOIN permissions p
WHERE p.code = 'production_plan:batchDelete'
  AND d.code IN ('GM', 'DEPT_PROD', 'SUB_PLAN')
  AND d.is_deleted = FALSE
ON CONFLICT DO NOTHING;

-- =====================================================================
-- V41：补授 goods:edit 给 PMC 运营部（一致性修复）
-- =====================================================================
-- 背景：V32（货品，首个主档）建表时 goods:edit 仅超管恒有、未授任何部门；而后续主档均
--   授了具体业务部门（V34 mould:edit→DEPT_PROD、V36 client:edit→DEPT_SALES、
--   V38 supplier:edit→DEPT_PMC、V39 color:edit→DEPT_PMC、V40 unit:edit→DEPT_PMC）。
--   货品是唯一 edit 超管专属的主档 → 部门用户无法维护货品（含其颜色/单位字段），
--   与其他主档不一致。货品属物料/仓储主数据，归 PMC（同 supplier/color/unit），故补授。
-- 幂等：ON CONFLICT DO NOTHING，重跑安全。
-- =====================================================================

INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id FROM departments d, permissions p
WHERE d.code = 'DEPT_PMC' AND p.code = 'goods:edit'
ON CONFLICT DO NOTHING;

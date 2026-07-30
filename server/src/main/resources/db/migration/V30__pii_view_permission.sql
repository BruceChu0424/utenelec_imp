-- =====================================================================
-- V30：敏感字段脱敏按权限点化——新增 employee:pii:view
-- =====================================================================
-- 背景：DataAccessPolicy 旧实现按角色名（hr/admin）决定能否看身份证/手机号/
-- 银行卡明文。角色体系下线（V29）后，残留角色会导致"权限被收回但仍能看明文"
-- （fail-open 安全隐患），故改为按权限点判定（ADR-011 演进）。
--
-- 本迁移：
--   a) 登记新权限点 employee:pii:view（查看员工证件与银行字段）；
--   b) 预配给行政与人力资源部（原 hr 角色的对应部门，超管可在管理页调整）。
--   薪资字段沿用已有 employee:compensation:view，无需新点。
-- =====================================================================

-- a) 新权限点（幂等）
INSERT INTO permissions (code, name, category, sort_order)
VALUES ('employee:pii:view', '查看员工证件与银行字段', '员工档案', 60)
ON CONFLICT (code) DO NOTHING;

-- b) 预配给行政与人力资源部（幂等）
INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id
FROM departments d, permissions p
WHERE d.code = 'DEPT_HR' AND p.code = 'employee:pii:view'
ON CONFLICT DO NOTHING;

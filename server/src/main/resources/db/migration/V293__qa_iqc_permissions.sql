-- V293：补品质管理部（DEPT_QA）的采购/委外收货 IQC 待检权限。
--
-- V222 种子把 view 给了 DEPT_PMC/DEPT_PROD、handle 只给了 DEPT_PMC，与脚本注释
-- 「待检查看给仓库 + 品质 + PMC；处置给品质 + PMC」不一致：品质管理部作为质检结论的
-- 本职岗位反而无任何 IQC 权限，真实岗位 UAT 时会被卡在看不到也处置不了。
-- 本迁移按注释口径补齐（幂等，可重复执行）。

INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id
FROM departments d
JOIN permissions p ON p.code = 'procurement_inspection:view'
WHERE d.code = 'DEPT_QA'
ON CONFLICT DO NOTHING;

INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id
FROM departments d
JOIN permissions p ON p.code = 'procurement_inspection:handle'
WHERE d.code = 'DEPT_QA'
ON CONFLICT DO NOTHING;

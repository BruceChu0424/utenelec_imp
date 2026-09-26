-- PermissionChainReachabilityContractTest: CREATE 型写端点码须有部门持有(或基线/专属)。
-- V714 播种的 production_plan:create 是 CREATE 码但没有任何部门持有——补授予生产部,
-- 与 production_daily_report:create 同部门(DEPT_PROD), 计划口径下「能建日报补计划的人
-- 所在部门也能被授予直接建计划」。
INSERT INTO department_permissions(department_id, permission_id)
SELECT department.id, permission.id
FROM departments department
JOIN permissions permission ON permission.code = 'production_plan:create'
WHERE department.code = 'DEPT_PROD' AND department.is_deleted = FALSE
ON CONFLICT DO NOTHING;

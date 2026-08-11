-- V136: expense payment is an effective department permission.
--
-- Since ADR-011, PermissionResolver only composes the employee baseline,
-- ancestor department permissions and user overrides. Non-baseline
-- role_permissions are retained for history/admin display but are not
-- authorization grants. V133 seeded expense:pay on retired finance/admin role
-- rows, so finance staff would otherwise always receive 403.
INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id
FROM departments d
CROSS JOIN permissions p
WHERE d.code = 'DEPT_FIN'
  AND d.is_deleted = FALSE
  AND p.code = 'expense:pay'
ON CONFLICT DO NOTHING;

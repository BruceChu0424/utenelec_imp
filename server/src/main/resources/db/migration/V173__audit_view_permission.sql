-- Dedicated read permission for the audit center.
--
-- This capability is intentionally absent from the employee baseline and from
-- department grants. Super administrators resolve all catalog permissions;
-- selected investigators can receive an explicit per-user grant afterwards.
INSERT INTO permissions (code, name, category, sort_order) VALUES
    ('audit_log:view', '查看审计日志', '审计管理', 0)
ON CONFLICT (code) DO NOTHING;

DELETE FROM department_permissions dp
USING permissions p
WHERE dp.permission_id = p.id
  AND p.code = 'audit_log:view';

DELETE FROM user_permission_overrides upo
USING permissions p, users u
WHERE upo.permission_id = p.id
  AND upo.user_id = u.id
  AND p.code = 'audit_log:view'
  AND upo.effect = 'grant'
  AND u.is_super_admin = FALSE;

-- Audit evidence is deliberately not inheritable through the department tree.
-- Keep this rule at the database boundary as well as in the admin service so
-- direct SQL and future write paths cannot widen access accidentally.
CREATE OR REPLACE FUNCTION fn_guard_department_audit_permissions()
RETURNS TRIGGER AS $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM permissions p
        WHERE p.id = NEW.permission_id
          AND p.code IN ('audit_log:view', 'audit_log:export')
    ) THEN
        RAISE EXCEPTION '审计权限仅允许个人授权'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_guard_department_audit_permissions
    BEFORE INSERT OR UPDATE ON department_permissions
    FOR EACH ROW EXECUTE FUNCTION fn_guard_department_audit_permissions();

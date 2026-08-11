-- V130: split support, authorization, and high-risk finance permissions.
--
-- `user:manage` previously mixed routine HR account support with authorization
-- administration.  HR could therefore grant arbitrary permissions (including
-- to itself) and operate on the bootstrap super administrator.  Keep the old
-- permission row for compatibility/audit history, but remove every effective
-- non-super-admin grant and move callers to the narrower permissions below.

INSERT INTO permissions (code, name, category, sort_order) VALUES
    ('account:support',        '账号支持（锁定/启停/重置密码）', '账号管理', 1),
    ('authorization:manage',   '授权策略管理',                   '账号管理', 2),
    ('finance_asset:edit',     '维护固定资产与待摊',             '钱流管理', 572),
    ('finance_post:execute',   '执行总账过账',                   '钱流管理', 573),
    ('finance_shipment_audit', '财务审核销售发货',               '钱流管理', 574)
ON CONFLICT (code) DO NOTHING;

-- Retired role rows no longer participate in PermissionResolver, but remove the
-- obsolete HR capability as defence in depth and for accurate admin displays.
DELETE FROM role_permissions rp
USING roles r, permissions p
WHERE rp.role_id = r.id
  AND rp.permission_id = p.id
  AND r.code = 'hr'
  AND p.code = 'user:manage';

-- Authorization administration is super-admin-only.  Super administrators get
-- all permission rows directly from PermissionResolver and need no department
-- or personal grant.
DELETE FROM department_permissions dp
USING permissions p
WHERE dp.permission_id = p.id
  AND p.code IN ('user:manage', 'authorization:manage');

DELETE FROM user_permission_overrides upo
USING permissions p, users u
WHERE upo.permission_id = p.id
  AND upo.user_id = u.id
  AND p.code IN ('user:manage', 'authorization:manage')
  AND upo.effect = 'grant'
  AND u.is_super_admin = FALSE;

-- HR receives routine support only; it cannot edit authorization policy.
INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id
FROM departments d
CROSS JOIN permissions p
WHERE d.code = 'DEPT_HR'
  AND p.code = 'account:support'
ON CONFLICT DO NOTHING;

-- High-risk finance writes are no longer authorized by a read-only report
-- permission and are scoped to the finance department.
INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id
FROM departments d
CROSS JOIN permissions p
WHERE d.code = 'DEPT_FIN'
  AND p.code IN (
      'finance_asset:edit',
      'finance_post:execute',
      'finance_shipment_audit'
  )
ON CONFLICT DO NOTHING;

-- V129 added this as NOT VALID so the repaired legacy data could be loaded
-- first.  The controlled finance re-import has now reconciled every violation.
ALTER TABLE ar_ap_ledger
    VALIDATE CONSTRAINT ar_ap_ledger_party_shape_chk;

-- Audit export permission and automatic two-stage retention.
--
-- Online rows remain queryable/exportable for the hot period. They are then
-- copied to the archive and removed from the audit-center read model. After
-- the additional archive period they are permanently deleted by the app
-- scheduler. The scheduler fails closed when either setting is invalid.

-- The previous manual ops script created this table lazily. Runtime retention
-- needs it to exist on every clean installation. LIKE preserves column order;
-- generated risk/category expressions are intentionally not copied, so the
-- archive stores the original classification as an immutable snapshot.
CREATE TABLE IF NOT EXISTS audit_log_archive
    (LIKE audit_log INCLUDING DEFAULTS INCLUDING INDEXES);

CREATE INDEX IF NOT EXISTS idx_audit_archive_created_id
    ON audit_log_archive (created_at, id);

COMMENT ON TABLE audit_log_archive IS
    '审计冷归档；超过在线保留期后写入，超过在线期+追加归档期后永久删除';

INSERT INTO system_settings (
    key, value, value_type, category, label, description, unit, sort_order
) VALUES
    (
        'audit_hot_retention_months',
        '6',
        'int',
        'audit',
        '在线审计保留期',
        '日志在审计中心可查询、可导出的月数；到期后自动转入冷归档',
        '个月',
        410
    ),
    (
        'audit_archive_retention_months',
        '30',
        'int',
        'audit',
        '归档追加保留期',
        '转入冷归档后继续保留的月数；到期将在每日清理任务中永久删除且不可恢复',
        '个月',
        420
    )
ON CONFLICT (key) DO NOTHING;

-- Export is a separate data-egress capability and receives no department or
-- ordinary-user grant. V173 adds the independent audit_log:view capability;
-- both capabilities are assigned only as explicit personal investigation grants.
INSERT INTO permissions (code, name, category, sort_order) VALUES
    ('audit_log:export', '导出审计日志', '审计管理', 1)
ON CONFLICT (code) DO NOTHING;

DELETE FROM department_permissions dp
USING permissions p
WHERE dp.permission_id = p.id
  AND p.code = 'audit_log:export';

DELETE FROM user_permission_overrides upo
USING permissions p, users u
WHERE upo.permission_id = p.id
  AND upo.user_id = u.id
  AND p.code = 'audit_log:export'
  AND upo.effect = 'grant'
  AND u.is_super_admin = FALSE;

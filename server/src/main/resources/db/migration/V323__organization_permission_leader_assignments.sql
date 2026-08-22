-- V323: explicit company/deputy/acting permission-management appointments.
--
-- This table records management scope only. It does not seed an appointment,
-- grant a business permission, or enable contextual permission delegation.

CREATE TABLE organization_permission_leader_assignments (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    employee_id         UUID NOT NULL REFERENCES employees(id) ON DELETE RESTRICT,
    assignment_type     VARCHAR(32) NOT NULL,
    scope_type          VARCHAR(16) NOT NULL,
    department_id       UUID REFERENCES departments(id) ON DELETE RESTRICT,
    enabled             BOOLEAN NOT NULL DEFAULT TRUE,
    valid_from          TIMESTAMPTZ NOT NULL,
    valid_until         TIMESTAMPTZ,
    row_version         BIGINT NOT NULL DEFAULT 1,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by          UUID,
    updated_by          UUID,
    CONSTRAINT organization_permission_leader_assignment_type_chk
        CHECK (assignment_type IN ('COMPANY_LEADER', 'DEPUTY', 'ACTING')),
    CONSTRAINT organization_permission_leader_scope_type_chk
        CHECK (scope_type IN ('COMPANY', 'SUBTREE', 'SELF')),
    CONSTRAINT organization_permission_leader_scope_shape_chk
        CHECK (
            (scope_type = 'COMPANY' AND department_id IS NULL)
            OR
            (scope_type IN ('SUBTREE', 'SELF') AND department_id IS NOT NULL)
        ),
    CONSTRAINT organization_permission_leader_validity_chk
        CHECK (valid_until IS NULL OR valid_until > valid_from),
    CONSTRAINT organization_permission_leader_version_chk
        CHECK (row_version >= 1)
);

CREATE INDEX idx_org_permission_leaders_employee_active
    ON organization_permission_leader_assignments(
        employee_id, enabled, valid_from, valid_until);
CREATE INDEX idx_org_permission_leaders_department_active
    ON organization_permission_leader_assignments(department_id, enabled)
    WHERE department_id IS NOT NULL;
CREATE INDEX idx_org_permission_leaders_expiry
    ON organization_permission_leader_assignments(valid_until, id)
    WHERE enabled = TRUE AND valid_until IS NOT NULL;

COMMENT ON TABLE organization_permission_leader_assignments IS
    '超级管理员显式维护的公司领导/副职/代理负责人管理范围；不直接授予业务权限';
COMMENT ON COLUMN organization_permission_leader_assignments.assignment_type IS
    'COMPANY_LEADER/DEPUTY/ACTING，仅表示任职类型，不从岗位名称自动推导';
COMMENT ON COLUMN organization_permission_leader_assignments.scope_type IS
    'COMPANY=公司全部可挂人组织，SUBTREE=指定组织子树，SELF=仅指定组织';
COMMENT ON COLUMN organization_permission_leader_assignments.row_version IS
    '管理端 PUT expectedVersion；停用保留行并递增版本';

CREATE TRIGGER trg_set_updated_at_org_permission_leaders
BEFORE UPDATE ON organization_permission_leader_assignments
FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

CREATE TRIGGER trg_audit_org_permission_leaders
AFTER INSERT OR UPDATE OR DELETE ON organization_permission_leader_assignments
FOR EACH ROW EXECUTE FUNCTION fn_audit();

-- Appointments are a low-frequency shared authorization definition. A row-level
-- epoch bump means INSERT/UPDATE/disable/DELETE invalidates every previously
-- issued staff access token on its next request. A zero-row expiry scan does not
-- churn the epoch.
CREATE TRIGGER trg_org_permission_leaders_authorization_epoch
AFTER INSERT OR UPDATE OR DELETE ON organization_permission_leader_assignments
FOR EACH ROW EXECUTE FUNCTION fn_bump_authorization_epoch();


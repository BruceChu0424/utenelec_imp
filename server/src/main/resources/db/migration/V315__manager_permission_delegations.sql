-- V315: page-context permission delegation by an authorized organization leader.
--
-- This table is intentionally separate from user_permission_overrides.  The latter
-- remains the super-administrator authority (including explicit revoke precedence);
-- an organization leader must never overwrite that central decision.

CREATE TABLE manager_permission_delegations (
    user_id             UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    permission_id       UUID NOT NULL REFERENCES permissions(id) ON DELETE CASCADE,
    department_id       UUID NOT NULL REFERENCES departments(id) ON DELETE CASCADE,
    enabled             BOOLEAN NOT NULL DEFAULT TRUE,
    surface_key         VARCHAR(128) NOT NULL,
    granted_by_user_id  UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    row_version         BIGINT NOT NULL DEFAULT 1,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by          UUID,
    updated_by          UUID,
    PRIMARY KEY (user_id, permission_id, department_id),
    CONSTRAINT manager_permission_delegations_version_chk
        CHECK (row_version >= 1),
    CONSTRAINT manager_permission_delegations_surface_chk
        CHECK (
            surface_key ~ '^[a-z][a-z0-9]*(\.[a-z0-9][a-z0-9-]*)+$'
            AND length(surface_key) <= 128
        ),
    CONSTRAINT manager_permission_delegations_no_self_chk
        CHECK (user_id <> granted_by_user_id)
);

CREATE INDEX idx_manager_permission_delegations_target_enabled
    ON manager_permission_delegations(user_id, enabled);
CREATE INDEX idx_manager_permission_delegations_department
    ON manager_permission_delegations(department_id, user_id);
CREATE INDEX idx_manager_permission_delegations_grantor_enabled
    ON manager_permission_delegations(granted_by_user_id, permission_id)
    WHERE enabled = TRUE;

COMMENT ON TABLE manager_permission_delegations IS
    '组织负责人在具体页面上下文内授予下属的独立权限来源；中央个人覆盖始终独立且 revoke 优先';
COMMENT ON COLUMN manager_permission_delegations.department_id IS
    '授权时目标员工的直属部门；员工调离后该委派立即失效但保留审计行';
COMMENT ON COLUMN manager_permission_delegations.surface_key IS
    '服务端 PermissionSurfaceRegistry 的稳定页面标识，不使用可变路由';
COMMENT ON COLUMN manager_permission_delegations.row_version IS
    '写请求 expectedVersion；关闭保留行并递增版本，避免 ABA';

CREATE TRIGGER trg_set_updated_at_manager_permission_delegations
BEFORE UPDATE ON manager_permission_delegations
FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

CREATE TRIGGER trg_audit_manager_permission_delegations
AFTER INSERT OR UPDATE OR DELETE ON manager_permission_delegations
FOR EACH ROW EXECUTE FUNCTION fn_audit();

-- Any delegation mutation changes the target user's effective authorization.
CREATE TRIGGER trg_manager_permission_delegations_auth_version
AFTER INSERT OR UPDATE OR DELETE ON manager_permission_delegations
FOR EACH ROW EXECUTE FUNCTION fn_bump_user_auth_version();

-- A central personal grant/revoke on a grantor changes that grantor's
-- non-transitive delegation ceiling.  Invalidate every enabled recipient so an
-- already-issued access token cannot retain a now-invalid derived permission.
CREATE OR REPLACE FUNCTION fn_bump_manager_delegation_recipients_from_override()
RETURNS TRIGGER AS $$
DECLARE
    grantor_id UUID;
BEGIN
    FOR grantor_id IN
        SELECT DISTINCT candidate
        FROM unnest(ARRAY[
            CASE WHEN TG_OP <> 'INSERT' THEN OLD.user_id ELSE NULL END,
            CASE WHEN TG_OP <> 'DELETE' THEN NEW.user_id ELSE NULL END
        ]) AS candidate
        WHERE candidate IS NOT NULL
    LOOP
        UPDATE users recipient
        SET auth_version = recipient.auth_version + 1
        WHERE recipient.id IN (
            SELECT delegation.user_id
            FROM manager_permission_delegations delegation
            WHERE delegation.granted_by_user_id = grantor_id
              AND delegation.enabled = TRUE
        );
    END LOOP;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_user_override_manager_delegation_recipients
AFTER INSERT OR UPDATE OR DELETE ON user_permission_overrides
FOR EACH ROW EXECUTE FUNCTION fn_bump_manager_delegation_recipients_from_override();

-- A manager change alters delegation eligibility even when no permission row
-- changes.  The shared epoch invalidates both former and new manager snapshots
-- and every recipient in a single statement-level update.
CREATE TRIGGER trg_department_manager_authorization_epoch
AFTER UPDATE OF manager_id ON departments
FOR EACH STATEMENT EXECUTE FUNCTION fn_bump_authorization_epoch();

-- Account state/super-admin shape changes on a grantor also change whether their
-- contextual delegations remain valid.  Recipient access tokens must fail closed.
CREATE OR REPLACE FUNCTION fn_bump_manager_delegation_recipients_from_user()
RETURNS TRIGGER AS $$
BEGIN
    UPDATE users recipient
    SET auth_version = recipient.auth_version + 1
    WHERE recipient.id IN (
        SELECT delegation.user_id
        FROM manager_permission_delegations delegation
        WHERE delegation.granted_by_user_id = NEW.id
          AND delegation.enabled = TRUE
    );
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_user_state_manager_delegation_recipients
AFTER UPDATE OF status, is_deleted, is_super_admin, employee_id ON users
FOR EACH ROW
WHEN (
    OLD.status IS DISTINCT FROM NEW.status
    OR OLD.is_deleted IS DISTINCT FROM NEW.is_deleted
    OR OLD.is_super_admin IS DISTINCT FROM NEW.is_super_admin
    OR OLD.employee_id IS DISTINCT FROM NEW.employee_id
)
EXECUTE FUNCTION fn_bump_manager_delegation_recipients_from_user();

-- Department membership or employment-state changes on a grantor alter their
-- ceiling; membership changes on a target are already covered by V135 for the
-- target itself.  This trigger additionally invalidates all derived recipients.
CREATE OR REPLACE FUNCTION fn_bump_manager_delegation_recipients_from_employee()
RETURNS TRIGGER AS $$
DECLARE
    grantor_user_id UUID;
BEGIN
    FOR grantor_user_id IN
        SELECT id
        FROM users
        WHERE employee_id = NEW.id
    LOOP
        UPDATE users recipient
        SET auth_version = recipient.auth_version + 1
        WHERE recipient.id IN (
            SELECT delegation.user_id
            FROM manager_permission_delegations delegation
            WHERE delegation.granted_by_user_id = grantor_user_id
              AND delegation.enabled = TRUE
        );
    END LOOP;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_employee_state_manager_delegation_recipients
AFTER UPDATE OF department_id, status, is_deleted ON employees
FOR EACH ROW
WHEN (
    OLD.department_id IS DISTINCT FROM NEW.department_id
    OR OLD.status IS DISTINCT FROM NEW.status
    OR OLD.is_deleted IS DISTINCT FROM NEW.is_deleted
)
EXECUTE FUNCTION fn_bump_manager_delegation_recipients_from_employee();

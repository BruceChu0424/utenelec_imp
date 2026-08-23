-- V317: fail closed against organization/account ABA for manager delegations.
--
-- V315 rows remain immutable history.  A target moving out and back, or a
-- manager leaving and later returning, must not reactivate an old enabled row.

-- A former manager loses contributions for the exact ordinary node, or for the
-- former management-center subtree. Super-admin contextual grants are based on
-- the live super-admin flag and are not tied to manager_id.
CREATE OR REPLACE FUNCTION fn_disable_replaced_manager_delegations()
RETURNS TRIGGER AS $$
DECLARE
    old_grantor_user_id UUID;
    old_grantor_super_admin BOOLEAN;
BEGIN
    SELECT account.id, account.is_super_admin
    INTO old_grantor_user_id, old_grantor_super_admin
    FROM users account
    WHERE account.employee_id = OLD.manager_id
    LIMIT 1;

    IF old_grantor_user_id IS NOT NULL
       AND NOT COALESCE(old_grantor_super_admin, FALSE) THEN
        PERFORM recipient.id
        FROM users recipient
        WHERE recipient.id IN (
            WITH RECURSIVE revoked_scope(id) AS (
                SELECT OLD.id
                UNION ALL
                SELECT child.id
                FROM departments child
                JOIN revoked_scope parent ON child.parent_id = parent.id
                WHERE OLD.level = '管理中心'
                  AND child.is_deleted = FALSE
            )
            SELECT delegation.user_id
            FROM manager_permission_delegations delegation
            WHERE delegation.granted_by_user_id = old_grantor_user_id
              AND delegation.department_id IN (SELECT id FROM revoked_scope)
              AND delegation.enabled = TRUE
        )
        ORDER BY recipient.id
        FOR UPDATE;

        WITH RECURSIVE revoked_scope(id) AS (
            SELECT OLD.id
            UNION ALL
            SELECT child.id
            FROM departments child
            JOIN revoked_scope parent ON child.parent_id = parent.id
            WHERE OLD.level = '管理中心'
              AND child.is_deleted = FALSE
        )
        UPDATE manager_permission_delegations delegation
        SET enabled = FALSE,
            row_version = delegation.row_version + 1,
            updated_at = now(),
            updated_by = COALESCE(
                NULLIF(current_setting('app.actor_id', true), '')::uuid,
                delegation.updated_by
            )
        WHERE delegation.granted_by_user_id = old_grantor_user_id
          AND delegation.department_id IN (SELECT id FROM revoked_scope)
          AND delegation.enabled = TRUE;
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_department_manager_disable_delegations
AFTER UPDATE OF manager_id ON departments
FOR EACH ROW
WHEN (OLD.manager_id IS DISTINCT FROM NEW.manager_id AND OLD.manager_id IS NOT NULL)
EXECUTE FUNCTION fn_disable_replaced_manager_delegations();

-- Moving, deleting/restoring or reclassifying a node invalidates every enabled
-- delegation bound to that node/subtree. Reversing the organization edit does
-- not revive those historical rows.
CREATE OR REPLACE FUNCTION fn_disable_department_shape_delegations()
RETURNS TRIGGER AS $$
BEGIN
    PERFORM recipient.id
    FROM users recipient
    WHERE recipient.id IN (
        WITH RECURSIVE affected_scope(id) AS (
            SELECT NEW.id
            UNION ALL
            SELECT child.id
            FROM departments child
            JOIN affected_scope parent ON child.parent_id = parent.id
        )
        SELECT delegation.user_id
        FROM manager_permission_delegations delegation
        WHERE delegation.department_id IN (SELECT id FROM affected_scope)
          AND delegation.enabled = TRUE
    )
    ORDER BY recipient.id
    FOR UPDATE;

    WITH RECURSIVE affected_scope(id) AS (
        SELECT NEW.id
        UNION ALL
        SELECT child.id
        FROM departments child
        JOIN affected_scope parent ON child.parent_id = parent.id
    )
    UPDATE manager_permission_delegations delegation
    SET enabled = FALSE,
        row_version = delegation.row_version + 1,
        updated_at = now(),
        updated_by = COALESCE(
            NULLIF(current_setting('app.actor_id', true), '')::uuid,
            delegation.updated_by
        )
    WHERE delegation.department_id IN (SELECT id FROM affected_scope)
      AND delegation.enabled = TRUE;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_department_shape_disable_delegations
AFTER UPDATE OF parent_id, is_deleted, level ON departments
FOR EACH ROW
WHEN (
    OLD.parent_id IS DISTINCT FROM NEW.parent_id
    OR OLD.is_deleted IS DISTINCT FROM NEW.is_deleted
    OR OLD.level IS DISTINCT FROM NEW.level
)
EXECUTE FUNCTION fn_disable_department_shape_delegations();

-- Account state/super-admin shape changes invalidate both permissions received
-- by this user and permissions contributed by this user.
CREATE OR REPLACE FUNCTION fn_disable_manager_delegations_from_user_state()
RETURNS TRIGGER AS $$
DECLARE
    permanent_change BOOLEAN;
    recipient_user_id UUID;
BEGIN
    permanent_change :=
        NEW.is_deleted = TRUE
        OR OLD.employee_id IS DISTINCT FROM NEW.employee_id
        OR OLD.is_super_admin IS DISTINCT FROM NEW.is_super_admin
        OR NEW.status = 'disabled'
        OR (NEW.status = 'locked' AND NEW.locked_until IS NULL);

    IF permanent_change THEN
        FOR recipient_user_id IN
            SELECT DISTINCT delegation.user_id
            FROM manager_permission_delegations delegation
            WHERE (
                    delegation.user_id = NEW.id
                    OR delegation.granted_by_user_id = NEW.id
                  )
              AND delegation.enabled = TRUE
            ORDER BY delegation.user_id
        LOOP
            PERFORM 1
            FROM users recipient
            WHERE recipient.id = recipient_user_id
            FOR UPDATE;
        END LOOP;

        UPDATE manager_permission_delegations delegation
        SET enabled = FALSE,
            row_version = delegation.row_version + 1,
            updated_at = now(),
            updated_by = COALESCE(
                NULLIF(current_setting('app.actor_id', true), '')::uuid,
                delegation.updated_by
            )
        WHERE (
                delegation.user_id = NEW.id
                OR delegation.granted_by_user_id = NEW.id
              )
          AND delegation.enabled = TRUE;
    ELSE
        -- Temporary brute-force lock/unlock changes only dynamic eligibility.
        -- Invalidate recipients in stable UUID order without destroying grants.
        FOR recipient_user_id IN
            SELECT DISTINCT delegation.user_id
            FROM manager_permission_delegations delegation
            WHERE delegation.granted_by_user_id = NEW.id
              AND delegation.enabled = TRUE
            ORDER BY delegation.user_id
        LOOP
            UPDATE users recipient
            SET auth_version = recipient.auth_version + 1
            WHERE recipient.id = recipient_user_id;
        END LOOP;
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER trg_user_state_manager_delegation_recipients ON users;
CREATE TRIGGER trg_user_state_manager_delegation_recipients
AFTER UPDATE OF status, is_deleted, is_super_admin, employee_id ON users
FOR EACH ROW
WHEN (
    OLD.status IS DISTINCT FROM NEW.status
    OR OLD.is_deleted IS DISTINCT FROM NEW.is_deleted
    OR OLD.is_super_admin IS DISTINCT FROM NEW.is_super_admin
    OR OLD.employee_id IS DISTINCT FROM NEW.employee_id
)
EXECUTE FUNCTION fn_disable_manager_delegations_from_user_state();

-- Membership/employment changes invalidate target membership and ordinary
-- grantor scope. Disabling rows prevents move-out/move-back ABA.
CREATE OR REPLACE FUNCTION fn_disable_manager_delegations_from_employee_state()
RETURNS TRIGGER AS $$
DECLARE
    affected_user_id UUID;
    affected_super_admin BOOLEAN;
BEGIN
    SELECT id, is_super_admin
    INTO affected_user_id, affected_super_admin
    FROM users
    WHERE employee_id = NEW.id
    LIMIT 1;

    IF affected_user_id IS NOT NULL THEN
        PERFORM recipient.id
        FROM users recipient
        WHERE recipient.id IN (
            SELECT delegation.user_id
            FROM manager_permission_delegations delegation
            WHERE (
                    delegation.user_id = affected_user_id
                    OR (
                        NOT COALESCE(affected_super_admin, FALSE)
                        AND delegation.granted_by_user_id = affected_user_id
                    )
                  )
              AND delegation.enabled = TRUE
        )
        ORDER BY recipient.id
        FOR UPDATE;

        UPDATE manager_permission_delegations delegation
        SET enabled = FALSE,
            row_version = delegation.row_version + 1,
            updated_at = now(),
            updated_by = COALESCE(
                NULLIF(current_setting('app.actor_id', true), '')::uuid,
                delegation.updated_by
            )
        WHERE (
                delegation.user_id = affected_user_id
                OR (
                    NOT COALESCE(affected_super_admin, FALSE)
                    AND delegation.granted_by_user_id = affected_user_id
                )
              )
          AND delegation.enabled = TRUE;
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER trg_employee_state_manager_delegation_recipients ON employees;
CREATE TRIGGER trg_employee_state_manager_delegation_recipients
AFTER UPDATE OF department_id, status, is_deleted ON employees
FOR EACH ROW
WHEN (
    OLD.department_id IS DISTINCT FROM NEW.department_id
    OR OLD.status IS DISTINCT FROM NEW.status
    OR OLD.is_deleted IS DISTINCT FROM NEW.is_deleted
)
EXECUTE FUNCTION fn_disable_manager_delegations_from_employee_state();

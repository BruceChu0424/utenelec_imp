-- V322: monotonic validity generations for contextual permission delegation.
--
-- This closes first-insert write skew and organization/account ABA without
-- guessing from titles or deleting audit history. V315-V321 are immutable.

ALTER TABLE users
    ADD COLUMN permission_delegation_generation BIGINT NOT NULL DEFAULT 0,
    ADD CONSTRAINT users_permission_delegation_generation_chk
        CHECK (permission_delegation_generation >= 0);

ALTER TABLE employees
    ADD COLUMN permission_delegation_generation BIGINT NOT NULL DEFAULT 0,
    ADD CONSTRAINT employees_permission_delegation_generation_chk
        CHECK (permission_delegation_generation >= 0);

ALTER TABLE departments
    ADD COLUMN permission_delegation_generation BIGINT NOT NULL DEFAULT 0,
    ADD CONSTRAINT departments_permission_delegation_generation_chk
        CHECK (permission_delegation_generation >= 0);

ALTER TABLE manager_permission_delegations
    ADD COLUMN target_user_generation BIGINT,
    ADD COLUMN target_employee_generation BIGINT,
    ADD COLUMN target_department_generation BIGINT,
    ADD COLUMN grantor_user_generation BIGINT,
    ADD COLUMN grantor_employee_generation BIGINT,
    ADD COLUMN grantor_auth_version BIGINT,
    ADD COLUMN grantor_authorization_epoch BIGINT,
    ADD COLUMN scope_source TEXT,
    ADD COLUMN scope_department_id UUID REFERENCES departments(id) ON DELETE RESTRICT,
    ADD COLUMN scope_generation BIGINT;

-- The feature gate has never been approved ON in a target environment. Any
-- source-candidate rows are therefore unverified test/history rows: preserve
-- them, but disable them and require an explicit fresh grant.
UPDATE manager_permission_delegations delegation
SET enabled = FALSE,
    row_version = delegation.row_version + 1,
    target_user_generation = 0,
    target_employee_generation = 0,
    target_department_generation = 0,
    grantor_user_generation = 0,
    grantor_employee_generation = NULL,
    grantor_auth_version = 0,
    grantor_authorization_epoch = 0,
    scope_source = 'LEGACY_UNVERIFIED',
    scope_department_id = NULL,
    scope_generation = NULL,
    updated_at = now()
WHERE TRUE;

ALTER TABLE manager_permission_delegations
    ALTER COLUMN target_user_generation SET NOT NULL,
    ALTER COLUMN target_employee_generation SET NOT NULL,
    ALTER COLUMN target_department_generation SET NOT NULL,
    ALTER COLUMN grantor_user_generation SET NOT NULL,
    ALTER COLUMN grantor_auth_version SET NOT NULL,
    ALTER COLUMN grantor_authorization_epoch SET NOT NULL,
    ALTER COLUMN scope_source SET NOT NULL,
    ADD CONSTRAINT manager_permission_delegations_target_user_generation_chk
        CHECK (target_user_generation >= 0),
    ADD CONSTRAINT manager_permission_delegations_target_employee_generation_chk
        CHECK (target_employee_generation >= 0),
    ADD CONSTRAINT manager_permission_delegations_target_department_generation_chk
        CHECK (target_department_generation >= 0),
    ADD CONSTRAINT manager_permission_delegations_grantor_user_generation_chk
        CHECK (grantor_user_generation >= 0),
    ADD CONSTRAINT manager_permission_delegations_grantor_employee_generation_chk
        CHECK (grantor_employee_generation IS NULL OR grantor_employee_generation >= 0),
    ADD CONSTRAINT manager_permission_delegations_grantor_auth_version_chk
        CHECK (grantor_auth_version >= 0),
    ADD CONSTRAINT manager_permission_delegations_grantor_authorization_epoch_chk
        CHECK (grantor_authorization_epoch >= 0),
    ADD CONSTRAINT manager_permission_delegations_scope_generation_chk
        CHECK (scope_generation >= 0),
    ADD CONSTRAINT manager_permission_delegations_scope_source_chk
        CHECK (scope_source IN (
            'LEGACY_UNVERIFIED',
            'DEPARTMENT_MANAGER',
            'SUPER_ADMIN'
        )),
    ADD CONSTRAINT manager_permission_delegations_scope_shape_chk
        CHECK (
            (
                scope_source = 'DEPARTMENT_MANAGER'
                AND scope_department_id IS NOT NULL
                AND scope_generation IS NOT NULL
                AND grantor_employee_generation IS NOT NULL
            )
            OR (
                scope_source = 'SUPER_ADMIN'
                AND scope_department_id IS NULL
                AND scope_generation IS NULL
                AND grantor_employee_generation IS NULL
            )
            OR (
                scope_source = 'LEGACY_UNVERIFIED'
                AND scope_department_id IS NULL
                AND scope_generation IS NULL
                AND enabled = FALSE
            )
        );

CREATE INDEX idx_manager_permission_delegations_scope_generation
    ON manager_permission_delegations(
        scope_department_id,
        scope_generation,
        enabled
    );

COMMENT ON COLUMN users.permission_delegation_generation IS
    'Monotonic generation for permanent account eligibility changes; temporary lock/unlock does not increment';
COMMENT ON COLUMN employees.permission_delegation_generation IS
    'Monotonic generation for organization membership or current/non-current employment boundary changes';
COMMENT ON COLUMN departments.permission_delegation_generation IS
    'Monotonic generation propagated to a changed organization subtree';
COMMENT ON COLUMN manager_permission_delegations.grantor_auth_version IS
    'Grantor users.auth_version snapshot; central personal override changes cannot later revive an old delegation';
COMMENT ON COLUMN manager_permission_delegations.grantor_authorization_epoch IS
    'Shared authorization_state.epoch snapshot for department/catalog authority changes';
COMMENT ON COLUMN manager_permission_delegations.scope_source IS
    'Authority source captured at grant time; V323 adds explicit assignment source';

-- Replace V317 synchronous-disable triggers. Generation snapshots are the
-- authority; old rows remain append-visible and cannot revive after ABA.
DROP TRIGGER IF EXISTS trg_department_manager_disable_delegations ON departments;
DROP TRIGGER IF EXISTS trg_user_state_manager_delegation_recipients ON users;
DROP TRIGGER IF EXISTS trg_employee_state_manager_delegation_recipients ON employees;
DROP TRIGGER IF EXISTS trg_user_override_manager_delegation_recipients
    ON user_permission_overrides;
DROP FUNCTION IF EXISTS fn_disable_replaced_manager_delegations();
DROP FUNCTION IF EXISTS fn_disable_manager_delegations_from_user_state();
DROP FUNCTION IF EXISTS fn_disable_manager_delegations_from_employee_state();
DROP FUNCTION IF EXISTS fn_bump_manager_delegation_recipients_from_user();
DROP FUNCTION IF EXISTS fn_bump_manager_delegation_recipients_from_employee();

CREATE OR REPLACE FUNCTION fn_user_permission_delegation_generation()
RETURNS TRIGGER AS $$
DECLARE
    old_manual_lock BOOLEAN;
    new_manual_lock BOOLEAN;
    permanent_status_change BOOLEAN;
BEGIN
    old_manual_lock := OLD.status = 'locked' AND OLD.locked_until IS NULL;
    new_manual_lock := NEW.status = 'locked' AND NEW.locked_until IS NULL;
    permanent_status_change :=
        OLD.status = 'disabled'
        OR NEW.status = 'disabled'
        OR old_manual_lock
        OR new_manual_lock;

    IF OLD.is_deleted IS DISTINCT FROM NEW.is_deleted
       OR OLD.employee_id IS DISTINCT FROM NEW.employee_id
       OR OLD.is_super_admin IS DISTINCT FROM NEW.is_super_admin
       OR (
            (OLD.status IS DISTINCT FROM NEW.status
             OR OLD.locked_until IS DISTINCT FROM NEW.locked_until)
            AND permanent_status_change
       )
    THEN
        NEW.permission_delegation_generation :=
            OLD.permission_delegation_generation + 1;
        NEW.auth_version := GREATEST(
            NEW.auth_version,
            OLD.auth_version + 1
        );
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_user_permission_delegation_generation
BEFORE UPDATE OF status, locked_until, is_deleted, is_super_admin, employee_id
ON users
FOR EACH ROW EXECUTE FUNCTION fn_user_permission_delegation_generation();

CREATE OR REPLACE FUNCTION fn_employee_permission_delegation_generation()
RETURNS TRIGGER AS $$
DECLARE
    old_current BOOLEAN;
    new_current BOOLEAN;
BEGIN
    old_current := OLD.status IN ('active', 'probation', 'onLeave');
    new_current := NEW.status IN ('active', 'probation', 'onLeave');
    IF OLD.department_id IS DISTINCT FROM NEW.department_id
       OR OLD.is_deleted IS DISTINCT FROM NEW.is_deleted
       OR old_current IS DISTINCT FROM new_current
    THEN
        NEW.permission_delegation_generation :=
            OLD.permission_delegation_generation + 1;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_employee_permission_delegation_generation
BEFORE UPDATE OF department_id, status, is_deleted
ON employees
FOR EACH ROW EXECUTE FUNCTION fn_employee_permission_delegation_generation();

CREATE OR REPLACE FUNCTION fn_department_permission_delegation_generation()
RETURNS TRIGGER AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM new_department_rows new_row
        JOIN old_department_rows old_row USING (id)
        WHERE old_row.manager_id IS DISTINCT FROM new_row.manager_id
           OR old_row.parent_id IS DISTINCT FROM new_row.parent_id
           OR old_row.is_deleted IS DISTINCT FROM new_row.is_deleted
           OR old_row.level IS DISTINCT FROM new_row.level
    ) THEN
        RETURN NULL;
    END IF;

    WITH RECURSIVE changed(id, old_parent_id, new_parent_id) AS (
        SELECT new_row.id, old_row.parent_id, new_row.parent_id
        FROM new_department_rows new_row
        JOIN old_department_rows old_row USING (id)
        WHERE old_row.manager_id IS DISTINCT FROM new_row.manager_id
           OR old_row.parent_id IS DISTINCT FROM new_row.parent_id
           OR old_row.is_deleted IS DISTINCT FROM new_row.is_deleted
           OR old_row.level IS DISTINCT FROM new_row.level
    ),
    affected_subtree(id, visited) AS (
        SELECT id, ARRAY[id] FROM changed
        UNION
        SELECT child.id, parent.visited || child.id
        FROM departments child
        JOIN affected_subtree parent ON child.parent_id = parent.id
        WHERE NOT child.id = ANY(parent.visited)
    ),
    old_ancestors(id, parent_id, visited) AS (
        SELECT department.id,
               department.parent_id,
               ARRAY[department.id]
        FROM departments department
        WHERE department.id IN (
            SELECT old_parent_id
            FROM changed
            WHERE old_parent_id IS NOT NULL
        )
        UNION
        SELECT parent.id,
               parent.parent_id,
               child.visited || parent.id
        FROM departments parent
        JOIN old_ancestors child ON child.parent_id = parent.id
        WHERE NOT parent.id = ANY(child.visited)
    ),
    new_ancestors(id, parent_id, visited) AS (
        SELECT department.id,
               department.parent_id,
               ARRAY[department.id]
        FROM departments department
        WHERE department.id IN (
            SELECT new_parent_id
            FROM changed
            WHERE new_parent_id IS NOT NULL
        )
        UNION
        SELECT parent.id,
               parent.parent_id,
               child.visited || parent.id
        FROM departments parent
        JOIN new_ancestors child ON child.parent_id = parent.id
        WHERE NOT parent.id = ANY(child.visited)
    ),
    affected(id) AS (
        SELECT id FROM affected_subtree
        UNION
        SELECT id FROM old_ancestors
        UNION
        SELECT id FROM new_ancestors
    )
    UPDATE departments department
    SET permission_delegation_generation =
        department.permission_delegation_generation + 1
    WHERE department.id IN (SELECT id FROM affected);

    IF FOUND THEN
        UPDATE authorization_state
        SET epoch = epoch + 1,
            updated_at = now()
        WHERE singleton_id = 1;
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_department_permission_delegation_generation
AFTER UPDATE ON departments
REFERENCING OLD TABLE AS old_department_rows
            NEW TABLE AS new_department_rows
FOR EACH STATEMENT EXECUTE FUNCTION fn_department_permission_delegation_generation();

-- A central personal override changes both V135 auth_version and this
-- permanent delegation generation. Removing and later re-adding the same
-- permission therefore cannot revive an old manager grant.
CREATE OR REPLACE FUNCTION fn_override_permission_delegation_generation()
RETURNS TRIGGER AS $$
DECLARE
    affected_user_id UUID;
BEGIN
    FOR affected_user_id IN
        SELECT DISTINCT candidate
        FROM unnest(ARRAY[
            CASE WHEN TG_OP <> 'INSERT' THEN OLD.user_id ELSE NULL END,
            CASE WHEN TG_OP <> 'DELETE' THEN NEW.user_id ELSE NULL END
        ]) AS candidate
        WHERE candidate IS NOT NULL
        ORDER BY candidate
    LOOP
        UPDATE users
        SET permission_delegation_generation =
            permission_delegation_generation + 1
        WHERE id = affected_user_id;
    END LOOP;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_override_permission_delegation_generation
AFTER INSERT OR UPDATE OR DELETE ON user_permission_overrides
FOR EACH ROW EXECUTE FUNCTION fn_override_permission_delegation_generation();

-- A generation change invalidates the changed user's own snapshot and every
-- recipient whose permission depended on that grantor. UUID UNION prevents a
-- double increment when the same user appears in both sets.
CREATE OR REPLACE FUNCTION fn_invalidate_user_permission_delegations()
RETURNS TRIGGER AS $$
BEGIN
    IF OLD.permission_delegation_generation
       IS DISTINCT FROM NEW.permission_delegation_generation
    THEN
        UPDATE users affected
        SET auth_version = affected.auth_version + 1
        WHERE affected.id IN (
            SELECT delegation.user_id
            FROM manager_permission_delegations delegation
            WHERE delegation.granted_by_user_id = NEW.id
              AND delegation.enabled = TRUE
        );
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_invalidate_user_permission_delegations
AFTER UPDATE ON users
FOR EACH ROW EXECUTE FUNCTION fn_invalidate_user_permission_delegations();

CREATE OR REPLACE FUNCTION fn_invalidate_employee_permission_delegations()
RETURNS TRIGGER AS $$
DECLARE
    affected_user_id UUID;
BEGIN
    IF OLD.permission_delegation_generation
       IS DISTINCT FROM NEW.permission_delegation_generation
    THEN
        SELECT id INTO affected_user_id
        FROM users
        WHERE employee_id = NEW.id
        LIMIT 1;

        IF affected_user_id IS NOT NULL THEN
            UPDATE users affected
            SET auth_version = affected.auth_version + 1
            WHERE affected.id IN (
                SELECT affected_user_id
                UNION
                SELECT delegation.user_id
                FROM manager_permission_delegations delegation
                WHERE delegation.granted_by_user_id = affected_user_id
                  AND delegation.enabled = TRUE
            );
        END IF;
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_invalidate_employee_permission_delegations
AFTER UPDATE ON employees
FOR EACH ROW EXECUTE FUNCTION fn_invalidate_employee_permission_delegations();

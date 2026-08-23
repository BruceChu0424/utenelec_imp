-- V324: explicit-assignment scope snapshots and lock-order forward fixes.
--
-- V322/V323 are immutable. This migration integrates V323 appointments into
-- delegation provenance and replaces remaining synchronous recipient-row
-- invalidation with the shared authorization epoch to avoid user<->user and
-- delegation->user lock inversions.

ALTER TABLE manager_permission_delegations
    ADD COLUMN scope_assignment_id UUID
        REFERENCES organization_permission_leader_assignments(id)
        ON DELETE RESTRICT,
    ADD COLUMN scope_assignment_version BIGINT,
    ADD CONSTRAINT manager_permission_delegations_scope_assignment_version_chk
        CHECK (
            scope_assignment_version IS NULL
            OR scope_assignment_version >= 1
        );

ALTER TABLE manager_permission_delegations
    DROP CONSTRAINT manager_permission_delegations_scope_source_chk,
    DROP CONSTRAINT manager_permission_delegations_scope_shape_chk;

ALTER TABLE manager_permission_delegations
    ADD CONSTRAINT manager_permission_delegations_scope_source_chk
        CHECK (scope_source IN (
            'LEGACY_UNVERIFIED',
            'DEPARTMENT_MANAGER',
            'SUPER_ADMIN',
            'EXPLICIT_ASSIGNMENT'
        )),
    ADD CONSTRAINT manager_permission_delegations_scope_shape_chk
        CHECK (
            (
                scope_source = 'DEPARTMENT_MANAGER'
                AND scope_department_id IS NOT NULL
                AND scope_generation IS NOT NULL
                AND scope_assignment_id IS NULL
                AND scope_assignment_version IS NULL
                AND grantor_employee_generation IS NOT NULL
            )
            OR (
                scope_source = 'SUPER_ADMIN'
                AND scope_department_id IS NULL
                AND scope_generation IS NULL
                AND scope_assignment_id IS NULL
                AND scope_assignment_version IS NULL
                AND grantor_employee_generation IS NULL
            )
            OR (
                scope_source = 'EXPLICIT_ASSIGNMENT'
                AND scope_assignment_id IS NOT NULL
                AND scope_assignment_version IS NOT NULL
                AND grantor_employee_generation IS NOT NULL
                AND (
                    (
                        scope_department_id IS NULL
                        AND scope_generation IS NULL
                    )
                    OR (
                        scope_department_id IS NOT NULL
                        AND scope_generation IS NOT NULL
                    )
                )
            )
            OR (
                scope_source = 'LEGACY_UNVERIFIED'
                AND scope_department_id IS NULL
                AND scope_generation IS NULL
                AND scope_assignment_id IS NULL
                AND scope_assignment_version IS NULL
                AND enabled = FALSE
            )
        );

CREATE INDEX idx_manager_permission_delegations_scope_assignment
    ON manager_permission_delegations(
        scope_assignment_id,
        scope_assignment_version,
        enabled
    )
    WHERE scope_assignment_id IS NOT NULL;

COMMENT ON COLUMN manager_permission_delegations.scope_assignment_id IS
    'V323 explicit company/deputy/acting appointment captured at grant time';
COMMENT ON COLUMN manager_permission_delegations.scope_assignment_version IS
    'Appointment row_version snapshot; update/disable/expiry cannot revive an old grant';

-- V317 shape-trigger was intentionally not touched by V322 and still performs
-- delegation->user synchronous writes. Generation snapshots supersede it.
DROP TRIGGER IF EXISTS trg_department_shape_disable_delegations ON departments;
DROP FUNCTION IF EXISTS fn_disable_department_shape_delegations();

-- Stable department UUID order; generation-only nested updates short-circuit
-- before issuing another UPDATE, preventing statement-trigger recursion.
CREATE OR REPLACE FUNCTION fn_department_permission_delegation_generation()
RETURNS TRIGGER AS $$
DECLARE
    affected_department_id UUID;
    changed_any BOOLEAN := FALSE;
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

    FOR affected_department_id IN
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
        )
        SELECT id FROM affected_subtree
        UNION
        SELECT id FROM old_ancestors
        UNION
        SELECT id FROM new_ancestors
        ORDER BY id
    LOOP
        UPDATE departments
        SET permission_delegation_generation =
            permission_delegation_generation + 1
        WHERE id = affected_department_id;
        changed_any := TRUE;
    END LOOP;

    IF changed_any THEN
        UPDATE authorization_state
        SET epoch = epoch + 1,
            updated_at = now()
        WHERE singleton_id = 1;
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

-- Permanent account/employee generation changes are low-frequency shared
-- authorization events. Bump one singleton epoch instead of synchronously
-- locking arbitrary recipient user rows.
CREATE OR REPLACE FUNCTION fn_invalidate_user_permission_delegations()
RETURNS TRIGGER AS $$
BEGIN
    IF OLD.permission_delegation_generation
       IS DISTINCT FROM NEW.permission_delegation_generation
    THEN
        UPDATE authorization_state
        SET epoch = epoch + 1,
            updated_at = now()
        WHERE singleton_id = 1;
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION fn_invalidate_employee_permission_delegations()
RETURNS TRIGGER AS $$
BEGIN
    IF OLD.permission_delegation_generation
       IS DISTINCT FROM NEW.permission_delegation_generation
    THEN
        UPDATE authorization_state
        SET epoch = epoch + 1,
            updated_at = now()
        WHERE singleton_id = 1;
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;


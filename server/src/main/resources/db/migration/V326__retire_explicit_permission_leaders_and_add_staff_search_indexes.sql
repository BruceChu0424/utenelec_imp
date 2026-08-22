-- V326: retire explicit permission-leader appointments in favor of the
-- authoritative departments.manager_id hierarchy.
--
-- V323/V324 remain immutable audit history. Existing appointments and grants
-- sourced from them are closed with an ABA-safe version advance, then CHECK
-- constraints make the retirement permanent without dropping provenance.

UPDATE organization_permission_leader_assignments assignment
SET enabled = FALSE,
    row_version = assignment.row_version + 1
WHERE assignment.enabled = TRUE;

UPDATE manager_permission_delegations delegation
SET enabled = FALSE,
    row_version = delegation.row_version + 1
WHERE delegation.enabled = TRUE
  AND delegation.scope_source = 'EXPLICIT_ASSIGNMENT';

ALTER TABLE organization_permission_leader_assignments
    ADD CONSTRAINT organization_permission_leader_assignments_retired_chk
        CHECK (enabled = FALSE) NOT VALID;

ALTER TABLE organization_permission_leader_assignments
    VALIDATE CONSTRAINT organization_permission_leader_assignments_retired_chk;

ALTER TABLE manager_permission_delegations
    ADD CONSTRAINT manager_permission_delegations_explicit_assignment_retired_chk
        CHECK (
            scope_source <> 'EXPLICIT_ASSIGNMENT'
            OR enabled = FALSE
        ) NOT VALID;

ALTER TABLE manager_permission_delegations
    VALIDATE CONSTRAINT
        manager_permission_delegations_explicit_assignment_retired_chk;

COMMENT ON TABLE organization_permission_leader_assignments IS
    'V323 retired explicit permission-management appointments; retained disabled as immutable audit provenance';
COMMENT ON COLUMN manager_permission_delegations.scope_assignment_id IS
    'Retired V323 appointment snapshot; retained only for disabled historical delegation audit evidence';

-- Central overrides also participate in optimistic concurrency. PostgreSQL 11+
-- installs a constant default without rewriting existing rows.
ALTER TABLE user_permission_overrides
    ADD COLUMN row_version BIGINT NOT NULL DEFAULT 1,
    ADD CONSTRAINT user_permission_overrides_row_version_chk
        CHECK (row_version >= 1) NOT VALID;

ALTER TABLE user_permission_overrides
    VALIDATE CONSTRAINT user_permission_overrides_row_version_chk;

COMMENT ON COLUMN user_permission_overrides.row_version IS
    'Central permission override expectedVersion; every successful mutation advances this value';

-- Direct-department staff pagination remains index-backed as headcount grows.
CREATE INDEX idx_employees_department_status_name_page
    ON employees(department_id, status, full_name, id)
    WHERE is_deleted = FALSE
      AND status IN ('active', 'probation', 'onLeave');

-- Case-insensitive contains search for the staff picker. pg_trgm is installed
-- by V186; partial indexes exclude deleted/resigned historical employees.
CREATE INDEX idx_employees_full_name_current_trgm
    ON employees USING GIN ((LOWER(full_name)) gin_trgm_ops)
    WHERE is_deleted = FALSE
      AND status IN ('active', 'probation', 'onLeave');

CREATE INDEX idx_employees_code_current_trgm
    ON employees USING GIN ((LOWER(code)) gin_trgm_ops)
    WHERE is_deleted = FALSE
      AND status IN ('active', 'probation', 'onLeave');

-- Capability and managed-scope discovery start from the authoritative manager.
CREATE INDEX idx_departments_manager_current
    ON departments(manager_id, id)
    WHERE manager_id IS NOT NULL
      AND is_deleted = FALSE;

package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class ManagerPermissionDelegationGenerationMigrationContractTest {

    private static final Path ROOT = Path.of("src/main/resources/db/migration");
    private static final Path V322 = ROOT.resolve(
            "V322__manager_permission_delegation_generations.sql");
    private static final Path V324 = ROOT.resolve(
            "V324__permission_delegation_assignment_scope_and_lock_order.sql");
    private static final Path V325 = ROOT.resolve(
            "V325__refresh_audit_trigger_coverage.sql");

    @Test
    void delegationSnapshotsCoverTargetGrantorScopeAndSharedAuthority() throws Exception {
        String sql = normalized(V322);

        assertThat(sql)
                .contains("alter table users add column permission_delegation_generation bigint not null default 0")
                .contains("alter table employees add column permission_delegation_generation bigint not null default 0")
                .contains("alter table departments add column permission_delegation_generation bigint not null default 0")
                .contains("add column target_user_generation bigint")
                .contains("add column target_employee_generation bigint")
                .contains("add column target_department_generation bigint")
                .contains("add column grantor_user_generation bigint")
                .contains("add column grantor_employee_generation bigint")
                .contains("add column grantor_auth_version bigint")
                .contains("add column grantor_authorization_epoch bigint")
                .contains("add column scope_department_id uuid references departments(id) on delete restrict")
                .contains("add column scope_generation bigint");
    }

    @Test
    void legacyRowsAreRetainedDisabledAndCannotRevive() throws Exception {
        String sql = normalized(V322);

        assertThat(sql)
                .contains("update manager_permission_delegations delegation set enabled = false")
                .contains("row_version = delegation.row_version + 1")
                .contains("scope_source = 'legacy_unverified'")
                .contains("scope_source = 'legacy_unverified' and scope_department_id is null and scope_generation is null and enabled = false")
                .doesNotContain("delete from manager_permission_delegations");
    }

    @Test
    void temporaryLocksAndCurrentEmployeeTransitionsDoNotAdvanceGeneration()
            throws Exception {
        String sql = normalized(V322);

        assertThat(sql)
                .contains("old_manual_lock := old.status = 'locked' and old.locked_until is null")
                .contains("new_manual_lock := new.status = 'locked' and new.locked_until is null")
                .contains("old_current := old.status in ('active', 'probation', 'onleave')")
                .contains("new_current := new.status in ('active', 'probation', 'onleave')")
                .contains("or old_current is distinct from new_current");
    }

    @Test
    void organizationGenerationCoversSubtreeBothAncestorChainsAndCycles()
            throws Exception {
        String sql = normalized(V322);

        assertThat(sql)
                .contains("referencing old table as old_department_rows new table as new_department_rows")
                .contains("affected_subtree(id, visited)")
                .contains("old_ancestors(id, parent_id, visited)")
                .contains("new_ancestors(id, parent_id, visited)")
                .contains("where not child.id = any(parent.visited)")
                .contains("where not parent.id = any(child.visited)");
    }

    @Test
    void forwardIntegrationAddsAssignmentProvenanceAndRemovesOldLockInversion()
            throws Exception {
        String sql = normalized(V324);

        assertThat(sql)
                .contains("add column scope_assignment_id uuid references organization_permission_leader_assignments(id) on delete restrict")
                .contains("add column scope_assignment_version bigint")
                .contains("'explicit_assignment'")
                .contains("drop trigger if exists trg_department_shape_disable_delegations on departments")
                .contains("drop function if exists fn_disable_department_shape_delegations()")
                .contains("if not exists ( select 1 from new_department_rows")
                .contains("order by id")
                .contains("update authorization_state set epoch = epoch + 1")
                .doesNotContain("update manager_permission_delegations set enabled = false");
    }

    @Test
    void latestSweepUsesIdentifierSafeFailClosedRepair() throws Exception {
        String sql = normalized(V325);

        assertThat(sql)
                .contains("create trigger trg_audit_%1$i after insert or update or delete on %1$i")
                .contains("if prefixed_trigger_count > 0 then raise exception")
                .contains("audit trigger coverage remains invalid for")
                .doesNotContain("on %1 ");
    }

    private static String normalized(Path path) throws Exception {
        return Files.readString(path, StandardCharsets.UTF_8)
                .replaceAll("--[^\r\n]*", " ")
                .replaceAll("\\s+", " ")
                .trim()
                .toLowerCase();
    }
}

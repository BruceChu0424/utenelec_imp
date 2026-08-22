package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class PagePermissionDelegationRetirementMigrationContractTest {

    private static final Path V326 = Path.of(
            "src/main/resources/db/migration",
            "V326__retire_explicit_permission_leaders_and_add_staff_search_indexes.sql");

    @Test
    void v326RetiresExplicitAppointmentsAndDelegationsWithoutDeletingAuditHistory()
            throws Exception {
        String sql = normalized();

        String appointmentUpdate =
                "update organization_permission_leader_assignments assignment "
                        + "set enabled = false, "
                        + "row_version = assignment.row_version + 1 "
                        + "where assignment.enabled = true";
        String appointmentConstraint =
                "add constraint organization_permission_leader_assignments_retired_chk";
        String delegationUpdate =
                "update manager_permission_delegations delegation "
                        + "set enabled = false, "
                        + "row_version = delegation.row_version + 1 "
                        + "where delegation.enabled = true "
                        + "and delegation.scope_source = 'explicit_assignment'";
        String delegationConstraint =
                "add constraint "
                        + "manager_permission_delegations_explicit_assignment_retired_chk";

        assertThat(sql)
                .contains(appointmentUpdate)
                .contains(delegationUpdate)
                .contains(appointmentConstraint + " check (enabled = false) not valid")
                .contains(delegationConstraint)
                .contains("scope_source <> 'explicit_assignment' or enabled = false")
                .contains("validate constraint "
                        + "organization_permission_leader_assignments_retired_chk")
                .contains("validate constraint "
                        + "manager_permission_delegations_explicit_assignment_retired_chk")
                .doesNotContain("delete from organization_permission_leader_assignments")
                .doesNotContain("delete from manager_permission_delegations")
                .doesNotContain("drop table organization_permission_leader_assignments")
                .doesNotContain("drop column scope_assignment_id")
                .doesNotContain("drop column scope_assignment_version");

        assertThat(sql.indexOf(appointmentUpdate))
                .isLessThan(sql.indexOf(appointmentConstraint));
        assertThat(sql.indexOf(delegationUpdate))
                .isLessThan(sql.indexOf(delegationConstraint));
    }

    @Test
    void centralOverridesGainAbaSafeOptimisticConcurrencyVersion() throws Exception {
        assertThat(normalized())
                .contains("alter table user_permission_overrides "
                        + "add column row_version bigint not null default 1")
                .contains("add constraint user_permission_overrides_row_version_chk "
                        + "check (row_version >= 1) not valid")
                .contains("validate constraint user_permission_overrides_row_version_chk");
    }

    @Test
    void staffPickerIndexesCoverStablePagingContainsSearchAndManagerLookup()
            throws Exception {
        assertThat(normalized())
                .contains("create index idx_employees_department_status_name_page "
                        + "on employees(department_id, status, full_name, id) "
                        + "where is_deleted = false "
                        + "and status in ('active', 'probation', 'onleave')")
                .contains("create index idx_employees_full_name_current_trgm "
                        + "on employees using gin ((lower(full_name)) gin_trgm_ops) "
                        + "where is_deleted = false "
                        + "and status in ('active', 'probation', 'onleave')")
                .contains("create index idx_employees_code_current_trgm "
                        + "on employees using gin ((lower(code)) gin_trgm_ops) "
                        + "where is_deleted = false "
                        + "and status in ('active', 'probation', 'onleave')")
                .contains("create index idx_departments_manager_current "
                        + "on departments(manager_id, id) "
                        + "where manager_id is not null and is_deleted = false");
    }

    private static String normalized() throws Exception {
        return Files.readString(V326, StandardCharsets.UTF_8)
                .replaceAll("--[^\r\n]*", " ")
                .replaceAll("\\s+", " ")
                .trim()
                .toLowerCase();
    }
}

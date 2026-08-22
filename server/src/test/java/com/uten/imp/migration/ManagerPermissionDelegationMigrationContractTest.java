package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class ManagerPermissionDelegationMigrationContractTest {

    private static final Path V315 = Path.of(
            "src/main/resources/db/migration",
            "V315__manager_permission_delegations.sql");
    private static final Path V317 = Path.of(
            "src/main/resources/db/migration",
            "V317__disable_stale_manager_permission_delegations.sql");
    private static final Path V318 = Path.of(
            "src/main/resources/db/migration",
            "V318__refresh_audit_trigger_coverage.sql");
    private static final Path V319 = Path.of(
            "src/main/resources/db/migration",
            "V319__permission_override_authority_provenance.sql");

    @Test
    void delegationIsSeparateVersionedAuditedAuthoritySource() throws Exception {
        String sql = compact();

        assertThat(sql)
                .contains("create table manager_permission_delegations")
                .contains("primary key (user_id, permission_id, department_id)")
                .contains("enabled boolean not null default true")
                .contains("surface_key varchar(128) not null")
                .contains("granted_by_user_id uuid not null references users(id)")
                .contains("row_version bigint not null default 1")
                .contains("check (row_version >= 1)")
                .contains("check (user_id <> granted_by_user_id)")
                .contains("create trigger trg_audit_manager_permission_delegations "
                        + "after insert or update or delete on manager_permission_delegations")
                .contains("for each row execute function fn_audit()")
                .doesNotContain("alter table user_permission_overrides");
    }

    @Test
    void directAndUpstreamAuthorizationChangesInvalidateRecipients() throws Exception {
        String sql = compact();

        assertThat(sql)
                .contains("create trigger trg_manager_permission_delegations_auth_version "
                        + "after insert or update or delete on manager_permission_delegations")
                .contains("execute function fn_bump_user_auth_version()")
                .contains("create trigger trg_user_override_manager_delegation_recipients "
                        + "after insert or update or delete on user_permission_overrides")
                .contains("create trigger trg_department_manager_authorization_epoch "
                        + "after update of manager_id on departments")
                .contains("execute function fn_bump_authorization_epoch()")
                .contains("create trigger trg_user_state_manager_delegation_recipients")
                .contains("create trigger trg_employee_state_manager_delegation_recipients");
    }

    @Test
    void disabledRowsRemainForAuditAndAbaProtection() throws Exception {
        String sql = compact();

        assertThat(sql)
                .contains("enabled boolean not null default true")
                .contains("row_version bigint not null default 1")
                .doesNotContain("where enabled = false then delete");
    }

    @Test
    void organizationAndAccountChangesDisableRowsInsteadOfAllowingAbaRevival()
            throws Exception {
        String sql = normalize(Files.readString(V317, StandardCharsets.UTF_8));

        assertThat(sql)
                .contains("create trigger trg_department_manager_disable_delegations")
                .contains("execute function fn_disable_replaced_manager_delegations()")
                .contains("drop trigger trg_user_state_manager_delegation_recipients on users")
                .contains("execute function fn_disable_manager_delegations_from_user_state()")
                .contains("drop trigger trg_employee_state_manager_delegation_recipients on employees")
                .contains("execute function fn_disable_manager_delegations_from_employee_state()")
                .contains("set enabled = false, row_version = delegation.row_version + 1")
                .doesNotContain("delete from manager_permission_delegations");
    }

    @Test
    void forwardAuditSweepUsesIdentifierSafeRepairFormatting() throws Exception {
        String sql = normalize(Files.readString(V318, StandardCharsets.UTF_8));

        assertThat(sql)
                .contains("create trigger trg_audit_%1$i "
                        + "after insert or update or delete on %1$i")
                .doesNotContain("on %1 ");
    }

    @Test
    void historicalCentralOverridesAreConservativelyUnknown() throws Exception {
        String sql = normalize(Files.readString(V319, StandardCharsets.UTF_8));

        assertThat(sql)
                .contains("add column authority_source text not null default 'legacy_unknown'")
                .contains("add column source_actor_user_id uuid references users(id)")
                .contains("'legacy_unknown', 'super_admin_confirmed'")
                .contains("idx_user_permission_overrides_authority_source")
                .doesNotContain("update user_permission_overrides set authority_source = 'super_admin_confirmed'");
    }

    private static String compact() throws Exception {
        return normalize(Files.readString(V315, StandardCharsets.UTF_8));
    }

    private static String normalize(String sql) {
        return sql
                .replaceAll("--[^\r\n]*", " ")
                .replaceAll("\\s+", " ")
                .trim()
                .toLowerCase();
    }
}

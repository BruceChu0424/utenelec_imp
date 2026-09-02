package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * Static guard for the V459 review-inbox department-targeting migration.
 *
 * <p>V459 adds the secondary-department organizational layer (per-user auth
 * invalidation wired to the V135 mechanism), aggregate positioning plus
 * completion-resolution columns on {@code notices} (history rows stay NULL and
 * therefore keep the legacy read lifecycle), the cross-device snooze column on
 * {@code notice_user_states}, and the {@code review_inbox:view} permission with
 * its {@code reviews.inbox} surface. This contract pins the forward-only shape:
 * no history rewrite on notices, unique secondary membership, not-primary
 * guard, pending-aggregate partial index, and zero-default-grant DML.
 */
class ReviewInboxDeptTargetingMigrationContractTest {

    private static final Path MIGRATION = Path.of(
            "src/main/resources/db/migration/"
                    + "V459__review_inbox_dept_targeting.sql");

    private static String compact(Path path) throws IOException {
        return Files.readString(path, StandardCharsets.UTF_8)
                .replaceAll("--[^\\r\\n]*", " ")
                .replaceAll("\\s+", " ")
                .trim()
                .toLowerCase();
    }

    private static String migration() throws IOException {
        return compact(MIGRATION);
    }

    @Test
    void secondaryDepartmentsAreUniqueGuardedAndVersionInvalidated()
            throws IOException {
        String sql = migration();

        assertThat(sql)
                .contains("create table employee_secondary_departments")
                .contains("unique (employee_id, department_id)")
                .contains("references employees(id) on delete restrict")
                .contains("references departments(id) on delete restrict")
                .contains("fn_validate_secondary_department_not_primary")
                .contains("secondary department must differ from the primary department")
                .contains("trg_employee_secondary_departments_auth_version")
                .contains("after insert or update or delete on "
                        + "employee_secondary_departments")
                .contains("set auth_version = auth_version + 1")
                .contains("trg_audit_employee_secondary_departments")
                .contains("execute function fn_audit()");
    }

    @Test
    void noticesAggregateColumnsAreAdditiveWithPendingIndexOnly()
            throws IOException {
        String sql = migration();

        assertThat(sql)
                .contains("add column aggregate_kind varchar(40)")
                .contains("add column aggregate_id uuid")
                .contains("add column resolved_at timestamptz")
                .contains("add column resolved_reason varchar(40)")
                .contains("notices_aggregate_shape_chk")
                .contains("create index idx_notices_pending_aggregate")
                .contains("where resolved_at is null")
                .contains("add column snoozed_until timestamptz")
                // 历史行零行为变化：不重写、不删除既有通知与状态行。
                .doesNotContain("update notices set")
                .doesNotContain("delete from notices")
                .doesNotContain("update notice_user_states set");
    }

    @Test
    void reviewInboxPermissionAndSurfaceRegisteredWithoutDefaultGrant()
            throws IOException {
        String sql = migration();

        assertThat(sql)
                .contains("'review_inbox:view'")
                .contains("'reviews.inbox'")
                .contains("on conflict (code) do update")
                .contains("on conflict (surface_key) do nothing")
                .contains("on conflict (surface_id, permission_id) do nothing")
                // 零默认 grant：不向 department_permissions /
                // user_permission_overrides 插入任何授权行。
                .doesNotContain("insert into department_permissions")
                .doesNotContain("insert into user_permission_overrides");
    }
}

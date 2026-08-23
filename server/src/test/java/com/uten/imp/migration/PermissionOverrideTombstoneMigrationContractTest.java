package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class PermissionOverrideTombstoneMigrationContractTest {

    @Test
    void v327AddsNeutralActiveTombstonesWithoutDeletingHistory()
            throws Exception {
        String sql = Files.readString(
                        Path.of("src/main/resources/db/migration/"
                                + "V327__permission_override_tombstones.sql"),
                        StandardCharsets.UTF_8)
                .replaceAll("--[^\r\n]*", " ")
                .replaceAll("\\s+", " ")
                .trim()
                .toLowerCase();

        assertThat(sql)
                .contains("alter table user_permission_overrides "
                        + "add column active boolean not null default true")
                .contains("create index idx_user_permission_overrides_active_user "
                        + "on user_permission_overrides(user_id, permission_id) "
                        + "where active = true")
                .doesNotContain("delete from user_permission_overrides")
                .doesNotContain("drop table user_permission_overrides");
    }

    @Test
    void runtimeReadsOnlyActiveRowsAndExposesNoBulkDeleteRepositoryMethod()
            throws Exception {
        String repository = Files.readString(
                        Path.of("src/main/java/com/uten/imp/features/rbac/"
                                + "UserPermissionOverrideRepository.java"),
                        StandardCharsets.UTF_8)
                .replaceAll("\\s+", " ")
                .toLowerCase();
        String adminService = Files.readString(
                        Path.of("src/main/java/com/uten/imp/features/admin/"
                                + "PermissionOverrideAdminService.java"),
                        StandardCharsets.UTF_8)
                .replaceAll("\\s+", " ")
                .toLowerCase();

        assertThat(repository)
                .contains("and o.active = true")
                .doesNotContain("deletebyiduserid");
        assertThat(adminService)
                .contains("row.setactive(false)")
                .contains("row.setrowversion(row.getrowversion() + 1l)")
                .doesNotContain("deletebyiduserid");
    }
}

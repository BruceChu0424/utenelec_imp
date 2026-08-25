package com.uten.imp.features.admin;

import org.junit.jupiter.api.Test;

import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class UserAccountLifecycleOptimisticLockContractTest {

    @Test
    void everyWholeAccountSaveIsProtectedByAnIndependentJpaVersion() throws Exception {
        String account = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/auth/model/UserAccount.java"));
        String migration = Files.readString(Path.of(
                "src/main/resources/db/migration/"
                        + "V399__user_account_lifecycle_optimistic_lock.sql"));
        String handler = Files.readString(Path.of(
                "src/main/java/com/uten/imp/common/web/GlobalExceptionHandler.java"));

        assertThat(account)
                .contains("@Version", "private long version")
                .contains("Separate from database-maintained auth_version");
        assertThat(migration)
                .contains("ALTER TABLE users")
                .contains("ADD COLUMN version BIGINT NOT NULL DEFAULT 0")
                .contains("users_version_chk")
                .contains("independent from auth_version");
        assertThat(handler)
                .contains("OptimisticLockingFailureException.class")
                .contains("jakarta.persistence.OptimisticLockException.class")
                .contains("该记录已被他人修改，请刷新后重试");
    }

    @Test
    void adminAndOverrideWritesUseTheCanonicalEmployeeThenUserLock() throws Exception {
        String lifecycle = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/admin/"
                        + "AdminAccountLifecycleLock.java"));
        String accountAdmin = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/admin/"
                        + "UserAccountAdminService.java"));
        String overrides = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/admin/"
                        + "PermissionOverrideAdminService.java"));

        int employeeLock = lifecycle.indexOf(
                "employeeRepo.findByIdForUpdate(initialEmployeeId)");
        int userLock = lifecycle.indexOf("userRepo.findByIdForUpdate(userId)");
        int bindingRecheck = lifecycle.indexOf(
                "!Objects.equals(initialEmployeeId, account.getEmployeeId())");
        assertThat(employeeLock).isGreaterThan(0);
        assertThat(userLock).isGreaterThan(employeeLock);
        assertThat(bindingRecheck).isGreaterThan(userLock);
        assertThat(accountAdmin).contains(
                "accountLifecycle.lock(id)",
                "accountLifecycle.requireCurrentEmployee(locked)",
                "accountLifecycle.requireActiveAccount(locked)");
        assertThat(overrides).contains(
                "accountLifecycle.lock(userId)",
                "accountLifecycle.requireCurrentEmployee(locked)",
                "accountLifecycle.requireActiveAccount(locked)");
    }
}

package com.uten.imp.features.auth;

import org.junit.jupiter.api.Test;

import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class InactivePermissionResolutionContractTest {

    private static final Path MAIN = Path.of("src/main/java");

    @Test
    void everyEffectivePermissionSourceExcludesInactiveCatalogRows()
            throws Exception {
        assertThat(source(
                "com/uten/imp/features/rbac/RolePermissionRepository.java"))
                .contains("AND p.active = TRUE")
                .contains("WHERE p.active = TRUE");
        assertThat(source(
                "com/uten/imp/features/rbac/DepartmentPermissionRepository.java"))
                .contains("AND p.active = TRUE")
                .contains("WHERE p.active = TRUE");
        assertThat(source(
                "com/uten/imp/features/rbac/UserPermissionOverrideRepository.java"))
                .contains("AND o.active = TRUE")
                .contains("AND p.active = TRUE");
        assertThat(source(
                "com/uten/imp/features/rbac/ManagerPermissionDelegationRepository.java"))
                .contains("AND delegation.enabled = TRUE")
                .contains("AND permission.active = TRUE");
    }

    @Test
    void superAdministratorCatalogAlsoExcludesInactiveRows()
            throws Exception {
        assertThat(source(
                "com/uten/imp/features/auth/PermissionResolver.java"))
                .contains("permissionRepo.findAllByActiveTrue().stream()")
                .doesNotContain("permissionRepo.findAll().stream()")
                .contains(".map(Permission::getCode)");
    }

    private static String source(String relative) throws Exception {
        return Files.readString(MAIN.resolve(relative));
    }
}

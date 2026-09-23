package com.uten.imp.features.auth;

import org.junit.jupiter.api.Test;

import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * ADR-109：退役即删除。权限目录里不再有「停用但保留」的码，所以任何授权来源都不该再
 * 按 active 过滤——出现这种过滤就说明有人又把停用码留在了目录里。
 *
 * <p>原先这里断言各来源都带 {@code p.active = TRUE}(V328 保留停用码时代的防线)；
 * 目录单一事实源落地后停用列已删除，断言改为「不再出现」。
 */
class InactivePermissionResolutionContractTest {

    private static final Path MAIN = Path.of("src/main/java");

    @Test
    void effectivePermissionSourcesNoLongerFilterOnARetiredActiveColumn() throws Exception {
        for (String relative : new String[] {
                "com/uten/imp/features/rbac/DepartmentPermissionRepository.java",
                "com/uten/imp/features/rbac/UserPermissionOverrideRepository.java",
                "com/uten/imp/features/rbac/ManagerPermissionDelegationRepository.java",
                "com/uten/imp/features/rbac/PermissionRepository.java"}) {
            assertThat(source(relative))
                    .as(relative)
                    .doesNotContain("p.active")
                    .doesNotContain("permission.active")
                    .doesNotContain("ActiveTrue");
        }
        assertThat(source("com/uten/imp/features/rbac/Permission.java"))
                .doesNotContain("private boolean active");
        assertThat(Files.exists(MAIN.resolve("com/uten/imp/features/rbac/RolePermissionRepository.java")))
                .as("角色体系已删除，不能再有角色授权来源")
                .isFalse();
    }

    @Test
    void superAdministratorResolvesTheWholeCatalog() throws Exception {
        assertThat(source("com/uten/imp/features/auth/PermissionResolver.java"))
                .contains("permissionRepo.findAllCodes()")
                .doesNotContain("findAllByActiveTrue");
    }

    private static String source(String relative) throws Exception {
        return Files.readString(MAIN.resolve(relative));
    }
}

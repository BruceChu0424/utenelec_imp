package com.uten.imp.features.org.department.staffpermission;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

class PagePermissionDelegationFeatureGateTest {

    @Test
    void disabledIsFailClosed() {
        PagePermissionDelegationFeatureGate gate =
                new PagePermissionDelegationFeatureGate(false);

        assertFalse(gate.enabled());
        ApiException error = assertThrows(ApiException.class, gate::requireEnabled);
        assertEquals(ErrorCode.CONFLICT, error.getCode());
        assertEquals("页面权限委派已由运行配置显式关闭", error.getMessage());
    }

    @Test
    void enabledAllowsDelegationWorkspace() {
        PagePermissionDelegationFeatureGate gate =
                new PagePermissionDelegationFeatureGate(true);

        assertTrue(gate.enabled());
        assertDoesNotThrow(gate::requireEnabled);
    }

    @Test
    void baseDefaultsToAcceptedFeatureAndProfilesKeepOneConfigurationSource()
            throws Exception {
        Path resources = Path.of("src/main/resources");
        String base = Files.readString(
                resources.resolve("application.yml"), StandardCharsets.UTF_8);
        assertThat(base).contains(
                "manager-permission-delegation-enabled: "
                        + "$" + "{UTEN_MANAGER_PERMISSION_DELEGATION_ENABLED:true}");
        for (String profile : new String[]{
                "application-dev.yml",
                "application-cloud.yml",
                "application-prod.yml",
                "application-internal-test.yml"}) {
            Path path = resources.resolve(profile);
            if (Files.isRegularFile(path)) {
                assertThat(Files.readString(path, StandardCharsets.UTF_8))
                        .doesNotContain("manager-permission-delegation-enabled:");
            }
        }
    }
}

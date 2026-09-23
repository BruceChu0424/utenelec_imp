package com.uten.imp.features.admin.systemtest;

import com.uten.imp.common.web.ApiException;
import org.junit.jupiter.api.Test;
import org.springframework.mock.env.MockEnvironment;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * security-06: 测试期决定保留开关 (prod 默认开、只加启动告警与再认证), 但对公网开放的云端站点
 * 不论开关一律关闭 (UTEN_PROFILE=cloud,prod 会继承 prod 的默认 true)。
 */
class BusinessDataResetFeatureGateTest {

    @Test
    void prodProfileKeepsTheTestPhaseDecision() {
        MockEnvironment prod = new MockEnvironment();
        prod.setActiveProfiles("prod");

        BusinessDataResetFeatureGate gate = new BusinessDataResetFeatureGate(true, "local", prod);

        assertTrue(gate.enabled());
        assertDoesNotThrow(gate::requireEnabled);
    }

    @Test
    void cloudSiteIsAlwaysClosedEvenWhenTheFlagInheritsTrue() {
        MockEnvironment cloud = new MockEnvironment();
        cloud.setActiveProfiles("cloud", "prod");

        BusinessDataResetFeatureGate gate = new BusinessDataResetFeatureGate(true, "cloud", cloud);

        assertFalse(gate.enabled());
        assertThrows(ApiException.class, gate::requireEnabled);
    }
}

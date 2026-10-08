package com.uten.imp.features.admin.systemtest;

import com.uten.imp.common.web.ApiException;
import org.junit.jupiter.api.Test;
import org.springframework.mock.env.MockEnvironment;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Production defaults closed. Explicit local testing retains all authorization gates;
 * cloud cannot enable this operation even with an explicit true flag.
 */
class BusinessDataResetFeatureGateTest {

    @Test
    void prodCanExplicitlyEnableTheControlledLocalTestOperation() {
        MockEnvironment prod = new MockEnvironment();
        prod.setActiveProfiles("prod");

        BusinessDataResetFeatureGate gate = new BusinessDataResetFeatureGate(true, "local", prod);

        assertTrue(gate.enabled());
        assertDoesNotThrow(gate::requireEnabled);
    }

    @Test
    void productionYamlDefaultsClosedAndOnlyAnExplicitOverrideCanEnableIt() throws java.io.IOException {
        var environment = new MockEnvironment();
        var source = new org.springframework.boot.env.YamlPropertySourceLoader().load("prod",
                new org.springframework.core.io.FileSystemResource("src/main/resources/application-prod.yml")).getFirst();
        environment.getPropertySources().addLast(source);
        assertFalse(Boolean.TRUE.equals(environment.getProperty(BusinessDataResetFeatureGate.PROPERTY, Boolean.class)));
        environment.setProperty("UTEN_BUSINESS_DATA_RESET_ENABLED", "true");
        assertTrue(Boolean.TRUE.equals(environment.getProperty(BusinessDataResetFeatureGate.PROPERTY, Boolean.class)));
    }

    @Test
    void cloudSiteIsAlwaysClosedEvenWhenTheFlagIsExplicitlyTrue() {
        MockEnvironment cloud = new MockEnvironment();
        cloud.setActiveProfiles("cloud", "prod");

        BusinessDataResetFeatureGate gate = new BusinessDataResetFeatureGate(true, "cloud", cloud);

        assertFalse(gate.enabled());
        assertThrows(ApiException.class, gate::requireEnabled);
    }
}

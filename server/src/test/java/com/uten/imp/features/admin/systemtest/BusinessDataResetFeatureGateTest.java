package com.uten.imp.features.admin.systemtest;

import com.uten.imp.common.web.ApiException;
import org.junit.jupiter.api.Test;
import org.springframework.mock.env.MockEnvironment;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Server reset retirement cannot be bypassed with the old environment flag.
 * The local developer path requires both a loopback listener and a loopback database.
 */
class BusinessDataResetFeatureGateTest {

    @Test
    void allServerProfilesStayClosedEvenWithExplicitTrueAndLoopbackTargets() {
        for (String[] profiles : new String[][]{{"prod"}, {"internal-test"}, {"cloud", "prod"},
                {"dev", "prod"}, {"dev", "internal-test"}, {"dev", "test"}, {}}) {
            MockEnvironment environment = localEnvironment();
            environment.setActiveProfiles(profiles);
            BusinessDataResetFeatureGate gate = new BusinessDataResetFeatureGate(true, "local", environment);
            assertFalse(gate.enabled(), java.util.Arrays.toString(profiles));
            assertThrows(ApiException.class, gate::requireEnabled);
        }
    }

    @Test
    void serverYamlCannotBeEnabledByTheRetiredEnvironmentOverride() throws java.io.IOException {
        for (String profile : new String[]{"prod", "internal-test"}) {
            var environment = new MockEnvironment();
            var source = new org.springframework.boot.env.YamlPropertySourceLoader().load("prod",
                    new org.springframework.core.io.FileSystemResource("src/main/resources/application-" + profile + ".yml")).getFirst();
            environment.getPropertySources().addLast(source);
            assertFalse(Boolean.TRUE.equals(environment.getProperty(BusinessDataResetFeatureGate.PROPERTY, Boolean.class)));
            environment.setProperty("UTEN_BUSINESS_DATA_RESET_ENABLED", "true");
            assertFalse(Boolean.TRUE.equals(environment.getProperty(BusinessDataResetFeatureGate.PROPERTY, Boolean.class)));
        }
    }

    @org.junit.jupiter.params.ParameterizedTest
    @org.junit.jupiter.params.provider.ValueSource(strings = {"dev"})
    void localTestingYamlHonorsExplicitDisableAndEnable(String profile) throws java.io.IOException {
        var environment = new MockEnvironment();
        var source = new org.springframework.boot.env.YamlPropertySourceLoader().load(profile,
                new org.springframework.core.io.FileSystemResource("src/main/resources/application-" + profile + ".yml")).getFirst();
        environment.getPropertySources().addLast(source);
        assertTrue(Boolean.TRUE.equals(environment.getProperty(BusinessDataResetFeatureGate.PROPERTY, Boolean.class)));
        environment.setProperty("UTEN_BUSINESS_DATA_RESET_ENABLED", "false");
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

    @Test
    void localDeveloperCanUseTheToolAndExplicitlyDisableIt() {
        var environment = localEnvironment();
        var gate = new BusinessDataResetFeatureGate(true, "local", environment);
        assertTrue(gate.enabled());
        assertDoesNotThrow(gate::requireEnabled);
        assertFalse(new BusinessDataResetFeatureGate(false, "local", environment).enabled());
    }

    @org.junit.jupiter.params.ParameterizedTest
    @org.junit.jupiter.params.provider.ValueSource(strings = {"", "0.0.0.0", "::", "192.168.1.252", "localhost.example.com"})
    void wildcardOrRemoteListenerCannotUseTheLocalTool(String listener) {
        var environment = localEnvironment().withProperty("server.address", listener);
        assertFalse(new BusinessDataResetFeatureGate(true, "local", environment).enabled());
    }

    @org.junit.jupiter.params.ParameterizedTest
    @org.junit.jupiter.params.provider.ValueSource(strings = {"", "jdbc:postgresql:uten_imp",
            "jdbc:postgresql://192.168.1.252:5432/uten_imp", "jdbc:postgresql://localhost.example.com:5432/uten_imp",
            "jdbc:postgresql://127.0.0.1:5432,192.168.1.252:5432/uten_imp",
            "jdbc:postgresql://127.0.0.1:5432/uten_imp?service=production",
            "jdbc:postgresql://127.0.0.1:5432/uten_imp?socketFactory=custom.Socket",
            "jdbc:postgresql://user@127.0.0.1:5432/uten_imp"})
    void remoteOrOverridableDatabaseTargetIsRefused(String target) {
        var environment = localEnvironment().withProperty("spring.datasource.url", target);
        assertFalse(new BusinessDataResetFeatureGate(true, "local", environment).enabled());
    }

    @Test
    void resetControllerIsNotRegisteredOnAnyServer() {
        for (String[] profiles : new String[][]{{"prod"}, {"internal-test"}, {"cloud", "prod"},
                {"dev", "prod"}, {"dev", "internal-test"}, {"dev"}}) {
            try (var context = new org.springframework.context.annotation.AnnotationConfigApplicationContext()) {
                context.getEnvironment().setActiveProfiles(profiles);
                context.registerBean(BusinessDataResetService.class,
                        () -> org.mockito.Mockito.mock(BusinessDataResetService.class));
                context.registerBean(com.uten.imp.security.SecurityContextCurrentUser.class,
                        () -> org.mockito.Mockito.mock(com.uten.imp.security.SecurityContextCurrentUser.class));
                context.register(SystemTestController.class);
                context.refresh();
                assertTrue(context.getBeansOfType(SystemTestController.class).isEmpty()
                        == !(profiles.length == 1 && "dev".equals(profiles[0])));
            }
        }
    }

    private static MockEnvironment localEnvironment() {
        var environment = new MockEnvironment()
                .withProperty("server.address", "127.0.0.1")
                .withProperty("spring.datasource.url", "jdbc:postgresql://127.0.0.1:5433/uten_imp");
        environment.setActiveProfiles("dev");
        return environment;
    }
}

package com.uten.imp.config;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.Arguments;
import org.junit.jupiter.params.provider.MethodSource;
import org.springframework.context.annotation.AnnotationConfigApplicationContext;
import org.springframework.mock.env.MockEnvironment;

import java.util.stream.Stream;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

class InternalTestRuntimeSafetyGateTest {

    @Test
    void acceptsTheExclusiveProductionLikeLocalRuntimeContract() {
        assertDoesNotThrow(() -> gate(safeEnvironment()).validate());
    }

    @Test
    void rejectsCombiningInternalTestWithAnyOtherProfile() {
        MockEnvironment environment = safeEnvironment();
        environment.setActiveProfiles("internal-test", "dev");

        assertThrows(IllegalStateException.class, () -> gate(environment).validate());
    }

    @ParameterizedTest(name = "rejects unsafe {0}={1}")
    @MethodSource("unsafeOverrides")
    void rejectsEverySecurityBoundaryOverride(String key, String value) {
        MockEnvironment environment = safeEnvironment();
        environment.setProperty(key, value);

        assertThrows(IllegalStateException.class, () -> gate(environment).validate());
    }

    @Test
    void executesDuringBeanFactoryProcessingEvenWhenLazyInitializationIsRequested() {
        MockEnvironment environment = safeEnvironment();
        environment.setProperty("spring.main.lazy-initialization", "true");

        try (AnnotationConfigApplicationContext context =
                     new AnnotationConfigApplicationContext()) {
            context.setEnvironment(environment);
            context.register(InternalTestRuntimeSafetyGate.class);
            RuntimeException failure = assertThrows(RuntimeException.class, context::refresh);
            Throwable current = failure;
            boolean foundGateFailure = false;
            while (current != null) {
                if (current.getMessage() != null
                        && current.getMessage().contains(
                        "spring.main.lazy-initialization=false")) {
                    foundGateFailure = true;
                    break;
                }
                current = current.getCause();
            }
            assertTrue(foundGateFailure, "the eager runtime gate must reject lazy startup");
        }
    }

    @Test
    void ignoresOtherProfilesSoProductionOssGateRemainsIndependent() {
        MockEnvironment environment = new MockEnvironment();
        environment.setActiveProfiles("prod");

        assertDoesNotThrow(() -> gate(environment).validate());
    }

    private static Stream<Arguments> unsafeOverrides() {
        return Stream.of(
                Arguments.of("server.address", "0.0.0.0"),
                Arguments.of("server.forward-headers-strategy", "framework"),
                Arguments.of("server.tomcat.remoteip.internal-proxies", ".*"),
                Arguments.of("server.ssl.enabled", "true"),
                Arguments.of("spring.main.lazy-initialization", "true"),
                Arguments.of("spring.flyway.enabled", "true"),
                Arguments.of("spring.datasource.url", "jdbc:postgresql://db/uten_imp"),
                Arguments.of("spring.datasource.password", "short"),
                Arguments.of("uten.deployment.local-allowed-cidrs", "1.2.3.4/0"),
                Arguments.of("uten.deployment.local-allowed-cidrs", "10.1.2.3/8"),
                Arguments.of("uten.deployment.local-allowed-cidrs", "10.0.0.0/8"),
                Arguments.of("uten.deployment.local-allowed-cidrs", "172.16.0.0/12"),
                Arguments.of("uten.deployment.local-allowed-cidrs", "192.168.0.0/16"),
                Arguments.of("uten.deployment.local-allowed-cidrs", "192.168.1.1/24"),
                Arguments.of("uten.deployment.local-allowed-cidrs", "203.0.113.0/24"),
                Arguments.of("uten.deployment.local-allowed-cidrs", "2001:db8::/64"),
                Arguments.of("uten.deployment.local-allowed-cidrs", "0.0.0.0/00"),
                Arguments.of("uten.deployment.local-allowed-cidrs", "10.0.0.0/+9"),
                Arguments.of("uten.deployment.local-allowed-cidrs", "010.0.0.0/9"),
                Arguments.of("uten.deployment.local-allowed-cidrs",
                        "127.0.0.0/8,127.0.0.0/8"),
                Arguments.of("uten.security.cors-allowed-origins", "http://erp.internal"),
                Arguments.of("uten.security.require-https", "false"),
                Arguments.of("uten.security.swagger-enabled", "true"),
                Arguments.of("uten.bootstrap.admin-login", "REPLACE_ACCOUNT"),
                Arguments.of("uten.bootstrap.admin-login", "bad account"),
                Arguments.of("springdoc.api-docs.enabled", "true"),
                Arguments.of("uten.jwt.secret", "short"),
                Arguments.of("uten.crypto.pgp-master-key", "short"),
                Arguments.of("uten.storage.provider", "oss"),
                Arguments.of("uten.storage.local-dir", "/tmp/attachments"),
                Arguments.of("uten.storage.uploads-enabled", "true"),
                Arguments.of("uten.storage.oss.access-key-id", "unused-credential"),
                Arguments.of("uten.website.inquiry-ingest-token", "website-is-out-of-scope"),
                Arguments.of("app.legacy.enabled", "true"));
    }

    private static InternalTestRuntimeSafetyGate gate(MockEnvironment environment) {
        InternalTestRuntimeSafetyGate gate = new InternalTestRuntimeSafetyGate();
        gate.setEnvironment(environment);
        return gate;
    }

    private static MockEnvironment safeEnvironment() {
        MockEnvironment environment = new MockEnvironment();
        environment.setActiveProfiles("internal-test");
        environment.setProperty("server.address", "127.0.0.1");
        environment.setProperty("server.port", "8080");
        environment.setProperty("server.forward-headers-strategy", "native");
        environment.setProperty("server.tomcat.remoteip.internal-proxies", "127\\..*|::1");
        environment.setProperty("server.ssl.enabled", "false");
        environment.setProperty("spring.main.lazy-initialization", "false");
        environment.setProperty("spring.flyway.enabled", "false");
        environment.setProperty("spring.datasource.url",
                "jdbc:postgresql://127.0.0.1:5432/uten_imp");
        environment.setProperty("spring.datasource.username", "uten");
        environment.setProperty("spring.datasource.password", "d".repeat(32));
        environment.setProperty("uten.deployment.site", "local");
        environment.setProperty("uten.deployment.local-allowed-cidrs",
                "127.0.0.0/8,192.168.0.0/23");
        environment.setProperty("uten.security.cors-allowed-origins",
                "https://erp.internal.test");
        environment.setProperty("uten.security.require-https", "true");
        environment.setProperty("uten.security.swagger-enabled", "false");
        environment.setProperty("uten.bootstrap.admin-login", "bootstrap-admin-test");
        environment.setProperty("springdoc.api-docs.enabled", "false");
        environment.setProperty("springdoc.swagger-ui.enabled", "false");
        environment.setProperty("uten.jwt.secret", "j".repeat(32));
        environment.setProperty("uten.jwt.issuer", "uten-imp-internal-test");
        environment.setProperty("uten.crypto.pgp-master-key", "p".repeat(32));
        environment.setProperty("uten.crypto.hmac-key", "h".repeat(32));
        environment.setProperty("uten.sms.provider", "disabled");
        environment.setProperty("uten.sms.expose-code", "false");
        environment.setProperty("uten.policy-intelligence.enabled", "false");
        environment.setProperty("uten.policy-intelligence.api-key", "");
        environment.setProperty("uten.website.inquiry-ingest-token", "");
        environment.setProperty("app.legacy.enabled", "false");
        environment.setProperty("uten.storage.provider", "local");
        environment.setProperty("uten.storage.local-dir",
                InternalTestRuntimeSafetyGate.LOCAL_ATTACHMENT_ROOT);
        environment.setProperty("uten.storage.uploads-enabled", "false");
        environment.setProperty("uten.storage.malware-scan.provider", "disabled");
        environment.setProperty("uten.storage.reconciliation.enabled", "false");
        return environment;
    }
}

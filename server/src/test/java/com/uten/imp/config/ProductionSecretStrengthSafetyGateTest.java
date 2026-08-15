package com.uten.imp.config;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;
import org.springframework.mock.env.MockEnvironment;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertThrows;

class ProductionSecretStrengthSafetyGateTest {

    @Test
    void acceptsProductionSecretsMeetingTheMinimumLength() {
        assertDoesNotThrow(() -> gate(safeEnvironment("prod")).validate());
        assertDoesNotThrow(() -> gate(safeEnvironment("cloud")).validate());
    }

    @ParameterizedTest(name = "rejects {0} {1}")
    @CsvSource({
            "prod, uten.jwt.secret",
            "prod, uten.crypto.pgp-master-key",
            "prod, uten.crypto.hmac-key",
            "cloud, uten.jwt.secret",
            "cloud,uten.crypto.pgp-master-key",
            "cloud, uten.crypto.hmac-key"
    })
    void rejectsShortSecrets(String profile, String key) {
        MockEnvironment environment = safeEnvironment(profile);
        environment.setProperty(key, "short");

        assertThrows(IllegalStateException.class, () -> gate(environment).validate());
    }

    @ParameterizedTest(name = "rejects placeholder {1}")
    @CsvSource({
            "prod, uten.jwt.secret",
            "prod, uten.crypto.pgp-master-key",
            "prod, uten.crypto.hmac-key"
    })
    void rejectsPlaceholderSecrets(String profile, String key) {
        MockEnvironment environment = safeEnvironment(profile);
        environment.setProperty(key, "REPLACE-with-a-placeholder-value-of-32-bytes!!");

        assertThrows(IllegalStateException.class, () -> gate(environment).validate());
    }

    @ParameterizedTest(name = "rejects missing {1}")
    @CsvSource({
            "prod, uten.jwt.secret",
            "prod, uten.crypto.pgp-master-key",
            "prod, uten.crypto.hmac-key"
    })
    void rejectsMissingSecrets(String profile, String key) {
        MockEnvironment environment = safeEnvironment(profile);
        environment.setProperty(key, "");

        assertThrows(IllegalStateException.class, () -> gate(environment).validate());
    }

    @Test
    void ignoresNonProductionProfiles() {
        MockEnvironment environment = new MockEnvironment();
        environment.setActiveProfiles("dev");
        environment.setProperty("uten.jwt.secret", "short");
        environment.setProperty("uten.crypto.pgp-master-key", "short");
        environment.setProperty("uten.crypto.hmac-key", "short");

        assertDoesNotThrow(() -> gate(environment).validate());
    }

    private static ProductionSecretStrengthSafetyGate gate(MockEnvironment environment) {
        return new ProductionSecretStrengthSafetyGate(environment);
    }

    private static MockEnvironment safeEnvironment(String profile) {
        MockEnvironment environment = new MockEnvironment();
        environment.setActiveProfiles(profile);
        environment.setProperty("uten.jwt.secret", "j".repeat(48));
        environment.setProperty("uten.crypto.pgp-master-key", "p".repeat(48));
        environment.setProperty("uten.crypto.hmac-key", "h".repeat(48));
        return environment;
    }
}

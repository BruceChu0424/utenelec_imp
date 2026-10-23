package com.uten.imp.config;

import org.junit.jupiter.api.Test;
import org.springframework.mock.env.MockEnvironment;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertThrows;

/** AI 服务商密钥的专用加密密钥(ADR-133)在生产/云端可选, 但配置了就必须是强密钥。 */
class ProductionSecretCipherKeyGateTest {

    private static MockEnvironment production(String profile) {
        MockEnvironment environment = new MockEnvironment();
        environment.setActiveProfiles(profile);
        environment.setProperty("uten.jwt.secret", RuntimeSecretTestValues.forPurpose("jwt"));
        environment.setProperty("uten.crypto.pgp-master-key", RuntimeSecretTestValues.forPurpose("pgp"));
        environment.setProperty("uten.crypto.hmac-key", RuntimeSecretTestValues.forPurpose("hmac"));
        return environment;
    }

    @Test
    void absentKeyFallsBackToTheHmacDerivation() {
        MockEnvironment environment = production("prod");
        environment.setProperty("uten.crypto.secret-cipher-key", "");

        assertDoesNotThrow(() -> new ProductionSecretStrengthSafetyGate(environment).validate());
    }

    @Test
    void configuredKeyMustBeStrongAndNotAPlaceholder() {
        MockEnvironment strong = production("cloud");
        strong.setProperty("uten.crypto.secret-cipher-key", RuntimeSecretTestValues.forPurpose("cipher"));
        assertDoesNotThrow(() -> new ProductionSecretStrengthSafetyGate(strong).validate());

        MockEnvironment weak = production("prod");
        weak.setProperty("uten.crypto.secret-cipher-key", "short-secret-cipher-key");
        assertThrows(IllegalStateException.class, () -> new ProductionSecretStrengthSafetyGate(weak).validate());

        MockEnvironment placeholder = production("prod");
        placeholder.setProperty("uten.crypto.secret-cipher-key", "REPLACE_GENERATED_SECRET_CIPHER_KEY_AT_LEAST_32_BYTES");
        assertThrows(IllegalStateException.class,
                () -> new ProductionSecretStrengthSafetyGate(placeholder).validate());
    }
}

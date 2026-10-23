package com.uten.imp.config;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.NullAndEmptySource;
import org.junit.jupiter.params.provider.ValueSource;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

class RuntimeSecretPolicyTest {
    @Test
    void acceptsAdequatelySizedHexAndBase64Secrets() {
        assertDoesNotThrow(() -> require("6f8130ac9e4bd25f0871d6b349a5ce20"));
        assertDoesNotThrow(() -> require("vE3+qP9/T6xJ2wU8rL0aN5cB7zD4yS1g="));
    }

    @ParameterizedTest
    @NullAndEmptySource
    @ValueSource(strings = {
            "replace-with-a-strong-random-secret-at-least-32-bytes-long",
            "RePlAcE_GENERATED_RANDOM_SECRET_WITH_32_BYTES",
            "change-me-to-a-real-secret-before-production",
            "CHANGE_ME_TO_A_REAL_SECRET_BEFORE_PRODUCTION",
            "changeme-to-a-real-secret-before-production",
            "placeholder-secret-that-is-long-enough-for-the-gate",
            "your_secret_key_that_is_at_least_32_bytes",
            "example-secret-that-is-long-enough-for-production",
            "${UTEN_JWT_SECRET:12345678901234567890123456789012}",
            "<generate-a-secret-of-at-least-32-bytes>",
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "0123456701234567012345670123456701234567",
            "6f8130ac9e4bd25f0871d6b349a5ce2 ",
            "6f8130ac9e4bd25f0871d6b349a5ce20\n",
            "tiny-test-secret-value"
    })
    void rejectsConfigurationMistakesWithoutDisclosingTheValue(String value) {
        IllegalStateException failure = assertThrows(IllegalStateException.class, () -> require(value));
        assertTrue(failure.getMessage().contains("uten.jwt.secret"));
        if (value != null && !value.isEmpty()) assertFalse(failure.getMessage().contains(value));
    }

    private static void require(String value) {
        RuntimeSecretPolicy.requireSecret("prod/cloud", "uten.jwt.secret", value, 32);
    }
}

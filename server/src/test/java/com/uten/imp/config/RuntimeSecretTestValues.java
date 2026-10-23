package com.uten.imp.config;

import java.nio.charset.StandardCharsets;
import java.util.UUID;

/** Public deterministic fixtures; never deployment credentials. */
final class RuntimeSecretTestValues {
    private RuntimeSecretTestValues() {
    }

    static String forPurpose(String purpose) {
        return UUID.nameUUIDFromBytes(("test-only:" + purpose).getBytes(StandardCharsets.UTF_8)).toString();
    }
}

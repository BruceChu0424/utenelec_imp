package com.uten.imp.config;

import java.nio.charset.StandardCharsets;
import java.util.Locale;

/** Rejects recognizable configuration mistakes; only a CSPRNG establishes secret entropy. */
final class RuntimeSecretPolicy {

    private RuntimeSecretPolicy() {
    }

    static void requireSecret(String profile, String key, String value, int minimumUtf8Bytes) {
        if (value == null || value.isBlank() || isPlaceholder(value)) {
            throw invalid(profile, key, "requires a non-placeholder secret");
        }
        if (value.codePoints().anyMatch(character -> Character.isWhitespace(character)
                || Character.isISOControl(character))) {
            throw invalid(profile, key, "secret must not contain whitespace or control characters");
        }
        if (value.getBytes(StandardCharsets.UTF_8).length < minimumUtf8Bytes) {
            throw invalid(profile, key, "secret is too short (min " + minimumUtf8Bytes + " UTF-8 bytes)");
        }
        if (value.codePoints().distinct().limit(8).count() < 8 || repeatsShortPattern(value)) {
            throw invalid(profile, key, "secret is visibly predictable; generate a fresh random secret");
        }
    }

    private static boolean isPlaceholder(String value) {
        String normalized = value.toLowerCase(Locale.ROOT).replaceAll("[-_\\s]", "");
        return normalized.contains("replace")
                || normalized.contains("changeme")
                || normalized.contains("placeholder")
                || normalized.contains("yourpassword")
                || normalized.contains("yoursecret")
                || normalized.contains("yourkey")
                || normalized.contains("example")
                || normalized.contains("${")
                || (normalized.contains("<") && normalized.contains(">"));
    }

    private static boolean repeatsShortPattern(String value) {
        for (int period = 1; period <= 8 && period * 2 <= value.length(); period++) {
            boolean repeated = true;
            for (int index = period; index < value.length(); index++) {
                if (value.charAt(index) != value.charAt(index % period)) {
                    repeated = false;
                    break;
                }
            }
            if (repeated) return true;
        }
        return false;
    }

    private static IllegalStateException invalid(String profile, String key, String reason) {
        // Never include the configured value, even in nested exceptions.
        return new IllegalStateException(profile + " " + reason + ": " + key);
    }
}

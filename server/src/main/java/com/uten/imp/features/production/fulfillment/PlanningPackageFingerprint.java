package com.uten.imp.features.production.fulfillment;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.Collection;
import java.util.HexFormat;
import java.util.List;

/** Canonical SHA-256 helper for stale-preview and idempotency checks. */
public final class PlanningPackageFingerprint {

    private PlanningPackageFingerprint() {
    }

    public static String sha256(Collection<String> canonicalParts) {
        try {
            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            List<String> ordered = canonicalParts == null
                    ? List.of()
                    : canonicalParts.stream()
                    .map(part -> part == null ? "<null>" : part)
                    .sorted()
                    .toList();
            for (String part : ordered) {
                byte[] bytes = part.getBytes(StandardCharsets.UTF_8);
                digest.update(Integer.toString(bytes.length).getBytes(StandardCharsets.US_ASCII));
                digest.update((byte) ':');
                digest.update(bytes);
                digest.update((byte) '\n');
            }
            return HexFormat.of().formatHex(digest.digest());
        } catch (NoSuchAlgorithmException impossible) {
            throw new IllegalStateException("SHA-256 不可用", impossible);
        }
    }
}

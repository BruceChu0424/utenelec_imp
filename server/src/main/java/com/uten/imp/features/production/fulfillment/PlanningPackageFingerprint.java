package com.uten.imp.features.production.fulfillment;

import com.uten.imp.common.util.CanonicalFingerprint;

import java.util.Collection;

/** Canonical SHA-256 helper for stale-preview and idempotency checks. */
public final class PlanningPackageFingerprint {

    private PlanningPackageFingerprint() {
    }

    public static String sha256(Collection<String> canonicalParts) {
        return CanonicalFingerprint.sha256(canonicalParts);
    }
}

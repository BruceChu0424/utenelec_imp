package com.uten.imp.features.production.analysis;

import java.util.UUID;

/**
 * Lazy hook invoked after a new IQC/MAKE origin entitlement exists in the
 * current transaction. Implementations must be idempotent by origin event id.
 */
@FunctionalInterface
public interface PreplanOriginEntitlementHook {
    void applyPriorityForOriginEvent(UUID originEventId);
}

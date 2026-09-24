package com.uten.imp.features.production.analysis;

import java.util.UUID;

/**
 * Lazy hook invoked after every IQC/MAKE origin entitlement in the physical
 * batch exists in the current transaction. Each ordered hook handles the whole
 * batch before the next hook runs, so readiness cannot precede priority ownership.
 * Implementations must be idempotent by origin event id and tolerate an earlier
 * ordered hook consuming the complete remaining lot.
 */
@FunctionalInterface
public interface PreplanOriginEntitlementHook {
    void applyPriorityForOriginEvent(UUID originEventId);
}

package com.uten.imp.features.stock.allocation.dto;

import java.util.UUID;

/** Real issue-owning task, retained within its original material permissions. */
public record ProductionMaterialUsageSource(UUID executionSegmentId, String executionSegmentCode,
                                            boolean shared, boolean canOpen, boolean canSettle,
                                            UUID sourcePlanId) {
    public ProductionMaterialUsageSource(UUID executionSegmentId, String executionSegmentCode,
            boolean shared, boolean canOpen, boolean canSettle) {
        this(executionSegmentId,executionSegmentCode,shared,canOpen,canSettle,null);
    }
}

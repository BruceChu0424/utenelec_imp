package com.uten.imp.responsibility.dto;

import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

/** Read-only impact preview. Preview never creates a handover batch or mutates business data. */
public record DataHandoverPreview(
        UUID sourceEmployeeId,
        UUID targetEmployeeId,
        Set<String> scopes,
        List<DataHandoverPreviewItem> items,
        boolean hasBlockers,
        boolean requiresTarget,
        long transferCount,
        long historyAccessCount,
        long releaseCount,
        long blockingCount,
        long total,
        Map<String, UUID> scopeTargetEmployeeIds,
        Map<String, String> scopeTargetEmployeeNames
) {
    /** Classified impact occurrences, not a distinct-row count. */
}

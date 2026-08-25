package com.uten.imp.responsibility.dto;

import java.util.Map;
import java.util.Set;
import java.util.UUID;

/** Persisted handover receipt. A replay returns the original receipt with {@code replayed=true}. */
public record DataHandoverResult(
        UUID id,
        long sequenceNo,
        UUID requestId,
        UUID sourceEmployeeId,
        UUID targetEmployeeId,
        String mode,
        String status,
        Set<String> scopes,
        Map<String, Long> resultSummary,
        boolean replayed
) {
}

package com.uten.imp.audit;

import java.time.LocalDate;
import java.util.UUID;

/** Shared filters for audit list, summary, and export queries. */
public record AuditSearchCriteria(
        String action,
        String actorAccount,
        String actorScope,
        String riskLevel,
        String eventCategory,
        String outcome,
        String keyword,
        String targetType,
        String targetId,
        String eventSource,
        String requestId,
        String operationKind,
        LocalDate dateFrom,
        LocalDate dateTo,
        Long snapshotId,
        UUID actorId,
        boolean activityOnly) {

    /**
     * Compatibility constructor for internal callers that predate the
     * UUID-authoritative actor picker and activity view.
     */
    AuditSearchCriteria(
            String action,
            String actorAccount,
            String actorScope,
            String riskLevel,
            String eventCategory,
            String outcome,
            String keyword,
            String targetType,
            String targetId,
            String eventSource,
            String requestId,
            String operationKind,
            LocalDate dateFrom,
            LocalDate dateTo,
            Long snapshotId) {
        this(
                action, actorAccount, actorScope, riskLevel, eventCategory, outcome,
                keyword, targetType, targetId, eventSource, requestId, operationKind,
                dateFrom, dateTo, snapshotId, null, true);
    }

    AuditSearchCriteria withSnapshotId(long value) {
        return new AuditSearchCriteria(
                action, actorAccount, actorScope, riskLevel, eventCategory, outcome,
                keyword, targetType, targetId, eventSource, requestId, operationKind,
                dateFrom, dateTo, value, actorId, activityOnly);
    }
}

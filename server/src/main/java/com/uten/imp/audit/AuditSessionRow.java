package com.uten.imp.audit;

import java.time.OffsetDateTime;
import java.util.UUID;

/**
 * One server-grouped login session in the audit center.
 *
 * <p>The status describes only evidence that exists in the audit/token stores. It
 * deliberately does not claim that a credential is online, that an event was read,
 * or that an unrecorded logout happened at a guessed time.
 */
public record AuditSessionRow(
        UUID sessionId,
        UUID actorId,
        String actorAccount,
        String actorDisplay,
        String actorDepartment,
        String actorPosition,
        String startAction,
        String startLabel,
        OffsetDateTime loginAt,
        OffsetDateTime firstActivityAt,
        OffsetDateTime lastActivityAt,
        OffsetDateTime logoutAt,
        String status,
        String statusLabel,
        long eventCount,
        long operationCount,
        long successCount,
        long failureCount,
        long postLogoutCount,
        UUID deviceInstallationId,
        String deviceLabel,
        String devicePlatform,
        String lastIp,
        OffsetDateTime refreshExpiresAt,
        OffsetDateTime refreshRevokedAt,
        String refreshCredentialStatus,
        String refreshCredentialStatusLabel,
        boolean timelinePartial) {
}

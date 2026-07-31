package com.uten.imp.audit;

import java.time.OffsetDateTime;
import java.util.UUID;

/**
 * Full, super-admin-only audit detail.
 *
 * <p>The list deliberately stays compact; this detail exposes the redacted
 * before/after JSON written by the database audit trigger so a production
 * package, demand, reservation, supply peg, issue, return, report or inbound
 * change can be explained from System Management without querying the
 * database manually.
 */
public record AuditLogDetail(
        Long id,
        UUID actorId,
        String actorAccount,
        String action,
        String targetType,
        String targetId,
        String before,
        String after,
        String ip,
        String userAgent,
        String result,
        OffsetDateTime createdAt) {

    static AuditLogDetail of(AuditLog value) {
        return new AuditLogDetail(
                value.getId(),
                value.getActorId(),
                value.getActorAccount(),
                value.getAction(),
                value.getTargetType(),
                value.getTargetId(),
                value.getBefore(),
                value.getAfter(),
                value.getIp(),
                value.getUserAgent(),
                value.getResult(),
                value.getCreatedAt());
    }
}

package com.uten.imp.audit;

import java.time.OffsetDateTime;
import java.util.UUID;

/** One UUID-authoritative person option for the audit-center actor picker. */
public record AuditActorOption(
        UUID actorId,
        String actorType,
        String account,
        String displayName,
        String name,
        String department,
        String position,
        OffsetDateTime lastActivityAt,
        UUID departmentId,
        String accountStatus,
        String employmentStatus) {
    public AuditActorOption(UUID actorId, String actorType, String account, String displayName,
                            String name, String department, String position, OffsetDateTime lastActivityAt,
                            UUID departmentId) {
        this(actorId, actorType, account, displayName, name, department, position,
                lastActivityAt, departmentId, null, null);
    }
}

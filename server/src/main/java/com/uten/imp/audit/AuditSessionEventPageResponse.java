package com.uten.imp.audit;

import java.time.OffsetDateTime;
import java.util.List;

/** Keyset-paginated event slice for one and only one audit session. */
public record AuditSessionEventPageResponse(
        List<AuditLogRow> items,
        int size,
        OffsetDateTime nextCursorAt,
        Long nextCursorId,
        boolean hasMore,
        long snapshotAuditId) {
}

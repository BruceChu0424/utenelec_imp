package com.uten.imp.audit;

import java.util.List;

/** Stable, high-water-mark bounded page of audit sessions. */
public record AuditSessionPageResponse(
        List<AuditSessionRow> items,
        int page,
        int size,
        long total,
        int totalPages,
        long snapshotAuditId) {
}

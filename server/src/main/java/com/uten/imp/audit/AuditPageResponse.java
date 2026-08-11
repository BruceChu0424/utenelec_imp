package com.uten.imp.audit;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.util.List;

/** Audit-log page bounded by the returned high-water-mark audit ID. */
@Getter
@AllArgsConstructor
public class AuditPageResponse {

    private final List<AuditLogRow> items;
    private final int page;
    private final int size;
    private final long total;
    private final int totalPages;
    private final long snapshotId;
}

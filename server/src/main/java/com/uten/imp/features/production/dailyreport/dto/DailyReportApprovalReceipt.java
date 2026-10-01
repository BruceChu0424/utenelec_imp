package com.uten.imp.features.production.dailyreport.dto;

import java.util.UUID;

/** Facts from the append-only command row. Null version metadata is historical, not version zero. */
public record DailyReportApprovalReceipt(
        UUID reportId,
        String idempotencyKey,
        Integer commandVersion,
        Long reviewedVersion,
        boolean replay) {
    public String getReviewProtection() {
        return Integer.valueOf(2).equals(commandVersion)
                ? "REVIEWED_VERSION" : "LEGACY_UNVERSIONED";
    }
}

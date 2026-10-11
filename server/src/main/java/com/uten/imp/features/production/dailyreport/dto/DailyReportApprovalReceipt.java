package com.uten.imp.features.production.dailyreport.dto;

import java.util.UUID;

/** Facts from the append-only command row. Null version metadata is historical, not version zero. */
public record DailyReportApprovalReceipt(
        UUID reportId,
        String idempotencyKey,
        Integer commandVersion,
        Long reviewedVersion,
        boolean replay,
        String materialReviewFingerprint) {
    public DailyReportApprovalReceipt(UUID reportId, String key, Integer commandVersion,
            Long reviewedVersion, boolean replay) {
        this(reportId, key, commandVersion, reviewedVersion, replay, null);
    }
    public String getReviewProtection() {
        if (Integer.valueOf(3).equals(commandVersion)) return "REVIEWED_MATERIAL_SNAPSHOT";
        return Integer.valueOf(2).equals(commandVersion)
                ? "REVIEWED_VERSION" : "LEGACY_UNVERSIONED";
    }
}

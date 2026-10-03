package com.uten.imp.features.production.dailyreport.dto;

import java.util.UUID;

/**
 * Observes the original CREATE command. UNKNOWN is inconclusive and must keep
 * the frozen draft; detail is the current read-only history projection.
 */
public record DailyReportCreateResolution(
        String status,
        String idempotencyKey,
        String requestHash,
        Integer fullPayloadVersion,
        String fullPayloadHash,
        UUID reportId,
        DailyReportDetail detail) {
}

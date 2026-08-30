package com.uten.imp.audit;

import java.time.LocalDate;
import java.util.List;

/** Compact statistics for the selected person and Beijing date window. */
public record AuditSummary(
        long total,
        long riskCount,
        long criticalCount,
        long failedCount,
        /** Compatibility field name; value is the effective write-operation count. */
        long dataChangeCount,
        List<DailyPoint> dailyTrend) {

    public record DailyPoint(LocalDate date, long total, long riskCount) {
    }
}

package com.uten.imp.audit;

import java.time.LocalDate;
import java.util.List;

/** Compact statistics for the audit overview cards and seven-day trend. */
public record AuditSummary(
        long total,
        long riskCount,
        long criticalCount,
        long failedCount,
        long dataChangeCount,
        List<DailyPoint> dailyTrend) {

    public record DailyPoint(LocalDate date, long total, long riskCount) {
    }
}

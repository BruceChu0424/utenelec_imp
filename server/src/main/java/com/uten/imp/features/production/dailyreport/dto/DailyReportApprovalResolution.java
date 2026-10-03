package com.uten.imp.features.production.dailyreport.dto;

/** Read-only observation. UNCONFIRMED does not prove that an older in-flight request cannot commit. */
public record DailyReportApprovalResolution(
        String status,
        DailyReportApprovalReceipt receipt,
        DailyReportDetail detail) {
}

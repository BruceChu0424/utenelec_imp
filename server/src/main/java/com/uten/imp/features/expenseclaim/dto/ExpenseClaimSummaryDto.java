package com.uten.imp.features.expenseclaim.dto;

import java.math.BigDecimal;

/**
 * 报销队列汇总（审批列表页顶部统计卡）：待审批/待打款两队列的单数与金额，
 * 外加本月提交/本月打款口径（财务汇总）。金额均为人民币两位小数。
 */
public record ExpenseClaimSummaryDto(
        long pendingCount,
        BigDecimal pendingAmount,
        long payableCount,
        BigDecimal payableAmount,
        long monthSubmittedCount,
        BigDecimal monthSubmittedAmount,
        long monthPaidCount,
        BigDecimal monthPaidAmount) {
}

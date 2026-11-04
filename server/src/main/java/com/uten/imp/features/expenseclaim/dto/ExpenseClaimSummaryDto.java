package com.uten.imp.features.expenseclaim.dto;

import java.math.BigDecimal;

/**
 * 报销队列汇总（审批列表页顶部统计卡）：待审批/待打款两队列的单数与金额，
 * 外加本月提交/本月打款口径（财务汇总）。金额均为人民币两位小数。
 * pending/payable 是授权浏览范围；actionable 两项独立沿用 /counts 的实际任务资格与回避规则。
 */
public record ExpenseClaimSummaryDto(
        long pendingCount,
        BigDecimal pendingAmount,
        long payableCount,
        BigDecimal payableAmount,
        long monthSubmittedCount,
        BigDecimal monthSubmittedAmount,
        long monthPaidCount,
        BigDecimal monthPaidAmount,
        long actionablePendingCount,
        long actionablePayableCount) {
    /** Browsing totals never imply a task subscription or command capability. */
    public ExpenseClaimSummaryDto(long pendingCount, BigDecimal pendingAmount,
            long payableCount, BigDecimal payableAmount, long monthSubmittedCount,
            BigDecimal monthSubmittedAmount, long monthPaidCount, BigDecimal monthPaidAmount) {
        this(pendingCount, pendingAmount, payableCount, payableAmount, monthSubmittedCount,
                monthSubmittedAmount, monthPaidCount, monthPaidAmount, 0, 0);
    }

    public ExpenseClaimSummaryDto withActionableCounts(long pending, long payable) {
        return new ExpenseClaimSummaryDto(pendingCount, pendingAmount, payableCount, payableAmount,
                monthSubmittedCount, monthSubmittedAmount, monthPaidCount, monthPaidAmount, pending, payable);
    }
    public String getPendingAmountExact(){return com.uten.imp.common.util.DecimalText.of(pendingAmount);}
    public String getPayableAmountExact(){return com.uten.imp.common.util.DecimalText.of(payableAmount);}
    public String getMonthSubmittedAmountExact(){return com.uten.imp.common.util.DecimalText.of(monthSubmittedAmount);}
    public String getMonthPaidAmountExact(){return com.uten.imp.common.util.DecimalText.of(monthPaidAmount);}
}

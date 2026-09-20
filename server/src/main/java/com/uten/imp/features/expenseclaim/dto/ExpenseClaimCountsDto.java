package com.uten.imp.features.expenseclaim.dto;
public record ExpenseClaimCountsDto(long draftCount, long rejectedCount,
        long pendingApprovalCount, long pendingPaymentCount) {}

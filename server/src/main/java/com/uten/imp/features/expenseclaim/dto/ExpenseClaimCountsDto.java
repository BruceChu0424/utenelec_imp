package com.uten.imp.features.expenseclaim.dto;

/**
 * 报销计数。前三个是本人视角(draft/rejected 红：等本人动手；processing 黄：已提交在审批链上跑，
 * 现在不用本人动手)，后两个是审批人视角(已排除自审自付)。
 * processingCount 追加在末尾，不打乱既有位置构造。
 */
public record ExpenseClaimCountsDto(long draftCount, long rejectedCount,
        long pendingApprovalCount, long pendingPaymentCount,
        long processingCount) {}

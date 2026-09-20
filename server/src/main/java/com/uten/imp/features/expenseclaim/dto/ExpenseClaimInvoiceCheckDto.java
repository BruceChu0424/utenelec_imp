package com.uten.imp.features.expenseclaim.dto;

/**
 * 发票查重预检结果：duplicated=true 时携带已登记该票的报销单号/状态/申请人，
 * 前端在登记表单里即时提示（财会〔2020〕6 号防重复入账）。
 */
public record ExpenseClaimInvoiceCheckDto(
        boolean duplicated,
        String heldByClaimNo,
        String heldByStatus,
        String heldByApplicantName) {

    public static final ExpenseClaimInvoiceCheckDto CLEAN =
            new ExpenseClaimInvoiceCheckDto(false, null, null, null);
}

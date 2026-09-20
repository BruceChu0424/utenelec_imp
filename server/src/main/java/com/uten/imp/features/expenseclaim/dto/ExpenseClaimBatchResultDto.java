package com.uten.imp.features.expenseclaim.dto;

/** 批量审批/驳回结果（整批一个事务：要么全成功，要么异常回滚无此响应）。 */
public record ExpenseClaimBatchResultDto(int processed) {
}

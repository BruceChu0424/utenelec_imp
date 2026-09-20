package com.uten.imp.features.expenseclaim.dto;

import jakarta.validation.constraints.NotEmpty;
import jakarta.validation.constraints.Size;

import java.util.List;
import java.util.UUID;

/** 批量审批/驳回入参（单事务全成全败，上限 50 与前端一致）。 */
public record ExpenseClaimBatchRequest(
        @NotEmpty @Size(max = 50) List<@jakarta.validation.constraints.NotNull UUID> ids,
        /** 批量驳回时必填（服务层校验）；批量通过忽略。 */
        @Size(max = 1000) String reason, java.util.Map<UUID, Long> expectedVersions) {
    public ExpenseClaimBatchRequest(List<UUID> ids, String reason) { this(ids,reason,null); }
}

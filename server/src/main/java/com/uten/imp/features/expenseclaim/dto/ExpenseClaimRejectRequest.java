package com.uten.imp.features.expenseclaim.dto;

import jakarta.validation.constraints.Size;

public record ExpenseClaimRejectRequest(
        @Size(max = 1000) String reason, Long expectedVersion
) {
    public ExpenseClaimRejectRequest(String reason) { this(reason,null); }
}

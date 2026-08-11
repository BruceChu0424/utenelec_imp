package com.uten.imp.features.expenseclaim.dto;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;

public record ExpenseClaimRejectRequest(
        @NotBlank @Size(max = 1000) String reason
) {
}

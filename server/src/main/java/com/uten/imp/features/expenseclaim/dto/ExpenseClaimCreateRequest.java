package com.uten.imp.features.expenseclaim.dto;

import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotEmpty;
import jakarta.validation.constraints.Size;

import java.util.List;

public record ExpenseClaimCreateRequest(
        @NotBlank @Size(max = 200) String title,
        @Size(max = 2000) String remark,
        @NotEmpty @Size(max = 100) List<@Valid ExpenseClaimItemInput> items
) {
}

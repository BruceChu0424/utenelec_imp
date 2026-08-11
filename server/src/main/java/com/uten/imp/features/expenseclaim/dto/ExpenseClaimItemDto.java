package com.uten.imp.features.expenseclaim.dto;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

public record ExpenseClaimItemDto(
        UUID id,
        String category,
        BigDecimal amount,
        LocalDate date,
        String description
) {
}

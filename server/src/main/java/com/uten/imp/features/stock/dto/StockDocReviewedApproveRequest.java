package com.uten.imp.features.stock.dto;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Pattern;
import java.util.UUID;
import java.util.List;

public record StockDocReviewedApproveRequest(
        @NotBlank @Pattern(regexp = "[0-9a-f]{64}") String expectedReviewToken,
        @jakarta.validation.constraints.Size(min = 1, max = com.uten.imp.common.validation.RequestLimits.DOCUMENT_LINES)
        List<@jakarta.validation.constraints.NotNull UUID> itemIds) {
    public StockDocReviewedApproveRequest(String expectedReviewToken) {
        this(expectedReviewToken, null);
    }
}

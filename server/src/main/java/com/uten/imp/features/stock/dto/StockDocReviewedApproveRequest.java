package com.uten.imp.features.stock.dto;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Pattern;

public record StockDocReviewedApproveRequest(
        @NotBlank @Pattern(regexp = "[0-9a-f]{64}") String expectedReviewToken) {
}

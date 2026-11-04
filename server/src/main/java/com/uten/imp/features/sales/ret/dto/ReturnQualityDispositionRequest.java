package com.uten.imp.features.sales.ret.dto;

import com.uten.imp.common.validation.DocumentQuantity;
import jakarta.validation.constraints.DecimalMin;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;

import java.math.BigDecimal;

/** A controlled disposition of physically received, quality-frozen return stock. */
public record ReturnQualityDispositionRequest(
        @NotBlank String action,
        @NotNull @DecimalMin(value = "0", inclusive = false)
        @DocumentQuantity BigDecimal baseQty,
        @NotBlank @Size(max = 500) String reason,
        @NotBlank @Size(min = 8, max = 128) String idempotencyKey) {
}

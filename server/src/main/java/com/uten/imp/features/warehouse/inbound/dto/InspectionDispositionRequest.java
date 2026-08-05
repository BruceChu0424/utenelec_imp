package com.uten.imp.features.warehouse.inbound.dto;

import jakarta.validation.constraints.DecimalMin;
import jakarta.validation.constraints.Digits;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Pattern;
import jakarta.validation.constraints.Size;

import java.math.BigDecimal;

/** 采购/委外收货待检处置请求：PASS 合格放行（进可用 + 唤醒生产）/ FAIL 不合格（只记事实）。 */
public record InspectionDispositionRequest(
        @NotBlank
        @Pattern(regexp = "PASS|FAIL", message = "质检结论仅支持 PASS 或 FAIL")
        String action,
        @NotNull @DecimalMin(value = "0", inclusive = false)
        @Digits(integer = 14, fraction = 4) BigDecimal baseQty,
        @NotBlank @Size(max = 500) String reason,
        @NotBlank @Size(min = 8, max = 128) String idempotencyKey) {
}

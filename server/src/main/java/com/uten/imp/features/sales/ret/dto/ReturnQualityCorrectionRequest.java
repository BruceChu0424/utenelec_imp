package com.uten.imp.features.sales.ret.dto;

import jakarta.validation.constraints.DecimalMin;
import jakarta.validation.constraints.Digits;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;

import java.math.BigDecimal;

/**
 * 受控纠错（追加式补偿）：撤回已登记的某类质检处置量（V291）。
 *
 * <p>{@code action} 指明被撤回的处置桶：GOOD_RELEASE（撤回良品释放，反向出库）、
 * SCRAP（撤回报废，恢复待处置）、REWORK（撤回返工，恢复待处置）。补偿事件以
 * {@code *_REVOKED} 追加进不可改删的事件账；原处置事件保留为历史证据。
 */
public record ReturnQualityCorrectionRequest(
        @NotBlank String action,
        @NotNull @DecimalMin(value = "0", inclusive = false)
        @Digits(integer = 14, fraction = 4) BigDecimal baseQty,
        @NotBlank @Size(max = 500) String reason,
        @NotBlank @Size(min = 8, max = 128) String idempotencyKey) {
}

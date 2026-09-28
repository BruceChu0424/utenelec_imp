package com.uten.imp.features.stock.dto;

import com.uten.imp.common.validation.RequestLimits;
import jakarta.validation.Valid;
import jakarta.validation.constraints.DecimalMin;
import jakarta.validation.constraints.Digits;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Pattern;
import jakarta.validation.constraints.Size;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

/**
 * Warehouse staff select where the current workshop's surplus is physically received.
 *
 * <p>lines 选填(ADR-135 §3.9): 退料明细 id -> 收料时的实称重量(千克, 最多 4 位小数, 空或 0 = 没称),
 * 一次写进收料确认记录, 退料入库流水按它记实称重量。
 */
public record ProductionMaterialReturnConfirmRequest(
        @NotNull UUID warehouseId,
        @NotNull @Pattern(regexp="[A-Za-z0-9._:-]{8,128}") String idempotencyKey,
        @Valid @Size(max = RequestLimits.DOCUMENT_LINES) List<Line> lines) {

    public ProductionMaterialReturnConfirmRequest(UUID warehouseId, String idempotencyKey) {
        this(warehouseId, idempotencyKey, null);
    }

    /** 一行退料的收料实称重量。 */
    public record Line(
            @NotNull UUID itemId,
            @DecimalMin("0") @Digits(integer = 14, fraction = 4) BigDecimal weightKg) {
    }
}

package com.uten.imp.features.production.execution;

import com.fasterxml.jackson.databind.JsonNode;
import jakarta.validation.constraints.DecimalMin;
import jakarta.validation.constraints.Digits;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.PositiveOrZero;
import jakarta.validation.constraints.Size;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.UUID;

public final class ProductionOverproductionRateContracts {
    private ProductionOverproductionRateContracts() {}

    public record SubmitRequest(
            @NotNull UUID segmentId,
            @NotNull @PositiveOrZero Long expectedRateVersion,
            @NotNull @DecimalMin("0") @Digits(integer=3,fraction=6) BigDecimal requestedRate,
            @NotBlank @Size(min=2,max=500) String reason,
            @NotBlank @Size(min=8,max=128) String idempotencyKey) {}

    public record DecisionRequest(
            @NotNull @PositiveOrZero Long expectedVersion,
            @NotBlank @Size(min=8,max=128) String idempotencyKey,
            @Size(max=500) String reason) {}

    public record RateContext(
            UUID segmentId, UUID planId, String planNo, String segmentCode,
            String goodsCode, String goodsName, String colorName, String unitName,
            BigDecimal plannedQty, BigDecimal effectiveRate, long rateVersion, BigDecimal limitQty,
            UUID pendingRequestId, BigDecimal pendingRate, boolean canSubmit, boolean overproductionPolicyApplies,
            long requestGeneration) {}

    public record RequestView(
            UUID id, UUID segmentId, UUID planId, String planNo, String segmentCode,
            String goodsName, String goodsCode, String colorName, String unitName,
            BigDecimal plannedQty, BigDecimal beforeRate, BigDecimal requestedRate,
            String status, long rowVersion, String reason, String submittedByName,
            OffsetDateTime submittedAt, JsonNode beforeSnapshot, JsonNode afterSnapshot,
            String decisionReason, String reviewedByName, OffsetDateTime reviewedAt,
            boolean canApprove, boolean canReturn, String blockingReason) {}
}

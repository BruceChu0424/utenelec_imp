package com.uten.imp.features.production.dailyreport;

import com.fasterxml.jackson.databind.annotation.JsonSerialize;
import com.uten.imp.common.finance.ExactDecimalText;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.PositiveOrZero;
import jakarta.validation.constraints.Size;
import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;

public final class ProductionOverLimitDispositionContracts {
    private ProductionOverLimitDispositionContracts() {}

    public record DecisionRequest(@NotBlank String action,
            @NotBlank @Size(min=2,max=500) String reason,
            @NotNull @PositiveOrZero Long expectedVersion,
            @NotBlank @Size(min=8,max=128) String idempotencyKey) {}

    public record DecisionView(String action,String reason,String decidedByName,OffsetDateTime decidedAt) {}

    public record View(UUID id,String status,long rowVersion,UUID reportId,String reportNo,
            UUID reportItemId,UUID outputBatchId,UUID sourceSegmentId,String segmentCode,
            UUID planId,String planNo,String goodsCode,String goodsName,String colorName,String unitName,
            @JsonSerialize(using=ExactDecimalText.class) BigDecimal plannedQty,
            @JsonSerialize(using=ExactDecimalText.class) BigDecimal allowedRate,
            @JsonSerialize(using=ExactDecimalText.class) BigDecimal actualBatchQty,
            @JsonSerialize(using=ExactDecimalText.class) BigDecimal withinAuthorizationQty,
            @JsonSerialize(using=ExactDecimalText.class) BigDecimal overLimitQty,String overLimitReason,
            OffsetDateTime createdAt,String decisionReason,String decidedByName,OffsetDateTime decidedAt,
            boolean canDecide,String blockingReason,List<DecisionView> decisionHistory) {}
}

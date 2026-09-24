package com.uten.imp.features.production.fulfillment;

import com.fasterxml.jackson.databind.JsonNode;
import jakarta.validation.constraints.*;
import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;

public final class ProductionMaterialIncrementContracts {
    private ProductionMaterialIncrementContracts() {}
    public record SubmitRequest(@NotNull UUID originalDemandId, @NotNull UUID targetSegmentId,
            UUID supplementProofId, @NotNull @DecimalMin(value="0",inclusive=false) @Digits(integer=14,fraction=4) BigDecimal deltaQty,
            @NotBlank @Size(min=2,max=500) String reason, @NotNull @PositiveOrZero Long expectedDemandVersion,
            @NotBlank @Size(min=8,max=128) String idempotencyKey) {}
    public record DecisionRequest(@NotNull @PositiveOrZero Long expectedVersion,
            @NotBlank @Size(min=8,max=128) String idempotencyKey, @Size(max=500) String reason) {}
    public record DemandView(UUID originalDemandId,UUID sourcePlanId,UUID sourceSegmentId,UUID goodsId,
            String goodsCode,String goodsName,String colorName,String unitName,BigDecimal requiredQty,
            BigDecimal approvedIncrementQty,BigDecimal netIssuedQty,BigDecimal availableQty,long lockVersion,
            UUID pendingRequestId,BigDecimal pendingDeltaQty,long requestGeneration) {}
    public record Context(UUID segmentId,UUID planId,String planNo,String segmentCode,UUID supplementProofId,
            boolean canSubmit,String blockingReason,List<DemandView> demands) {}
    public record RequestView(UUID id,UUID originalDemandId,UUID targetSegmentId,UUID supplementProofId,
            UUID planId,String planNo,String segmentCode,String goodsName,String goodsCode,String colorName,String unitName,
            BigDecimal originalRequiredQty,BigDecimal approvedIncrementQty,BigDecimal deltaQty,String status,long rowVersion,
            String reason,String submittedByName,OffsetDateTime submittedAt,JsonNode beforeSnapshot,JsonNode afterSnapshot,
            String decisionReason,String reviewedByName,OffsetDateTime reviewedAt,boolean canApprove,boolean canReturn,
            String blockingReason,UUID authorizedDemandId,boolean canCancel) {}
}

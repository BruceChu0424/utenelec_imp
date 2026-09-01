package com.uten.imp.features.production.analysis;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;

public final class SubcontractPreparationContracts {
    private SubcontractPreparationContracts() {
    }

    public record Task(
            UUID planItemId, UUID orderId, UUID orderItemId, String orderBillNo,
            UUID targetGoodsId, String targetGoodsCode, String targetGoodsName,
            UUID colorId, String colorName, UUID unitId, String unitName,
            BigDecimal requiredQty, BigDecimal preparedQty, BigDecimal issuedQty,
            LocalDate needDate, String status, String blocker,
             UUID preparationWarehouseId, String preparationWarehouseName,
             boolean warehouseSelectionRequired,
             UUID sourceAnalysisId, UUID sourceMaterialLineId,
             String handoffStatus, BigDecimal takeoverQty,
             BigDecimal handedOffEntitlementQty, String handoffBlocker,
             UUID analysisId, UUID analysisItemId, List<String> allowedActions,
            long version, OffsetDateTime updatedAt) {
    }

    public record StartRequest(
            @NotNull Long expectedVersion,
            @NotBlank @Size(min = 8, max = 128) String idempotencyKey,
            UUID warehouseId) {
    }

    public record StartResult(
             UUID planItemId, String status, UUID analysisId,
             UUID analysisItemId, long version,
             UUID sourceAnalysisId, UUID sourceMaterialLineId,
             UUID handoffId, String handoffStatus,
             BigDecimal takeoverQty, BigDecimal handedOffEntitlementQty) {
    }
}

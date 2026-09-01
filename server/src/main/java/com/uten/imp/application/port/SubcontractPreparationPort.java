package com.uten.imp.application.port;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;

/**
 * Subcontract-owned task/state port used by the production coordinator.
 * Production creates the analysis; subcontract keeps the order-line gate.
 */
public interface SubcontractPreparationPort {

    Page tasks(TaskQuery query, boolean canStart, boolean canOpen);

    /**
     * Read-only start preflight.  The production coordinator uses the returned
     * source dimensions to acquire the canonical inventory locks before the
     * subcontract plan row is claimed.
     */
    StartContext prepareStart(UUID planItemId, UUID requestedWarehouseId);

    StartClaim beginStart(
            UUID planItemId,
            long expectedVersion,
            String idempotencyKey,
            UUID requestedWarehouseId,
            StartContext expectedContext);

    StartResult completeStart(
            StartClaim claim,
            UUID analysisId,
            UUID analysisItemId,
            UUID actorUserId);

    void requireRefresh(
            UUID analysisId,
            UUID warehouseId,
            String sourceRef,
            UUID goodsId,
            UUID colorId,
            UUID unitId,
            BigDecimal requestedQty);

    record TaskQuery(
            int page,
            int size,
            String status,
            String keyword,
            UUID planItemId,
            UUID sourceAnalysisId,
            UUID sourceMaterialLineId) {
    }

    record Page(
            List<Task> content,
            int page,
            int size,
            long totalElements,
            int totalPages) {
    }

    record Task(
            UUID planItemId,
            UUID orderId,
            UUID orderItemId,
            String orderBillNo,
            UUID targetGoodsId,
            String targetGoodsCode,
            String targetGoodsName,
            UUID colorId,
            String colorName,
            UUID unitId,
            String unitName,
            BigDecimal requiredQty,
            BigDecimal preparedQty,
            BigDecimal issuedQty,
            LocalDate needDate,
            String status,
            String blocker,
            UUID preparationWarehouseId,
            String preparationWarehouseName,
            boolean warehouseSelectionRequired,
            UUID sourceAnalysisId,
            UUID sourceMaterialLineId,
            String handoffStatus,
            BigDecimal takeoverQty,
            BigDecimal handedOffEntitlementQty,
            String handoffBlocker,
            UUID analysisId,
            UUID analysisItemId,
            List<String> allowedActions,
            long version,
             OffsetDateTime updatedAt) {
    }

    record InventoryDimension(UUID goodsId, UUID colorId) {
    }

    record StartContext(
            UUID planItemId,
            UUID sourceSupplyActionId,
            UUID sourceSupplyActionAllocationId,
            UUID sourceAnalysisId,
            UUID sourceAnalysisItemId,
            UUID sourceMaterialLineId,
            List<InventoryDimension> inventoryDimensions) {
        public boolean hasSourceAnalysis() {
            return sourceAnalysisId != null;
        }
    }

    record StartClaim(
            boolean replay,
            UUID planItemId,
            UUID orderItemId,
            String orderBillNo,
            UUID goodsId,
            UUID colorId,
            UUID unitId,
            BigDecimal requiredQty,
            LocalDate needDate,
            UUID warehouseId,
            long expectedVersion,
            long resultingVersion,
            String idempotencyKey,
            String requestHash,
            UUID sourceSupplyActionId,
            UUID sourceSupplyActionAllocationId,
            UUID sourceAnalysisId,
            UUID sourceAnalysisItemId,
            UUID sourceMaterialLineId,
            long sourceAnalysisVersion,
            String sourceAnalysisFingerprint,
            UUID replayAnalysisId,
            UUID replayAnalysisItemId,
            UUID replayHandoffId) {
    }

    record StartResult(
            UUID planItemId,
            String status,
            UUID analysisId,
            UUID analysisItemId,
            long version,
            UUID sourceAnalysisId,
            UUID sourceMaterialLineId,
            UUID handoffId,
            String handoffStatus,
            BigDecimal takeoverQty,
            BigDecimal handedOffEntitlementQty) {
    }
}

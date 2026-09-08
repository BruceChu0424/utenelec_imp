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

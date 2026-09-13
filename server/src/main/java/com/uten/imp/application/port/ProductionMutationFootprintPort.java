package com.uten.imp.application.port;

import com.uten.imp.application.concurrency.FulfillmentMutationLockPlan;
import java.util.Collection;
import java.util.UUID;

/** Read-only discovery of production callbacks for physical or supply-state mutations. */
public interface ProductionMutationFootprintPort {
    record WarehouseDimension(UUID warehouseId, UUID goodsId, UUID colorId) {}

    FulfillmentMutationLockPlan forStockDocuments(Collection<UUID> documentIds);
    FulfillmentMutationLockPlan forAnalyses(Collection<UUID> analysisIds);
    /**
     * Only the plan-creation loop may hold this scope. Its complete material/BOM
     * structure is verified again on close, before any analysis refresh.
     * Dynamic commercial and execution discovery remains live on every call.
     */
    AnalysisStructureScope openAnalysisStructureScope(UUID analysisId);

    interface AnalysisStructureScope extends AutoCloseable {
        @Override void close();
    }
    FulfillmentMutationLockPlan forSharedFutureClaim(UUID analysisId);
    FulfillmentMutationLockPlan forPreview(
            Collection<UUID> salesItemIds, Collection<UUID> subcontractItemIds,
            Collection<WarehouseDimension> manualRoots, Collection<UUID> warehouseIds,
            Collection<UUID> existingAnalysisIds);

    /**
     * Pass only source dimensions whose physical quantity or authoritative
     * availability/in-transit state changes, including a resolved IQC verdict.
     * Never pass additional dimensions discovered solely for locking.
     * Exact analyses include original source
     * plans reopened by a reversal, even when they are currently completed.
     */
    FulfillmentMutationLockPlan forInventoryChange(
            Collection<WarehouseDimension> changedDimensions, Collection<UUID> exactAnalysisIds);
}

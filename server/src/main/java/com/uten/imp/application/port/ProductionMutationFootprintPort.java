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

    /**
     * 先入库后质检(V597)：品质合格时同事务自动点收会新建一张 FINISHED_IN 并立刻走
     * {@link #forStockDocuments}，但那张单在预锁时还不存在。这里给出它的等价前像——
     * 落仓维度的唤醒目标 + 该计划行父工序需求 + 销售归属——让品质判定一次把锁拿全，
     * 回调时 requireCovered 才不会撞「禁止持锁补拿上游目标」。
     */
    FulfillmentMutationLockPlan forFutureFinishedInbound(
            Collection<WarehouseDimension> shelvedDimensions, Collection<UUID> planItemIds);
}

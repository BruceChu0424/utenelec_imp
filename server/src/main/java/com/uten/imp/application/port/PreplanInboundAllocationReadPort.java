package com.uten.imp.application.port;

import java.math.BigDecimal;
import java.util.Collection;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * Amount-free CQRS projection for warehouse IQC stock-in purpose and result.
 *
 * <p>The preview is explicitly advisory until the stock-in transaction commits.
 * The actual projection is rebuilt from the append-only reservation, exact-peg
 * and entitlement ledgers; callers must never persist a second allocation fact.</p>
 */
public interface PreplanInboundAllocationReadPort {

    PreplanInboundAllocationReadPort NOOP = new PreplanInboundAllocationReadPort() {
        @Override
        public Map<UUID, List<AllocationView>> expectedForPassEvents(
                String receiptType, UUID receiptId, Collection<UUID> passEventIds) {
            return Map.of();
        }

        @Override
        public Map<UUID, List<AllocationView>> expectedForOrderItems(
                String orderType, Collection<OrderItemQuantity> orderItems) {
            return Map.of();
        }

        @Override
        public List<AllocationView> actualForBatches(Collection<UUID> stockInBatchIds) {
            return List.of();
        }
    };

    String EXACT_ANALYSIS = "EXACT_ANALYSIS";
    String SHARED_CLAIM = "SHARED_CLAIM";
    String FORMAL_DEMAND = "FORMAL_DEMAND";
    String PUBLIC = "PUBLIC";

    record AllocationView(
            UUID passEventId,
            UUID stockInBatchItemId,
            String kind,
            BigDecimal qty,
            UUID actualWarehouseId,
            String actualWarehouseName,
            UUID targetWarehouseId,
            String targetWarehouseName,
            List<String> intendedWarehouseNames,
            boolean warehouseMatches,
            UUID analysisId,
            UUID analysisMaterialId,
            String productCode,
            String productName,
            String sourceLabel,
            UUID planId,
            String planNo,
            UUID executionSegmentId,
            String executionSegmentCode,
            UUID workshopDepartmentId,
            String workshopName,
            UUID responsibleEmployeeId,
            String responsibleEmployeeName,
            String formationStatus) {
    }

    record OrderItemQuantity(UUID orderItemId, BigDecimal receivableBaseQty) {
    }

    /** Batch-computed preview keyed by PASS event; implementations must avoid N+1 queries. */
    Map<UUID, List<AllocationView>> expectedForPassEvents(
            String receiptType,
            UUID receiptId,
            Collection<UUID> passEventIds);

    /** Pre-arrival destination preview keyed by commercial order item. */
    Map<UUID, List<AllocationView>> expectedForOrderItems(
            String orderType,
            Collection<OrderItemQuantity> orderItems);

    /** Actual allocation/public result for committed warehouse stock-in batches. */
    List<AllocationView> actualForBatches(Collection<UUID> stockInBatchIds);

    default List<AllocationView> actualForBatch(UUID stockInBatchId) {
        return stockInBatchId == null
                ? List.of() : actualForBatches(List.of(stockInBatchId));
    }
}

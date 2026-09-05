package com.uten.imp.features.warehouse.inbound;

import com.fasterxml.jackson.databind.annotation.JsonSerialize;
import com.fasterxml.jackson.databind.ser.std.ToStringSerializer;
import jakarta.validation.Valid;
import jakarta.validation.constraints.DecimalMin;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotEmpty;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;

/** Amount-free contracts for the warehouse-owned IQC released-stock queue. */
public final class ProcurementIqcStockInContracts {

    private ProcurementIqcStockInContracts() {
    }

    public record TaskDetail(
            String receiptType,
            @JsonSerialize(using = ToStringSerializer.class) UUID receiptId,
            String billNo,
            LocalDate billDate,
            @JsonSerialize(using = ToStringSerializer.class) UUID supplierId,
            String supplierName,
            @JsonSerialize(using = ToStringSerializer.class) UUID warehouseId,
            String warehouseName,
            String qualityStatus,
            long pendingSliceCount,
            boolean completed,
            List<String> allowedActions,
            List<ReleasedSlice> items,
            List<StockInHistoryItem> history) {

        public TaskDetail {
            allowedActions = allowedActions == null ? List.of() : List.copyOf(allowedActions);
            items = items == null ? List.of() : List.copyOf(items);
            history = history == null ? List.of() : List.copyOf(history);
        }
    }

    public record ReleasedSlice(
            @JsonSerialize(using = ToStringSerializer.class) UUID passEventId,
            @JsonSerialize(using = ToStringSerializer.class) UUID inspectionItemId,
            @JsonSerialize(using = ToStringSerializer.class) UUID goodsId,
            String goodsCode,
            String goodsName,
            String colorName,
            @JsonSerialize(using = ToStringSerializer.class) UUID unitId,
            String unitName,
            String sourceOrderNo,
            BigDecimal receivedBaseQty,
            BigDecimal qualityPassedBaseQty,
            BigDecimal warehouseStockedBaseQty,
            BigDecimal releasedBaseQty,
            BigDecimal stockedForReleaseBaseQty,
            BigDecimal remainingBaseQty,
            BigDecimal releasedWeight,
            @JsonSerialize(using = ToStringSerializer.class) UUID weightUnitId,
            String weightUnitName,
            String placeHint,
            String releaseNote,
            String releasedBy,
            OffsetDateTime releasedAt,
            List<InboundAllocation> expectedAllocations) {

        public ReleasedSlice {
            expectedAllocations = expectedAllocations == null
                    ? List.of() : List.copyOf(expectedAllocations);
        }

        public ReleasedSlice(
                UUID passEventId, UUID inspectionItemId, UUID goodsId,
                String goodsCode, String goodsName, String colorName,
                UUID unitId, String unitName, String sourceOrderNo,
                BigDecimal receivedBaseQty, BigDecimal qualityPassedBaseQty,
                BigDecimal warehouseStockedBaseQty, BigDecimal releasedBaseQty,
                BigDecimal stockedForReleaseBaseQty, BigDecimal remainingBaseQty,
                BigDecimal releasedWeight, UUID weightUnitId, String weightUnitName,
                String placeHint, String releaseNote, String releasedBy,
                OffsetDateTime releasedAt) {
            this(passEventId, inspectionItemId, goodsId, goodsCode, goodsName,
                    colorName, unitId, unitName, sourceOrderNo, receivedBaseQty,
                    qualityPassedBaseQty, warehouseStockedBaseQty, releasedBaseQty,
                    stockedForReleaseBaseQty, remainingBaseQty, releasedWeight,
                    weightUnitId, weightUnitName, placeHint, releaseNote, releasedBy,
                    releasedAt, List.of());
        }
    }

    public record StockInHistoryItem(
            @JsonSerialize(using = ToStringSerializer.class) UUID stockInItemId,
            @JsonSerialize(using = ToStringSerializer.class) UUID batchId,
            @JsonSerialize(using = ToStringSerializer.class) UUID passEventId,
            @JsonSerialize(using = ToStringSerializer.class) UUID goodsId,
            String goodsCode,
            String goodsName,
            String colorName,
            String unitName,
            BigDecimal baseQty,
            BigDecimal weight,
            String weightUnitName,
            String place,
            String confirmedBy,
            OffsetDateTime confirmedAt,
            List<InboundAllocation> actualAllocations) {

        public StockInHistoryItem {
            actualAllocations = actualAllocations == null
                    ? List.of() : List.copyOf(actualAllocations);
        }

        public StockInHistoryItem(
                UUID stockInItemId, UUID batchId, UUID passEventId, UUID goodsId,
                String goodsCode, String goodsName, String colorName, String unitName,
                BigDecimal baseQty, BigDecimal weight, String weightUnitName,
                String place, String confirmedBy, OffsetDateTime confirmedAt) {
            this(stockInItemId, batchId, passEventId, goodsId, goodsCode, goodsName,
                    colorName, unitName, baseQty, weight, weightUnitName, place,
                    confirmedBy, confirmedAt, List.of());
        }
    }

    /** Amount-free expected or actual production purpose for one warehouse slice. */
    public record InboundAllocation(
            @JsonSerialize(using = ToStringSerializer.class) UUID passEventId,
            @JsonSerialize(using = ToStringSerializer.class) UUID stockInBatchItemId,
            String kind,
            BigDecimal qty,
            @JsonSerialize(using = ToStringSerializer.class) UUID actualWarehouseId,
            String actualWarehouseName,
            @JsonSerialize(using = ToStringSerializer.class) UUID targetWarehouseId,
            String targetWarehouseName,
            List<String> intendedWarehouseNames,
            boolean warehouseMatches,
            @JsonSerialize(using = ToStringSerializer.class) UUID analysisId,
            @JsonSerialize(using = ToStringSerializer.class) UUID analysisMaterialId,
            String productCode,
            String productName,
            String sourceLabel,
            @JsonSerialize(using = ToStringSerializer.class) UUID planId,
            String planNo,
            @JsonSerialize(using = ToStringSerializer.class) UUID executionSegmentId,
            String executionSegmentCode,
            @JsonSerialize(using = ToStringSerializer.class) UUID workshopDepartmentId,
            String workshopName,
            @JsonSerialize(using = ToStringSerializer.class) UUID responsibleEmployeeId,
            String responsibleEmployeeName,
            String formationStatus) {

        public InboundAllocation {
            intendedWarehouseNames = intendedWarehouseNames == null
                    ? List.of() : List.copyOf(intendedWarehouseNames);
        }
    }

    public record ConfirmRequest(
            @NotBlank @Size(min = 8, max = 128) String idempotencyKey,
            @NotEmpty @Size(max = 100) List<@Valid ConfirmItem> items) {
    }

    public record ConfirmItem(
            @NotNull @JsonSerialize(using = ToStringSerializer.class) UUID passEventId,
            @NotNull @DecimalMin(value = "0.0001") BigDecimal baseQty,
            @NotNull @DecimalMin(value = "0.0001") BigDecimal expectedRemainingBaseQty,
            @NotBlank @Size(max = 100) String place) {
    }

    public record ConfirmResult(
            @JsonSerialize(using = ToStringSerializer.class) UUID batchId,
            boolean replayed,
            int confirmedCount,
            OffsetDateTime confirmedAt,
            List<InboundAllocation> allocations) {

        public ConfirmResult {
            allocations = allocations == null ? List.of() : List.copyOf(allocations);
        }

        public ConfirmResult(
                UUID batchId, boolean replayed, int confirmedCount,
                OffsetDateTime confirmedAt) {
            this(batchId, replayed, confirmedCount, confirmedAt, List.of());
        }
    }

    /** 跨收货单批量入库：整批同事务，先校验全部集合再执行，任一冲突整批回滚。 */
    public record BatchConfirmRequest(
            @NotEmpty @Size(max = 20) List<@Valid BatchConfirmEntry> batches) {
    }

    public record BatchConfirmEntry(
            @NotBlank String receiptType,
            @NotNull @JsonSerialize(using = ToStringSerializer.class) UUID receiptId,
            @NotBlank @Size(min = 8, max = 128) String idempotencyKey,
            @NotEmpty @Size(max = 100) List<@Valid ConfirmItem> items) {
    }

    public record BatchConfirmResult(
            List<BatchConfirmEntryResult> results,
            int confirmedReceipts,
            int confirmedItemCount) {

        public BatchConfirmResult {
            results = results == null ? List.of() : List.copyOf(results);
        }
    }

    public record BatchConfirmEntryResult(
            String receiptType,
            @JsonSerialize(using = ToStringSerializer.class) UUID receiptId,
            @JsonSerialize(using = ToStringSerializer.class) UUID batchId,
            boolean replayed,
            int confirmedCount,
            OffsetDateTime confirmedAt,
            List<InboundAllocation> allocations) {

        public BatchConfirmEntryResult {
            allocations = allocations == null ? List.of() : List.copyOf(allocations);
        }

        public BatchConfirmEntryResult(
                String receiptType, UUID receiptId, UUID batchId,
                boolean replayed, int confirmedCount, OffsetDateTime confirmedAt) {
            this(receiptType, receiptId, batchId, replayed, confirmedCount,
                    confirmedAt, List.of());
        }
    }
}

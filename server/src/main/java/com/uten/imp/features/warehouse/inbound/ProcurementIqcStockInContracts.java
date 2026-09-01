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

    public record TaskSummary(
            String receiptType,
            @JsonSerialize(using = ToStringSerializer.class) UUID receiptId,
            String billNo,
            LocalDate billDate,
            @JsonSerialize(using = ToStringSerializer.class) UUID supplierId,
            String supplierName,
            @JsonSerialize(using = ToStringSerializer.class) UUID warehouseId,
            String warehouseName,
            long goodsLineCount,
            long pendingSliceCount,
            OffsetDateTime firstReleasedAt,
            OffsetDateTime lastReleasedAt,
            String status) {
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
            OffsetDateTime releasedAt) {
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
            OffsetDateTime confirmedAt) {
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
            OffsetDateTime confirmedAt) {
    }
}

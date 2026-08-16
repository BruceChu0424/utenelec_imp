package com.uten.imp.features.warehouse.inbound;

import com.fasterxml.jackson.databind.annotation.JsonSerialize;
import com.fasterxml.jackson.databind.ser.std.ToStringSerializer;

import jakarta.validation.constraints.DecimalMin;
import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;

public final class ProcurementArrivalContracts {

    private ProcurementArrivalContracts() {
    }

    public record ArrivalDecisionRequest(
            @NotNull @Min(1) Long expectedVersion,
            @NotBlank String decision,
            @DecimalMin(value = "0", inclusive = true) BigDecimal customApprovedExcessQty,
            @Size(max = 1000) String financeReason) {
    }

    public record ReturnCompletionRequest(
            @NotNull @Min(1) Long expectedVersion,
            @Size(max = 1000) String completionNote) {
    }

    public record SupplierReturnTask(
            UUID id,
            BigDecimal qty,
            String status,
            long version,
            String completionNote,
            OffsetDateTime completedAt) {
    }

    public record ArrivalExceptionTask(
            UUID id,
            String orderType,
            UUID receiptId,
            UUID receiptItemId,
            String receiptBillNo,
            UUID orderId,
            UUID orderItemId,
            String orderBillNo,
            String supplierName,
            String warehouseName,
            String goodsCode,
            String goodsName,
            String colorName,
            String unitName,
            BigDecimal declaredQty,
            BigDecimal approvedRemainingQty,
            @JsonSerialize(using = ToStringSerializer.class) BigDecimal unitPrice,
            @JsonSerialize(using = ToStringSerializer.class)
                    BigDecimal declaredAmountOriginal,
            @JsonSerialize(using = ToStringSerializer.class)
                    BigDecimal declaredAmountLocal,
            @JsonSerialize(using = ToStringSerializer.class)
                    BigDecimal excessAmountLocal,
            BigDecimal requestedExcessQty,
            BigDecimal approvedExcessQty,
            UUID financeAssigneeUserId,
            UUID financeAssigneeEmployeeId,
            String financeAssigneeName,
            String detectedByEmployeeName,
            String financeReason,
            BigDecimal acceptedQty,
            BigDecimal unacceptedQty,
            String status,
            String decision,
            long version,
            OffsetDateTime detectedAt,
            OffsetDateTime decidedAt,
            SupplierReturnTask returnTask,
            List<String> allowedActions) {
        public ArrivalExceptionTask {
            allowedActions = List.copyOf(allowedActions);
        }
    }

    public record InboundExpectationItem(
            UUID id,
            UUID orderItemId,
            Integer lineNo,
            UUID goodsId,
            String goodsCode,
            String goodsName,
            String goodsSeries,
            String goodsStockPlace,
            UUID colorId,
            String colorName,
            UUID unitId,
            String unitName,
            BigDecimal unitRate,
            BigDecimal unitPrice,
            BigDecimal orderedQty,
            BigDecimal acceptedQty,
            BigDecimal remainingQty,
            LocalDate expectedDate) {
    }

    public record InboundExpectationTask(
            UUID id,
            String orderType,
            UUID orderId,
            String billNo,
            UUID supplierId,
            String supplierName,
            UUID warehouseId,
            String warehouseName,
            LocalDate expectedDate,
            UUID ownerEmployeeId,
            String ownerEmployeeName,
            String status,
            BigDecimal orderedQty,
            BigDecimal acceptedQty,
            BigDecimal remainingQty,
            List<InboundExpectationItem> items,
            List<String> allowedActions) {
        public InboundExpectationTask {
            items = List.copyOf(items);
            allowedActions = List.copyOf(allowedActions);
        }
    }
}

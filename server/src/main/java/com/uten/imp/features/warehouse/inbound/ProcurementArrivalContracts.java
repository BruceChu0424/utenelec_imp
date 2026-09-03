package com.uten.imp.features.warehouse.inbound;

import com.fasterxml.jackson.databind.annotation.JsonSerialize;
import com.fasterxml.jackson.databind.ser.std.ToStringSerializer;
import com.uten.imp.common.validation.RequestLimits;

import jakarta.validation.Valid;
import jakarta.validation.constraints.DecimalMin;
import jakarta.validation.constraints.Digits;
import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotEmpty;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Pattern;
import jakarta.validation.constraints.Size;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;

public final class ProcurementArrivalContracts {

    private ProcurementArrivalContracts() {
    }

    /**
     * 货品资料「学习」回写条目：仓库登记到货时填写的库位号/物料系列/物料编码。
     * 空值跳过；goodsCode 仅补空且防与他货重复；series/stockPlace 不同才更新。
     */
    public record GoodsProfileHintRequest(
            @NotNull UUID goodsId,
            @Size(max = 64) String goodsCode,
            @Size(max = 100) String series,
            @Size(max = 100) String stockPlace) {
    }

    /**
     * 仓库到货登记一步完成（登记 + 送检审核）请求体。
     *
     * <p>与「登记实际到货」页字段一致：只有数量、可选实际总重量与库位语义字段，无价格/币族——
     * 服务端从财务批准的来源订货单权威带出 币种/汇率/结算方式 后建收货单草稿，
     * 并在同一事务内立即审核（转品质待检）；实到超量时审核被到货控制拦截，
     * 草稿与 PENDING_FINANCE 异常一并提交，接口以 {@code EXCESS_QUARANTINED} 正常返回。
     */
    public record WarehouseArrivalRegisterRequest(
            @NotBlank @Size(max = 128) String idempotencyKey,
            @NotBlank String orderType,
            @NotNull LocalDate billDate,
            @NotNull UUID supplierId,
            @NotNull UUID warehouseId,
            UUID purchaserId,
            @NotNull UUID receiverEmployeeId,
            @Size(max = 1000) String remark,
            @NotNull @Size(min = 1, max = RequestLimits.DOCUMENT_LINES)
                    List<@Valid ArrivalLine> items) {

        public record ArrivalLine(
                @NotNull UUID goodsId,
                @NotNull @DecimalMin(value = "0", inclusive = false) BigDecimal qty,
                @NotNull UUID orderItemId,
                UUID colorId,
                UUID unitId,
                BigDecimal unitRate,
                @DecimalMin(value = "0", inclusive = true)
                @Digits(integer = 14, fraction = 4) BigDecimal weight,
                @Size(max = 64) String sourceDocNo) {

            /** Compatibility for callers that do not provide an actual total weight. */
            public ArrivalLine(UUID goodsId, BigDecimal qty, UUID orderItemId,
                               UUID colorId, UUID unitId, BigDecimal unitRate,
                               String sourceDocNo) {
                this(goodsId, qty, orderItemId, colorId, unitId, unitRate,
                        null, sourceDocNo);
            }
        }
    }

    /**
     * 一步登记结果：{@code SUBMITTED_FOR_INSPECTION} = 已审核并转品质待检；
     * {@code EXCESS_QUARANTINED} = 实到超量，未入库未立应付，已隔离等待财务定案。
     */
    public record WarehouseArrivalRegisterResult(
            String outcome,
            UUID receiptId,
            String receiptBillNo,
            UUID exceptionId) {
    }

    /**
     * 预计到货「批量继续送检」：一次事务逐张草稿收货单完成中断的送检步骤。
     * 单张超量隔离不回滚其他单（与单册「继续送检」一致，隔离单走财务异常流程）。
     */
    public record WarehouseArrivalBatchCompleteRequest(
            @NotBlank
            @Size(min = 8, max = 128)
            @Pattern(regexp = "[A-Za-z0-9._:-]+")
            String idempotencyKey,
            @NotEmpty @Size(max = 100)
            List<@NotNull UUID> receiptIds) {
    }

    /**
     * 逐张送检结果；{@code alreadyCompleted} = 重试时该收货单已不是草稿
     * （先前同键请求已处理），按既有事实安全重放，不重复审核。
     */
    public record WarehouseArrivalBatchCompleteResult(
            int processedCount,
            List<WarehouseArrivalBatchCompleteItemResult> items) {
        public WarehouseArrivalBatchCompleteResult {
            items = List.copyOf(items);
        }
    }

    public record WarehouseArrivalBatchCompleteItemResult(
            UUID receiptId,
            String receiptBillNo,
            String outcome,
            UUID exceptionId,
            boolean alreadyCompleted) {
    }

    /**
     * Atomic warehouse submission of finance-adjusted arrival exceptions.
     *
     * <p>Each item binds the immutable exception UUID to the version observed by
     * the operator. The top-level key identifies the whole all-or-nothing
     * command; it is not a per-line retry key.</p>
     */
    public record WarehouseArrivalExceptionBatchStockInRequest(
            @NotBlank
            @Size(min = 8, max = 128)
            @Pattern(regexp = "[A-Za-z0-9._:-]+")
            String idempotencyKey,
            @NotEmpty @Size(max = 100)
            List<@Valid WarehouseArrivalExceptionBatchStockInItem> items) {
    }

    public record WarehouseArrivalExceptionBatchStockInItem(
            @NotNull UUID exceptionId,
            @NotNull @Min(1) Long expectedVersion) {
    }

    /**
     * A successful batch has submitted every unique receipt group into the
     * existing receipt-approval/IQC pipeline. It does not assert that IQC has
     * released usable inventory.
     */
    public record WarehouseArrivalExceptionBatchStockInResult(
            UUID batchId,
            boolean replay,
            boolean submittedForInspection,
            int processedExceptions,
            List<WarehouseArrivalExceptionStockInReceiptGroup> receiptGroups) {
        public WarehouseArrivalExceptionBatchStockInResult {
            receiptGroups = List.copyOf(receiptGroups);
        }
    }

    public record WarehouseArrivalExceptionStockInReceiptGroup(
            String orderType,
            UUID receiptId,
            String receiptBillNo,
            boolean submittedForInspection,
            List<WarehouseArrivalExceptionStockInItemResult> items) {
        public WarehouseArrivalExceptionStockInReceiptGroup {
            items = List.copyOf(items);
        }
    }

    public record WarehouseArrivalExceptionStockInItemResult(
            UUID exceptionId,
            long expectedVersion,
            String resultStatus,
            long resultVersion) {
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
            List<String> allowedActions,
            /** 价格族字段已对当前用户脱敏（仓库视角无收货单价格权限时置 null；V302）。 */
            boolean priceMasked) {
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
            BigDecimal registeredQty,
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
            UUID suggestedWarehouseId,
            String suggestedWarehouseName,
            LocalDate expectedDate,
            UUID ownerEmployeeId,
            String ownerEmployeeName,
            String status,
            BigDecimal orderedQty,
            BigDecimal acceptedQty,
            BigDecimal remainingQty,
            BigDecimal registeredQty,
            List<InboundExpectationItem> items,
            List<String> allowedActions,
            /** 已登记待审核的草稿收货单（status=0 未删）：任务中心据此提供「继续送检」恢复入口。 */
            List<UUID> draftReceiptIds,
            /** 待品质放行的收货单张数（已审核、IQC 未结）：任务卡「待品质检验」步骤。 */
            int pendingInspectionReceipts,
            /** 未结到货异常数（超量待财务定案）：任务卡「超量待财务」步骤。 */
            int openArrivalExceptions) {
        public InboundExpectationTask {
            items = List.copyOf(items);
            allowedActions = List.copyOf(allowedActions);
            draftReceiptIds = List.copyOf(draftReceiptIds);
        }
    }
}

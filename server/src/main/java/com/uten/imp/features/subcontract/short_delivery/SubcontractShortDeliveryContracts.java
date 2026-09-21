package com.uten.imp.features.subcontract.short_delivery;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Pattern;
import jakarta.validation.constraints.Size;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;

/** ADR-098 委外回厂短交判定页与供应商损耗汇总的请求/响应契约。 */
public final class SubcontractShortDeliveryContracts {

    private SubcontractShortDeliveryContracts() {
    }

    /** 判定请求：WAIT_MORE 必填预计到齐日(不早于今天); ACCEPT_LOSS 低于下限时必填说明。 */
    public record DecisionRequest(
            @NotBlank @Pattern(regexp = "WAIT_MORE|ACCEPT_LOSS") String decision,
            LocalDate expectedCompleteBy,
            @Size(max = 500) String note,
            @NotNull Long expectedVersion) {
    }

    /** 列表/详情共用的案件行。 */
    public record CaseRow(
            UUID id,
            UUID orderId,
            String orderBillNo,
            UUID orderItemId,
            Integer lineNo,
            UUID supplierId,
            String supplierName,
            UUID goodsId,
            String goodsCode,
            String goodsName,
            String colorName,
            String unitName,
            UUID receiptId,
            String receiptBillNo,
            BigDecimal orderedQty,
            BigDecimal allowedLossPct,
            BigDecimal floorQty,
            BigDecimal deliveredQty,
            BigDecimal shortfallQty,
            BigDecimal shortfallPct,
            String severity,
            String status,
            /** 有效状态：WAITING_MORE 且已过预计到齐日 → PENDING_OWNER(逾期), 其余 = status。 */
            String effectiveStatus,
            boolean overdue,
            String decision,
            LocalDate expectedCompleteBy,
            String decisionNote,
            int arrivalCount,
            String ownerName,
            String decidedByName,
            OffsetDateTime detectedAt,
            OffsetDateTime lastEvaluatedAt,
            OffsetDateTime decidedAt,
            OffsetDateTime closedAt,
            BigDecimal lossQty,
            BigDecimal lossPct,
            UUID wasteId,
            String wasteBillNo,
            long version,
            /** 当前登录人可否判定(权限点 + 对象级：本人负责的订货单或 view:all)。 */
            boolean canDecide) {
    }

    public record CaseEvent(
            UUID id,
            String eventType,
            String actorName,
            OffsetDateTime createdAt,
            java.util.Map<String, Object> snapshot) {
    }

    public record CaseDetail(CaseRow row, List<CaseEvent> events) {
    }

    /** 判定页分段计数：待判定(红：低于下限或分批逾期) / 容差内待结案(中性) / 分批等待中(中性)。 */
    public record Counts(long pending, long tolerant, long waiting) {
    }

    /** 供应商损耗汇总(详情页「委外损耗」段 + 列表「损耗率(%)」列)。 */
    public record SupplierLossSummary(
            UUID supplierId,
            long settledLineCount,
            long acceptedLossCount,
            BigDecimal orderedQty,
            BigDecimal lossQty,
            BigDecimal lossPct,
            BigDecimal maxLossPct,
            OffsetDateTime lastLossAt,
            List<GoodsLossRow> byGoods,
            List<CaseRow> recentCases) {
    }

    public record GoodsLossRow(
            UUID goodsId,
            String goodsCode,
            String goodsName,
            long settledLineCount,
            long acceptedLossCount,
            BigDecimal orderedQty,
            BigDecimal lossQty,
            BigDecimal lossPct,
            BigDecimal maxLossPct,
            OffsetDateTime lastLossAt) {
    }
}

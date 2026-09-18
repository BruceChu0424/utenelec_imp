package com.uten.imp.features.production.quality;

import jakarta.validation.constraints.DecimalMin;
import jakarta.validation.constraints.Digits;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Pattern;
import jakarta.validation.constraints.Size;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;

/** HTTP and application contracts for production FQC. */
public final class ProductionFqcContracts {

    private ProductionFqcContracts() {
    }

    public record DecisionRequest(
            @NotBlank
            @Pattern(regexp = "PASS|PARTIAL|FAIL",
                    message = "质检决定仅支持 PASS、PARTIAL 或 FAIL")
            String decision,
            @DecimalMin(value = "0", inclusive = false)
            @Digits(integer = 14, fraction = 4)
            BigDecimal passQty,
            @DecimalMin(value = "0", inclusive = false)
            @Digits(integer = 14, fraction = 4)
            BigDecimal failQty,
            @Size(max = 32) String dispositionCode,
            @Size(max = 1000) String reason,
            @NotBlank
            @Size(min = 8, max = 128)
            @Pattern(regexp = "[A-Za-z0-9._:-]+",
                    message = "幂等键只能包含字母、数字或 ._:-")
            String idempotencyKey) {
    }

    public record InspectionView(
            UUID id,
            UUID sourceReportId,
            UUID sourceReportItemId,
            String reportNo,
            UUID sourcePlanItemId,
            UUID planId,
            String planNo,
            UUID executionSegmentId,
            UUID executionSegmentSalesAllocationId,
            UUID warehouseId,
            UUID goodsId,
            String goodsCode,
            String goodsName,
            UUID colorId,
            String colorName,
            UUID unitId,
            String unitName,
            BigDecimal unitRate,
            BigDecimal reportedQty,
            BigDecimal passedQty,
            BigDecimal failedQty,
            BigDecimal remainingQty,
            BigDecimal authorizedInboundQty,
            String status,
            UUID reportMakerId,
            OffsetDateTime createdAt,
            OffsetDateTime updatedAt,
            UUID sheetId,
            String sheetNo,
            String warehouseName,
            String place,
            String registrationRemark,
            String receiverName,
            /** 先入库后检(V597)：登记时已上架的成品仓 + 库位；null = 原流程(合格后仓库点收)。 */
            PreStockedLocationView preStocked) {
    }

    /**
     * 先入库后质检的实物位置(V597)：与采购/委外 IQC 的 PreStockedLocation 同形，
     * 前端复用同一个模型渲染「已入库 · 仓 / 库位」与顶部标红横幅。
     */
    public record PreStockedLocationView(
            UUID warehouseId,
            String warehouseName,
            String place,
            OffsetDateTime stockedAt,
            String stockedByName) {
    }

    /** V547 品质检查单头（待检处置队列一行 = 一张检查单）。 */
    public record InspectionSheetView(
            UUID id,
            String sheetNo,
            UUID warehouseId,
            String warehouseName,
            UUID receiverEmployeeId,
            String receiverName,
            String remark,
            String sourceKind,
            int itemCount,
            int activeCount,
            String pendingQtyText,
            String reportNos,
            /** 一单多货品的身份摘要，每项形如「名称 (编号 · 颜色)」，多项以「、」连接。 */
            String goodsSummary,
            String status,
            OffsetDateTime createdAt,
            /** 先入库后检(V597)：本单仍等结论且已上架的行数(0 = 原流程)。 */
            int preStockedItemCount,
            /** 登记库位去重清单（2026-09-17）：待检队列「库位号」列，品质部按此到储放区域检验。 */
            String placeSummary) {
    }

    /** 检查单办理视图：头 + 逐条 inspection（PASS/FAIL 仍按 inspection 决定）。 */
    public record InspectionSheetDetailView(
            InspectionSheetView sheet,
            List<InspectionView> inspections) {

        public InspectionSheetDetailView {
            inspections = List.copyOf(inspections);
        }
    }

    public record DecisionResult(
            UUID decisionEventId,
            InspectionView inspection,
            boolean replay) {
    }

    public record PassAllBatchRequest(
            @NotNull
            @Size(min = 1, max = 100)
            List<@NotNull UUID> inspectionIds,
            @NotBlank
            @Size(min = 8, max = 128)
            @Pattern(regexp = "[A-Za-z0-9._:-]+",
                    message = "幂等键只能包含字母、数字或 ._:-")
            String idempotencyKey) {
    }

    public record PassAllBatchItem(
            UUID inspectionId,
            UUID decisionEventId,
            InspectionView inspection) {
    }

    public record PassAllBatchResult(
            UUID batchId,
            List<PassAllBatchItem> items,
            boolean replay) {

        public PassAllBatchResult {
            items = List.copyOf(items);
        }
    }
}

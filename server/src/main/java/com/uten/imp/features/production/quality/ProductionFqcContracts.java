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
            PreStockedLocationView preStocked,
            /** ADR-148 实物交接批：同一报工、同一产出批次、同一去向的各份共用一个批号。 */
            UUID lotId,
            /** 本份在批内的归属优先级(0 需求 / 1 计划公共 / 2 实际超产)与归属码。 */
            int sliceRank,
            String sliceKind,
            /** 本批还在(未取消)的份数；大于 1 时只能按整批判定。 */
            int lotSliceCount) {
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

    /**
     * 检查单办理视图：头 + 逐份 inspection + 按实物交接批分组的 lots(ADR-148)。
     * 页面一批一行，一次判定合格/不良数量；服务端按瀑布分给批内各份。
     */
    public record InspectionSheetDetailView(
            InspectionSheetView sheet,
            List<InspectionView> inspections,
            List<InspectionLotView> lots) {

        public InspectionSheetDetailView {
            inspections = List.copyOf(inspections);
            lots = List.copyOf(lots);
        }
    }

    /**
     * 一批实物的品质视图(ADR-148)：批内各份合计、按归属拆分(服务端算一次)与各份当前判定。
     * status：PENDING 未判 / PARTIAL 部分已判 / RESOLVED 全部判完 / CANCELLED 已取消。
     */
    public record InspectionLotView(
            UUID lotId,
            UUID sourceReportId,
            String reportNo,
            UUID planId,
            String planNo,
            UUID goodsId,
            String goodsCode,
            String goodsName,
            UUID colorId,
            String colorName,
            UUID unitId,
            String unitName,
            BigDecimal reportedQty,
            BigDecimal passedQty,
            BigDecimal failedQty,
            BigDecimal remainingQty,
            BigDecimal demandQty,
            BigDecimal publicQty,
            BigDecimal actualSurplusQty,
            /** 「需求 1000 · 实际超产 100」；整批都是需求份时为空。 */
            String splitText,
            String status,
            UUID warehouseId,
            String warehouseName,
            String place,
            PreStockedLocationView preStocked,
            List<InspectionLotMemberView> members) {

        public InspectionLotView {
            members = List.copyOf(members);
        }
    }

    /** 批内一份的当前判定。 */
    public record InspectionLotMemberView(
            UUID inspectionId,
            UUID sourceReportItemId,
            int sliceRank,
            String kind,
            BigDecimal reportedQty,
            BigDecimal passedQty,
            BigDecimal failedQty,
            BigDecimal remainingQty,
            String status) {
    }

    /**
     * 整批判定(ADR-148)：合格与不良数量(可以只判一部分，剩下的继续待检)。合格先满足需求份、
     * 再计划公共、最后实际超产；不良先扣实际超产、再计划公共、最后需求份。有不良时必须写处置方式与原因。
     */
    public record LotDecisionRequest(
            @NotNull
            @DecimalMin(value = "0", inclusive = true)
            @Digits(integer = 14, fraction = 4)
            BigDecimal passQty,
            @NotNull
            @DecimalMin(value = "0", inclusive = true)
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

    public record LotDecisionResult(
            UUID lotCommandId,
            InspectionLotView lot,
            boolean replay) {
    }

    public record DecisionResult(
            UUID decisionEventId,
            InspectionView inspection,
            boolean replay) {
    }

    /** Only COMMITTED confirms this actor's command. UNKNOWN and LEGACY must retain the original request. */
    public record DecisionResolution(String state, String idempotencyKey, DecisionResult result,
                                     DecisionFacts decision) {}
    public record DecisionFacts(String decision, BigDecimal passQty, BigDecimal failQty,
                                String dispositionCode, String reason, String requestHash,
                                OffsetDateTime decidedAt) {}
    public record PassAllResolution(String state, String idempotencyKey, PassAllBatchResult result) {}

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

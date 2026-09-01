package com.uten.imp.features.subcontract.order.dto;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;

/** 委外订货单全链路进度契约（委外/财务视角；价格族仅在 AP 摘要出现，不对仓库暴露）。 */
public final class OrderProgressContracts {

    private OrderProgressContracts() {
    }

    /** 发料计划行进度（父件→子件）。 */
    public record MaterialPlanLine(
            UUID planItemId,
            String parentGoodsCode,
            String parentGoodsName,
            String goodsCode,
            String goodsName,
            String colorName,
            String unitName,
            BigDecimal bomUnitQty,
            BigDecimal plannedQty,
            BigDecimal issuedQty,
            BigDecimal draftReservedQty,
            String flowMode,
            String preparationStatus,
            BigDecimal preparedQty,
            BigDecimal readyOutboundQty,
            BigDecimal remainingQty,
            UUID preparationAnalysisId,
            UUID preparationAnalysisItemId,
            String blocker,
            List<String> allowedActions) {
        public MaterialPlanLine {
            allowedActions = allowedActions == null ? List.of() : List.copyOf(allowedActions);
        }
    }

    /** 出仓单进度。 */
    public record IssueDoc(
            UUID id, String billNo, Short status, LocalDate billDate,
            String warehouseName, String approverName, BigDecimal totalQty,
            OffsetDateTime updatedAt) {
    }

    /** 进仓单进度（含 IQC 聚合状态）。 */
    public record ReceiptDoc(
            UUID id, String billNo, Short status, LocalDate billDate,
            String warehouseName, String approverName, BigDecimal totalQty,
            BigDecimal totalLocal, String iqcStatus,
            String warehouseStockInStatus,
            BigDecimal iqcPassedBaseQty,
            BigDecimal warehouseStockedBaseQty,
            BigDecimal pendingStockInBaseQty,
            OffsetDateTime updatedAt) {
    }

    /** 成品退货单进度。 */
    public record ReturnDoc(
            UUID id, String billNo, Short status, LocalDate billDate,
            BigDecimal totalQty, BigDecimal totalLocal) {
    }

    /** 损耗单进度。 */
    public record WasteDoc(
            UUID id, String billNo, Short status, LocalDate billDate,
            BigDecimal totalQty, BigDecimal deductAmount, Boolean deductPosted) {
    }

    /** 供应商处材料台账（V221 守恒口径，按子件聚合）。 */
    public record SupplierLedgerLine(
            String goodsCode, String goodsName, String colorName, String unitName,
            BigDecimal atSupplierQty, BigDecimal consumedQty, BigDecimal returnedQty,
            BigDecimal wastedQty, BigDecimal supplierEnding) {
    }

    public record OrderProgress(
            UUID orderId,
            String billNo,
            Short status,
            /** 财务审批 case 状态（PENDING/APPROVED/REJECTED；null=未提交）。 */
            String financeCaseStatus,
            OffsetDateTime financeDecidedAt,
            /** false means only that a legacy order has no identifiable outbound plan. */
            boolean materialRequired,
            /** 发料计划状态（OPEN/CLOSED/CANCELED；null=无计划）。 */
            String planStatus,
            String planCloseReason,
            List<MaterialPlanLine> materialLines,
            List<IssueDoc> issues,
            List<ReceiptDoc> receipts,
            List<ReturnDoc> returns,
            List<WasteDoc> wastes,
            List<SupplierLedgerLine> supplierLedger,
            /** 已立应付加工费合计（本币，已审进仓 − 已审成品退货）。 */
            BigDecimal apPostedTotal,
            /** V304 历史已立损耗负AP合计；新超耗责任/索赔不写此字段。 */
            BigDecimal wasteDeductTotal,
            /** 当前用户无委外商业金额权限时为 true，进度中的金额族字段全部置 null。 */
            boolean priceMasked) {
        public OrderProgress {
            materialLines = List.copyOf(materialLines);
            issues = List.copyOf(issues);
            receipts = List.copyOf(receipts);
            returns = List.copyOf(returns);
            wastes = List.copyOf(wastes);
            supplierLedger = List.copyOf(supplierLedger);
        }
    }
}

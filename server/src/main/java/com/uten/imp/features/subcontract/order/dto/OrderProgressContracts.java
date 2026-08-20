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
            BigDecimal draftQty) {
        public BigDecimal remainingQty() {
            return plannedQty.subtract(issuedQty).subtract(draftQty).max(BigDecimal.ZERO);
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
            BigDecimal totalLocal, String iqcStatus, OffsetDateTime updatedAt) {
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
            /** false = 订货货品无 BOM 子件（委外商自备料，无需发料）。 */
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
            /** 已立损耗扣款合计（本币，deduct_posted 的损耗单）。 */
            BigDecimal wasteDeductTotal) {
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

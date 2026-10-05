package com.uten.imp.features.subcontract.order.dto;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;

/**
 * 委外订货单全链路进度契约（ADR-143 §4.6；委外/财务视角；价格族仅在 AP 摘要出现，不对仓库暴露）。
 *
 * <p>一条订货明细 = 一个委外任务：时间线「下单 → 财务审批 → 领料发外 → 加工回厂 → 品质检验 →
 * 仓库确认入仓 → 结案核销」，物料段与委外任务详情的物料表同字段。所有数量服务端算好，
 * 订货单位；物料行用物料自己的单位。
 */
public final class OrderProgressContracts {

    private OrderProgressContracts() {
    }

    /**
     * 明细物料方式：DRAW = 按工序领直属物料发外；MISSING_BOM = 委外件还没有可发外的直属物料
     * (缺 BOM)，不能提交财务(ADR-143 §二.3)，只会出现在未批准的订货单上。
     */
    public static final String MATERIAL_MODE_DRAW = "DRAW";
    public static final String MATERIAL_MODE_MISSING_BOM = "MISSING_BOM";

    /** 时间线节点状态。 */
    public static final String NODE_DONE = "DONE";
    public static final String NODE_ACTIVE = "ACTIVE";
    public static final String NODE_PENDING = "PENDING";
    public static final String NODE_SKIPPED = "SKIPPED";

    /** 物料在途供应来源(kind: PURCHASE / PRODUCTION / SUBCONTRACT)。 */
    public record SupplySource(String kind, UUID docId, String docNo, BigDecimal openQty) {
    }

    /**
     * 委外任务的一种直属物料(冻结领料计划行)。字段与委外任务详情物料表一致：
     * 每套用量 / 需求 / 已发外 / 待仓库发 / 仓库可用 / 本次可领 / 还缺；
     * state ∈ SENT_FULL / PENDING / DRAWABLE / SHORT / CLOSED。
     * usableQty = 委外商处可做成委外件的物料(已核销 + 结存)。
     */
    public record MaterialLine(
            UUID planItemId,
            Integer lineNo,
            UUID goodsId,
            String goodsCode,
            String goodsName,
            UUID colorId,
            String colorName,
            UUID unitId,
            String unitName,
            BigDecimal perUnitQty,
            BigDecimal requiredQty,
            BigDecimal sentQty,
            BigDecimal pendingQty,
            BigDecimal availableQty,
            BigDecimal drawableQty,
            BigDecimal shortQty,
            BigDecimal usableQty,
            String state,
            List<SupplySource> supplySources) {
        public MaterialLine {
            supplySources = supplySources == null ? List.of() : List.copyOf(supplySources);
        }
    }

    /**
     * 时间线节点。key ∈ ORDER / FINANCE / DRAW / RETURN / QUALITY / STOCK_IN / CLOSE；
     * state ∈ DONE / ACTIVE / PENDING / SKIPPED；detail 为面向人的说明(可空)。
     */
    public record TimelineNode(String key, String label, String state, String detail) {
    }

    /**
     * 委外任务(订货明细)进度。数量全部为订货单位：
     * 批准后 drawn + pending + drawable + short = orderQty；
     * returnableQty 为委外商处物料可做成的完整套数(未批准时为 0)；
     * receivedQty 为已审核回厂净量；qualifiedQty/stockedQty 来自来料质检与仓库确认入仓；
     * settledLossQty 为已结损耗。
     */
    public record ItemProgress(
            UUID orderItemId,
            Integer lineNo,
            UUID goodsId,
            String goodsCode,
            String goodsName,
            UUID colorId,
            String colorName,
            UUID unitId,
            String unitName,
            BigDecimal orderQty,
            String materialMode,
            boolean drawOpen,
            int materialKindCount,
            int readyKindCount,
            BigDecimal drawnQty,
            BigDecimal pendingQty,
            BigDecimal drawableQty,
            BigDecimal shortQty,
            BigDecimal returnableQty,
            BigDecimal receivedQty,
            BigDecimal qualifiedQty,
            BigDecimal pendingInspectionQty,
            BigDecimal stockedQty,
            BigDecimal settledLossQty,
            List<MaterialLine> materials,
            List<TimelineNode> timeline) {
        public ItemProgress {
            materials = materials == null ? List.of() : List.copyOf(materials);
            timeline = timeline == null ? List.of() : List.copyOf(timeline);
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

    /** 委外商处材料台账（V221 守恒口径，按物料聚合）。 */
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
            /** 领料计划状态（OPEN/CLOSED/CANCELED；null=未批准或无计划）。 */
            String planStatus,
            String planCloseReason,
            List<ItemProgress> items,
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
            items = List.copyOf(items);
            issues = List.copyOf(issues);
            receipts = List.copyOf(receipts);
            returns = List.copyOf(returns);
            wastes = List.copyOf(wastes);
            supplierLedger = List.copyOf(supplierLedger);
        }
    }
}

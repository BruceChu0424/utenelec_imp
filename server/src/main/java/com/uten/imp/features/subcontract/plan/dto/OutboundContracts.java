package com.uten.imp.features.subcontract.plan.dto;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/** 委外出仓工作台契约（仓库视角：无价格/金额字段）。 */
public final class OutboundContracts {

    private OutboundContracts() {
    }

    /** 待出仓任务列表行（一张 OPEN 发料计划 = 一个任务）。 */
    public record OutboundTaskListItem(
            UUID planId,
            UUID orderId,
            String orderBillNo,
            String supplierName,
            LocalDate deliverDate,
            int lineCount,
            BigDecimal plannedQty,
            BigDecimal issuedQty,
            BigDecimal remainingQty,
            /** 未审出仓草稿（null = 尚未生成/已被处理）。 */
            UUID draftId,
            String draftBillNo,
            BigDecimal readyOutboundQty,
            int readyLineCount,
            int waitingPreparationCount,
            int blockedLineCount,
            /**
             * ADR-103: 发现货的两种流向 (DIRECT / COMPONENT) 里「有余量、没挂未审草稿、作业叶仓
             * 里一件都没有」的行数——这些行在等子件到货, 不是轮到仓库动手。
             */
            long waitingComponentLineCount,
            /**
             * ADR-103: 此刻真能开出去的合计 (基本单位) = 发现货两流向按 min(余量, 作业叶仓合格
             * 可动用量), 其它流向按余量; 0 且无草稿 = 整张任务在等子件到货 (WAITING_COMPONENT)。
             */
            BigDecimal issuableTotal) {
    }

    /** Server-authoritative outbound line; parent fields are legacy compatibility only. */
    public record OutboundPlanLine(
            UUID planItemId,
            UUID orderItemId,
            UUID parentGoodsId,
            UUID parentColorId,
            String parentGoodsCode,
            String parentGoodsName,
            UUID goodsId,
            String goodsCode,
            String goodsName,
            String goodsStockPlace,
            UUID colorId,
            String colorName,
            UUID unitId,
            String unitName,
            BigDecimal unitRate,
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
            List<String> allowedActions,
            /**
             * 此刻还能再填多少 = min(计划余量, 该仓合格可动用量)，两边都已扣掉未审草稿占用。
             * 只有真按现货出仓的 DIRECT / COMPONENT 两种流向算得出来，**一个仓都没货时是 0
             * 而不是 null**；前置自制两种流向吃的是专属预留、历史 LEGACY 行不经出仓预留校验，
             * 一律 null，客户端据此回落纯计划口径。
             */
            BigDecimal issuableQty,
            /** [stockWarehouseId] 里该货品/颜色当前的合格可动用量，不含本计划行的草稿占用。 */
            BigDecimal stockAvailableQty,
            /** 上面两个数算在哪个仓：已定发料仓就是它，未定则是当前可动用量最多的作业叶仓。 */
            UUID stockWarehouseId,
            String stockWarehouseName) {
        public OutboundPlanLine {
            allowedActions = allowedActions == null ? List.of() : List.copyOf(allowedActions);
        }
    }

    /** 计划关联的出仓单（草稿/已审/红冲历史）。 */
    public record OutboundDraftRef(
            UUID issueId,
            String billNo,
            Short status,
            LocalDate billDate,
            String warehouseName,
            String approverName,
            BigDecimal totalQty) {
    }

    public record OutboundTaskDetail(
            UUID planId,
            UUID orderId,
            String orderBillNo,
            String status,
            UUID supplierId,
            String supplierName,
            LocalDate deliverDate,
            String closeReason,
            List<OutboundPlanLine> lines,
            List<OutboundDraftRef> drafts) {
        public OutboundTaskDetail {
            lines = List.copyOf(lines);
            drafts = List.copyOf(drafts);
        }
    }
}

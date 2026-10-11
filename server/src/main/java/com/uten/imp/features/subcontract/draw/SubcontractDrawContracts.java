package com.uten.imp.features.subcontract.draw;

import com.uten.imp.common.web.PageResponse;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * ADR-143 委外任务中心「领料」接口契约({@code /api/subcontract/draw-tasks})。
 *
 * <p>所有数量由服务端算好下发, 前端不再计算: 行级数量是委外件的订货单位, 物料级数量是物料基本单位。
 * 恒等式 已领 + 待仓库发 + 可领 + 还缺 = 我方供料套数 materialQty 由数据库函数保证; 没有财务批准的
 * 委外商自带料时 materialQty = 订货数量 orderQty(ADR-143 §三.4a)。
 */
public final class SubcontractDrawContracts {

    private SubcontractDrawContracts() {
    }

    /** 行状态: 可领(剩余全部可领) / 部分可领 / 已提交待仓库发料 / 等计划安排 / 等待物料。 */
    public static final List<String> ROW_STATUSES = List.of(
            "DRAWABLE", "DRAWABLE_PARTIAL", "DRAW_SUBMITTED", "WAITING_PLANNING", "WAITING_MATERIAL");

    /**
     * 一个委外任务(一条已批准、未领满的委外订货明细)。materialQty = 我方供料套数 Qm
     * (订货数量扣掉财务批准的委外商自带料, 不低于已领套数; 没有自带料时等于 orderQty)。
     * planNo = 来源计划(WL 分析编号, 为空时是订货单号), 与申请行显示同一口径。
     */
    public record DrawTaskRow(
            UUID orderItemId,
            UUID orderId,
            String orderBillNo,
            Integer lineNo,
            UUID supplierId,
            String supplierName,
            UUID goodsId,
            String goodsCode,
            String goodsName,
            UUID colorId,
            String colorName,
            UUID unitId,
            String unitName,
            BigDecimal orderQty,
            BigDecimal drawnQty,
            BigDecimal pendingQty,
            BigDecimal drawableQty,
            BigDecimal shortQty,
            int materialKindCount,
            int readyKindCount,
            int shortKindCount,
            int unplannedShortKindCount,
            String status,
            LocalDate deliverDate,
            boolean canDraw,
            BigDecimal materialQty,
            String planNo) {
    }

    /** 列表能力位: 是否持有委外领料权限(新页面一律读它, 不在页面里判断权限常量)。 */
    public record DrawCapabilities(boolean canSubmitDraw) {
    }

    /**
     * 列表响应。statusCounts 键: DRAWABLE(含部分可领)、DRAW_SUBMITTED、WAITING_PLANNING、
     * WAITING_MATERIAL、ALL; 计数按当前关键字/订货单筛选, 不受状态筛选影响。
     */
    public record DrawTaskPage(
            PageResponse<DrawTaskRow> page,
            Map<String, Long> statusCounts,
            DrawCapabilities capabilities) {
        public DrawTaskPage {
            statusCounts = java.util.Collections.unmodifiableMap(new java.util.LinkedHashMap<>(statusCounts));
        }
    }

    /** 物料在途来源: kind ∈ PURCHASE / PRODUCTION / SUBCONTRACT, openQty 为基本单位未到量。 */
    public record DrawSupplySource(String kind, UUID docId, String docNo, BigDecimal openQty) {
    }

    /**
     * 任务详情的物料行(物料基本单位)。requiredQty = 我方需发量 LEAST(计划量, f(Qm)), 没有委外商自带料时
     * 就是冻结计划量。state ∈ SENT_FULL / PENDING / DRAWABLE / SHORT / CLOSED:
     * CLOSED = 已结束领料; SENT_FULL = 已发外 ≥ 需求; PENDING = 有待仓库发的领料; SHORT = 还缺 &gt; 0;
     * DRAWABLE = 本物料仓库可用已够(drawableQty 为本批可领, 其它物料还缺时可能为 0)。
     */
    public record DrawTaskMaterial(
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
            String state,
            List<DrawSupplySource> supplySources) {
        public DrawTaskMaterial {
            supplySources = List.copyOf(supplySources);
        }
    }

    /**
     * 本任务挂着、仓库还没发出的领料草稿。lineCount = 本任务在该草稿里的物料行数。
     * edited = 仓库已保存过拣货修改(改了数量、删了物料行或改过草稿): 这种草稿委外这边撤回不了,
     * 要请仓库在拣货页整张退回; 「结束领料」仍可一并撤回。
     */
    public record DrawPendingDraft(
            UUID issueId,
            String billNo,
            UUID warehouseId,
            String warehouseName,
            int lineCount,
            OffsetDateTime submittedAt,
            String submittedByName,
            boolean edited) {
    }

    /**
     * 任务详情。allowedActions ⊆ {WITHDRAW, CLOSE}, 由服务端按权限与事实给出: 至少有一张待发领料
     * 仓库还没改过才给 WITHDRAW; CLOSE 会连仓库改过的待发领料一起撤回。
     */
    public record DrawTaskMaterials(
            DrawTaskRow task,
            List<DrawTaskMaterial> materials,
            List<DrawPendingDraft> pendingDrafts,
            List<String> allowedActions) {
        public DrawTaskMaterials {
            materials = List.copyOf(materials);
            pendingDrafts = List.copyOf(pendingDrafts);
            allowedActions = List.copyOf(allowedActions);
        }
    }

    /** 批量领料的一项: qty 为 null 时取联合分配后的本批可领。 */
    public record DrawItemRequest(UUID orderItemId, BigDecimal qty) {
    }

    public record DrawPreviewRequest(List<DrawItemRequest> items) {
    }

    public record DrawPreviewTask(
            UUID orderItemId,
            UUID orderId,
            String orderBillNo,
            Integer lineNo,
            String supplierName,
            UUID goodsId,
            String goodsCode,
            String goodsName,
            String colorName,
            String unitName,
            BigDecimal orderQty,
            BigDecimal drawnQty,
            BigDecimal drawableQty,
            BigDecimal batchDrawableQty,
            BigDecimal qty) {
    }

    /** 预览物料行: 某仓、某物料本次要领的量; warehouseAvailableQty 为该仓本行此刻可动用量。 */
    public record DrawPreviewLine(
            UUID orderItemId,
            UUID planItemId,
            UUID warehouseId,
            String warehouseName,
            UUID goodsId,
            String goodsCode,
            String goodsName,
            UUID colorId,
            String colorName,
            UUID unitId,
            String unitName,
            BigDecimal qty,
            BigDecimal warehouseAvailableQty) {
    }

    /** documentCount = 将新建的出仓草稿张数(订货单 × 仓库)。 */
    public record DrawPreview(
            List<DrawPreviewTask> tasks,
            List<DrawPreviewLine> lines,
            int documentCount) {
        public DrawPreview {
            tasks = List.copyOf(tasks);
            lines = List.copyOf(lines);
        }
    }

    public record DrawSubmitRequest(List<DrawItemRequest> items, String idempotencyKey) {
    }

    public record DrawSubmitResult(
            List<UUID> issueIds,
            List<String> issueBillNos,
            int documentCount,
            boolean replayed) {
        public DrawSubmitResult {
            issueIds = List.copyOf(issueIds);
            issueBillNos = List.copyOf(issueBillNos);
        }
    }

    public record DrawWithdrawRequest(List<UUID> orderItemIds) {
    }

    public record DrawWithdrawResult(List<UUID> withdrawnIssueIds, int removedLineCount) {
        public DrawWithdrawResult {
            withdrawnIssueIds = List.copyOf(withdrawnIssueIds);
        }
    }

    public record DrawCloseRequest(String reason) {
    }

    public record DrawCloseResult(boolean closed) {
    }
}

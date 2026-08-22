package com.uten.imp.features.production.analysis;

import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.production.ProductionDocumentAccessPolicy;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.sql.Timestamp;
import java.time.Instant;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;
import java.util.UUID;

/**
 * 物料分析「供给全链路进度」只读投影。
 *
 * <p>从一条 BOM 物料节点出发，沿 计划前供给行动 → 采购/委外申请 → 订货 →
 * 财务审批 → 预计到货 → 收货 → IQC 质检 → 分析目标仓齐套 的真实单据链回溯，
 * 输出「提交需求 / 下单 / 财务批准 / 仓库收货 / 品质验收 / 入库齐套」逐步状态。
 * 前端只展示该投影，不在客户端推算任何一步。自制（MAKE）路线改投
 * 「自制任务 → 生产计划 → 完工入库」三步。</p>
 */
@Service
@RequiredArgsConstructor
public class MaterialAnalysisSupplyProgressService {

    private static final String DONE = "DONE";
    private static final String CURRENT = "CURRENT";
    private static final String WAITING = "WAITING";
    private static final String REJECTED = "REJECTED";

    private final EntityManager em;
    private final ProductionDocumentAccessPolicy access;
    private final com.uten.imp.common.util.EmployeeNameResolver nameResolver;

    @Transactional(readOnly = true)
    public MaterialAnalysisContracts.SupplyProgressView supplyProgress(
            UUID analysisId, UUID materialLineId) {
        // 对象级授权与分析详情同一口径：无权读到 header 即视为不存在。
        UUID makerId = NativeQueryResults.typedRows(em.createNativeQuery("""
                        SELECT maker_id FROM production_material_analyses
                        WHERE id = :id AND is_deleted = FALSE
                        """).setParameter("id", analysisId), UUID.class)
                .stream().findFirst()
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "物料分析不存在"));
        access.requireReadable(makerId, "物料分析不存在");

        List<Object[]> materialRows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT material.analysis_item_id, material.required_qty, material.shortage_qty,
                       goods.code, goods.name
                FROM production_material_analysis_materials material
                JOIN goods goods ON goods.id = material.goods_id
                WHERE material.id = :materialLineId
                  AND material.analysis_id = :analysisId
                  AND material.active = TRUE
                """)
                .setParameter("materialLineId", materialLineId)
                .setParameter("analysisId", analysisId));
        if (materialRows.isEmpty()) {
            throw new ApiException(ErrorCode.NOT_FOUND, "物料分析节点不存在或已过期");
        }
        Object[] material = materialRows.getFirst();
        UUID analysisItemId = (UUID) material[0];
        BigDecimal requiredQty = decimal(material[1]);
        BigDecimal shortageQty = decimal(material[2]);
        String goodsCode = (String) material[3];
        String goodsName = (String) material[4];

        // 该节点最近一次未取消的供给行动（含外部单据锚点与提交人）。
        List<Object[]> actions = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT action.id, action.route, action.external_document_type,
                       action.external_document_id, action.external_document_no,
                       action.created_at, action.created_by
                FROM preplan_supply_action_allocations allocation
                JOIN preplan_supply_actions action ON action.id = allocation.action_id
                WHERE allocation.analysis_material_id = :materialLineId
                  AND action.status <> 'CANCELLED'
                ORDER BY action.created_at DESC, action.id DESC
                LIMIT 1
                """).setParameter("materialLineId", materialLineId));

        List<MaterialAnalysisContracts.SupplyProgressStep> steps = new ArrayList<>();
        if (actions.isEmpty()) {
            return new MaterialAnalysisContracts.SupplyProgressView(
                    materialLineId.toString(), goodsCode, goodsName, null, steps);
        }
        Object[] action = actions.getFirst();
        String route = (String) action[1];
        String externalType = (String) action[2];
        OffsetDateTime actionAt = time(action[5]);
        String actorName = nameResolver.nameWithCodeOf((UUID) action[6]);
        UUID supplyActionId = (UUID) action[0];

        if ("MAKE".equals(route)) {
            steps = makeSteps(
                    materialLineId, analysisItemId, supplyActionId,
                    requiredQty, shortageQty, actionAt, actorName);
        } else {
            boolean purchase = !"SUBCONTRACT_APPLICATION".equals(externalType);
            steps = procurementSteps(
                    materialLineId, supplyActionId, purchase,
                    requiredQty, shortageQty, actionAt, actorName);
        }
        return new MaterialAnalysisContracts.SupplyProgressView(
                materialLineId.toString(), goodsCode, goodsName, route, steps);
    }

    // ============================ 采购 / 委外链 ============================

    private List<MaterialAnalysisContracts.SupplyProgressStep> procurementSteps(
            UUID materialLineId, UUID supplyActionId, boolean purchase,
            BigDecimal requiredQty, BigDecimal shortageQty, OffsetDateTime actionAt,
            String actorName) {
        String routeLabel = purchase ? "采购" : "委外";
        List<MaterialAnalysisContracts.SupplyProgressStep> steps = new ArrayList<>();

        // ① 已提交需求：行动存在即完成；单号取申请/委外申请（行动外部单据）。
        List<Object[]> requestRows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT DISTINCT request.bill_no, request.created_at
                FROM preplan_supply_action_allocations allocation
                JOIN preplan_supply_actions action ON action.id = allocation.action_id
                JOIN %s request_item ON request_item.id = allocation.external_item_id
                JOIN %s request ON request.id = request_item.%s
                WHERE allocation.analysis_material_id = :materialLineId
                  AND action.status <> 'CANCELLED'
                  AND request.is_deleted = FALSE
                ORDER BY request.created_at
                """.formatted(
                purchase ? "purchase_request_items" : "subcontract_application_items",
                purchase ? "purchase_requests" : "subcontract_applications",
                purchase ? "request_id" : "application_id"))
                .setParameter("materialLineId", materialLineId));
        String requestNos = joinColumn(requestRows, 0);
        steps.add(new MaterialAnalysisContracts.SupplyProgressStep(
                "REQUEST_SUBMITTED", "已提交" + routeLabel + "需求", DONE,
                null, requestNos.isEmpty() ? null : requestNos, iso(actionAt), actorName));

        // ② 下单：申请明细 → 订货明细 → 订货单。
        String orderItemSource = purchase ? "request_item_id" : "application_item_id";
        List<Object[]> orderRows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT DISTINCT ord.id, ord.bill_no, ord.status, ord.is_closed, ord.created_at,
                       ord.maker_id, order_item.id
                FROM preplan_supply_action_allocations allocation
                JOIN preplan_supply_actions action ON action.id = allocation.action_id
                JOIN %s order_item ON order_item.%s = allocation.external_item_id
                JOIN %s ord ON ord.id = order_item.order_id
                WHERE allocation.analysis_material_id = :materialLineId
                  AND action.status <> 'CANCELLED'
                  AND order_item.is_deleted = FALSE
                  AND ord.is_deleted = FALSE
                ORDER BY ord.created_at, ord.id, order_item.id
                """.formatted(
                purchase ? "purchase_order_items" : "subcontract_order_items",
                orderItemSource,
                purchase ? "purchase_orders" : "subcontract_orders"))
                .setParameter("materialLineId", materialLineId));

        if (orderRows.isEmpty()) {
            steps.add(new MaterialAnalysisContracts.SupplyProgressStep(
                    "ORDER_PLACED", routeLabel + "下单", CURRENT,
                    routeLabel + "员尚未生成订货单", null, null, null));
            steps.add(new MaterialAnalysisContracts.SupplyProgressStep(
                    "FINANCE", "财务批准", WAITING, null, null, null, null));
            if (!purchase) {
                // 委外 = 先出（材料）后进（成品）：出仓步骤同步进计划部进度链。
                steps.add(new MaterialAnalysisContracts.SupplyProgressStep(
                        "MATERIAL_ISSUED", "材料出仓", WAITING, null, null, null, null));
            }
            steps.add(new MaterialAnalysisContracts.SupplyProgressStep(
                    "RECEIVED", "仓库收货", WAITING, null, null, null, null));
            steps.add(new MaterialAnalysisContracts.SupplyProgressStep(
                    "QUALITY", "品质验收", WAITING, null, null, null, null));
            steps.add(stockedStep(
                    materialLineId, supplyActionId, requiredQty, shortageQty));
            return steps;
        }

        Set<UUID> orderIds = new LinkedHashSet<>();
        Set<UUID> orderItemIds = new LinkedHashSet<>();
        StringBuilder orderNos = new StringBuilder();
        OffsetDateTime firstOrderAt = null;
        String orderMakerName = null;
        boolean allApproved = true;
        for (Object[] row : orderRows) {
            boolean newOrder = orderIds.add((UUID) row[0]);
            orderItemIds.add((UUID) row[6]);
            if (newOrder) {
                if (!orderNos.isEmpty()) orderNos.append('、');
                orderNos.append((String) row[1]);
            }
            OffsetDateTime createdAt = time(row[4]);
            if (firstOrderAt == null || (createdAt != null && createdAt.isBefore(firstOrderAt))) {
                firstOrderAt = createdAt;
                orderMakerName = nameResolver.nameWithCodeOf((UUID) row[5]);
            }
            if (((Number) row[2]).intValue() != 1) allApproved = false;
        }
        steps.add(new MaterialAnalysisContracts.SupplyProgressStep(
                "ORDER_PLACED", routeLabel + "下单", DONE,
                null, orderNos.toString(), iso(firstOrderAt), orderMakerName));

        // ③ 财务批准：以审批案件与订单生效状态联合判定。
        List<Object[]> caseRows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT DISTINCT approval.status, approval.decided_at, approval.decided_by_employee_id
                FROM procurement_order_approval_cases approval
                WHERE approval.order_type = :orderType AND approval.order_id IN (:orderIds)
                ORDER BY approval.decided_at NULLS LAST
                """)
                .setParameter("orderType", purchase ? "PURCHASE" : "SUBCONTRACT")
                .setParameter("orderIds", List.copyOf(orderIds)));
        boolean anyPending = false;
        boolean anyRejected = false;
        OffsetDateTime decidedAt = null;
        String deciderName = null;
        for (Object[] row : caseRows) {
            String status = (String) row[0];
            if ("PENDING".equals(status)) anyPending = true;
            if ("REJECTED".equals(status)) anyRejected = true;
            if ("APPROVED".equals(status) && decidedAt == null) {
                decidedAt = time(row[1]);
                deciderName = nameResolver.nameWithCodeOf((UUID) row[2]);
            }
        }
        String financeState;
        String financeDetail = null;
        if (allApproved) {
            financeState = DONE;
        } else if (anyPending) {
            financeState = CURRENT;
            financeDetail = "等待财务审核组处理";
        } else if (anyRejected) {
            financeState = REJECTED;
            financeDetail = "财务已驳回，待" + routeLabel + "员修改后重新提交";
        } else {
            financeState = CURRENT;
        }
        steps.add(new MaterialAnalysisContracts.SupplyProgressStep(
                "FINANCE", "财务批准", financeState,
                financeDetail, null, financeState == DONE ? iso(decidedAt) : null,
                financeState == DONE ? deciderName : null));

        // ③.5 委外材料出仓（仅委外）：财务批准 → 发料计划/出仓单 → 仓库出仓（V304 口径）。
        if (!purchase) {
            steps.add(subcontractOutboundStep(orderItemIds, financeState));
        }

        // ④ 仓库收货：订货明细 → 收货明细 → 收货单（status=1 为已审核收货）。
        String receiptItemTable = purchase ? "purchase_receipt_items" : "subcontract_receipt_items";
        String receiptTable = purchase ? "purchase_receipts" : "subcontract_receipts";
        List<Object[]> receiptRows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT DISTINCT receipt.id, receipt.bill_no, receipt.status, receipt.created_at,
                       receipt.maker_id, receipt_item.id
                FROM %s receipt_item
                JOIN %s receipt ON receipt.id = receipt_item.receipt_id
                WHERE receipt_item.order_item_id IN (:orderItemIds)
                  AND receipt_item.is_deleted = FALSE
                  AND receipt.is_deleted = FALSE
                ORDER BY receipt.created_at, receipt.id, receipt_item.id
                """.formatted(
                receiptItemTable, receiptTable))
                .setParameter("orderItemIds", List.copyOf(orderItemIds)));
        Set<UUID> approvedReceiptIds = new LinkedHashSet<>();
        Set<UUID> approvedReceiptItemIds = new LinkedHashSet<>();
        StringBuilder receiptNos = new StringBuilder();
        OffsetDateTime firstReceiptAt = null;
        String receiverName = null;
        boolean anyReceiptDraft = false;
        for (Object[] row : receiptRows) {
            int status = ((Number) row[2]).intValue();
            if (status == 1) {
                boolean newReceipt = approvedReceiptIds.add((UUID) row[0]);
                approvedReceiptItemIds.add((UUID) row[5]);
                if (newReceipt) {
                    if (!receiptNos.isEmpty()) receiptNos.append('、');
                    receiptNos.append((String) row[1]);
                }
                OffsetDateTime createdAt = time(row[3]);
                if (firstReceiptAt == null
                        || (createdAt != null && createdAt.isBefore(firstReceiptAt))) {
                    firstReceiptAt = createdAt;
                    receiverName = nameResolver.nameWithCodeOf((UUID) row[4]);
                }
            } else if (status == 0) {
                anyReceiptDraft = true;
            }
        }
        String receivedState;
        String receivedDetail = null;
        if (financeState != DONE) {
            receivedState = WAITING;
        } else if (!approvedReceiptIds.isEmpty()) {
            receivedState = DONE;
        } else if (anyReceiptDraft) {
            receivedState = CURRENT;
            receivedDetail = "收货单已登记，待审核";
        } else {
            receivedState = CURRENT;
            receivedDetail = "等待仓库登记实际到货";
        }
        steps.add(new MaterialAnalysisContracts.SupplyProgressStep(
                "RECEIVED", "仓库收货", receivedState,
                receivedDetail,
                receiptNos.isEmpty() ? null : receiptNos.toString(),
                receivedState == DONE ? iso(firstReceiptAt) : null,
                receivedState == DONE ? receiverName : null));

        // ⑤ 品质验收：已审收货单的 IQC 待检明细（全部结案且有合格量 = 完成）。
        String qualityState;
        String qualityDetail = null;
        OffsetDateTime qualityAt = null;
        if (approvedReceiptItemIds.isEmpty()) {
            qualityState = receivedState == WAITING ? WAITING : CURRENT;
            if (receivedState != WAITING) qualityDetail = "等待收货审核后送检";
        } else {
            List<Object[]> inspectionRows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                    SELECT COUNT(*),
                           COUNT(*) FILTER (WHERE status IN ('PENDING','PARTIAL')),
                           COALESCE(SUM(passed_base_qty), 0),
                           COALESCE(SUM(failed_base_qty), 0),
                           MAX(passed_at)
                    FROM procurement_inspection_items
                    WHERE receipt_type = :receiptType
                      AND receipt_item_id IN (:receiptItemIds)
                    """)
                    .setParameter("receiptType", purchase ? "PURCHASE" : "SUBCONTRACT")
                    .setParameter("receiptItemIds", List.copyOf(approvedReceiptItemIds)));
            Object[] agg = inspectionRows.getFirst();
            long total = ((Number) agg[0]).longValue();
            long open = ((Number) agg[1]).longValue();
            BigDecimal passed = decimal(agg[2]);
            BigDecimal failed = decimal(agg[3]);
            qualityAt = time(agg[4]);
            if (total == 0) {
                qualityState = CURRENT;
                qualityDetail = "待检记录生成中";
            } else if (open > 0) {
                qualityState = CURRENT;
                qualityDetail = "待品质部检验 " + open + " 行";
            } else if (passed.signum() > 0) {
                qualityState = DONE;
                qualityDetail = failed.signum() > 0
                        ? "合格 " + passed.stripTrailingZeros().toPlainString()
                                + " · 不合格 " + failed.stripTrailingZeros().toPlainString()
                        : "全部合格";
            } else {
                qualityState = REJECTED;
                qualityDetail = "全部判定不合格";
            }
        }
        steps.add(new MaterialAnalysisContracts.SupplyProgressStep(
                "QUALITY", "品质验收", qualityState,
                qualityDetail, null,
                qualityState == DONE ? iso(qualityAt) : null, null));

        // ⑥ 入库齐套：以分析节点实时缺口为权威（合格入目标仓即归零）。
        steps.add(stockedStep(
                materialLineId, supplyActionId, requiredQty, shortageQty));
        return steps;
    }

    // ============================ 委外材料出仓（V304） ============================

    /**
     * 委外材料出仓步骤：财务批准后按计划/出仓单聚合。DONE = 全部计划量已出仓或余量已关闭；
     * CURRENT = 草稿待审 / 部分出仓 / 等待仓库出仓；无计划且无出仓单 = 委外商自备料（DONE）。
     */
    private MaterialAnalysisContracts.SupplyProgressStep subcontractOutboundStep(
            Set<UUID> orderItemIds, String financeState) {
        if (!DONE.equals(financeState)) {
            return new MaterialAnalysisContracts.SupplyProgressStep(
                    "MATERIAL_ISSUED", "材料出仓", WAITING, null, null, null, null);
        }
        List<Object[]> planAgg = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT COALESCE(SUM(pi.planned_qty), 0), COALESCE(SUM(pi.issued_qty), 0),
                       COALESCE(SUM(GREATEST(pi.planned_qty - pi.issued_qty, 0))
                           FILTER (WHERE p.status = 'OPEN'), 0),
                       COUNT(DISTINCT p.id)
                FROM subcontract_material_plans p
                JOIN subcontract_material_plan_items pi
                  ON pi.plan_id = p.id AND pi.is_deleted = FALSE
                WHERE pi.order_item_id IN (:orderItemIds) AND p.is_deleted = FALSE
                """)
                .setParameter("orderItemIds", List.copyOf(orderItemIds)));
        List<Object[]> issueRows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT i.bill_no, i.status, i.updated_at, i.approver_id
                FROM subcontract_material_issues i
                WHERE i.is_deleted = FALSE AND EXISTS (
                    SELECT 1 FROM subcontract_material_issue_items ii
                    WHERE ii.issue_id = i.id
                      AND ii.order_item_id IN (:orderItemIds))
                ORDER BY i.created_at
                """)
                .setParameter("orderItemIds", List.copyOf(orderItemIds)));
        Object[] agg = planAgg.getFirst();
        BigDecimal planned = decimal(agg[0]);
        BigDecimal issued = decimal(agg[1]);
        BigDecimal openRemaining = agg[2] == null ? BigDecimal.ZERO : decimal(agg[2]);
        long planCount = ((Number) agg[3]).longValue();

        StringBuilder approvedNos = new StringBuilder();
        OffsetDateTime lastApprovedAt = null;
        String approverName = null;
        boolean anyDraft = false;
        for (Object[] row : issueRows) {
            int status = ((Number) row[1]).intValue();
            if (status == 1) {
                if (!approvedNos.isEmpty()) approvedNos.append('、');
                approvedNos.append((String) row[0]);
                OffsetDateTime at = time(row[2]);
                if (lastApprovedAt == null || (at != null && at.isAfter(lastApprovedAt))) {
                    lastApprovedAt = at;
                    approverName = nameResolver.nameWithCodeOf((UUID) row[3]);
                }
            } else if (status == 0) {
                anyDraft = true;
            }
        }

        if (planCount == 0 && issueRows.isEmpty()) {
            return new MaterialAnalysisContracts.SupplyProgressStep(
                    "MATERIAL_ISSUED", "材料出仓", DONE, "无需发料（委外商自备料）", null, null, null);
        }
        String qtyText = "已出仓 " + issued.stripTrailingZeros().toPlainString()
                + " / 计划 " + planned.stripTrailingZeros().toPlainString();
        if (openRemaining.signum() <= 0 && planCount > 0) {
            return new MaterialAnalysisContracts.SupplyProgressStep(
                    "MATERIAL_ISSUED", "材料出仓", DONE, qtyText,
                    approvedNos.isEmpty() ? null : approvedNos.toString(),
                    iso(lastApprovedAt), approverName);
        }
        String detail = issued.signum() > 0
                ? qtyText + "（部分出仓）"
                : anyDraft ? "出仓单已生成，待仓库审核出仓" : "等待仓库出仓";
        return new MaterialAnalysisContracts.SupplyProgressStep(
                "MATERIAL_ISSUED", "材料出仓", CURRENT, detail,
                approvedNos.isEmpty() ? null : approvedNos.toString(), null, null);
    }

    // ============================ 自制链 ============================

    private List<MaterialAnalysisContracts.SupplyProgressStep> makeSteps(
            UUID materialLineId, UUID analysisItemId, UUID supplyActionId,
            BigDecimal requiredQty, BigDecimal shortageQty,
            OffsetDateTime actionAt, String actorName) {
        List<MaterialAnalysisContracts.SupplyProgressStep> steps = new ArrayList<>();
        steps.add(new MaterialAnalysisContracts.SupplyProgressStep(
                "MAKE_TASK", "已创建自制备料任务", DONE, null, null, iso(actionAt), actorName));

        List<Object[]> planRows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT plan.bill_no, plan.status, plan.is_closed, plan.created_at, plan.maker_id
                FROM production_plans plan
                WHERE plan.material_analysis_item_id = :analysisItemId
                  AND plan.is_deleted = FALSE
                ORDER BY plan.created_at DESC, plan.id DESC
                LIMIT 1
                """).setParameter("analysisItemId", analysisItemId));
        if (planRows.isEmpty()) {
            steps.add(new MaterialAnalysisContracts.SupplyProgressStep(
                    "PLAN", "生产计划", CURRENT, "待计划员安排生产", null, null, null));
            steps.add(new MaterialAnalysisContracts.SupplyProgressStep(
                    "PRODUCTION", "生产完工入库", WAITING, null, null, null, null));
            steps.add(stockedStep(
                    materialLineId, supplyActionId, requiredQty, shortageQty));
            return steps;
        }
        Object[] plan = planRows.getFirst();
        int planStatus = ((Number) plan[1]).intValue();
        boolean closed = Boolean.TRUE.equals(plan[2]);
        steps.add(new MaterialAnalysisContracts.SupplyProgressStep(
                "PLAN", "生产计划", planStatus == 1 ? DONE : CURRENT,
                planStatus == 1 ? null : "计划待审核下达",
                (String) plan[0], iso(time(plan[3])),
                nameResolver.nameWithCodeOf((UUID) plan[4])));
        steps.add(new MaterialAnalysisContracts.SupplyProgressStep(
                "PRODUCTION", "生产完工入库", closed ? DONE : (planStatus == 1 ? CURRENT : WAITING),
                closed ? null : (planStatus == 1 ? "生产进行中" : null), null, null, null));
        steps.add(stockedStep(
                materialLineId, supplyActionId, requiredQty, shortageQty));
        return steps;
    }

    // ============================ 共用 ============================

    /** 末步「入库齐套」：以分析节点实时缺口为权威（缺口归零 = 已齐套）。 */
    private MaterialAnalysisContracts.SupplyProgressStep stockedStep(
            UUID materialLineId, UUID supplyActionId,
            BigDecimal requiredQty, BigDecimal shortageQty) {
        if (requiredQty.compareTo(BigDecimal.ZERO) <= 0) {
            BigDecimal delegated = decimal(em.createNativeQuery("""
                    SELECT COALESCE(SUM(state.qty), 0)
                    FROM v_preplan_make_entitlement_delegation_state state
                    JOIN preplan_stock_entitlement_events source_event
                      ON source_event.id = state.source_entitlement_event_id
                    JOIN preplan_analysis_stock_exact_pegs exact_peg
                      ON exact_peg.id = source_event.source_exact_peg_id
                    JOIN preplan_supply_action_allocations allocation
                      ON allocation.id =
                         exact_peg.supply_action_allocation_id
                    WHERE state.source_analysis_material_id = :materialLineId
                      AND state.state = 'ACTIVE'
                      AND allocation.action_id = :supplyActionId
                    """)
                    .setParameter("materialLineId", materialLineId)
                    .setParameter("supplyActionId", supplyActionId)
                    .getSingleResult());
            String detail = delegated.signum() > 0
                    ? "该供给行动的合格权益已移交自制子件 "
                            + delegated.stripTrailingZeros().toPlainString()
                            + " · 原路径本批无需重复备料"
                    : "本批无需补货";
            return new MaterialAnalysisContracts.SupplyProgressStep(
                    "STOCKED", "入库齐套", DONE, detail,
                    null, null, null);
        }
        boolean stocked = shortageQty.compareTo(BigDecimal.ZERO) <= 0;
        BigDecimal covered = requiredQty.subtract(shortageQty).max(BigDecimal.ZERO);
        return new MaterialAnalysisContracts.SupplyProgressStep(
                "STOCKED", "入库齐套", stocked ? DONE : WAITING,
                "已备 " + covered.stripTrailingZeros().toPlainString()
                        + " / " + requiredQty.stripTrailingZeros().toPlainString(),
                null, null, null);
    }

    private static String joinColumn(List<Object[]> rows, int index) {
        StringBuilder builder = new StringBuilder();
        for (Object[] row : rows) {
            if (row[index] == null) continue;
            if (!builder.isEmpty()) builder.append('、');
            builder.append(row[index]);
        }
        return builder.toString();
    }

    private static BigDecimal decimal(Object value) {
        return value == null ? BigDecimal.ZERO : new BigDecimal(value.toString());
    }

    private static OffsetDateTime time(Object value) {
        if (value == null) return null;
        if (value instanceof OffsetDateTime dateTime) {
            return dateTime.withOffsetSameInstant(ZoneOffset.UTC);
        }
        if (value instanceof Instant instant) {
            return instant.atOffset(ZoneOffset.UTC);
        }
        if (value instanceof Timestamp timestamp) {
            return timestamp.toInstant().atOffset(ZoneOffset.UTC);
        }
        return null;
    }

    private static String iso(OffsetDateTime value) {
        return value == null ? null : value.toString();
    }
}

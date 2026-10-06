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
 * 委外在财务批准后多一步「领料发外」(ADR-143 §4.6：已领 x/Q 套，按领料读模型，
 * 不把不同物料的数量相加)，回厂按批次显示。前端只展示该投影，不在客户端推算任何一步。
 * 自制（MAKE）路线改投「自制任务 → 生产计划 → 完工入库」三步。</p>
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
                       goods.code, goods.name, material.goods_id, material.color_id
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
        BigDecimal requiredQty = decimal(material[1]);
        BigDecimal shortageQty = decimal(material[2]);
        String goodsCode = (String) material[3];
        String goodsName = (String) material[4];
        UUID goodsId = (UUID) material[5];
        UUID colorId = (UUID) material[6];

        // 该节点最近一次未取消的供给行动（含外部单据锚点与提交人）。
        List<Object[]> actions = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT action.id, action.route, action.external_document_type,
                       action.external_document_id, action.external_document_no,
                       action.created_at, action.created_by
                FROM preplan_supply_actions action
                WHERE action.analysis_id = :analysisId
                  AND action.status <> 'CANCELLED'
                  AND (
                      EXISTS (
                          SELECT 1 FROM preplan_supply_action_allocations allocation
                          WHERE allocation.action_id = action.id
                            AND allocation.analysis_material_id = :materialLineId)
                      OR action.safety_replenishment_qty > 0
                         AND action.goods_id = :goodsId
                         AND action.color_id IS NOT DISTINCT FROM
                             CAST(:colorId AS uuid)
                         AND action.warehouse_id = (
                             SELECT analysis.warehouse_id
                             FROM production_material_analyses analysis
                             WHERE analysis.id = :analysisId)
                  )
                ORDER BY action.created_at DESC, action.id DESC
                LIMIT 1
                """).setParameter("materialLineId", materialLineId)
                .setParameter("goodsId", goodsId)
                .setParameter("colorId", colorId)
                .setParameter("analysisId", analysisId));

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

        if ("PREPLAN_MAKE_TASK".equals(externalType)) {
            UUID makeChildAnalysisItemId = (UUID) action[3];
            steps = makeSteps(
                    analysisId, materialLineId, makeChildAnalysisItemId, supplyActionId,
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
        String splitDetail = purchase ? buySplitDetail(supplyActionId) : null;

        // ① 已提交需求：行动存在即完成；单号取申请/委外申请（行动外部单据）。
        List<Object[]> requestRows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT DISTINCT request.bill_no, request.created_at
                FROM preplan_supply_actions action
                JOIN %s request ON request.id = action.external_document_id
                WHERE action.id = :supplyActionId
                  AND action.status <> 'CANCELLED'
                  AND request.is_deleted = FALSE
                ORDER BY request.created_at
                """.formatted(
                purchase ? "purchase_requests" : "subcontract_applications"))
                .setParameter("supplyActionId", supplyActionId));
        String requestNos = joinColumn(requestRows, 0);
        steps.add(new MaterialAnalysisContracts.SupplyProgressStep(
                "REQUEST_SUBMITTED", "已提交" + routeLabel + "需求", DONE,
                splitDetail, requestNos.isEmpty() ? null : requestNos,
                iso(actionAt), actorName));

        // ② 下单：申请明细 → 订货明细（V463 起经来源分配行，合并行对每个来源可见）→ 订货单。
        // src 必须挂到 order_item 上(src.order_item_id), 否则来源只按行动过滤 = 与全部订货明细交叉连接。
        List<Object[]> orderRows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT DISTINCT ord.id, ord.bill_no, ord.status, ord.is_closed, ord.created_at,
                       ord.maker_id, order_item.id
                FROM %s order_item
                JOIN %s ord ON ord.id = order_item.order_id
                JOIN %s src ON src.order_item_id = order_item.id
                WHERE src.%s IN (
                      SELECT allocation.external_item_id
                      FROM preplan_supply_action_allocations allocation
                      WHERE allocation.action_id = :supplyActionId
                        AND allocation.external_item_id IS NOT NULL
                      UNION
                      SELECT action.safety_external_item_id
                      FROM preplan_supply_actions action
                      WHERE action.id = :supplyActionId
                        AND action.safety_external_item_id IS NOT NULL)
                  AND order_item.is_deleted = FALSE
                  AND ord.is_deleted = FALSE
                ORDER BY ord.created_at, ord.id, order_item.id
                """.formatted(
                purchase ? "purchase_order_items" : "subcontract_order_items",
                purchase ? "purchase_orders" : "subcontract_orders",
                purchase ? "purchase_order_item_sources" : "subcontract_order_item_sources",
                purchase ? "request_item_id" : "application_item_id"))
                .setParameter("supplyActionId", supplyActionId));

        if (orderRows.isEmpty()) {
            steps.add(new MaterialAnalysisContracts.SupplyProgressStep(
                    "ORDER_PLACED", routeLabel + "下单", CURRENT,
                    routeLabel + "员尚未生成订货单", null, null, null));
            steps.add(new MaterialAnalysisContracts.SupplyProgressStep(
                    "FINANCE", "财务批准", WAITING, null, null, null, null));
            if (!purchase) {
                steps.add(new MaterialAnalysisContracts.SupplyProgressStep(
                        "DRAW", "领料发外", WAITING,
                        "等待委外订货与财务批准", null, null, null));
            }
            steps.add(new MaterialAnalysisContracts.SupplyProgressStep(
                    "RECEIVED", purchase ? "仓库收货" : "委外件回厂登记",
                    WAITING, null, null, null, null));
            steps.add(new MaterialAnalysisContracts.SupplyProgressStep(
                    "QUALITY", purchase ? "品质验收" : "委外回厂 IQC",
                    WAITING, null, null, null, null));
            steps.add(purchase
                    ? purchaseStockedStep(materialLineId, supplyActionId,
                            requiredQty, shortageQty,
                            BigDecimal.ZERO, BigDecimal.ZERO)
                    : subcontractStockedStep(materialLineId, supplyActionId,
                            requiredQty, shortageQty,
                            BigDecimal.ZERO, BigDecimal.ZERO));
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

        SubcontractDrawProgress subcontractDraw = null;
        if (!purchase) {
            subcontractDraw = subcontractDrawProgress(orderItemIds, financeState);
            steps.add(subcontractDraw.step());
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
            // 委外分批回厂：已回厂量没到订货量(且订货单未结案)时这一步仍在进行。
            if (subcontractDraw != null && subcontractDraw.returningInBatches()) {
                receivedState = CURRENT;
                receivedDetail = "已回厂 " + plain(subcontractDraw.returnedBaseQty())
                        + " / " + plain(subcontractDraw.orderBaseQty()) + "(分批回厂)";
            } else {
                receivedState = DONE;
            }
        } else if (anyReceiptDraft) {
            receivedState = CURRENT;
            receivedDetail = purchase ? "收货单已登记，待审核" : "回厂已登记，待审核送检";
        } else if (!purchase && (subcontractDraw == null
                || !subcontractDraw.canReturn())) {
            receivedState = WAITING;
            receivedDetail = "至少发出一批直属物料后方可登记回厂";
        } else {
            receivedState = CURRENT;
            receivedDetail = purchase ? "等待仓库登记实际到货" : "等待登记委外件回厂";
        }
        steps.add(new MaterialAnalysisContracts.SupplyProgressStep(
                "RECEIVED", purchase ? "仓库收货" : "委外件回厂登记", receivedState,
                receivedDetail,
                receiptNos.isEmpty() ? null : receiptNos.toString(),
                approvedReceiptIds.isEmpty() ? null : iso(firstReceiptAt),
                approvedReceiptIds.isEmpty() ? null : receiverName));

        // ⑤ 品质验收：已审收货单的 IQC 待检明细（全部结案且有合格量 = 完成）。
        String qualityState;
        String qualityDetail = null;
        OffsetDateTime qualityAt = null;
        BigDecimal qualifiedReturnedQty = BigDecimal.ZERO;
        BigDecimal warehouseStockedQty = BigDecimal.ZERO;
        if (approvedReceiptItemIds.isEmpty()) {
            qualityState = WAITING.equals(receivedState) ? WAITING : CURRENT;
            if (!WAITING.equals(receivedState)) qualityDetail = "等待收货审核后送检";
        } else {
            List<Object[]> inspectionRows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                    SELECT COUNT(*),
                           COUNT(*) FILTER (WHERE status IN ('PENDING','PARTIAL')),
                           COALESCE(SUM(passed_base_qty), 0),
                           COALESCE(SUM(failed_base_qty), 0),
                           MAX(passed_at),
                           COALESCE(SUM(warehouse_stocked_base_qty), 0)
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
            qualifiedReturnedQty = passed;
            BigDecimal failed = decimal(agg[3]);
            qualityAt = time(agg[4]);
            warehouseStockedQty = decimal(agg[5]);
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
                "QUALITY", purchase ? "品质验收" : "委外回厂 IQC", qualityState,
                qualityDetail, null,
                qualityState == DONE ? iso(qualityAt) : null, null));

        steps.add(purchase
                ? purchaseStockedStep(materialLineId, supplyActionId,
                        requiredQty, shortageQty,
                        qualifiedReturnedQty, warehouseStockedQty)
                : subcontractStockedStep(materialLineId, supplyActionId,
                        requiredQty, shortageQty,
                        qualifiedReturnedQty, warehouseStockedQty));
        return steps;
    }

    // ============================ 委外领料发外 ============================

    /**
     * 「领料发外」一步(ADR-143 §4.6)：与委外任务中心「领料」分段同一个服务端函数
     * {@code fn_subcontract_draw_summary}，按订货明细的套数(订货单位)折成委外件基本量后汇总；
     * 已领 = 每种直属物料都已发齐的完整套数，不同物料的数量从不相加。
     */
    private SubcontractDrawProgress subcontractDrawProgress(
            Set<UUID> orderItemIds, String financeState) {
        if (!DONE.equals(financeState)) {
            return SubcontractDrawProgress.waiting(new MaterialAnalysisContracts.SupplyProgressStep(
                    "DRAW", "领料发外", WAITING,
                    "财务批准后在委外任务中心按可领数量领料", null, null, null));
        }
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT COALESCE(item.unit_rate, 1), summary.order_qty, summary.material_kind_count,
                       summary.drawn_qty, summary.pending_qty, summary.drawable_qty, summary.short_qty,
                       summary.all_sent, summary.any_open, ord.is_closed,
                       COALESCE((
                           SELECT SUM(returned_item.qty * COALESCE(returned_item.unit_rate, 1))
                           FROM subcontract_receipt_items returned_item
                           JOIN subcontract_receipts returned_receipt
                             ON returned_receipt.id = returned_item.receipt_id
                            AND returned_receipt.status = 1
                            AND returned_receipt.is_deleted = FALSE
                           WHERE returned_item.order_item_id = item.id
                             AND returned_item.is_deleted = FALSE), 0)
                         - COALESCE(item.returned_qty, 0) * COALESCE(item.unit_rate, 1)
                FROM subcontract_order_items item
                JOIN subcontract_orders ord ON ord.id = item.order_id
                 AND ord.status = 1 AND ord.is_deleted = FALSE
                CROSS JOIN LATERAL fn_subcontract_draw_summary(item.id) summary
                WHERE item.id IN (:orderItemIds) AND item.is_deleted = FALSE
                """).setParameter("orderItemIds", List.copyOf(orderItemIds)));
        BigDecimal orderBase = BigDecimal.ZERO;
        BigDecimal drawnBase = BigDecimal.ZERO;
        BigDecimal pendingBase = BigDecimal.ZERO;
        BigDecimal drawableBase = BigDecimal.ZERO;
        BigDecimal shortBase = BigDecimal.ZERO;
        BigDecimal returnedBase = BigDecimal.ZERO;
        boolean anyDrawPlan = false;
        boolean anyWithoutPlan = false;
        boolean allSent = true;
        boolean anyOpen = false;
        boolean returningInBatches = false;
        for (Object[] row : rows) {
            BigDecimal rate = decimal(row[0]);
            BigDecimal itemOrderBase = decimal(row[1]).multiply(rate);
            BigDecimal itemReturnedBase = decimal(row[10]);
            orderBase = orderBase.add(itemOrderBase);
            returnedBase = returnedBase.add(itemReturnedBase);
            boolean closed = Boolean.TRUE.equals(row[9]);
            if (!closed && itemReturnedBase.compareTo(itemOrderBase) < 0) returningInBatches = true;
            // 已批准的委外订货明细一定有冻结领料计划行(缺 BOM 不能下单，ADR-143 §二.3)；
            // 万一没有，按「领料计划未生成」处理，不放行回厂。
            if (((Number) row[2]).intValue() == 0) {
                anyWithoutPlan = true;
                allSent = false;
                continue;
            }
            anyDrawPlan = true;
            drawnBase = drawnBase.add(decimal(row[3]).multiply(rate));
            pendingBase = pendingBase.add(decimal(row[4]).multiply(rate));
            drawableBase = drawableBase.add(decimal(row[5]).multiply(rate));
            shortBase = shortBase.add(decimal(row[6]).multiply(rate));
            if (!Boolean.TRUE.equals(row[7])) allSent = false;
            if (Boolean.TRUE.equals(row[8])) anyOpen = true;
        }
        if (rows.isEmpty()) {
            return SubcontractDrawProgress.waiting(new MaterialAnalysisContracts.SupplyProgressStep(
                    "DRAW", "领料发外", WAITING, "订货单尚未生效", null, null, null));
        }
        if (!anyDrawPlan) {
            return SubcontractDrawProgress.waiting(new MaterialAnalysisContracts.SupplyProgressStep(
                    "DRAW", "领料发外", WAITING, "领料计划尚未生成", null, null, null));
        }
        List<Object[]> issueRows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT i.bill_no, i.updated_at, i.approver_id
                FROM subcontract_material_issues i
                WHERE i.is_deleted = FALSE AND i.status = 1 AND EXISTS (
                    SELECT 1 FROM subcontract_material_issue_items ii
                    WHERE ii.issue_id = i.id AND ii.is_deleted = FALSE
                      AND ii.order_item_id IN (:orderItemIds))
                ORDER BY i.created_at
                """).setParameter("orderItemIds", List.copyOf(orderItemIds)));
        StringBuilder approvedNos = new StringBuilder();
        OffsetDateTime lastApprovedAt = null;
        String approverName = null;
        for (Object[] row : issueRows) {
            if (!approvedNos.isEmpty()) approvedNos.append('、');
            approvedNos.append((String) row[0]);
            OffsetDateTime at = time(row[1]);
            if (lastApprovedAt == null || (at != null && at.isAfter(lastApprovedAt))) {
                lastApprovedAt = at;
                approverName = nameResolver.nameWithCodeOf((UUID) row[2]);
            }
        }
        String docNos = approvedNos.isEmpty() ? null : approvedNos.toString();
        String drawnText = "已领 " + plain(drawnBase) + " / " + plain(orderBase);
        boolean canReturn = drawnBase.signum() > 0;
        if (allSent) {
            return new SubcontractDrawProgress(new MaterialAnalysisContracts.SupplyProgressStep(
                    "DRAW", "领料发外", DONE, drawnText + "(直属物料已全部发外)",
                    docNos, iso(lastApprovedAt), approverName),
                    canReturn, orderBase, returnedBase, returningInBatches);
        }
        if (!anyOpen && !anyWithoutPlan) {
            return new SubcontractDrawProgress(new MaterialAnalysisContracts.SupplyProgressStep(
                    "DRAW", "领料发外", DONE, drawnText + "(已结束领料)",
                    docNos, iso(lastApprovedAt), approverName),
                    canReturn, orderBase, returnedBase, returningInBatches);
        }
        StringBuilder detail = new StringBuilder(drawnText);
        if (drawableBase.signum() > 0) {
            detail.append("；可领 ").append(plain(drawableBase)).append("，请到委外任务中心领料");
        }
        if (pendingBase.signum() > 0) {
            detail.append("；已提交领料 ").append(plain(pendingBase)).append("，等仓库发料");
        }
        if (drawableBase.signum() == 0 && pendingBase.signum() == 0 && shortBase.signum() > 0) {
            detail.append("；等待物料备齐");
        }
        return new SubcontractDrawProgress(new MaterialAnalysisContracts.SupplyProgressStep(
                "DRAW", "领料发外", CURRENT, detail.toString(), docNos, null, null),
                canReturn, orderBase, returnedBase, returningInBatches);
    }

    /**
     * @param canReturn 已有完整套数发到委外商处，可以登记回厂
     * @param returningInBatches 某条未结案订货明细的已回厂量还没到订货量
     */
    private record SubcontractDrawProgress(
            MaterialAnalysisContracts.SupplyProgressStep step, boolean canReturn,
            BigDecimal orderBaseQty, BigDecimal returnedBaseQty, boolean returningInBatches) {
        static SubcontractDrawProgress waiting(MaterialAnalysisContracts.SupplyProgressStep step) {
            return new SubcontractDrawProgress(step, false, BigDecimal.ZERO, BigDecimal.ZERO, false);
        }
    }

    // ============================ 自制链 ============================

    private List<MaterialAnalysisContracts.SupplyProgressStep> makeSteps(
            UUID analysisId, UUID materialLineId, UUID makeChildAnalysisItemId,
            UUID supplyActionId,
            BigDecimal requiredQty, BigDecimal shortageQty,
            OffsetDateTime actionAt, String actorName) {
        List<MaterialAnalysisContracts.SupplyProgressStep> steps = new ArrayList<>();
        steps.add(new MaterialAnalysisContracts.SupplyProgressStep(
                "MAKE_TASK", "已创建自制备料任务",
                DONE, null, null, iso(actionAt), actorName));

        List<Object[]> planRows = makeChildAnalysisItemId == null
                ? List.of()
                : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                        SELECT plan.id, plan.bill_no, plan.status, plan.is_closed,
                               plan.created_at, plan.maker_id
                        FROM production_plans plan
                        JOIN production_material_analysis_items child
                          ON child.id = plan.material_analysis_item_id
                         AND child.analysis_id = plan.material_analysis_id
                         AND (child.source_type = 'MAKE_COMPONENT' OR
                             (child.source_type='AGGREGATE_MAKE' AND EXISTS(SELECT 1 FROM preplan_aggregate_batches batch
                               WHERE batch.anchor_analysis_item_id=child.id AND batch.plan_id=plan.id
                                 AND batch.analysis_id=child.analysis_id)))
                         AND child.is_deleted = FALSE
                        WHERE plan.material_analysis_id = :analysisId
                          AND plan.material_analysis_item_id = :makeChildAnalysisItemId
                          AND plan.is_deleted = FALSE
                        ORDER BY plan.created_at DESC, plan.id DESC
                        LIMIT 1
                        """)
                        .setParameter("analysisId", analysisId)
                        .setParameter("makeChildAnalysisItemId", makeChildAnalysisItemId));
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
        UUID planId = (UUID) plan[0];
        int planStatus = ((Number) plan[2]).intValue();
        boolean closed = Boolean.TRUE.equals(plan[3]);
        steps.add(new MaterialAnalysisContracts.SupplyProgressStep(
                "PLAN", "生产计划", planStatus == 1 ? DONE : CURRENT,
                planStatus == 1 ? null : "计划待审核下达",
                (String) plan[1], iso(time(plan[4])),
                nameResolver.nameWithCodeOf((UUID) plan[5]),
                "PRODUCTION_PLAN", planId));
        steps.add(new MaterialAnalysisContracts.SupplyProgressStep(
                "PRODUCTION", "生产完工入库",
                closed ? DONE : (planStatus == 1 ? CURRENT : WAITING),
                closed ? null : (planStatus == 1 ? "生产进行中" : null), null, null, null));
        steps.add(stockedStep(
                materialLineId, supplyActionId, requiredQty, shortageQty));
        return steps;
    }

    // ============================ 共用 ============================

    /**
     * 末步「入库齐套」（自制链）：需求转出且权益移交自制子件时以移交为准；
     * 需求仍在行内时以缺口为权威（缺口归零 = 现货/权益覆盖齐套）。
     */
    private MaterialAnalysisContracts.SupplyProgressStep stockedStep(
            UUID materialLineId, UUID supplyActionId,
            BigDecimal requiredQty, BigDecimal shortageQty) {
        if (requiredQty.compareTo(BigDecimal.ZERO) <= 0) {
            BigDecimal delegated = delegatedEntitlementQty(materialLineId, supplyActionId);
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
        String detail = "已备 " + covered.stripTrailingZeros().toPlainString()
                + " / " + requiredQty.stripTrailingZeros().toPlainString();
        return new MaterialAnalysisContracts.SupplyProgressStep(
                "STOCKED", "入库齐套", stocked ? DONE : WAITING,
                detail,
                null, null, null);
    }

    /**
     * 末步「入库齐套」（采购链，2026-09-06 修复「未下单却显示已入库」）：
     *
     * <p>整批下达会把行内 required/shortage 一并归零——那是需求转出，不是齐套。
     * 转出行（required&lt;=0）改为沿单据链的实际合格量与仓库入库量判定：
     * 未到货合格 = 未开始、合格未入库 = 进行中、合格且入库 = 完成；
     * 权益已移交自制子件的行动仍以移交为准（原路径无需重复备料）。
     * 需求仍在行内（required&gt;0）时保留缺口权威：缺口归零 = 现货/权益覆盖齐套。</p>
     */
    private MaterialAnalysisContracts.SupplyProgressStep purchaseStockedStep(
            UUID materialLineId, UUID supplyActionId,
            BigDecimal requiredQty, BigDecimal shortageQty,
            BigDecimal qualifiedQty, BigDecimal warehouseStockedQty) {
        if (requiredQty.signum() <= 0) {
            BigDecimal delegated = delegatedEntitlementQty(materialLineId, supplyActionId);
            if (delegated.signum() > 0) {
                return new MaterialAnalysisContracts.SupplyProgressStep(
                        "STOCKED", "入库齐套", DONE,
                        "该供给行动的合格权益已移交自制子件 "
                                + delegated.stripTrailingZeros().toPlainString()
                                + " · 原路径本批无需重复备料",
                        null, null, null);
            }
            if (qualifiedQty.signum() <= 0) {
                return new MaterialAnalysisContracts.SupplyProgressStep(
                        "STOCKED", "入库齐套", WAITING,
                        "本批需求已转出采购，等待到货合格入库", null, null, null);
            }
            if (warehouseStockedQty.signum() <= 0) {
                return new MaterialAnalysisContracts.SupplyProgressStep(
                        "STOCKED", "入库齐套", CURRENT,
                        "品质已合格，等待仓库确认实际库位并入库；确认前不计入可用库存",
                        null, null, null);
            }
            return new MaterialAnalysisContracts.SupplyProgressStep(
                    "STOCKED", "入库齐套", DONE,
                    "已合格入库 " + warehouseStockedQty
                            .stripTrailingZeros().toPlainString(),
                    null, null, null);
        }
        boolean stocked = shortageQty.compareTo(BigDecimal.ZERO) <= 0;
        BigDecimal covered = requiredQty.subtract(shortageQty).max(BigDecimal.ZERO);
        String detail = "已备 " + covered.stripTrailingZeros().toPlainString()
                + " / " + requiredQty.stripTrailingZeros().toPlainString();
        if (warehouseStockedQty.signum() > 0) {
            detail += " · 采购已合格入库 "
                    + warehouseStockedQty.stripTrailingZeros().toPlainString();
        }
        String split = buySplitDetail(supplyActionId);
        if (split != null) detail += " · " + split;
        return new MaterialAnalysisContracts.SupplyProgressStep(
                "STOCKED", "入库齐套", stocked ? DONE : WAITING,
                detail,
                null, null, null);
    }

    private MaterialAnalysisContracts.SupplyProgressStep subcontractStockedStep(
            UUID materialLineId, UUID supplyActionId,
            BigDecimal requiredQty, BigDecimal shortageQty,
            BigDecimal qualifiedReturnedQty,
            BigDecimal warehouseStockedQty) {
        if (requiredQty.signum() <= 0) {
            // 整批转出（2026-09-06 修复）：沿链路实际合格回厂与入库判定，
            // 不再用 shortage 提前判完；权益移交自制子件仍以移交为准。
            BigDecimal delegated = delegatedEntitlementQty(materialLineId, supplyActionId);
            if (delegated.signum() > 0) {
                return new MaterialAnalysisContracts.SupplyProgressStep(
                        "STOCKED", "委外合格供给入库", DONE,
                        "该供给行动的合格权益已移交自制子件 "
                                + delegated.stripTrailingZeros().toPlainString()
                                + " · 原路径本批无需重复备料",
                        null, null, null);
            }
            if (qualifiedReturnedQty.signum() <= 0) {
                return new MaterialAnalysisContracts.SupplyProgressStep(
                        "STOCKED", "委外合格供给入库", WAITING,
                        "本批需求已转出委外，等待回厂合格入库", null, null, null);
            }
            if (warehouseStockedQty.signum() <= 0) {
                return new MaterialAnalysisContracts.SupplyProgressStep(
                        "STOCKED", "委外合格供给入库", CURRENT,
                        "品质已合格，等待仓库确认实际库位并入库；确认前不计入可用库存",
                        null, null, null);
            }
            return new MaterialAnalysisContracts.SupplyProgressStep(
                    "STOCKED", "委外合格供给入库", DONE,
                    "已合格入库 " + warehouseStockedQty
                            .stripTrailingZeros().toPlainString(),
                    null, null, null);
        }
        if (qualifiedReturnedQty.signum() <= 0) {
            return new MaterialAnalysisContracts.SupplyProgressStep(
                    "STOCKED", "委外合格供给入库", WAITING,
                    "等待委外件回厂、IQC 合格后由仓库确认入库", null, null, null);
        }
        if (warehouseStockedQty.signum() <= 0) {
            return new MaterialAnalysisContracts.SupplyProgressStep(
                    "STOCKED", "委外合格供给入库", CURRENT,
                    "品质已合格，等待仓库确认实际库位并入库；确认前不计入可用库存",
                    null, null, null);
        }
        MaterialAnalysisContracts.SupplyProgressStep base =
                stockedStep(materialLineId, supplyActionId, requiredQty, shortageQty);
        return new MaterialAnalysisContracts.SupplyProgressStep(
                base.key(), "委外合格供给入库", base.state(), base.detail(),
                base.docNo(), base.at(), base.operatorName(),
                base.documentType(), base.documentId());
    }

    /** 该供给行动已移交自制子件的合格权益量（ACTIVE 委托态视图）。 */
    private BigDecimal delegatedEntitlementQty(
            UUID materialLineId, UUID supplyActionId) {
        return decimal(em.createNativeQuery("""
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
    }

    private String buySplitDetail(UUID supplyActionId) {
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT progress.demand_requested_qty,
                       progress.demand_qualified_qty,
                       progress.demand_future_qty,
                       progress.safety_requested_qty,
                       progress.safety_qualified_qty,
                       progress.safety_future_qty
                FROM v_preplan_buy_action_slice_progress progress
                WHERE progress.action_id = :actionId
                """).setParameter("actionId", supplyActionId));
        if (rows.isEmpty()) return null;
        Object[] row = rows.getFirst();
        BigDecimal demand = decimal(row[0]);
        BigDecimal demandQualified = decimal(row[1]);
        BigDecimal demandFuture = decimal(row[2]);
        BigDecimal safety = decimal(row[3]);
        BigDecimal safetyQualified = decimal(row[4]);
        BigDecimal safetyFuture = decimal(row[5]);
        if (safety.signum() <= 0) return null;
        return "生产需求绑定 " + demandQualified.stripTrailingZeros().toPlainString()
                + "/" + demand.stripTrailingZeros().toPlainString()
                + "(在途 " + demandFuture.stripTrailingZeros().toPlainString() + ")"
                + "；公共安全补库 "
                + safetyQualified.stripTrailingZeros().toPlainString()
                + "/" + safety.stripTrailingZeros().toPlainString()
                + "(在途 " + safetyFuture.stripTrailingZeros().toPlainString() + ")";
    }

    private static String plain(BigDecimal value) {
        return value.stripTrailingZeros().toPlainString();
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

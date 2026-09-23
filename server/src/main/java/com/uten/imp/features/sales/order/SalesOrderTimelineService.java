package com.uten.imp.features.sales.order;

import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.features.sales.SalesDocumentAccessPolicy;
import com.uten.imp.features.sales.order.dto.OrderProgressTimelineEvent;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.sql.Timestamp;
import java.time.Instant;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.UUID;

import static com.uten.imp.features.sales.order.dto.OrderProgressTimelineEvent.CURRENT;
import static com.uten.imp.features.sales.order.dto.OrderProgressTimelineEvent.DONE;
import static com.uten.imp.features.sales.order.dto.OrderProgressTimelineEvent.PENDING;
import static com.uten.imp.features.sales.order.dto.OrderProgressTimelineEvent.REJECTED;

/**
 * 销售订单全链路进度时间线（快递式追踪）：下单 → 销售审核 → 财务审核 → 物料分析 →
 * 物料准备（采购/委外下单、财务审批）→ 生产计划 → 生产 → 发货 → 结案。
 *
 * <p>每一环都尽量带「责任人 + 发生时间」：制单/审核/确认人取单据自身 *_by 列（员工经
 * {@link EmployeeNameResolver#nameOf} 解析为实际姓名，兼容 users.id 历史数据)；审核/红冲/驳回的时间点读单据
 * 自身的 approved_at / reversed_at / rejected_at 列(V672 起由命令写入，ADR-105 规定业务逻辑不读审计日志)。
 *
 * <p>展示顺序（服务端排好，前端直接渲染）：已发生事件（DONE/CURRENT/REJECTED）按发生时间倒序、
 * 无时间的当前阶段置顶；PENDING 占位按业务顺序垫底。只读接口，归属校验与 detail 同口径。
 */
@Service
@RequiredArgsConstructor
public class SalesOrderTimelineService {

    private final SalesOrderRepository orderRepo;
    private final SalesDocumentAccessPolicy accessPolicy;
    private final EmployeeNameResolver nameResolver;
    private final EntityManager em;

    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('sales_order:view')")
    public List<OrderProgressTimelineEvent> timeline(UUID orderId) {
        SalesOrder order = orderRepo.findById(orderId)
                .filter(o -> !o.isDeleted())
                .orElseThrow(() -> new com.uten.imp.common.web.ApiException(
                        com.uten.imp.common.web.ErrorCode.NOT_FOUND, "销售订货单不存在"));
        accessPolicy.requireReadable(order.getOwnerEmployeeId(), "销售订货单不存在");

        List<OrderProgressTimelineEvent> events = new ArrayList<>();
        addOrderEvents(order, events);
        addFinanceEvents(order, events);
        List<UUID> analysisIds = addMaterialAnalysisEvents(orderId, order, events);
        boolean hasSupplyDocs = addSupplyEvents(analysisIds, events);
        boolean hasPlans = addProductionPlanEvents(orderId, events);
        addProductionProgressEvent(orderId, hasPlans, events);
        addShipmentEvents(orderId, events);
        addClosureEvents(order, events, hasSupplyDocs, analysisIds);

        events.sort(TIMELINE_ORDER);
        return events;
    }

    /** 展示排序：已发生事件按时间倒序（无时间的当前阶段置顶），PENDING 占位按业务顺序垫底。 */
    private static final Comparator<OrderProgressTimelineEvent> TIMELINE_ORDER = (a, b) -> {
        boolean aPending = PENDING.equals(a.state());
        boolean bPending = PENDING.equals(b.state());
        if (aPending != bPending) return aPending ? 1 : -1;
        if (aPending) return Integer.compare(a.seq(), b.seq());
        OffsetDateTime at = a.occurredAt();
        OffsetDateTime bt = b.occurredAt();
        if (at == null && bt == null) return Integer.compare(b.seq(), a.seq());
        if (at == null) return -1; // 无时间的当前阶段排最上
        if (bt == null) return 1;
        int byTime = bt.compareTo(at); // 最新在前
        return byTime != 0 ? byTime : Integer.compare(b.seq(), a.seq());
    };

    // ============================ 下单 / 销售审核 ============================

    private void addOrderEvents(SalesOrder order, List<OrderProgressTimelineEvent> events) {
        events.add(new OrderProgressTimelineEvent(
                10, "ORDER_PLACED", "销售下单", "下单人",
                employeeDisplayName(order.getMakerId()), toTime(order.getCreatedAt()), DONE,
                "订单 " + order.getBillNo() + " 已创建", null, null, order.getBillNo()));

        if (order.getStatus() == 1) {
            events.add(new OrderProgressTimelineEvent(
                    20, "ORDER_APPROVED", "销售审核", "审核人",
                    employeeDisplayName(order.getApproverId()),
                    toTime(order.getApprovedAt()), DONE,
                    null, null, null, null));
        } else if (order.getStatus() == -1) {
            events.add(new OrderProgressTimelineEvent(
                    25, "ORDER_REVERSED", "订单红冲", "操作人",
                    employeeDisplayName(order.getReversedBy()),
                    toTime(order.getReversedAt()), REJECTED,
                    "订单已红冲作废", null, null, null));
        } else {
            events.add(new OrderProgressTimelineEvent(
                    20, "ORDER_APPROVED", "销售审核", null, null, null, CURRENT,
                    "草稿待审核", null, null, null));
        }
    }

    // ============================ 财务审核 ============================

    private void addFinanceEvents(SalesOrder order, List<OrderProgressTimelineEvent> events) {
        boolean hasRejectionHistory = order.getFinanceRejectedAt() != null;
        if (hasRejectionHistory) {
            events.add(new OrderProgressTimelineEvent(
                    35, "FINANCE_REJECTED", "财务驳回", "审核人",
                    employeeDisplayName(order.getFinanceRejectedBy()),
                    order.getFinanceRejectedAt(), REJECTED,
                    order.getFinanceRejectedReason(), null, null, null));
        }
        if (order.isFinanceConfirmed()) {
            events.add(new OrderProgressTimelineEvent(
                    30, "FINANCE_CONFIRMED", "财务审核通过", "审核人",
                    employeeDisplayName(order.getFinanceConfirmedBy()),
                    order.getFinanceConfirmedAt(), DONE,
                    order.getFinanceConfirmRemark(), null, null, null));
            return;
        }
        if (order.getStatus() == 1) {
            events.add(new OrderProgressTimelineEvent(
                    30, "FINANCE_CONFIRMED", "财务审核", null, null, null,
                    order.isFinanceRejected() ? REJECTED : CURRENT,
                    order.isFinanceRejected()
                            ? "已被驳回，待销售修订并重新审核"
                            : hasRejectionHistory
                                    ? "销售已修订并重新审核，等待财务确认"
                                    : "等待财务审核组确认",
                    null, null, null));
        } else if (order.getStatus() == 0) {
            events.add(new OrderProgressTimelineEvent(
                    30, "FINANCE_CONFIRMED", "财务审核", null, null, null,
                    order.isFinanceRejected() ? CURRENT : PENDING,
                    order.isFinanceRejected()
                            ? "财务已驳回，等待销售完成修订并重新审核"
                            : "销售审核通过后由财务确认",
                    null, null, null));
        }
    }

    // ============================ 物料分析 ============================

    /** 返回该订单关联的物料分析 id 列表（供备料事件查询复用）。 */
    private List<UUID> addMaterialAnalysisEvents(
            UUID orderId, SalesOrder order, List<OrderProgressTimelineEvent> events) {
        List<Object[]> rows = objectRows(em.createNativeQuery("""
                SELECT DISTINCT a.id, a.status, a.analyzed_at, a.maker_id
                FROM production_material_analyses a
                JOIN production_material_analysis_items ai ON ai.analysis_id = a.id
                JOIN sales_order_items i ON i.id = ai.sales_order_item_id
                WHERE i.order_id = :oid
                  AND i.is_deleted = FALSE
                  AND ai.is_deleted = FALSE
                  AND a.is_deleted = FALSE
                ORDER BY a.analyzed_at
                """).setParameter("oid", orderId));
        List<UUID> analysisIds = rows.stream().map(r -> (UUID) r[0]).toList();

        if (rows.isEmpty()) {
            if (order.isFinanceConfirmed()) {
                events.add(new OrderProgressTimelineEvent(
                        40, "MATERIAL_ANALYSIS", "计划单物料分析", null, null, null, CURRENT,
                        "等待计划部执行物料分析", null, null, null));
            } else {
                events.add(new OrderProgressTimelineEvent(
                        40, "MATERIAL_ANALYSIS", "计划单物料分析", null, null, null, PENDING,
                        "财务审核通过后进入物料分析", null, null, null));
            }
            return analysisIds;
        }
        for (Object[] row : rows) {
            String status = (String) row[1];
            events.add(new OrderProgressTimelineEvent(
                    40, "MATERIAL_ANALYSIS", "计划单物料分析", "执行人",
                    employeeDisplayName((UUID) row[3]), toTime(row[2]), DONE,
                    "分析状态 " + analysisStatusLabel(status),
                    "MATERIAL_ANALYSIS", (UUID) row[0], null));
        }
        return analysisIds;
    }

    static String analysisStatusLabel(String status) {
        if (status == null || status.isBlank()) return "—";
        return switch (status.trim().toUpperCase(Locale.ROOT)) {
            case "ACTIVE" -> "进行中";
            case "PARTIALLY_PLANNED" -> "部分已下达，剩余待料";
            case "COMPLETED" -> "已全部下达";
            case "CANCELLED" -> "已取消";
            case "READY" -> "已齐套";
            case "CONFIRMED" -> "已确认";
            case "STALE" -> "已过期待刷新";
            default -> "状态待确认";
        };
    }

    // ============================ 物料准备（采购 / 委外） ============================

    /** @return 是否已存在采购/委外订货单。 */
    private boolean addSupplyEvents(List<UUID> analysisIds, List<OrderProgressTimelineEvent> events) {
        if (analysisIds.isEmpty()) return false;
        boolean found = false;
        found |= addSupplyOrderEvents(analysisIds, true, events);
        found |= addSupplyOrderEvents(analysisIds, false, events);
        if (!found) {
            events.add(new OrderProgressTimelineEvent(
                    50, "SUPPLY_ORDER", "物料准备-采购/委外下单", null, null, null, PENDING,
                    "物料分析缺口待采购/委外在任务中心下单", null, null, null));
        }
        return found;
    }

    /** purchase=true 走采购链（sources.request_item_id），false 走委外链（sources.application_item_id）。 */
    private boolean addSupplyOrderEvents(
            List<UUID> analysisIds, boolean purchase, List<OrderProgressTimelineEvent> events) {
        String routeLabel = purchase ? "采购" : "委外";
        // V463：订货行多来源锚定——按来源分配行展开（同货品合并行对每个来源申请行可见）。
        String orderItemJoin = purchase
                ? """
                  JOIN purchase_order_item_sources pis
                    ON pis.request_item_id = al.external_item_id
                  JOIN purchase_order_items oi
                    ON oi.id = pis.order_item_id
                   AND oi.is_deleted = FALSE
                  """
                : """
                  JOIN subcontract_order_item_sources sis
                    ON sis.application_item_id = al.external_item_id
                  JOIN subcontract_order_items oi
                    ON oi.id = sis.order_item_id
                   AND oi.is_deleted = FALSE
                  """;
        String orderTable = purchase ? "purchase_orders" : "subcontract_orders";
        List<Object[]> rows = objectRows(em.createNativeQuery("""
                SELECT DISTINCT ord.id, ord.bill_no, ord.status, ord.created_at, ord.maker_id
                FROM preplan_supply_action_allocations al
                JOIN preplan_supply_actions a ON a.id = al.action_id
                %s
                JOIN %s ord ON ord.id = oi.order_id
                WHERE a.analysis_id IN (:analysisIds)
                  AND a.status <> 'CANCELLED'
                  AND oi.is_deleted = FALSE
                  AND ord.is_deleted = FALSE
                ORDER BY ord.created_at
                """.formatted(orderItemJoin, orderTable))
                .setParameter("analysisIds", analysisIds));
        if (rows.isEmpty()) return false;

        Map<UUID, Object[]> latestCaseByOrder = latestApprovalCases(
                purchase ? "PURCHASE" : "SUBCONTRACT",
                rows.stream().map(r -> (UUID) r[0]).toList());
        int seq = purchase ? 51 : 52;
        for (Object[] row : rows) {
            UUID docId = (UUID) row[0];
            int status = ((Number) row[2]).intValue();
            Object[] approval = latestCaseByOrder.get(docId);
            String state;
            String detail;
            if (status == -1) {
                state = REJECTED;
                detail = "订货单已红冲";
            } else if (approval != null && "REJECTED".equals(approval[1])) {
                state = REJECTED;
                detail = "财务审批驳回"
                        + (approval[4] == null ? "" : "：" + approval[4]);
            } else if (status == 1) {
                state = DONE;
                String approver = approval == null
                        ? null : employeeDisplayName((UUID) approval[3]);
                detail = approver == null ? "财务审批通过" : "财务审批通过(审批人：" + approver + ")";
            } else {
                state = CURRENT;
                detail = approval != null && "PENDING".equals(approval[1])
                        ? "财务审批中" : "待提交财务审批";
            }
            events.add(new OrderProgressTimelineEvent(
                    seq, purchase ? "PURCHASE_ORDER" : "SUBCONTRACT_ORDER",
                    "物料准备-" + routeLabel + "订货", routeLabel + "人",
                    employeeDisplayName((UUID) row[4]), toTime(row[3]), state, detail,
                    purchase ? "PURCHASE_ORDER" : "SUBCONTRACT_ORDER", docId, (String) row[1]));
        }
        return true;
    }

    /** 每单最新一版审批案件（attempt 最大者）。 */
    private Map<UUID, Object[]> latestApprovalCases(String orderType, List<UUID> orderIds) {
        if (orderIds.isEmpty()) return Map.of();
        List<Object[]> rows = objectRows(em.createNativeQuery("""
                SELECT c.order_id, c.status, c.decided_at, c.decided_by_employee_id,
                       c.rejection_reason
                FROM procurement_order_approval_cases c
                WHERE c.order_type = :orderType AND c.order_id IN (:orderIds)
                ORDER BY c.order_id, c.attempt DESC
                """)
                .setParameter("orderType", orderType)
                .setParameter("orderIds", orderIds));
        Map<UUID, Object[]> latest = new HashMap<>();
        for (Object[] row : rows) {
            latest.putIfAbsent((UUID) row[0], row);
        }
        return latest;
    }

    // ============================ 生产计划 / 生产进度 ============================

    /** @return 是否存在关联生产计划。 */
    private boolean addProductionPlanEvents(UUID orderId, List<OrderProgressTimelineEvent> events) {
        List<Object[]> rows = objectRows(em.createNativeQuery("""
                SELECT DISTINCT p.id, p.bill_no, p.status, p.is_closed,
                       p.created_at, p.maker_id, p.approver_id, p.approved_at
                FROM production_plans p
                WHERE p.is_deleted = FALSE AND (
                    p.id IN (
                        SELECT pi.plan_id
                        FROM production_plan_items pi
                        JOIN plan_order_item_links l ON l.plan_item_id = pi.id
                        JOIN sales_order_items i ON i.id = l.order_item_id
                        WHERE i.order_id = :oid
                          AND l.is_deleted = FALSE
                          AND i.is_deleted = FALSE)
                    OR p.id IN (
                        SELECT link.plan_id
                        FROM production_material_analysis_plan_links link
                        JOIN production_material_analysis_items ai
                          ON ai.id = link.analysis_item_id AND ai.analysis_id = link.analysis_id
                        JOIN sales_order_items i2 ON i2.id = ai.sales_order_item_id
                        WHERE i2.order_id = :oid
                          AND ai.is_deleted = FALSE))
                ORDER BY p.created_at
                """).setParameter("oid", orderId));
        for (Object[] row : rows) {
            UUID planId = (UUID) row[0];
            int status = ((Number) row[2]).intValue();
            boolean closed = Boolean.TRUE.equals(row[3]);
            String state;
            String detail;
            OffsetDateTime at = toTime(row[4]);
            if (status == -1) {
                state = REJECTED;
                detail = "计划已红冲";
            } else if (status == 1) {
                state = DONE;
                String approver = employeeDisplayName((UUID) row[6]);
                OffsetDateTime approvedAt = toTime(row[7]);
                if (approvedAt != null) at = approvedAt;
                detail = (approver == null ? "已审核下达" : "已审核下达(审核人：" + approver + ")")
                        + (closed ? " · 已结案" : "");
            } else {
                state = CURRENT;
                detail = "计划草稿/待批准下达";
            }
            events.add(new OrderProgressTimelineEvent(
                    60, "PRODUCTION_PLAN", "生产计划下达", "下达人",
                    employeeDisplayName((UUID) row[5]), at, state, detail,
                    "PRODUCTION_PLAN", planId, (String) row[1]));
        }
        return !rows.isEmpty();
    }

    /** 生产进度聚合（已产/订货）：有计划才给占位，避免噪声。 */
    private void addProductionProgressEvent(
            UUID orderId, boolean hasPlans, List<OrderProgressTimelineEvent> events) {
        List<Object[]> rows = objectRows(em.createNativeQuery("""
                SELECT COALESCE(SUM(i.qty), 0), COALESCE(SUM(i.produced_qty), 0)
                FROM sales_order_items i
                WHERE i.order_id = :oid AND i.is_deleted = FALSE
                """).setParameter("oid", orderId));
        if (rows.isEmpty()) return;
        BigDecimal orderQty = decimal(rows.getFirst()[0]);
        BigDecimal produced = decimal(rows.getFirst()[1]);
        String detail = "已产 " + produced.stripTrailingZeros().toPlainString()
                + " / 订货 " + orderQty.stripTrailingZeros().toPlainString();
        if (produced.signum() > 0) {
            boolean finished = produced.compareTo(orderQty) >= 0 && orderQty.signum() > 0;
            events.add(new OrderProgressTimelineEvent(
                    70, "PRODUCTION_PROGRESS", finished ? "生产完工" : "生产中",
                    null, null, null, finished ? DONE : CURRENT, detail, null, null, null));
        } else if (hasPlans) {
            events.add(new OrderProgressTimelineEvent(
                    70, "PRODUCTION_PROGRESS", "生产开工", null, null, null, PENDING,
                    detail, null, null, null));
        }
    }

    // ============================ 发货 ============================

    /**
     * 发货链（V631 起按出货单真实阶段拆成多环）：销售开出货单 → 等待财务审核出货 / 财务放行出货
     * → 等仓库出货 → 仓库已发货；财务退回、仓库驳回、红冲各是一条 REJECTED 环。
     * 一张订单可能有多张出货单，每张各自一串，单号可点跳出货详情。
     */
    private void addShipmentEvents(UUID orderId, List<OrderProgressTimelineEvent> events) {
        List<Object[]> rows = objectRows(em.createNativeQuery("""
                SELECT s.id, s.bill_no, s.status, s.created_at, s.maker_id, s.approver_id,
                       s.logistics_no, s.handed_over_at, s.finance_audit, s.finance_rejected,
                       s.finance_rejection_reason, s.finance_auditor_id, s.finance_audited_at,
                       s.handed_over_by, s.rejected,
                       (COALESCE(s.finance_gate_version, 0) < 2
                        OR (s.sales_confirmed_at IS NOT NULL
                            AND s.sales_confirmed_revision = s.review_revision)) AS sales_confirmed,
                       s.approved_at, s.reversed_at, s.reversed_by, s.rejected_at, s.rejected_by
                FROM sales_shipments s
                WHERE s.source_order_id = :oid
                  AND COALESCE(s.is_deleted, FALSE) = FALSE
                ORDER BY s.created_at
                """).setParameter("oid", orderId));
        for (Object[] row : rows) {
            UUID shipmentId = (UUID) row[0];
            String billNo = (String) row[1];
            int status = ((Number) row[2]).intValue();
            OffsetDateTime createdAt = toTime(row[3]);
            String maker = employeeDisplayName((UUID) row[4]);
            String approver = employeeDisplayName((UUID) row[5]);
            String logistics = (String) row[6];
            boolean financeAudited = row[8] != null && ((Number) row[8]).intValue() == 1;
            boolean financeRejected = Boolean.TRUE.equals(row[9]);
            String rejectionReason = (String) row[10];
            String auditor = employeeDisplayName((UUID) row[11]);
            OffsetDateTime auditedAt = toTime(row[12]);
            String handedOverBy = employeeDisplayName((UUID) row[13]);
            boolean warehouseRejected = Boolean.TRUE.equals(row[14]);
            boolean salesConfirmed = Boolean.TRUE.equals(row[15]);

            events.add(shipmentEvent(80, "SHIPMENT_CREATED", "销售开出货单", "发货人", maker,
                    createdAt, DONE, "出货单 " + billNo + " 已开出", shipmentId, billNo));
            if (status == -1) {
                events.add(shipmentEvent(86, "SHIPMENT_REVERSED", "出货单红冲", "操作人",
                        employeeDisplayName((UUID) row[18]), toTime(row[17]), REJECTED,
                        "出货单已红冲，库存与应收已冲回", shipmentId, billNo));
                continue;
            }
            if (status == 1) {
                if (financeAudited) {
                    events.add(shipmentEvent(82, "SHIPMENT_FINANCE_RELEASED", "财务放行出货", "审核人",
                            auditor, auditedAt, DONE, null, shipmentId, billNo));
                }
                OffsetDateTime shippedAt = toTime(row[16]);
                if (shippedAt == null) shippedAt = row[7] != null ? toTime(row[7]) : createdAt;
                String detail = "库存、已发数量与应收已过账";
                if (logistics != null && !logistics.isBlank()) detail += " · 物流单号 " + logistics;
                events.add(shipmentEvent(84, "SHIPMENT_SHIPPED", "仓库已发货", "出库人",
                        handedOverBy != null ? handedOverBy : approver, shippedAt, DONE, detail,
                        shipmentId, billNo));
                continue;
            }
            if (warehouseRejected) {
                events.add(shipmentEvent(82, "SHIPMENT_WAREHOUSE_REJECTED", "出货单已驳回", "驳回人",
                        employeeDisplayName((UUID) row[20]), toTime(row[19]), REJECTED,
                        "仓库驳回：预留已释放，请重新开单", shipmentId, billNo));
            } else if (financeRejected) {
                events.add(shipmentEvent(82, "SHIPMENT_FINANCE_REJECTED", "财务退回出货单", null, null,
                        null, REJECTED,
                        rejectionReason == null || rejectionReason.isBlank()
                                ? "请销售修改后重新提交财务审核"
                                : "退回原因：" + rejectionReason,
                        shipmentId, billNo));
            } else if (financeAudited) {
                events.add(shipmentEvent(82, "SHIPMENT_FINANCE_RELEASED", "财务放行出货", "审核人",
                        auditor, auditedAt, DONE, null, shipmentId, billNo));
                events.add(shipmentEvent(84, "SHIPMENT_WAREHOUSE_PENDING", "等仓库出货", null, null,
                        null, CURRENT, "仓库确认出库后才扣库存、立应收", shipmentId, billNo));
            } else if (salesConfirmed) {
                events.add(shipmentEvent(82, "SHIPMENT_FINANCE_PENDING", "等待财务审核出货", null, null,
                        null, CURRENT, "出货单已提交财务，放行后仓库才能出库", shipmentId, billNo));
            } else {
                events.add(shipmentEvent(82, "SHIPMENT_DRAFT", "出货草稿待销售确认", null, null,
                        null, CURRENT, "销售确认并提交财务后进入财审", shipmentId, billNo));
            }
        }
    }

    private static OrderProgressTimelineEvent shipmentEvent(
            int seq, String code, String title, String operatorLabel, String operatorName,
            OffsetDateTime at, String state, String detail, UUID shipmentId, String billNo) {
        return new OrderProgressTimelineEvent(seq, code, title, operatorLabel, operatorName, at,
                state, detail, "SALES_SHIPMENT", shipmentId, billNo);
    }

    // ============================ 结案 / 中止 ============================

    private void addClosureEvents(SalesOrder order, List<OrderProgressTimelineEvent> events,
                                  boolean hasSupplyDocs, List<UUID> analysisIds) {
        if (order.isStopped()) {
            events.add(new OrderProgressTimelineEvent(
                    90, "ORDER_STOPPED", "订单中止", null, null, null, REJECTED,
                    "订单已人工中止", null, null, null));
        }
        if (order.isClosed()) {
            events.add(new OrderProgressTimelineEvent(
                    95, "ORDER_CLOSED", "订单结案", null, null, null, DONE,
                    "全部明细已发货结案", null, null, null));
        }
    }

    // ============================ 工具 ============================

    String employeeDisplayName(UUID employeeId) {
        return nameResolver.nameOf(employeeId);
    }

    @SuppressWarnings("unchecked")
    private static List<Object[]> objectRows(jakarta.persistence.Query query) {
        return (List<Object[]>) query.getResultList();
    }

    private static BigDecimal decimal(Object value) {
        return value == null ? BigDecimal.ZERO : new BigDecimal(value.toString());
    }

    private static OffsetDateTime toTime(Object value) {
        if (value == null) return null;
        if (value instanceof OffsetDateTime dateTime) {
            return dateTime.withOffsetSameInstant(ZoneOffset.UTC);
        }
        if (value instanceof Instant instant) return instant.atOffset(ZoneOffset.UTC);
        if (value instanceof Timestamp timestamp) {
            return timestamp.toInstant().atOffset(ZoneOffset.UTC);
        }
        return null;
    }
}

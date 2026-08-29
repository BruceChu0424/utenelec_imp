package com.uten.imp.features.notice;

import com.fasterxml.jackson.databind.JsonNode;
import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.application.port.FinanceReviewerEligibilityPort;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.features.admin.workflow.SalesOrderFinanceConfirmerEligibility;
import com.uten.imp.features.auth.PermissionResolver;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.features.rbac.UserRoleRepository;
import com.uten.imp.features.rd_task.RdTaskService;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;

import java.math.BigDecimal;
import java.time.Instant;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.time.format.DateTimeFormatter;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

/**
 * 业务链自动通知（SOP §一 8 类：排产/完工/部分完工/数量不足补产/发货/驳回/延期预警/取消确认/缺料）。
 *
 * <p><b>可靠旁路原则</b>：业务事务只向 {@code business_outbox} 追加事件；后台处理器
 * 以 {@code FOR UPDATE SKIP LOCKED} 认领，并在同一事务中生成全部站内通知和送达标记。
 * 任一接收人失败会整体回滚并指数退避重试，因此不会出现主单回滚后误发或部分通知永久丢失。
 *
 * <p>接收人解析：订单归属销售（owner_employee_id，回退 seller_id）→ 员工账号；
 * 采购/调度按角色码（buyer/planner）广播。业务 Service 只传单据 ID，内容在此统一按 ID 自查组装。
 *
 * <p>每条定向业务通知都带 actionRoute（站内「查看详情」直达源单据/任务页）：归属销售类跳源单据
 * 详情，调度/仓库/财务类跳各自任务中心。route 由各 notify* 方法硬编码（非用户输入），仅做基本
 * sanity check（见 {@link NoticeService#publishForUser} 6 参重载）。
 */
@Service
public class ChainNoticeService {

    /** 合法类型见 NoticeService.TYPES；此处固定用到的子集。 */
    public static final String TYPE_WORKFLOW = "workflow";
    public static final String TYPE_TASK = "task";
    public static final String TYPE_URGENT = "urgent";
    public static final String TYPE_APPROVAL = "approval";

    private static final String PUBLISHER = "系统";
    static final String EVENT_PLAN_SCHEDULED = "PRODUCTION_PLAN_SCHEDULED";
    static final String EVENT_PRODUCTION_REPORTED = "PRODUCTION_REPORTED";
    static final String EVENT_FINISHED_INBOUND = "PRODUCTION_FINISHED_INBOUND";
    static final String EVENT_FINISHED_INBOUND_PENDING =
            "PRODUCTION_FINISHED_INBOUND_PENDING";
    static final String EVENT_FINISHED_INBOUND_REJECTED =
            "PRODUCTION_FINISHED_INBOUND_REJECTED";
    static final String EVENT_FINISHED_INBOUND_REVERSED =
            "PRODUCTION_FINISHED_INBOUND_REVERSED";
    static final String EVENT_PRODUCTION_DRAW_PENDING =
            "PRODUCTION_DRAW_PENDING";
    static final String EVENT_PRODUCTION_FQC_PENDING =
            "PRODUCTION_FQC_PENDING";
    static final String EVENT_PRODUCTION_FQC_RELEASED =
            "PRODUCTION_FQC_RELEASED";
    static final String EVENT_PRODUCTION_FQC_RESOLVED =
            "PRODUCTION_FQC_RESOLVED";
    static final String EVENT_PRODUCTION_DRAW_ISSUED =
            "PRODUCTION_DRAW_ISSUED";
    static final String EVENT_PRODUCTION_DRAW_ISSUE_REVERSED =
            "PRODUCTION_DRAW_ISSUE_REVERSED";
    static final String EVENT_REMAKE_CREATED = "PRODUCTION_REMAKE_CREATED";
    static final String EVENT_SEGMENT_READY = "PRODUCTION_SEGMENT_READY";
    static final String EVENT_SEGMENT_DISPATCHED = "PRODUCTION_SEGMENT_DISPATCHED";
    static final String EVENT_SEGMENT_STARTED = "PRODUCTION_SEGMENT_STARTED";
    static final String EVENT_SHIPMENT_APPROVED = "SALES_SHIPMENT_APPROVED";
    static final String EVENT_SHIPMENT_PENDING_PICK =
            "SALES_SHIPMENT_PENDING_PICK";
    static final String EVENT_SHIPMENT_REJECTED = "SALES_SHIPMENT_REJECTED";
    static final String EVENT_PREPLAN_SUPPLY_ACTION_CREATED =
            "PREPLAN_SUPPLY_ACTION_CREATED";
    static final String EVENT_MATERIAL_ANALYSIS_READY =
            "PRODUCTION_MATERIAL_ANALYSIS_READY";
    static final String EVENT_ORDER_CANCELED = "SALES_ORDER_CANCELED";
    static final String EVENT_ORDER_APPROVED = "SALES_ORDER_APPROVED";
    static final String EVENT_ORDER_PENDING_FINANCE =
            "SALES_ORDER_PENDING_FINANCE_CONFIRM";
    static final String EVENT_ORDER_FINANCE_CONFIRMED =
            "SALES_ORDER_FINANCE_CONFIRMED";
    static final String EVENT_ORDER_FINANCE_REJECTED =
            "SALES_ORDER_FINANCE_REJECTED";
    static final String EVENT_DELIVERY_DUE = "SALES_DELIVERY_DUE";
    static final String EVENT_RESERVATION_HOLD_OVERDUE = "SALES_RESERVATION_HOLD_OVERDUE";
    static final String EVENT_RESERVATION_YIELDED = "SALES_RESERVATION_YIELDED";
    static final String EVENT_PROCUREMENT_FINANCE_SUBMITTED =
            "PROCUREMENT_FINANCE_SUBMITTED";
    static final String EVENT_PROCUREMENT_FINANCE_APPROVED =
            "PROCUREMENT_FINANCE_APPROVED";
    static final String EVENT_PROCUREMENT_FINANCE_REJECTED =
            "PROCUREMENT_FINANCE_REJECTED";
    static final String EVENT_PROCUREMENT_ARRIVAL_DETECTED =
            "PROCUREMENT_ARRIVAL_EXCEPTION_DETECTED";
    static final String EVENT_PROCUREMENT_ARRIVAL_DECIDED =
            "PROCUREMENT_ARRIVAL_EXCEPTION_DECIDED";
    static final String EVENT_PROCUREMENT_RETURN_REQUIRED =
            "PROCUREMENT_SUPPLIER_RETURN_REQUIRED";
    static final String EVENT_PROCUREMENT_RETURN_COMPLETED =
            "PROCUREMENT_SUPPLIER_RETURN_COMPLETED";
    static final String EVENT_PROCUREMENT_ARRIVAL_RECEIPT_POSTED =
            "PROCUREMENT_ARRIVAL_RECEIPT_POSTED";
    static final String EVENT_BOM_UPDATED = "GOODS_BOM_UPDATED";
    static final String EVENT_RD_TASK_RESOLVED = "RD_TASK_RESOLVED";
    static final String EVENT_IQC_PENDING = "PROCUREMENT_IQC_PENDING";
    static final String EVENT_IQC_RESOLVED = "PROCUREMENT_IQC_RESOLVED";
    private static final String IQC_VIEW_AUTHORITY = "procurement_inspection:view";
    private static final String NOTICE_READ_AUTHORITY = "notice:read";
    private static final String PURCHASE_REQUEST_VIEW_AUTHORITY = "purchase_request:view";
    private static final String SUBCONTRACT_APPLICATION_VIEW_AUTHORITY =
            "subcontract_application:view";
    private static final ThreadLocal<Boolean> OUTBOX_DELIVERY =
            ThreadLocal.withInitial(() -> false);
    /** 当前锁定 Outbox 事件；用于给未显式传 sourceEvent 的通知补齐可靠事件来源。 */
    private static final ThreadLocal<String> OUTBOX_EVENT = new ThreadLocal<>();
    private static final DateTimeFormatter EVENT_TIME_FORMAT =
            DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm");


    private final NoticeService noticeService;
    private final UserAccountRepository userRepo;
    private final PermissionResolver permissionResolver;
    private final UserRoleRepository userRoleRepo;
    private final JdbcTemplate jdbc;
    private final BusinessEventPublisher outbox;
    private final RdTaskService rdTaskService;
    private final FinanceReviewerEligibilityPort financeReviewerEligibility;
    private final SalesOrderFinanceConfirmerEligibility salesOrderFinanceConfirmers;

    public ChainNoticeService(NoticeService noticeService,
                              UserAccountRepository userRepo,
                              PermissionResolver permissionResolver,
                              UserRoleRepository userRoleRepo,
                              JdbcTemplate jdbc,
                              BusinessEventPublisher outbox,
                              RdTaskService rdTaskService,
                              FinanceReviewerEligibilityPort financeReviewerEligibility,
                              SalesOrderFinanceConfirmerEligibility salesOrderFinanceConfirmers) {
        this.noticeService = noticeService;
        this.userRepo = userRepo;
        this.permissionResolver = permissionResolver;
        this.userRoleRepo = userRoleRepo;
        this.jdbc = jdbc;
        this.outbox = outbox;
        this.rdTaskService = rdTaskService;
        this.financeReviewerEligibility = financeReviewerEligibility;
        this.salesOrderFinanceConfirmers = salesOrderFinanceConfirmers;
    }

    /** Called only by the locked outbox processor inside its delivery transaction. */
    public void deliverOutboxEvent(String eventType, UUID aggregateId, JsonNode payload) {
        OUTBOX_DELIVERY.set(true);
        OUTBOX_EVENT.set(eventType);
        try {
            switch (eventType) {
                case EVENT_PLAN_SCHEDULED ->
                        notifyPlanScheduled(aggregateId, payload.path("shortage").asBoolean(false));
                case EVENT_PRODUCTION_REPORTED ->
                        notifyProductionReported(aggregateId);
                case EVENT_FINISHED_INBOUND ->
                        deliverFinishedInbound(aggregateId, payload);
                case EVENT_FINISHED_INBOUND_PENDING ->
                        notifyFinishedInboundPending(aggregateId);
                case EVENT_FINISHED_INBOUND_REJECTED ->
                        notifyFinishedInboundRejected(
                                aggregateId,
                                payload.path("reason").asText(""),
                                null);
                case EVENT_FINISHED_INBOUND_REVERSED ->
                        notifyFinishedInboundReversed(aggregateId, null);
                case EVENT_PRODUCTION_DRAW_PENDING ->
                        notifyProductionDrawPending(aggregateId);
                case EVENT_PRODUCTION_DRAW_ISSUED ->
                        notifyProductionDrawIssued(aggregateId, null);
                case EVENT_PRODUCTION_DRAW_ISSUE_REVERSED ->
                        notifyProductionDrawIssueReversed(aggregateId, null);
                case EVENT_PRODUCTION_FQC_PENDING,
                     EVENT_PRODUCTION_FQC_RELEASED,
                     EVENT_PRODUCTION_FQC_RESOLVED -> {
                    // FQC and warehouse queues are authoritative database
                    // projections. These durable events intentionally require
                    // no notice row to make the task discoverable.
                }
                case EVENT_REMAKE_CREATED ->
                        notifyRemakeCreated(aggregateId);
                case EVENT_SEGMENT_READY ->
                        notifyExecutionSegmentReady(
                                aggregateId,
                                null,
                                payload.path("sourceType").asText(""));
                case EVENT_SEGMENT_DISPATCHED ->
                        notifyExecutionSegmentTransition(aggregateId, false);
                case EVENT_SEGMENT_STARTED ->
                        notifyExecutionSegmentTransition(aggregateId, true);
                case EVENT_SHIPMENT_APPROVED -> notifyShipmentApproved(aggregateId);
                case EVENT_SHIPMENT_PENDING_PICK ->
                        notifyShipmentPendingPick(aggregateId);
                case EVENT_SHIPMENT_REJECTED ->
                        notifyShipmentRejected(aggregateId, payload.path("reason").asText(""));
                case EVENT_PREPLAN_SUPPLY_ACTION_CREATED ->
                        notifyPreplanSupplyActionCreated(aggregateId);
                case EVENT_MATERIAL_ANALYSIS_READY ->
                        deliverMaterialAnalysisReady(aggregateId, payload);
                case EVENT_ORDER_CANCELED -> notifyOrderCanceled(aggregateId);
                case EVENT_ORDER_APPROVED -> notifyOrderApproved(aggregateId);
                case EVENT_ORDER_PENDING_FINANCE ->
                        notifyOrderPendingFinanceConfirmation(aggregateId);
                case EVENT_ORDER_FINANCE_CONFIRMED ->
                        notifyOrderFinanceConfirmed(aggregateId);
                case EVENT_ORDER_FINANCE_REJECTED ->
                        notifyOrderFinanceRejected(aggregateId, payload.path("reason").asText(""));
                case EVENT_DELIVERY_DUE -> {
                    long daysLeft = payload.path("daysLeft").asLong();
                    if (payload.path("daily").asBoolean(false)) {
                        notifyDeliveryDueIfNotSentToday(aggregateId, daysLeft);
                    } else {
                        notifyDeliveryDue(aggregateId, daysLeft);
                    }
                }
                case EVENT_RESERVATION_HOLD_OVERDUE -> {
                    long overdueDays = payload.path("overdueDays").asLong();
                    if (payload.path("daily").asBoolean(false)) {
                        notifyReservationHoldOverdueIfNotSentToday(aggregateId, overdueDays);
                    } else {
                        notifyReservationHoldOverdue(aggregateId, overdueDays);
                    }
                }
                case EVENT_RESERVATION_YIELDED ->
                        notifyReservationYielded(aggregateId, payload.path("qty").asText(""),
                                payload.path("reason").asText(""), payload.path("yielderOrderNo").asText(""));
                case EVENT_PROCUREMENT_FINANCE_SUBMITTED,
                     EVENT_PROCUREMENT_FINANCE_APPROVED,
                     EVENT_PROCUREMENT_FINANCE_REJECTED ->
                        notifyProcurementFinanceEvent(eventType, aggregateId);
                case EVENT_PROCUREMENT_ARRIVAL_DETECTED,
                     EVENT_PROCUREMENT_ARRIVAL_DECIDED,
                     EVENT_PROCUREMENT_RETURN_REQUIRED,
                     EVENT_PROCUREMENT_RETURN_COMPLETED,
                     EVENT_PROCUREMENT_ARRIVAL_RECEIPT_POSTED ->
                        notifyProcurementArrivalEvent(eventType, aggregateId);
                case EVENT_RD_TASK_RESOLVED -> notifyRdTaskResolved(aggregateId);
                case EVENT_IQC_PENDING ->
                        notifyIqcPendingForQuality(
                                aggregateId, payload.path("receiptType").asText(""));
                case EVENT_IQC_RESOLVED ->
                        notifyIqcResolvedForPutaway(
                                aggregateId, payload.path("receiptType").asText(""));
                case EVENT_BOM_UPDATED -> notifyBomUpdated(aggregateId);
                default -> throw new IllegalArgumentException(
                        "Unsupported business outbox event: " + eventType);
            }
        } finally {
            OUTBOX_EVENT.remove();
            OUTBOX_DELIVERY.remove();
        }
    }

    // ---------- 8 类通知入口（业务 Service 一行调用） ----------

    /** ① 排产通知销售：计划单审核后，按订单聚合本次排产量。shortage=true 时另发缺料通知（⑧）。 */
    public void notifyPlanScheduled(UUID planId, boolean shortage) {
        if (!isOutboxDelivery()) {
            outbox.publish(EVENT_PLAN_SCHEDULED, "PRODUCTION_PLAN", planId,
                    Map.of("shortage", shortage));
            return;
        }
        deliverAtomically(() -> {
            String planNo = oneStr("SELECT bill_no FROM production_plans WHERE id = ?", planId);
            Map<UUID, BigDecimal> byOrder = new LinkedHashMap<>();
            Map<UUID, String> goodsByOrder = new LinkedHashMap<>();
            for (Map<String, Object> r : jdbc.queryForList("""
                    SELECT oi.order_id, SUM(l.allocated_qty) AS qty, g.code AS goods
                    FROM plan_order_item_links l
                    JOIN sales_order_items oi ON oi.id = l.order_item_id
                    JOIN production_plan_items pi ON pi.id = l.plan_item_id
                    LEFT JOIN goods g ON g.id = pi.goods_id
                    WHERE pi.plan_id = ? AND l.is_deleted = false AND l.source = 0
                    GROUP BY oi.order_id, g.code
                    """, planId)) {
                UUID orderId = (UUID) r.get("order_id");
                byOrder.merge(orderId, bd(r.get("qty")), BigDecimal::add);
                goodsByOrder.merge(orderId, str(r.get("goods")), (a, b) -> a + "/" + b);
            }
            for (var e : byOrder.entrySet()) {
                OrderRef o = orderRef(e.getKey());
                if (o == null) continue;
                notifyUser(o.ownerUserId(), TYPE_WORKFLOW,
                        "排产通知：" + o.billNo(),
                        "订单 " + o.billNo() + " 货品 " + goodsByOrder.get(e.getKey())
                                + " 已排产 " + qty(e.getValue()) + "(计划单 " + planNo + ")。",
                        o.route());
                if (shortage) {
                    sendToUser(o.ownerUserId(), TYPE_URGENT,
                            "生产缺料：" + o.billNo(),
                            "订单 " + o.billNo() + " 的计划单 " + planNo
                                    + " 已核验存在及时物料缺口，采购/调度已收到处理任务；"
                                    + "销售端排产进度会随到料、开工和完工继续更新。",
                            o.route(), null, "normal");
                }
            }
            if (shortage) {
                notifyRoles(List.of("buyer", "planner"), TYPE_TASK,
                        "缺料提醒：" + planNo,
                        "计划单 " + planNo + " 审核后 BOM 净需求不足(订单行状态=待物料)，请采购/调度跟进备料。",
                        "/production/plans/" + planId);
            }
        });
    }

    /**
     * 报工审核后通知归属销售。销售端进度直接读取订单/计划累计量，本通知只做可靠提醒，
     * 不复制一份易漂移的“进度状态”；Outbox 默认 2 秒轮询，正常情况下十秒内可见。
     */
    public void notifyProductionReported(UUID reportId) {
        if (!isOutboxDelivery()) {
            outbox.publish(EVENT_PRODUCTION_REPORTED,
                    "PRODUCTION_DAILY_REPORT", reportId, Map.of());
            return;
        }
        deliverAtomically(() -> {
            String reportNo = oneStr(
                    "SELECT bill_no FROM production_daily_reports WHERE id = ?", reportId);
            for (Map<String, Object> r : jdbc.queryForList("""
                    WITH affected AS (
                        SELECT DISTINCT allocation.sales_order_item_id AS order_item_id
                        FROM production_daily_report_items ri
                        JOIN execution_segment_sales_allocations allocation
                          ON allocation.id =
                             ri.execution_segment_sales_allocation_id
                        WHERE ri.report_id = ?
                          AND ri.is_deleted = false
                        UNION
                        SELECT DISTINCT ri.sales_order_item_id AS order_item_id
                        FROM production_daily_report_items ri
                        WHERE ri.report_id = ?
                          AND ri.is_deleted = false
                          AND ri.sales_order_item_id IS NOT NULL
                        UNION
                        SELECT DISTINCT l.order_item_id AS order_item_id
                        FROM production_daily_report_items ri
                        JOIN plan_order_item_links l
                          ON l.plan_item_id = ri.plan_item_id
                         AND l.is_deleted = false
                        WHERE ri.report_id = ?
                          AND ri.is_deleted = false
                          AND ri.execution_segment_id IS NULL
                          AND ri.sales_order_item_id IS NULL
                    )
                    SELECT oi.order_id,
                           SUM(COALESCE(oi.produced_qty,0)) AS produced_qty,
                           SUM(COALESCE(oi.planned_qty,0)) AS planned_qty,
                           SUM(COALESCE(oi.qty,0)) AS order_qty,
                           string_agg(DISTINCT g.code, ' / ') AS goods
                    FROM affected a
                    JOIN sales_order_items oi ON oi.id = a.order_item_id
                    LEFT JOIN goods g ON g.id = oi.goods_id
                    WHERE oi.is_deleted = false
                    GROUP BY oi.order_id
                    """, reportId, reportId, reportId)) {
                OrderRef order = orderRef((UUID) r.get("order_id"));
                if (order == null) continue;
                BigDecimal produced = bd(r.get("produced_qty"));
                BigDecimal planned = bd(r.get("planned_qty"));
                boolean reportedComplete =
                        planned.signum() > 0 && produced.compareTo(planned) >= 0;
                notifyUser(order.ownerUserId(), TYPE_WORKFLOW,
                        (reportedComplete ? "生产报工完成(待入库)：" : "生产进度更新：")
                                + order.billNo(),
                        "订单 " + order.billNo() + " 货品 " + str(r.get("goods"))
                                + " 的报工单 " + reportNo + " 已审核，累计合格 "
                                + qty(produced) + "/已排产 " + qty(planned)
                                + "(订单数量 " + qty(bd(r.get("order_qty"))) + ")。"
                                + (reportedComplete ? "成品入库审核后会再次通知可发货状态。" : ""),
                        order.route(), EVENT_PRODUCTION_REPORTED);
            }
        });
    }

    /** ②③ 完工/部分完工通知销售：成品入库审核后，按本单补的预留溯源订单行。 */
    public void notifyFinishedInbound(UUID stockDocId) {
        if (!isOutboxDelivery()) {
            List<Map<String, String>> allocations = finishedInboundSnapshot(stockDocId)
                    .stream()
                    .map(FinishedInboundSnapshot::payload)
                    .toList();
            outbox.publish(
                    EVENT_FINISHED_INBOUND,
                    "STOCK_DOCUMENT",
                    stockDocId,
                    Map.of("allocations", allocations));
            return;
        }
        deliverFinishedInbound(stockDocId, null);
    }

    private void deliverFinishedInbound(UUID stockDocId, JsonNode payload) {
        deliverAtomically(() -> {
            List<FinishedInboundSnapshot> allocations =
                    finishedInboundPayload(payload);
            if (allocations.isEmpty()
                    && (payload == null || !payload.has("allocations"))) {
                // Compatibility for durable events written before the snapshot
                // payload was introduced.
                allocations = finishedInboundSnapshot(stockDocId);
            }
            for (FinishedInboundSnapshot allocation : allocations) {
                OrderRef order = orderRef(allocation.orderId());
                if (order == null) continue;
                String orderNo = allocation.orderBillNo().isBlank()
                        ? order.billNo() : allocation.orderBillNo();
                boolean completeShipmentRequired =
                        "REQUIRE_COMPLETE".equals(allocation.shipmentPolicy())
                                && allocation.producedQty()
                                        .compareTo(allocation.orderQty()) < 0;
                String availability = completeShipmentRequired
                        ? "本批新增成品预留 " + qty(allocation.batchQty())
                                + "；该订单要求整单齐套，当前暂不可分批发货。"
                        : "本批新增可发数量 " + qty(allocation.batchQty())
                                + "，可按订单策略安排分批发货。";
                String content = "订单 " + orderNo + " 货品 "
                        + allocation.goods() + " 已完成成品入库(入库单 "
                        + allocation.documentNo() + ")。" + availability
                        + " 累计成品入库 " + qty(allocation.producedQty())
                        + "/订货 " + qty(allocation.orderQty()) + "。";
                notifyUser(
                        order.ownerUserId(),
                        TYPE_WORKFLOW,
                        "本批成品已入库：" + orderNo,
                        content,
                        order.route(),
                        EVENT_FINISHED_INBOUND);
                notifyRoles(
                        List.of("planner"),
                        TYPE_WORKFLOW,
                        "生产批次已入库：" + orderNo,
                        content,
                        "/production/plans");
            }
        });
    }

    private List<FinishedInboundSnapshot> finishedInboundSnapshot(
            UUID stockDocId) {
        if (stockDocId == null) return List.of();
        return jdbc.queryForList("""
                WITH inbound_item AS (
                    SELECT reservation.order_item_id,
                           SUM(
                               reservation.qty
                               / CASE
                                   WHEN COALESCE(item.unit_rate, 1) > 0
                                       THEN COALESCE(item.unit_rate, 1)
                                   ELSE 1
                                 END
                           ) AS batch_qty
                    FROM stock_reservations reservation
                    JOIN sales_order_items item
                      ON item.id = reservation.order_item_id
                     AND item.is_deleted = FALSE
                    WHERE reservation.source_doc_type = 'PRODUCTION_INBOUND'
                      AND reservation.source_doc_id = ?
                      AND reservation.order_item_id IS NOT NULL
                      AND reservation.is_deleted = FALSE
                      AND COALESCE(reservation.released_qty, 0)
                            < reservation.qty
                    GROUP BY reservation.order_item_id
                ), affected AS (
                    SELECT item.order_id,
                           SUM(inbound_item.batch_qty) AS batch_qty,
                           string_agg(DISTINCT goods.code, ' / ') AS goods
                    FROM inbound_item
                    JOIN sales_order_items item
                      ON item.id = inbound_item.order_item_id
                     AND item.is_deleted = FALSE
                    LEFT JOIN goods ON goods.id = item.goods_id
                    GROUP BY item.order_id
                ), order_totals AS (
                    SELECT item.order_id,
                           SUM(COALESCE(item.produced_qty, 0)) AS produced_qty,
                           SUM(COALESCE(item.qty, 0)) AS order_qty
                    FROM sales_order_items item
                    WHERE item.is_deleted = FALSE
                    GROUP BY item.order_id
                )
                SELECT affected.order_id,
                       sales_order.bill_no AS order_bill_no,
                       document.bill_no AS document_no,
                       affected.goods,
                       affected.batch_qty,
                       order_totals.produced_qty,
                       order_totals.order_qty,
                       COALESCE(sales_order.shipment_policy, 'ALLOW_PARTIAL')
                           AS shipment_policy
                FROM affected
                JOIN sales_orders sales_order
                  ON sales_order.id = affected.order_id
                 AND sales_order.is_deleted = FALSE
                JOIN order_totals
                  ON order_totals.order_id = affected.order_id
                JOIN stock_documents document
                  ON document.id = ?
                ORDER BY affected.order_id
                """, stockDocId, stockDocId).stream()
                .map(row -> new FinishedInboundSnapshot(
                        (UUID) row.get("order_id"),
                        str(row.get("order_bill_no")),
                        str(row.get("document_no")),
                        str(row.get("goods")),
                        bd(row.get("batch_qty")),
                        bd(row.get("produced_qty")),
                        bd(row.get("order_qty")),
                        str(row.get("shipment_policy"))))
                .toList();
    }

    private List<FinishedInboundSnapshot> finishedInboundPayload(
            JsonNode payload) {
        if (payload == null || !payload.path("allocations").isArray()) {
            return List.of();
        }
        List<FinishedInboundSnapshot> result = new ArrayList<>();
        for (JsonNode allocation : payload.path("allocations")) {
            UUID orderId = uuidOrNull(allocation.path("orderId").asText(""));
            if (orderId == null) continue;
            result.add(new FinishedInboundSnapshot(
                    orderId,
                    allocation.path("orderBillNo").asText(""),
                    allocation.path("documentNo").asText(""),
                    allocation.path("goods").asText(""),
                    decimal(allocation.path("batchQty").asText("0")),
                    decimal(allocation.path("producedQty").asText("0")),
                    decimal(allocation.path("orderQty").asText("0")),
                    allocation.path("shipmentPolicy")
                            .asText("ALLOW_PARTIAL")));
        }
        return List.copyOf(result);
    }

    /** 报工生成成品入库草稿后，给仓库部门投递一次待审核任务。 */
    public void notifyFinishedInboundPending(UUID stockDocId) {
        if (!isOutboxDelivery()) {
            outbox.publishOnce(
                    EVENT_FINISHED_INBOUND_PENDING,
                    "STOCK_DOCUMENT",
                    stockDocId,
                    Map.of(),
                    EVENT_FINISHED_INBOUND_PENDING + ':' + stockDocId);
            return;
        }
        deliverAtomically(() -> {
            Map<String, Object> document = one("""
                    SELECT stock.bill_no, stock.source_doc_no,
                           warehouse.name AS warehouse_name
                    FROM stock_documents stock
                    LEFT JOIN warehouses warehouse
                      ON warehouse.id = stock.warehouse_id
                    WHERE stock.id = ?
                      AND stock.doc_type = 'FINISHED_IN'
                      AND stock.status = 0
                      AND stock.is_deleted = FALSE
                    """, stockDocId);
            if (document == null) return;
            String billNo = str(document.get("bill_no"));
            String sourceNo = str(document.get("source_doc_no"));
            String warehouse = str(document.get("warehouse_name"));
            String content = "成品入库单 " + billNo
                    + (sourceNo.isBlank() ? "" : "(来源报工 " + sourceNo + ")")
                    + " 已生成并等待仓库审核"
                    + (warehouse.isBlank() ? "。" : "，目标仓库 " + warehouse + "。")
                    + "请核对实物、数量和库位后处理；通知不代替库存审核。";
            for (UUID warehouseUser : departmentUserIdsWithAuthority(
                    "SUB_WH", "stock_doc:approve")) {
                sendToUser(
                        warehouseUser,
                        TYPE_TASK,
                        "待审核成品入库：" + billNo,
                        content,
                        "/warehouse/FINISHED_IN/" + stockDocId,
                        EVENT_FINISHED_INBOUND_PENDING);
            }
        });
    }

    /** 仓库零实收拒收后，可靠退回生产/计划岗位更正报工或重新交接。 */
    public void notifyFinishedInboundRejected(
            UUID stockDocId,
            String reason,
            String confirmationIdempotencyKey) {
        if (!isOutboxDelivery()) {
            if (confirmationIdempotencyKey == null
                    || confirmationIdempotencyKey.isBlank()) {
                throw new IllegalArgumentException(
                        "confirmationIdempotencyKey is required for rejection notice");
            }
            outbox.publishOnce(
                    EVENT_FINISHED_INBOUND_REJECTED,
                    "STOCK_DOCUMENT",
                    stockDocId,
                    Map.of("reason", reason == null ? "" : reason),
                    EVENT_FINISHED_INBOUND_REJECTED + ':' + stockDocId + ':'
                            + confirmationIdempotencyKey.strip());
            return;
        }
        deliverAtomically(() -> {
            Map<String, Object> document = one("""
                    SELECT stock.bill_no, stock.plan_no,
                           stock.source_daily_report_id,
                           stock.source_doc_no,
                           report_maker_user.id AS report_maker_user_id
                    FROM stock_documents stock
                    LEFT JOIN production_daily_reports report
                      ON report.id = stock.source_daily_report_id
                     AND report.is_deleted = FALSE
                    LEFT JOIN users report_maker_user
                      ON report_maker_user.employee_id = report.maker_id
                     AND report_maker_user.is_deleted = FALSE
                     AND report_maker_user.status = 'active'
                    WHERE stock.id = ?
                      AND stock.doc_type = 'FINISHED_IN'
                      AND stock.status = -1
                      AND stock.is_deleted = FALSE
                    """, stockDocId);
            if (document == null) return;
            String billNo = str(document.get("bill_no"));
            String planNo = str(document.get("plan_no"));
            String reportNo = str(document.get("source_doc_no"));
            UUID reportId = (UUID) document.get("source_daily_report_id");
            String content = "仓库点收成品入库单 " + billNo + " 时确认整单实收为 0"
                    + (reportNo.isBlank() ? "" : "(来源报工 " + reportNo + ")")
                    + (planNo.isBlank() ? "" : "，生产计划 " + planNo)
                    + "。拒收原因：" + (reason == null || reason.isBlank()
                            ? "未填写"
                            : reason)
                    + "。本次未增加库存或入库累计，请生产主管核对实物并更正/红冲报工。";
            UUID reportMakerUserId = (UUID) document.get(
                    "report_maker_user_id");
            Set<UUID> recipients = new LinkedHashSet<>();
            recipients.addAll(departmentUserIdsWithAuthority(
                    "DEPT_PROD", "production_daily_report:approve"));
            recipients.addAll(departmentUserIdsWithAuthority(
                    "DEPT_PROD", "production_daily_report:reverse"));
            recipients.addAll(departmentUserIdsWithAuthority(
                    "SUB_PLAN", "production_daily_report:approve"));
            recipients.addAll(departmentUserIdsWithAuthority(
                    "SUB_PLAN", "production_daily_report:reverse"));
            String route = reportId == null
                    ? "/production/daily-reports"
                    : "/production/daily-reports/" + reportId;
            if (reportMakerUserId != null) {
                sendToUser(
                        reportMakerUserId,
                        TYPE_URGENT,
                        "成品入库被仓库拒收：" + billNo,
                        content,
                        route,
                        EVENT_FINISHED_INBOUND_REJECTED);
                recipients.remove(reportMakerUserId);
            }
            for (UUID recipient : recipients) {
                sendToUser(
                        recipient,
                        TYPE_URGENT,
                        "成品入库被仓库拒收：" + billNo,
                        content,
                        route,
                        EVENT_FINISHED_INBOUND_REJECTED,
                        "normal");
            }
        });
    }

    /** 已点收成品被专用红冲后，提醒生产责任人并指明已重建仓库待点收任务。 */
    public void notifyFinishedInboundReversed(
            UUID stockDocId, UUID replacementStockDocId) {
        if (!isOutboxDelivery()) {
            outbox.publishOnce(
                    EVENT_FINISHED_INBOUND_REVERSED,
                    "STOCK_DOCUMENT",
                    stockDocId,
                    replacementStockDocId == null
                            ? Map.of()
                            : Map.of("replacementStockDocId",
                                    replacementStockDocId.toString()),
                    EVENT_FINISHED_INBOUND_REVERSED + ':' + stockDocId);
            return;
        }
        deliverAtomically(() -> {
            Map<String, Object> document = one("""
                    SELECT source.bill_no, source.plan_no,
                           source.source_daily_report_id,
                           source.source_doc_no,
                           replacement.bill_no AS replacement_bill_no,
                           report_maker_user.id AS report_maker_user_id
                    FROM production_finished_in_confirmation_reversals reversal
                    JOIN stock_documents source
                      ON source.id = reversal.reversed_stock_document_id
                     AND source.status = -1
                     AND source.is_deleted = FALSE
                    JOIN stock_documents replacement
                      ON replacement.id =
                         reversal.replacement_stock_document_id
                     AND replacement.status = 0
                     AND replacement.is_deleted = FALSE
                    LEFT JOIN production_daily_reports report
                      ON report.id = source.source_daily_report_id
                     AND report.is_deleted = FALSE
                    LEFT JOIN users report_maker_user
                      ON report_maker_user.employee_id = report.maker_id
                     AND report_maker_user.is_deleted = FALSE
                     AND report_maker_user.status = 'active'
                    WHERE source.id = ?
                    """, stockDocId);
            if (document == null) return;
            String sourceNo = str(document.get("bill_no"));
            String replacementNo = str(document.get("replacement_bill_no"));
            String reportNo = str(document.get("source_doc_no"));
            UUID reportId = (UUID) document.get("source_daily_report_id");
            UUID reportMakerUserId = (UUID) document.get(
                    "report_maker_user_id");
            Set<UUID> recipients = new LinkedHashSet<>();
            recipients.addAll(departmentUserIdsWithAuthority(
                    "DEPT_PROD", "production_daily_report:approve"));
            recipients.addAll(departmentUserIdsWithAuthority(
                    "DEPT_PROD", "production_daily_report:reverse"));
            recipients.addAll(departmentUserIdsWithAuthority(
                    "SUB_PLAN", "production_daily_report:approve"));
            recipients.addAll(departmentUserIdsWithAuthority(
                    "SUB_PLAN", "production_daily_report:reverse"));
            String route = reportId == null
                    ? "/production/daily-reports"
                    : "/production/daily-reports/" + reportId;
            String content = "仓库已红冲成品入库单 " + sourceNo
                    + (reportNo.isBlank() ? "" : "(来源报工 " + reportNo + ")")
                    + "，原实收数量已从库存和入库累计回退，并重建待点收单 "
                    + replacementNo
                    + "。请核对生产实物与报工；通知不代替仓库重新点收。";
            if (reportMakerUserId != null) {
                sendToUser(
                        reportMakerUserId,
                        TYPE_URGENT,
                        "成品点收已红冲：" + sourceNo,
                        content,
                        route,
                        EVENT_FINISHED_INBOUND_REVERSED);
                recipients.remove(reportMakerUserId);
            }
            for (UUID recipient : recipients) {
                sendToUser(
                        recipient,
                        TYPE_URGENT,
                        "成品点收已红冲：" + sourceNo,
                        content,
                        route,
                        EVENT_FINISHED_INBOUND_REVERSED,
                        "normal");
            }
        });
    }

    /** 计划批准或待料段齐套后，把真实 DRAW 草稿可靠投递给仓库任务人员。 */
    public void notifyProductionDrawPending(UUID stockDocId) {
        if (!isOutboxDelivery()) {
            outbox.publishOnce(
                    EVENT_PRODUCTION_DRAW_PENDING,
                    "STOCK_DOCUMENT",
                    stockDocId,
                    Map.of(),
                    EVENT_PRODUCTION_DRAW_PENDING + ':' + stockDocId);
            return;
        }
        deliverAtomically(() -> {
            Map<String, Object> document = one("""
                    SELECT stock.bill_no, stock.plan_no,
                           warehouse.name AS warehouse_name,
                           department.name AS department_name,
                           COUNT(item.id) AS line_count
                    FROM stock_documents stock
                    LEFT JOIN warehouses warehouse
                      ON warehouse.id = stock.warehouse_id
                    LEFT JOIN departments department
                      ON department.id = stock.department_id
                    JOIN stock_document_items item
                      ON item.doc_id = stock.id
                     AND item.is_deleted = FALSE
                    WHERE stock.id = ?
                      AND stock.doc_type = 'DRAW'
                      AND stock.status = 0
                      AND stock.is_deleted = FALSE
                    GROUP BY stock.bill_no, stock.plan_no,
                             warehouse.name, department.name
                    """, stockDocId);
            if (document == null) return;
            String billNo = str(document.get("bill_no"));
            String planNo = str(document.get("plan_no"));
            String warehouse = str(document.get("warehouse_name"));
            String department = str(document.get("department_name"));
            String content = "计划部已下达生产领料单 " + billNo
                    + (planNo.isBlank() ? "" : "(生产计划 " + planNo + ")")
                    + "，共 " + str(document.get("line_count")) + " 行物料"
                    + (warehouse.isBlank() ? "" : "，发料仓库「" + warehouse + "」")
                    + (department.isBlank() ? "" : "，领料车间「" + department + "」")
                    + "。请先核对并审核领料需求，再按实物分轮出库；审核本身不扣库存。";
            Set<UUID> warehouseUsers = new LinkedHashSet<>();
            warehouseUsers.addAll(departmentUserIdsWithAuthority(
                    "SUB_WH", "stock_doc:approve"));
            warehouseUsers.addAll(departmentUserIdsWithAuthority(
                    "SUB_WH", "stock_doc:issue"));
            for (UUID warehouseUser : warehouseUsers) {
                sendToUser(
                        warehouseUser,
                        TYPE_TASK,
                        "待处理生产领料：" + billNo,
                        content,
                        "/warehouse/DRAW/" + stockDocId,
                        EVENT_PRODUCTION_DRAW_PENDING);
            }
        });
    }

    /** 仓库把 DRAW 全部实际出库后，通知计划和生产岗位可以继续正式开工。 */
    public void notifyProductionDrawIssued(
            UUID stockDocId, String issueIdempotencyKey) {
        if (!isOutboxDelivery()) {
            if (issueIdempotencyKey == null || issueIdempotencyKey.isBlank()) {
                throw new IllegalArgumentException(
                        "issueIdempotencyKey is required for DRAW issued notice");
            }
            outbox.publishOnce(
                    EVENT_PRODUCTION_DRAW_ISSUED,
                    "STOCK_DOCUMENT",
                    stockDocId,
                    Map.of(),
                    EVENT_PRODUCTION_DRAW_ISSUED + ':' + stockDocId + ':'
                            + issueIdempotencyKey.strip());
            return;
        }
        deliverAtomically(() -> {
            Map<String, Object> document = one("""
                    SELECT stock.bill_no, stock.plan_no,
                           warehouse.name AS warehouse_name
                    FROM stock_documents stock
                    LEFT JOIN warehouses warehouse
                      ON warehouse.id = stock.warehouse_id
                    WHERE stock.id = ?
                      AND stock.doc_type = 'DRAW'
                      AND stock.status = 1
                      AND stock.issue_status = 2
                      AND stock.is_deleted = FALSE
                    """, stockDocId);
            if (document == null) return;
            String billNo = str(document.get("bill_no"));
            String planNo = str(document.get("plan_no"));
            String warehouse = str(document.get("warehouse_name"));
            Set<UUID> recipients = new LinkedHashSet<>();
            recipients.addAll(departmentUserIdsWithAuthority(
                    "SUB_PLAN", "production_plan:view"));
            recipients.addAll(departmentUserIdsWithAuthority(
                    "DEPT_PROD", "production_plan:view"));
            for (UUID recipient : recipients) {
                sendToUser(
                        recipient,
                        TYPE_WORKFLOW,
                        "生产领料已全部发出：" + billNo,
                        "仓库" + (warehouse.isBlank() ? "" : "「" + warehouse + "」")
                                + "已完成领料单 " + billNo + " 的全部实物出库"
                                + (planNo.isBlank()
                                        ? "。"
                                        : "(生产计划 " + planNo + ")。")
                                + "对应执行子计划现可办理正式开工。",
                        "/production/schedule",
                        EVENT_PRODUCTION_DRAW_ISSUED);
            }
        });
    }

    /** 未派工前仓库撤回已发物料后，提醒计划/生产重新等待发料。 */
    public void notifyProductionDrawIssueReversed(
            UUID stockDocId, String reverseIdempotencyKey) {
        if (!isOutboxDelivery()) {
            if (reverseIdempotencyKey == null
                    || reverseIdempotencyKey.isBlank()) {
                throw new IllegalArgumentException(
                        "reverseIdempotencyKey is required for DRAW reverse notice");
            }
            outbox.publishOnce(
                    EVENT_PRODUCTION_DRAW_ISSUE_REVERSED,
                    "STOCK_DOCUMENT",
                    stockDocId,
                    Map.of(),
                    EVENT_PRODUCTION_DRAW_ISSUE_REVERSED + ':' + stockDocId
                            + ':' + reverseIdempotencyKey.strip());
            return;
        }
        deliverAtomically(() -> {
            Map<String, Object> document = one("""
                    SELECT stock.bill_no, stock.plan_no,
                           warehouse.name AS warehouse_name
                    FROM stock_documents stock
                    LEFT JOIN warehouses warehouse
                      ON warehouse.id = stock.warehouse_id
                    WHERE stock.id = ?
                      AND stock.doc_type = 'DRAW'
                      AND stock.status = 1
                      AND stock.issue_status <> 2
                      AND stock.is_deleted = FALSE
                    """, stockDocId);
            if (document == null) return;
            String billNo = str(document.get("bill_no"));
            String planNo = str(document.get("plan_no"));
            String warehouse = str(document.get("warehouse_name"));
            Set<UUID> recipients = new LinkedHashSet<>();
            recipients.addAll(departmentUserIdsWithAuthority(
                    "SUB_PLAN", "production_plan:view"));
            recipients.addAll(departmentUserIdsWithAuthority(
                    "DEPT_PROD", "production_plan:view"));
            for (UUID recipient : recipients) {
                sendToUser(
                        recipient,
                        TYPE_URGENT,
                        "生产发料已撤回：" + billNo,
                        "仓库" + (warehouse.isBlank() ? "" : "「" + warehouse + "」")
                                + "已反向领料单 " + billNo + " 的部分实物出库"
                                + (planNo.isBlank()
                                        ? "。"
                                        : "(生产计划 " + planNo + ")。")
                                + "执行子计划恢复为待发料，重新全量发料前不得开工。",
                        "/production/schedule",
                        EVENT_PRODUCTION_DRAW_ISSUE_REVERSED,
                        "normal");
            }
        });
    }

    /**
     * 仓库审核采购/委外收货后通知品质部：收货单已进入 IQC 待检。
     * 接收人只取品质部子树内在职、启用且当前有效拥有查看权限的账号；通知不是角标真相。
     */
    public void notifyIqcPendingForQuality(UUID receiptId, String receiptType) {
        if (!isOutboxDelivery()) {
            outbox.publishOnce(
                    EVENT_IQC_PENDING,
                    "PROCUREMENT_INSPECTION",
                    receiptId,
                    Map.of("receiptType", receiptType),
                    EVENT_IQC_PENDING + ':' + receiptId);
            return;
        }
        deliverAtomically(() -> {
            boolean purchase = "PURCHASE".equals(receiptType);
            if (!purchase && !"SUBCONTRACT".equals(receiptType)) return;
            Map<String, Object> receipt = one(purchase
                    ? """
                    SELECT receipt.bill_no, supplier.name AS supplier_name,
                           warehouse.name AS warehouse_name
                    FROM purchase_receipts receipt
                    LEFT JOIN suppliers supplier ON supplier.id = receipt.supplier_id
                    LEFT JOIN warehouses warehouse ON warehouse.id = receipt.warehouse_id
                    WHERE receipt.id = ? AND COALESCE(receipt.is_deleted, FALSE) = FALSE
                    """
                    : """
                    SELECT receipt.bill_no, supplier.name AS supplier_name,
                           warehouse.name AS warehouse_name
                    FROM subcontract_receipts receipt
                    LEFT JOIN suppliers supplier ON supplier.id = receipt.supplier_id
                    LEFT JOIN warehouses warehouse ON warehouse.id = receipt.warehouse_id
                    WHERE receipt.id = ? AND COALESCE(receipt.is_deleted, FALSE) = FALSE
                    """, receiptId);
            if (receipt == null) return;
            Map<String, Object> pending = one("""
                    SELECT COUNT(*) AS pending_lines,
                           COALESCE(SUM(received_base_qty - passed_base_qty - failed_base_qty), 0)
                               AS pending_base_qty
                    FROM procurement_inspection_items
                    WHERE receipt_type = ? AND receipt_id = ?
                      AND status IN ('PENDING', 'PARTIAL')
                    """, receiptType, receiptId);
            long pendingLines = pending == null
                    ? 0L
                    : ((Number) pending.get("pending_lines")).longValue();
            if (pendingLines == 0L) return;
            BigDecimal pendingQty = bd(pending.get("pending_base_qty"));
            String billNo = str(receipt.get("bill_no"));
            String supplier = str(receipt.get("supplier_name"));
            String warehouse = str(receipt.get("warehouse_name"));
            String documentLabel = purchase ? "采购收货单 " : "委外进仓单 ";
            String content = documentLabel + billNo
                    + (supplier.isBlank() ? "" : "(" + supplier + ")")
                    + " 已由仓库审核并进入待检，共 " + pendingLines + " 行、待检 "
                    + qty(pendingQty) + "(基本单位)"
                    + (warehouse.isBlank() ? "。" : "，目标仓库「" + warehouse + "」。")
                    + "请到品质任务中心核验；角标和待检数量以任务中心实时数据为准。";
            for (UUID qualityUser : qualityInspectionViewerUserIds()) {
                sendToUser(
                        qualityUser,
                        TYPE_TASK,
                        "待检处置：" + billNo,
                        content,
                        "/quality/task-center",
                        EVENT_IQC_PENDING);
            }
        });
    }

    /**
     * 采购/委外收货 IQC 整单结案后通知仓库：合格量已放行入库，不合格量未入库。
     * 事件由仓库 inbound 模块（ProcurementInspectionService）在结案同事务投递；
     * 本方法只在 outbox 处理事务内做真实通知写入。
     */
    public void notifyIqcResolvedForPutaway(UUID receiptId, String receiptType) {
        if (!isOutboxDelivery()) {
            outbox.publishOnce(
                    EVENT_IQC_RESOLVED,
                    "PROCUREMENT_INSPECTION",
                    receiptId,
                    Map.of("receiptType", receiptType),
                    EVENT_IQC_RESOLVED + ':' + receiptId);
            return;
        }
        deliverAtomically(() -> {
            boolean purchase = "PURCHASE".equals(receiptType);
            Map<String, Object> receipt = one(purchase
                    ? """
                    SELECT receipt.bill_no, supplier.name AS supplier_name,
                           warehouse.name AS warehouse_name
                    FROM purchase_receipts receipt
                    LEFT JOIN suppliers supplier ON supplier.id = receipt.supplier_id
                    LEFT JOIN warehouses warehouse ON warehouse.id = receipt.warehouse_id
                    WHERE receipt.id = ? AND COALESCE(receipt.is_deleted, FALSE) = FALSE
                    """
                    : """
                    SELECT receipt.bill_no, supplier.name AS supplier_name,
                           warehouse.name AS warehouse_name
                    FROM subcontract_receipts receipt
                    LEFT JOIN suppliers supplier ON supplier.id = receipt.supplier_id
                    LEFT JOIN warehouses warehouse ON warehouse.id = receipt.warehouse_id
                    WHERE receipt.id = ? AND COALESCE(receipt.is_deleted, FALSE) = FALSE
                    """, receiptId);
            if (receipt == null) return;
            Map<String, Object> sums = one("""
                    SELECT COALESCE(SUM(passed_base_qty), 0) AS passed,
                           COALESCE(SUM(failed_base_qty), 0) AS failed
                    FROM procurement_inspection_items
                    WHERE receipt_type = ? AND receipt_id = ? AND status <> 'REVERSED'
                    """, receiptType, receiptId);
            BigDecimal passed = sums == null ? BigDecimal.ZERO : (BigDecimal) sums.get("passed");
            BigDecimal failed = sums == null ? BigDecimal.ZERO : (BigDecimal) sums.get("failed");
            String billNo = str(receipt.get("bill_no"));
            String supplier = str(receipt.get("supplier_name"));
            String warehouse = str(receipt.get("warehouse_name"));
            String content = (purchase ? "采购收货单 " : "委外进仓单 ") + billNo
                    + (supplier.isBlank() ? "" : "(" + supplier + ")")
                    + " 品质部检验已结案：合格 " + qty(passed) + " 已放行入库"
                    + (warehouse.isBlank() ? "" : " 至「" + warehouse + "」")
                    + (failed.signum() > 0
                            ? "；不合格 " + qty(failed) + " 未入库，请核对实物并跟进采购/供应商处置。"
                            : "，请核对实物上架。");
            String route = (purchase ? "/purchase/receipts/" : "/subcontract/receipts/")
                    + receiptId;
            for (UUID warehouseUser : departmentUserIds("SUB_WH")) {
                sendToUser(
                        warehouseUser,
                        TYPE_WORKFLOW,
                        "品质检验通过，已入库：" + billNo,
                        content,
                        route,
                        EVENT_IQC_RESOLVED);
            }
        });
    }

    /** 销售创建待拣货发货单后，给仓库部门投递一次待拣货任务。 */
    public void notifyShipmentPendingPick(UUID shipmentId) {
        if (!isOutboxDelivery()) {
            outbox.publishOnce(
                    EVENT_SHIPMENT_PENDING_PICK,
                    "SALES_SHIPMENT",
                    shipmentId,
                    Map.of(),
                    EVENT_SHIPMENT_PENDING_PICK + ':' + shipmentId);
            return;
        }
        deliverAtomically(() -> {
            Map<String, Object> shipment = one("""
                    SELECT shipment.bill_no,
                           warehouse.name AS warehouse_name,
                           SUM(COALESCE(item.qty, 0)) AS shipment_qty
                    FROM sales_shipments shipment
                    LEFT JOIN warehouses warehouse
                      ON warehouse.id = shipment.warehouse_id
                    LEFT JOIN sales_shipment_items item
                      ON item.shipment_id = shipment.id
                     AND item.is_deleted = FALSE
                    WHERE shipment.id = ?
                      AND shipment.warehouse_work_status = 'PENDING_PICK'
                      AND shipment.status = 0
                      AND shipment.is_deleted = FALSE
                    GROUP BY shipment.bill_no, warehouse.name
                    """, shipmentId);
            if (shipment == null) return;
            String billNo = str(shipment.get("bill_no"));
            String warehouse = str(shipment.get("warehouse_name"));
            String content = "发货单 " + billNo + " 已进入待拣货，数量 "
                    + qty(bd(shipment.get("shipment_qty")))
                    + (warehouse.isBlank() ? "。" : "，出库仓库 " + warehouse + "。")
                    + "请按仓库作业流程核对库存并拣货；通知不代表已占用或已出库。";
            for (UUID warehouseUser : departmentUserIds("SUB_WH")) {
                sendToUser(
                        warehouseUser,
                        TYPE_TASK,
                        "待拣货发货单：" + billNo,
                        content,
                        "/sales/shipments/" + shipmentId,
                        EVENT_SHIPMENT_PENDING_PICK);
            }
        });
    }

    /**
     * Reliable handoff after material analysis creates a real purchase or
     * subcontract application. The action remains the aggregate authority:
     * delivery re-reads route, downstream document and material snapshots.
     * Cancelled actions or actions without a real downstream link are ignored.
     */
    public void notifyPreplanSupplyActionCreated(UUID actionId) {
        if (!isOutboxDelivery()) {
            outbox.publishOnce(
                    EVENT_PREPLAN_SUPPLY_ACTION_CREATED,
                    "PREPLAN_SUPPLY_ACTION",
                    actionId,
                    Map.of(),
                    EVENT_PREPLAN_SUPPLY_ACTION_CREATED + ':' + actionId);
            return;
        }
        deliverAtomically(() -> {
            Map<String, Object> action = one("""
                    SELECT supply.route, supply.requested_qty, supply.need_date,
                           supply.external_document_type, supply.external_document_id,
                           supply.external_document_no,
                           goods.code AS goods_code, goods.name AS goods_name
                    FROM preplan_supply_actions supply
                    JOIN goods ON goods.id = supply.goods_id
                    WHERE supply.id = ?
                      AND supply.status <> 'CANCELLED'
                      AND supply.external_document_id IS NOT NULL
                      AND supply.external_document_no IS NOT NULL
                      AND (
                            (supply.route = 'BUY'
                             AND supply.external_document_type = 'PURCHASE_REQUEST'
                             AND EXISTS (
                                 SELECT 1
                                 FROM purchase_requests request
                                 WHERE request.id = supply.external_document_id
                                   AND request.is_deleted = FALSE
                             ))
                         OR (supply.route = 'SUBCONTRACT'
                             AND supply.external_document_type = 'SUBCONTRACT_APPLICATION'
                             AND EXISTS (
                                 SELECT 1
                                 FROM subcontract_applications application
                                 WHERE application.id = supply.external_document_id
                                   AND application.is_deleted = FALSE
                             ))
                      )
                    """, actionId);
            if (action == null) return;

            String supplyRoute = str(action.get("route"));
            UUID documentId = (UUID) action.get("external_document_id");
            String documentNo = str(action.get("external_document_no"));
            String goodsLabel = (str(action.get("goods_code")) + " "
                    + str(action.get("goods_name"))).strip();
            if (goodsLabel.isBlank()) {
                goodsLabel = "\u6240\u9009\u7269\u6599";
            }
            String needDate = str(action.get("need_date"));
            String quantity = qty(bd(action.get("requested_qty")));

            String title;
            String content;
            String actionRoute;
            String requiredViewAuthority;
            if ("BUY".equals(supplyRoute)) {
                title = "\u65b0\u91c7\u8d2d\u9700\u6c42\uff1a" + documentNo;
                content = "\u8ba1\u5212\u90e8\u5df2\u4e0b\u8fbe\u91c7\u8d2d\u7533\u8bf7 "
                        + documentNo + "\uff0c\u7269\u6599 " + goodsLabel
                        + "\uff0c\u6570\u91cf " + quantity
                        + (needDate.isBlank()
                                ? "\u3002"
                                : "\uff0c\u9700\u6c42\u65e5\u671f " + needDate + "\u3002")
                        + "\u8bf7\u5230\u91c7\u8d2d\u7533\u8bf7\u8be6\u60c5\u6838\u5bf9\uff0c"
                        + "\u5e76\u4ece\u91c7\u8d2d\u4efb\u52a1\u4e2d\u5fc3\u7ee7\u7eed"
                        + "\u5206\u89e3\u8ba2\u8d27\u3002";
                actionRoute = "/purchase/requests/" + documentId;
                requiredViewAuthority = PURCHASE_REQUEST_VIEW_AUTHORITY;
            } else if ("SUBCONTRACT".equals(supplyRoute)) {
                title = "\u65b0\u59d4\u5916\u9700\u6c42\uff1a" + documentNo;
                content = "\u8ba1\u5212\u90e8\u5df2\u4e0b\u8fbe\u59d4\u5916\u7533\u8bf7 "
                        + documentNo + "\uff0c\u7269\u6599 " + goodsLabel
                        + "\uff0c\u6570\u91cf " + quantity
                        + (needDate.isBlank()
                                ? "\u3002"
                                : "\uff0c\u9700\u6c42\u65e5\u671f " + needDate + "\u3002")
                        + "\u8bf7\u5230\u59d4\u5916\u7533\u8bf7\u8be6\u60c5\u6838\u5bf9\uff0c"
                        + "\u5e76\u4ece\u59d4\u5916\u4efb\u52a1\u4e2d\u5fc3\u7ee7\u7eed"
                        + "\u5206\u89e3\u8ba2\u8d27\u3002";
                actionRoute = "/subcontract/applications/" + documentId;
                requiredViewAuthority = SUBCONTRACT_APPLICATION_VIEW_AUTHORITY;
            } else {
                return;
            }
            notifyPreplanSupplyRecipients(
                    TYPE_TASK,
                    title,
                    content,
                    actionRoute,
                    requiredViewAuthority);
        });
    }

    /**
     * Publishes the durable handoff used when a receipt or manual recheck makes
     * more of an existing material analysis executable. Delivery is strictly
     * scoped to the analysis maker's active account.
     */
    public void notifyMaterialAnalysisReady(
            UUID analysisId,
            UUID makerEmployeeId,
            String sourceType,
            UUID sourceDocumentId,
            BigDecimal readyFinishDelta,
            BigDecimal readyFinishQty) {
        if (isOutboxDelivery()) {
            throw new IllegalStateException(
                    "Material-analysis READY delivery must use the outbox payload");
        }
        if (analysisId == null
                || readyFinishDelta == null
                || readyFinishDelta.signum() <= 0) {
            return;
        }
        UUID authoritativeMaker = materialAnalysisMaker(analysisId);
        if (authoritativeMaker == null) return;
        String normalizedSource = normalizeAnalysisReadySource(sourceType);
        BigDecimal total = readyFinishQty == null
                ? BigDecimal.ZERO : readyFinishQty.max(BigDecimal.ZERO);
        String sourceId = sourceDocumentId == null
                ? "" : sourceDocumentId.toString();
        Map<String, String> payload = Map.of(
                "makerEmployeeId", authoritativeMaker.toString(),
                "sourceType", normalizedSource,
                "sourceDocumentId", sourceId,
                "readyFinishDelta", qty(readyFinishDelta),
                "readyFinishQty", qty(total));
        String sourceKey = sourceId.isBlank() ? qty(total) : sourceId;
        outbox.publishOnce(
                EVENT_MATERIAL_ANALYSIS_READY,
                "PRODUCTION_MATERIAL_ANALYSIS",
                analysisId,
                payload,
                EVENT_MATERIAL_ANALYSIS_READY + ':' + analysisId + ':'
                        + normalizedSource + ':' + sourceKey);
    }

    private void deliverMaterialAnalysisReady(
            UUID analysisId,
            JsonNode payload) {
        deliverAtomically(() -> {
            UUID currentMaker = materialAnalysisMaker(analysisId);
            if (currentMaker == null) return;
            UUID payloadMaker = uuidOrNull(
                    payload.path("makerEmployeeId").asText(""));
            // The analysis row remains authoritative if ownership ever changes
            // between event creation and delivery. Never broadcast to a guessed
            // role or to the stale payload owner.
            UUID makerEmployeeId = payloadMaker != null
                    && payloadMaker.equals(currentMaker)
                    ? payloadMaker : currentMaker;
            UUID makerUserId = userIdOfEmployee(makerEmployeeId);
            if (makerUserId == null) return;
            BigDecimal delta = decimal(
                    payload.path("readyFinishDelta").asText("0"));
            if (delta.signum() <= 0) return;
            BigDecimal readyQty = decimal(
                    payload.path("readyFinishQty").asText("0"));
            String sourceType = normalizeAnalysisReadySource(
                    payload.path("sourceType").asText(""));
            String sourceLabel = analysisReadySourceLabel(sourceType);
            // 来源只展示业务单号（CJ/EJ/CR…）；id 仅作关联键，不进用户可见文案。
            String sourceDocumentNo = payload.path("sourceDocumentNo").asText("");
            notifyUser(
                    makerUserId,
                    TYPE_TASK,
                    "剩余物料已可下达：新增 " + qty(delta),
                    sourceLabel + "后，本物料分析新增可完工下达数量 "
                            + qty(delta) + "，当前累计可完工下达 "
                            + qty(readyQty)
                            + (sourceDocumentNo.isBlank()
                                    ? "。"
                                    : "(来源单据 " + sourceDocumentNo + ")。")
                            + "请打开物料分析复核后，再生成下一批正式生产计划。",
                    "/production/material-analysis",
                    EVENT_MATERIAL_ANALYSIS_READY);
        });
    }

    private UUID materialAnalysisMaker(UUID analysisId) {
        Map<String, Object> row = one("""
                SELECT maker_id
                FROM production_material_analyses
                WHERE id = ?
                  AND is_deleted = FALSE
                  AND status IN ('ACTIVE', 'PARTIALLY_PLANNED')
                """, analysisId);
        return row == null ? null : (UUID) row.get("maker_id");
    }

    static String analysisReadySourceLabel(String sourceType) {
        return switch (normalizeAnalysisReadySource(sourceType)) {
            case "PURCHASE" -> "采购到货";
            case "SUBCONTRACT" -> "委外回厂";
            case "MAKE" -> "自制件完工入库";
            case "MANUAL" -> "人工复核";
            default -> "物料状态变化";
        };
    }

    private static String normalizeAnalysisReadySource(String sourceType) {
        String normalized = sourceType == null ? "" : sourceType.strip();
        if ("MANUAL_RELEASE".equals(normalized)) return "MANUAL";
        return switch (normalized) {
            case "PURCHASE", "SUBCONTRACT", "MAKE", "MANUAL" ->
                    normalized;
            default -> "UNKNOWN";
        };
    }

    /** ④ 数量不足（补产）通知销售：报工完结缺额自动生成补产计划后。 */
    public void notifyRemakeCreated(UUID reportId) {
        if (!isOutboxDelivery()) {
            outbox.publish(EVENT_REMAKE_CREATED, "PRODUCTION_DAILY_REPORT", reportId,
                    Map.of());
            return;
        }
        deliverAtomically(() -> {
            String reportBillNo = oneStr(
                    "SELECT bill_no FROM production_daily_reports WHERE id = ?", reportId);
            for (Map<String, Object> r : jdbc.queryForList("""
                    SELECT oi.order_id, rp.bill_no AS plan_no, SUM(rl.allocated_qty) AS qty
                    FROM production_plans rp
                    JOIN production_plan_items ri ON ri.plan_id = rp.id
                    JOIN plan_order_item_links rl ON rl.plan_item_id = ri.id AND rl.is_deleted = false AND rl.source = 1
                    JOIN sales_order_items oi ON oi.id = rl.order_item_id
                    WHERE rp.source_daily_report_id = ?
                    GROUP BY oi.order_id, rp.bill_no
                    """, reportId)) {
                OrderRef o = orderRef((UUID) r.get("order_id"));
                if (o == null) continue;
                notifyUser(o.ownerUserId(), TYPE_TASK,
                        "数量不足·已补产：" + o.billNo(),
                        "订单 " + o.billNo() + " 报工完结缺额 " + qty(bd(r.get("qty")))
                                + "，已自动生成补产计划 " + str(r.get("plan_no")) + "(报工单 " + reportBillNo
                                + ")，待调度审核排产。",
                        o.route());
            }
        });
    }

    /**
     * 执行段派工/开工节点通知归属销售。销售来源只认精确分摊账，
     * 不按相同货品或计划行猜测订单；内部生产段因此不会误发销售通知。
     */
    public void notifyExecutionSegmentTransition(UUID segmentId, boolean started) {
        String eventType = started ? EVENT_SEGMENT_STARTED : EVENT_SEGMENT_DISPATCHED;
        if (!isOutboxDelivery()) {
            outbox.publish(eventType, "PRODUCTION_EXECUTION_SEGMENT", segmentId, Map.of());
            return;
        }
        deliverAtomically(() -> {
            Map<String, Object> segment = one("""
                    SELECT s.segment_code, s.planned_qty, s.plan_begin_date,
                           s.plan_end_date, p.bill_no AS plan_no, g.code AS goods
                    FROM production_execution_segments s
                    JOIN production_plans p ON p.id = s.plan_id
                    JOIN goods g ON g.id = s.product_goods_id
                    WHERE s.id = ? AND s.is_deleted = false
                    """, segmentId);
            if (segment == null) return;
            List<Map<String, Object>> owners = jdbc.queryForList("""
                    SELECT oi.order_id, SUM(a.allocated_qty) AS allocated_qty
                    FROM execution_segment_sales_allocations a
                    JOIN sales_order_items oi ON oi.id = a.sales_order_item_id
                    WHERE a.execution_segment_id = ?
                      AND oi.is_deleted = false
                    GROUP BY oi.order_id
                    ORDER BY oi.order_id
                    """, segmentId);
            String node = started ? "已开工" : "已派工";
            String titlePrefix = started ? "生产开工：" : "生产派工：";
            for (Map<String, Object> owner : owners) {
                OrderRef order = orderRef((UUID) owner.get("order_id"));
                if (order == null) continue;
                String begin = segment.get("plan_begin_date") == null
                        ? "未定" : segment.get("plan_begin_date").toString();
                String end = segment.get("plan_end_date") == null
                        ? "未定" : segment.get("plan_end_date").toString();
                notifyUser(order.ownerUserId(), TYPE_WORKFLOW,
                        titlePrefix + order.billNo(),
                        "订单 " + order.billNo() + " 的货品 "
                                + str(segment.get("goods")) + " " + node
                                + " " + qty(bd(owner.get("allocated_qty")))
                                + "(计划 " + str(segment.get("plan_no"))
                                + "，子任务 " + str(segment.get("segment_code"))
                                + "，计划 " + begin + " 至 " + end + ")。",
                        order.route());
            }
        });
    }

    /**
     * A purchase/subcontract receipt changed a material-complete execution
     * segment from WAITING to READY. The receipt id is part of the dedupe key:
     * replaying the same receipt is silent, while a later legitimate
     * demotion/re-kit can notify again from its new receipt.
     */
    public void notifyExecutionSegmentReady(
            UUID segmentId,
            UUID triggeringReceiptId,
            String sourceType) {
        String normalizedSource = sourceType == null ? "" : sourceType.strip();
        if (!isOutboxDelivery()) {
            if (triggeringReceiptId == null) {
                throw new IllegalArgumentException(
                        "triggeringReceiptId is required for a READY event");
            }
            outbox.publishOnce(
                    EVENT_SEGMENT_READY,
                    "PRODUCTION_EXECUTION_SEGMENT",
                    segmentId,
                    Map.of(
                            "triggeringReceiptId",
                            triggeringReceiptId.toString(),
                            "sourceType",
                            normalizedSource),
                    EVENT_SEGMENT_READY + ':' + segmentId + ':'
                            + triggeringReceiptId);
            return;
        }
        deliverAtomically(() -> {
            Map<String, Object> segment = one("""
                    SELECT s.segment_code, s.planned_qty,
                           s.plan_begin_date, s.plan_end_date,
                           p.bill_no AS plan_no, g.code AS goods
                    FROM production_execution_segments s
                    JOIN production_plans p ON p.id = s.plan_id
                    JOIN goods g ON g.id = s.product_goods_id
                    WHERE s.id = ? AND s.status = 'READY'
                      AND s.is_deleted = false
                    """, segmentId);
            if (segment == null) return;
            String sourceLabel = executionReadySourceLabel(normalizedSource);
            notifyRoles(
                    List.of("planner", "production"),
                    TYPE_TASK,
                    "待料子任务已齐套："
                            + str(segment.get("segment_code")),
                    sourceLabel + "后物料已重新核验并完整占用。生产计划 "
                            + str(segment.get("plan_no")) + "、产品 "
                            + str(segment.get("goods")) + "、数量 "
                            + qty(bd(segment.get("planned_qty")))
                            + " 已转为可生产，请安排派工；计划日期 "
                            + str(segment.get("plan_begin_date")) + " 至 "
                            + str(segment.get("plan_end_date")) + "。",
                    "/production/schedule");
        });
    }

    static String executionReadySourceLabel(String sourceType) {
        return switch (sourceType == null ? "" : sourceType.strip()) {
            case "PURCHASE" -> "采购到货";
            case "SUBCONTRACT" -> "委外回厂";
            case "MAKE" -> "自制件完工入库";
            case "MANUAL_RELEASE" -> "人工解除暂缓";
            default -> "物料状态变化";
        };
    }

    /** ⑤ 发货通知销售：出货单审核后，按订单聚合本次出货量。（出货单暂无物流单号字段，内容含单号/数量/仓库。） */
    public void notifyShipmentApproved(UUID shipmentId) {
        if (!isOutboxDelivery()) {
            outbox.publish(EVENT_SHIPMENT_APPROVED, "SALES_SHIPMENT", shipmentId, Map.of());
            return;
        }
        deliverAtomically(() -> {
            Map<String, Object> h = one("SELECT bill_no, warehouse_id FROM sales_shipments WHERE id = ?", shipmentId);
            if (h == null) return;
            String wh = oneStr("SELECT name FROM warehouses WHERE id = ?", h.get("warehouse_id"));
            Map<UUID, BigDecimal> byOrder = new LinkedHashMap<>();
            for (Map<String, Object> r : jdbc.queryForList("""
                    SELECT oi.order_id, SUM(si.qty) AS qty
                    FROM sales_shipment_items si
                    JOIN sales_order_items oi ON oi.id = si.order_item_id
                    WHERE si.shipment_id = ?
                    GROUP BY oi.order_id
                    """, shipmentId)) {
                byOrder.merge((UUID) r.get("order_id"), bd(r.get("qty")), BigDecimal::add);
            }
            for (var e : byOrder.entrySet()) {
                OrderRef o = orderRef(e.getKey());
                if (o == null) continue;
                notifyUser(o.ownerUserId(), TYPE_WORKFLOW,
                        "发货通知：" + o.billNo(),
                        "订单 " + o.billNo() + " 已发货 " + qty(e.getValue()) + "(出货单 " + str(h.get("bill_no"))
                                + (wh.isEmpty() ? "" : "，仓库 " + wh) + ")。",
                        "/sales/shipments/" + shipmentId);
            }
        });
    }

    /** ⑥ 驳回通知销售：仓库驳回出货单（草稿）后，按订单聚合缺口量。 */
    public void notifyShipmentRejected(UUID shipmentId, String reason) {
        if (!isOutboxDelivery()) {
            outbox.publish(EVENT_SHIPMENT_REJECTED, "SALES_SHIPMENT", shipmentId,
                    Map.of("reason", reason == null ? "" : reason));
            return;
        }
        deliverAtomically(() -> {
            String billNo = oneStr("SELECT bill_no FROM sales_shipments WHERE id = ?", shipmentId);
            for (Map<String, Object> r : jdbc.queryForList("""
                    SELECT oi.order_id, SUM(si.qty) AS qty
                    FROM sales_shipment_items si
                    JOIN sales_order_items oi ON oi.id = si.order_item_id
                    WHERE si.shipment_id = ? AND si.order_item_id IS NOT NULL
                    GROUP BY oi.order_id
                    """, shipmentId)) {
                OrderRef o = orderRef((UUID) r.get("order_id"));
                if (o == null) continue;
                notifyUser(o.ownerUserId(), TYPE_URGENT,
                        "出货驳回：" + o.billNo(),
                        "出货单 " + billNo + " 被仓库驳回(" + (reason == null || reason.isBlank() ? "备货异常" : reason)
                                + ")，订单 " + o.billNo() + " 缺口 " + qty(bd(r.get("qty")))
                                + " 已释放预留并回到调度待排产。",
                        "/sales/shipments/" + shipmentId);
            }
        });
    }

    /** ⑦ 取消确认：订单整单取消后，确认销售 + 通知调度不用排。 */
    public void notifyOrderCanceled(UUID orderId) {
        if (!isOutboxDelivery()) {
            outbox.publish(EVENT_ORDER_CANCELED, "SALES_ORDER", orderId, Map.of());
            return;
        }
        deliverAtomically(() -> {
            OrderRef o = orderRef(orderId);
            if (o == null) return;
            notifyUser(o.ownerUserId(), TYPE_WORKFLOW,
                    "取消确认：" + o.billNo(),
                    "订单 " + o.billNo() + " 已整单取消：销售库存预留已释放；"
                            + "系统已确认不存在待清理的排产、领料或完工承诺。",
                    o.route());
            notifyRoles(List.of("planner"), TYPE_WORKFLOW,
                    "订单取消·无需排产：" + o.billNo(),
                    "订单 " + o.billNo() + " 已取消且没有有效生产承诺，无需后续排产。",
                    o.route());
        });
    }

    /** ⑦.5 订单财务确认后通知计划员接手物料分析（V294 起由财务确认事件驱动，不在审核落点发）。 */
    public void notifyOrderApproved(UUID orderId) {
        if (!isOutboxDelivery()) {
            outbox.publish(EVENT_ORDER_APPROVED, "SALES_ORDER", orderId, Map.of());
            return;
        }
        deliverAtomically(() -> {
            OrderRef o = orderRef(orderId);
            if (o == null) return;
            Map<String, Object> agg = one("""
                    SELECT COUNT(*) AS lines,
                           MIN(COALESCE(i.deliver_date, oo.deliver_date)) AS deliver,
                           string_agg(DISTINCT g.code, ' / ') AS goods
                    FROM sales_order_items i
                    JOIN sales_orders oo ON oo.id = i.order_id
                    LEFT JOIN goods g ON g.id = i.goods_id
                    WHERE i.order_id = ? AND i.is_deleted = false
                    """, orderId);
            String lines = agg == null ? "?" : str(agg.get("lines"));
            Object d = agg == null ? null : agg.get("deliver");
            String deliver = d == null ? "未定" : d.toString();
            String goods = agg == null || agg.get("goods") == null ? "" : str(agg.get("goods"));
            notifyRoles(List.of("planner"), TYPE_TASK,
                    "新订单待物料分析：" + o.billNo(),
                    "订单 " + o.billNo() + " 已审核并通过财务确认，共 " + lines + " 行货品(" + goods
                            + ")待分析，最早交货日 " + deliver
                            + "。请先核对库存并按采购、委外、自制拆分需求，再下达生产计划。",
                    "/production/material-analysis");
        });
    }

    /** ⑦.6 订单审核后通知财务确认（V294 闸门：财务确认前计划部不可见该订单）。 */
    public void notifyOrderPendingFinanceConfirmation(UUID orderId) {
        if (!isOutboxDelivery()) {
            outbox.publish(EVENT_ORDER_PENDING_FINANCE, "SALES_ORDER", orderId, Map.of());
            return;
        }
        deliverAtomically(() -> {
            OrderRef o = orderRef(orderId);
            if (o == null) return;
            List<UUID> confirmers = salesOrderFinanceConfirmers.eligibleUserIds();
            for (UUID userId : confirmers) {
                sendToUser(userId, TYPE_APPROVAL,
                        "待财务确认：" + o.billNo(),
                        "销售订货单 " + o.billNo() + " 已审核，待财务确认；确认后计划部才可见并排产。",
                        "/finance/sales-order-confirmations");
            }
        });
    }

    /** ⑦.7 财务确认完成：经 outbox 转⑦.5 通知计划员（保留独立事件便于审计与重放）。 */
    public void notifyOrderFinanceConfirmed(UUID orderId) {
        if (!isOutboxDelivery()) {
            outbox.publish(EVENT_ORDER_FINANCE_CONFIRMED, "SALES_ORDER", orderId, Map.of());
            return;
        }
        notifyOrderApproved(orderId);
    }

    /** ⑦.8 财务驳回（V300）：通知归属销售修正——驳回原因直达，点通知跳订单详情处理。 */
    public void notifyOrderFinanceRejected(UUID orderId, String reason) {
        if (!isOutboxDelivery()) {
            outbox.publish(EVENT_ORDER_FINANCE_REJECTED, "SALES_ORDER", orderId,
                    Map.of("reason", reason == null ? "" : reason));
            return;
        }
        deliverAtomically(() -> {
            Map<String, Object> rejection = one("""
                    SELECT sales_order.bill_no,
                           sales_order.owner_employee_id,
                           sales_order.seller_id,
                           sales_order.finance_rejected_at,
                           COALESCE(reviewer.full_name, '财务人员') AS reviewer_name
                    FROM sales_orders sales_order
                    LEFT JOIN employees reviewer
                      ON reviewer.id = sales_order.finance_rejected_by
                    WHERE sales_order.id = ?
                    """, orderId);
            if (rejection == null) return;
            UUID ownerUserId = userIdOfEmployee(
                    (UUID) rejection.get("owner_employee_id"));
            if (ownerUserId == null) {
                ownerUserId = userIdOfEmployee((UUID) rejection.get("seller_id"));
            }
            if (ownerUserId == null) return;
            String billNo = str(rejection.get("bill_no"));
            String reviewerName = str(rejection.get("reviewer_name"));
            String rejectedAt = businessEventTime(
                    rejection.get("finance_rejected_at"));
            String why = reason == null || reason.isBlank() ? "未填写原因" : reason.trim();
            sendToUser(ownerUserId, TYPE_URGENT,
                    "订单被财务驳回：" + billNo,
                    "销售订货单 " + billNo + " 未通过财务确认，由财务 "
                            + (reviewerName.isBlank() ? "人员" : reviewerName)
                            + (rejectedAt.isBlank() ? "" : " 于 " + rejectedAt)
                            + " 驳回。驳回原因：" + why
                            + "。请修改订单并重新完成销售审核，系统会再次提交财务确认。",
                    "/sales/orders/" + orderId);
        });
    }

    /** ⑧ 延期预警（每日扫描调用）：交货 ≤3 天未结案订单，通知业务员 + 调度。 */
    public void notifyDeliveryDue(UUID orderId, long daysLeft) {
        if (!isOutboxDelivery()) {
            outbox.publish(EVENT_DELIVERY_DUE, "SALES_ORDER", orderId,
                    Map.of("daysLeft", daysLeft, "daily", false));
            return;
        }
        OrderRef o = orderRef(orderId);
        if (o == null) return;
        String when = daysLeft < 0 ? "已超期 " + (-daysLeft) + " 天"
                : daysLeft == 0 ? "今日交货" : "距交货 " + daysLeft + " 天";
        String title = "交货预警：" + o.billNo();
        String content = "订单 " + o.billNo() + " " + when + "，尚未结案，请跟进生产/发货进度。";
        Set<UUID> targets = new LinkedHashSet<>();
        if (o.ownerUserId() != null) targets.add(o.ownerUserId());
        targets.addAll(userRoleRepo.findUserIdsByRoleCode("planner"));
        for (UUID uid : targets) {
            // owner 跳订单详情跟进；planner 先到物料分析工作台查看待料缺口。
            String route = uid.equals(o.ownerUserId())
                    ? o.route() : "/production/material-analysis";
            if (uid.equals(o.ownerUserId())) {
                sendToUser(
                        uid,
                        TYPE_URGENT,
                        title,
                        content,
                        route,
                        null,
                        daysLeft < 0 ? "important" : "normal");
            } else {
                sendToUser(uid, TYPE_URGENT, title, content, route, null, "normal");
            }
        }
    }

    /** ⑧ 延期预警（调度器入口）：同一订单同一接收人同日只发一条（notices 标题+接收人+当日去重）。 */
    public void notifyDeliveryDueIfNotSentToday(UUID orderId, long daysLeft) {
        if (!isOutboxDelivery()) {
            outbox.publishOnce(EVENT_DELIVERY_DUE, "SALES_ORDER", orderId,
                    Map.of("daysLeft", daysLeft, "daily", true),
                    EVENT_DELIVERY_DUE + ':' + orderId + ':' + BusinessTime.today());
            return;
        }
        try {
            OrderRef o = orderRef(orderId);
            if (o == null) return;
            String title = "交货预警：" + o.billNo();
            Instant startOfToday = BusinessTime.startOfDayInstant(BusinessTime.today());
            String when = daysLeft < 0 ? "已超期 " + (-daysLeft) + " 天"
                    : daysLeft == 0 ? "今日交货" : "距交货 " + daysLeft + " 天";
            String content = "订单 " + o.billNo() + " " + when + "，尚未结案，请跟进生产/发货进度。";
            Set<UUID> targets = new LinkedHashSet<>();
            if (o.ownerUserId() != null) targets.add(o.ownerUserId());
            targets.addAll(userRoleRepo.findUserIdsByRoleCode("planner"));
            for (UUID uid : targets) {
                Boolean sent = jdbc.queryForObject(
                        "SELECT EXISTS(SELECT 1 FROM notices WHERE audience_user_id = ? AND title = ? AND published_at >= ?)",
                        Boolean.class, uid, title, startOfToday);
                if (Boolean.TRUE.equals(sent)) continue;
                String route = uid.equals(o.ownerUserId())
                        ? o.route() : "/production/material-analysis";
                if (uid.equals(o.ownerUserId())) {
                    sendToUser(
                            uid,
                            TYPE_URGENT,
                            title,
                            content,
                            route,
                            null,
                            daysLeft < 0 ? "important" : "normal");
                } else {
                    sendToUser(uid, TYPE_URGENT, title, content, route, null, "normal");
                }
            }
        } catch (Exception error) {
            throw new IllegalStateException("Failed to deliver due-date warning for " + orderId, error);
        }
    }

    /**
     * ⑨ 预留持有逾期（即时）：订单有生效预留且持有截止已过、仍未发完，通知归属销售跟进发货或释放。
     * 持有截止 = COALESCE(预留 hold_until, 订单交货日 + 宽限期)；与延期预警(⑧ 交货前)互补、不重叠。
     */
    public void notifyReservationHoldOverdue(UUID orderId, long overdueDays) {
        if (!isOutboxDelivery()) {
            outbox.publish(EVENT_RESERVATION_HOLD_OVERDUE, "SALES_ORDER", orderId,
                    Map.of("overdueDays", overdueDays, "daily", false));
            return;
        }
        sendHoldOverdueNotice(orderId, overdueDays);
    }

    /** ⑨ 预留持有逾期（调度器入口）：同一订单同一接收人同日只发一条（notices 标题+接收人+当日去重）。 */
    public void notifyReservationHoldOverdueIfNotSentToday(UUID orderId, long overdueDays) {
        if (!isOutboxDelivery()) {
            outbox.publishOnce(EVENT_RESERVATION_HOLD_OVERDUE, "SALES_ORDER", orderId,
                    Map.of("overdueDays", overdueDays, "daily", true),
                    EVENT_RESERVATION_HOLD_OVERDUE + ':' + orderId + ':' + BusinessTime.today());
            return;
        }
        try {
            OrderRef o = orderRef(orderId);
            if (o == null || o.ownerUserId() == null) return;
            String title = "预留持有逾期：" + o.billNo();
            Instant startOfToday = BusinessTime.startOfDayInstant(BusinessTime.today());
            Boolean sent = jdbc.queryForObject(
                    "SELECT EXISTS(SELECT 1 FROM notices WHERE audience_user_id = ? AND title = ? AND published_at >= ?)",
                    Boolean.class, o.ownerUserId(), title, startOfToday);
            if (Boolean.TRUE.equals(sent)) return;
            sendHoldOverdueNotice(orderId, overdueDays);
        } catch (Exception error) {
            throw new IllegalStateException("Failed to deliver hold-overdue notice for " + orderId, error);
        }
    }

    private void sendHoldOverdueNotice(UUID orderId, long overdueDays) {
        OrderRef o = orderRef(orderId);
        if (o == null || o.ownerUserId() == null) return;
        String title = "预留持有逾期：" + o.billNo();
        String content = "订单 " + o.billNo() + " 的现货预留已过持有截止"
                + (overdueDays <= 0 ? "" : " " + overdueDays + " 天")
                + "，仍未发货。请尽快安排出货；若客户暂不需要，请改量或取消以释放库存，"
                + "或由主管做稀缺让单重排。长期不处理将影响可承诺量。";
        sendToUser(
                o.ownerUserId(),
                TYPE_URGENT,
                title,
                content,
                o.route(),
                null,
                "important");
    }

    /**
     * ⑩ 让单通知：低优先级订单行的预留被主管让单重排后，通知其归属销售——
     * 库存已被高优先级急单调用，其缺口已自动回到调度待排产（将转生产补足）。
     */
    public void notifyReservationYielded(UUID orderItemId, String qtyText, String reason, String yielderOrderNo) {
        if (!isOutboxDelivery()) {
            outbox.publish(EVENT_RESERVATION_YIELDED, "SALES_ORDER_ITEM", orderItemId, Map.of(
                    "qty", qtyText == null ? "" : qtyText,
                    "reason", reason == null ? "" : reason,
                    "yielderOrderNo", yielderOrderNo == null ? "" : yielderOrderNo));
            return;
        }
        Map<String, Object> row = one("""
                SELECT o.id AS order_id, o.bill_no, g.code AS goods
                FROM sales_order_items i
                JOIN sales_orders o ON o.id = i.order_id
                LEFT JOIN goods g ON g.id = i.goods_id
                WHERE i.id = ?
                """, orderItemId);
        if (row == null) return;
        OrderRef o = orderRef((UUID) row.get("order_id"));
        if (o == null) return;
        String why = reason == null || reason.isBlank() ? "急单优先" : reason.trim();
        sendToUser(o.ownerUserId(), TYPE_URGENT,
                "库存被让单重排：" + o.billNo(),
                "订单 " + o.billNo() + " 货品 " + str(row.get("goods")) + " 的现货预留 "
                        + (qtyText == null || qtyText.isBlank() ? "" : qtyText + " ")
                        + "已被主管让单给" + (yielderOrderNo == null || yielderOrderNo.isBlank() ? "急单" : "订单 " + yielderOrderNo)
                        + "(原因：" + why + ")。缺口已自动回到调度待排产，将转生产补足，进度会在排产后更新。",
                o.route(), null, "important");
    }

    private void notifyProcurementFinanceEvent(
            String eventType, UUID approvalCaseId) {
        deliverAtomically(() -> {
            Map<String, Object> approval = one("""
                    SELECT approval_case.bill_no_snapshot,
                           approval_case.amount_snapshot,
                           approval_case.order_type,
                           approval_case.order_id,
                           approval_case.assignee_user_id,
                           approval_case.submitted_by_user_id,
                           approval_case.rejection_reason,
                           approval_case.decided_at,
                           COALESCE(decider.full_name, '财务人员') AS reviewer_name,
                           expectation.expected_date,
                           warehouse.name AS warehouse_name
                    FROM procurement_order_approval_cases approval_case
                    LEFT JOIN employees decider
                      ON decider.id = approval_case.decided_by_employee_id
                    LEFT JOIN inbound_expectations expectation
                      ON expectation.approval_case_id = approval_case.id
                    LEFT JOIN warehouses warehouse
                      ON warehouse.id = expectation.warehouse_id
                    WHERE approval_case.id = ?
                    """, approvalCaseId);
            if (approval == null) {
                return;
            }
            String billNo = str(approval.get("bill_no_snapshot"));
            String orderLabel = "SUBCONTRACT".equals(
                    str(approval.get("order_type")))
                    ? "委外订货单"
                    : "采购订货单";
            if (EVENT_PROCUREMENT_FINANCE_SUBMITTED.equals(eventType)) {
                String title = "待财务审核：" + billNo;
                String content = orderLabel + " " + billNo + " 已提交财务审核，金额 "
                        + str(approval.get("amount_snapshot"))
                        + "。请到钱流管理任务中心处理。";
                for (UUID reviewer : financeReviewerUserIds()) {
                    sendToUser(reviewer, TYPE_APPROVAL, title, content,
                            "/finance/procurement-approvals");
                }
                return;
            }
            if (EVENT_PROCUREMENT_FINANCE_REJECTED.equals(eventType)) {
                UUID orderId = (UUID) approval.get("order_id");
                String actionRoute = "SUBCONTRACT".equals(
                        str(approval.get("order_type")))
                        ? "/subcontract/orders/" + orderId
                        : "/purchase/orders/" + orderId;
                String reviewerName = str(approval.get("reviewer_name"));
                String decidedAt = businessEventTime(approval.get("decided_at"));
                notifyUser(
                        (UUID) approval.get("submitted_by_user_id"),
                        TYPE_URGENT,
                        "财务驳回：" + billNo,
                        orderLabel + " " + billNo + " 未通过财务审核，由财务 "
                                + (reviewerName.isBlank() ? "人员" : reviewerName)
                                + (decidedAt.isBlank() ? "" : " 于 " + decidedAt)
                                + " 驳回。原因："
                                + str(approval.get("rejection_reason"))
                                + "。请修改后重新提交。",
                        actionRoute);
                return;
            }
            notifyUser(
                    (UUID) approval.get("submitted_by_user_id"),
                    TYPE_WORKFLOW,
                    "财务通过：" + billNo,
                    orderLabel + " " + billNo
                            + " 已通过财务审核并正式生效，仓储部已收到预计到货提醒。",
                    "/finance/procurement-approvals");
            String warehouseName = str(approval.get("warehouse_name"));
            String expectedDate = str(approval.get("expected_date"));
            for (UUID warehouseUser : departmentUserIds("SUB_WH")) {
                sendToUser(
                        warehouseUser,
                        TYPE_TASK,
                        "预计到货：" + billNo,
                        orderLabel + " " + billNo + " 已生效"
                                + (warehouseName.isBlank()
                                        ? ""
                                        : "，目标仓库 " + warehouseName)
                                + (expectedDate.isBlank()
                                        ? ""
                                        : "，预计日期 " + expectedDate)
                                + "。请在仓库预计到货队列跟进。",
                        "/warehouse/inbound/expectations");
            }
        });
    }

    private void notifyProcurementArrivalEvent(String eventType, UUID exceptionId) {
        deliverAtomically(() -> {
            Map<String, Object> arrival = one("""
                    SELECT exception.order_type,
                           exception.receipt_bill_no_snapshot,
                           exception.order_bill_no_snapshot,
                           exception.owner_user_id,
                           exception.finance_assignee_user_id,
                           exception.declared_qty,
                           exception.approved_remaining_qty,
                           exception.approved_excess_qty,
                           exception.accepted_qty,
                           exception.unaccepted_qty,
                           exception.status,
                           exception.decision,
                           exception.finance_reason,
                           return_task.qty AS return_qty,
                           return_task.status AS return_status
                    FROM procurement_arrival_exceptions exception
                    LEFT JOIN supplier_return_tasks return_task
                      ON return_task.arrival_exception_id = exception.id
                    WHERE exception.id = ?
                    """, exceptionId);
            if (arrival == null) return;
            UUID ownerUser = (UUID) arrival.get("owner_user_id");
            String orderNo = str(arrival.get("order_bill_no_snapshot"));
            String receiptNo = str(arrival.get("receipt_bill_no_snapshot"));
            String orderLabel = "SUBCONTRACT".equals(str(arrival.get("order_type")))
                    ? "委外订货单" : "采购订货单";

            if (EVENT_PROCUREMENT_ARRIVAL_DETECTED.equals(eventType)) {
                String title = "到货超量待财务审核：" + orderNo;
                String content = "收货单 " + receiptNo + " 的实际到货量 "
                        + str(arrival.get("declared_qty"))
                        + " 超过当前财务批准剩余可收量 "
                        + str(arrival.get("approved_remaining_qty"))
                        + "。本次未入库、未立应付；请财务持权人员到仓库到货异常任务中心审核。";
                UUID assignee = (UUID) arrival.get("finance_assignee_user_id");
                Set<UUID> reviewers = new LinkedHashSet<>(financeReviewerUserIds());
                if (assignee != null) {
                    sendToUser(assignee, TYPE_URGENT, title, content,
                            "/finance/procurement-arrival-exceptions");
                    reviewers.remove(assignee);
                }
                for (UUID reviewer : reviewers) {
                    sendToUser(reviewer, TYPE_URGENT, title, content,
                            "/finance/procurement-arrival-exceptions", null, "normal");
                }
                return;
            }
            if (EVENT_PROCUREMENT_RETURN_REQUIRED.equals(eventType)) {
                String returnQty = str(arrival.get("return_qty"));
                notifyUser(ownerUser, TYPE_TASK,
                        "供应商退回任务：" + orderNo,
                        orderLabel + " " + orderNo + " 的未接收数量 "
                                + returnQty
                                + " 已形成持久任务。请完成实物退回后在本人任务中确认；通知不能代替任务台账。",
                        "/procurement/arrival-exceptions");
                // 部门广播：让采购/委外整组知晓有一笔退回任务已分配（委外单也归采购部管）。
                broadcastToPurchaseDept(ownerUser, TYPE_TASK, "供应商退回任务：" + orderNo,
                        orderLabel + " " + orderNo + " 有未接收数量 " + returnQty
                                + " 待退回，请跟进实物退回。",
                        "/procurement/arrival-exceptions");
                return;
            }
            if (EVENT_PROCUREMENT_ARRIVAL_RECEIPT_POSTED.equals(eventType)) {
                // 仓库一键入库后、本异常仍有待退量 → 通知采购/委外安排退回。
                String acceptedQty = str(arrival.get("accepted_qty"));
                String unacceptedQty = str(arrival.get("unaccepted_qty"));
                String content = orderLabel + " " + orderNo + " 的收货单 " + receiptNo
                        + " 已按财务批准量入库 " + acceptedQty
                        + "，未接收 " + unacceptedQty
                        + " 待退回供应商/委外商。请尽快安排实物退回。";
                // 原下单人须在本人任务确认退回；部门内其他人广播知会（去重避免重复通知）。
                notifyUser(ownerUser, TYPE_TASK, "到货已入库，余量待退：" + orderNo,
                        content, "/procurement/arrival-exceptions");
                broadcastToPurchaseDept(ownerUser, TYPE_TASK,
                        "到货已入库，余量待退：" + orderNo, content,
                        "/procurement/arrival-exceptions");
                return;
            }
            if (EVENT_PROCUREMENT_RETURN_COMPLETED.equals(eventType)) {
                notifyUser(ownerUser, TYPE_WORKFLOW,
                        "供应商退回已登记：" + orderNo,
                        orderLabel + " " + orderNo + " 的供应商退回任务已登记完成。",
                        "/procurement/arrival-exceptions");
                return;
            }

            BigDecimal accepted = bd(arrival.get("accepted_qty"));
            for (UUID warehouseUser : departmentUserIds("SUB_WH")) {
                if (accepted.signum() > 0) {
                    sendToUser(warehouseUser, TYPE_TASK,
                            "到货数量已由财务审核：" + orderNo,
                            "财务批准本行接收 " + str(arrival.get("accepted_qty"))
                                    + "，未接收 " + str(arrival.get("unaccepted_qty"))
                                    + "，批准额外超量 "
                                    + str(arrival.get("approved_excess_qty"))
                                    + "。收货草稿已由服务端调整，请重新核对并审核；不得按原申报量入库。",
                            "/warehouse/inbound/arrival-exceptions");
                } else {
                    sendToUser(warehouseUser, TYPE_WORKFLOW,
                            "到货超量已由财务拒绝：" + orderNo,
                            "财务未批准收货单 " + receiptNo
                                    + " 的该行接收，收货草稿行已移除；未接收数量 "
                                    + str(arrival.get("unaccepted_qty"))
                                    + " 已转原下单人处理供应商退回。",
                            "/warehouse/inbound/arrival-exceptions");
                }
            }
        });
    }

    /**
     * 广播到采购部（SUB_PURCHASE，委外单也归采购部管）相关人员，跳过 excludeUser 避免与
     * 原下单人的定向通知重复；停用/已删除账号由 sendToUser 内部跳过。
     */
    private void broadcastToPurchaseDept(UUID excludeUser, String type,
                                         String title, String content, String route) {
        for (UUID uid : departmentUserIds("SUB_PURCHASE")) {
            if (excludeUser != null && excludeUser.equals(uid)) continue;
            sendToUser(uid, type, title, content, route, null, "normal");
        }
    }

    // ---------- 接收人解析与发送 ----------

    /** 订单快照：id + 单号 + 归属销售的用户账号（owner_employee_id 优先，回退 seller_id）。 */
    private OrderRef orderRef(UUID orderId) {
        Map<String, Object> r = one(
                "SELECT bill_no, owner_employee_id, seller_id FROM sales_orders WHERE id = ?", orderId);
        if (r == null) return null;
        UUID userId = userIdOfEmployee((UUID) r.get("owner_employee_id"));
        if (userId == null) userId = userIdOfEmployee((UUID) r.get("seller_id"));
        return new OrderRef(orderId, str(r.get("bill_no")), userId);
    }

    private record OrderRef(UUID orderId, String billNo, UUID ownerUserId) {
        /** 订单详情页路由（问题 #12：通知点击跳源单据）。 */
        String route() {
            return "/sales/orders/" + orderId;
        }
    }

    /** 员工 → 活跃账号（无账号/已停用/已删除 → null，静默跳过）。 */
    private UUID userIdOfEmployee(UUID employeeId) {
        if (employeeId == null) return null;
        return userRepo.findByEmployeeId(employeeId)
                .filter(u -> "active".equals(u.getStatus()) && !u.isDeleted())
                .map(UserAccount::getId)
                .orElse(null);
    }

    private void notifyUser(UUID userId, String type, String title, String content) {
        notifyUser(userId, type, title, content, null, null);
    }

    /** 带跳转入口的定向通知（问题 #12：点排产/发货等通知能跳到对应单据）。 */
    private void notifyUser(UUID userId, String type, String title, String content, String actionRoute) {
        notifyUser(userId, type, title, content, actionRoute, null);
    }

    /** 带事件来源标记的定向通知：sourceEvent 写入 notices.source_event，供按事件统计未读徽章。 */
    private void notifyUser(UUID userId, String type, String title, String content,
                            String actionRoute, String sourceEvent) {
        if (userId == null) return;
        sendToUser(userId, type, title, content, actionRoute, sourceEvent);
    }

    private void notifyRoles(List<String> roleCodes, String type, String title, String content) {
        notifyRoles(roleCodes, type, title, content, null);
    }

    private void notifyRoles(
            List<String> roleCodes, String type, String title, String content, String actionRoute) {
        Set<UUID> targets = new LinkedHashSet<>();
        for (String code : roleCodes) {
            targets.addAll(userRoleRepo.findUserIdsByRoleCode(code));
            String departmentCode = switch (code) {
                case "buyer" -> "SUB_PURCHASE";
                case "planner" -> "SUB_PLAN";
                case "production" -> "DEPT_PROD";
                default -> null;
            };
            if (departmentCode != null) {
                targets.addAll(departmentUserIds(departmentCode));
            }
        }
        for (UUID uid : targets) {
            // 角色/部门池是公共任务广播，即使事件本身重要，也不得阻塞每个成员。
            sendToUser(uid, type, title, content, actionRoute, null, "normal");
        }
    }

    /**
     * 物料分析生成采购/委外申请后的办理人池。
     *
     * <p>候选仍沿用迁移期 buyer 角色 + 采购部子树，但最终必须同时拥有通知读取权和
     * 目标申请查看权。这样个人 revoke 后不会继续收到包含物料、数量和单号的通知，
     * 角色与部门重复命中仍只生成一条定向通知。
     */
    private void notifyPreplanSupplyRecipients(
            String type,
            String title,
            String content,
            String actionRoute,
            String requiredViewAuthority) {
        Set<UUID> candidates = new LinkedHashSet<>();
        candidates.addAll(userRoleRepo.findUserIdsByRoleCode("buyer"));
        candidates.addAll(departmentUserIds("SUB_PURCHASE"));
        for (UUID userId : candidates) {
            UserAccount account = userRepo.findById(userId).orElse(null);
            if (account == null
                    || account.isDeleted()
                    || !"active".equals(account.getStatus())) {
                continue;
            }
            Set<String> authorities = permissionResolver.permsOf(account);
            if (!authorities.contains(NOTICE_READ_AUTHORITY)
                    || !authorities.contains(requiredViewAuthority)) {
                continue;
            }
            sendToUser(userId, type, title, content, actionRoute);
        }
    }

    /**
     * Operational recipients follow the current department-permission model.
     * Legacy role lookup remains above for migrated accounts, while this query
     * covers the selected department and all active descendants.
     */
    private List<UUID> departmentUserIds(String departmentCode) {
        return jdbc.queryForList("""
                WITH RECURSIVE subtree(id) AS (
                    SELECT id
                    FROM departments
                    WHERE code = ? AND is_deleted = false
                    UNION ALL
                    SELECT child.id
                    FROM departments child
                    JOIN subtree parent ON child.parent_id = parent.id
                    WHERE child.is_deleted = false
                )
                SELECT DISTINCT user_account.id
                FROM users user_account
                JOIN employees employee
                  ON employee.id = user_account.employee_id
                WHERE employee.department_id IN (SELECT id FROM subtree)
                  AND employee.is_deleted = false
                  AND employee.status <> 'resigned'
                  AND user_account.is_deleted = false
                  AND user_account.status = 'active'
                ORDER BY user_account.id
                """, UUID.class, departmentCode);
    }

    /**
     * 品质待检通知池：只允许品质部子树内当前在职、账号启用的用户，并以服务端有效权限
     * 再次复核查看权。PMC/生产部门的默认查看权、跨部门个人加授和超管全集均不扩张此池。
     */
    private List<UUID> qualityInspectionViewerUserIds() {
        List<UUID> qualityCandidates = jdbc.queryForList("""
                WITH RECURSIVE quality_departments(id) AS (
                    SELECT id
                    FROM departments
                    WHERE code = 'DEPT_QA' AND is_deleted = FALSE
                    UNION ALL
                    SELECT child.id
                    FROM departments child
                    JOIN quality_departments parent ON child.parent_id = parent.id
                    WHERE child.is_deleted = FALSE
                )
                SELECT DISTINCT user_account.id
                FROM users user_account
                JOIN employees employee
                  ON employee.id = user_account.employee_id
                WHERE employee.department_id IN (SELECT id FROM quality_departments)
                  AND employee.is_deleted = FALSE
                  AND employee.status IN ('active', 'probation', 'onLeave')
                  AND user_account.is_deleted = FALSE
                  AND user_account.status = 'active'
                ORDER BY user_account.id
                """, UUID.class);
        return qualityCandidates.stream()
                .filter(userId -> userRepo.findById(userId)
                        .filter(account -> !account.isDeleted()
                                && "active".equals(account.getStatus()))
                        .map(permissionResolver::permsOf)
                        .map(permissions -> permissions.contains(IQC_VIEW_AUTHORITY))
                        .orElse(false))
                .toList();
    }

    /**
     * 当前可审批财务任务的接收人池：财务部门树内在职、账号启用且持有
     * finance_order_approval:approve 或 :reject 的全部合格用户（ADR-027 审核组模型）。
     */
    private List<UUID> financeReviewerUserIds() {
        return financeReviewerEligibility.allEligible().stream()
                .map(FinanceReviewerEligibilityPort.EligibleFinanceReviewer::userId)
                .toList();
    }

    /** 部门树候选与当前有效权限求交，个人 revoke 后不会继续收到业务详情。 */
    private List<UUID> departmentUserIdsWithAuthority(
            String departmentCode, String authority) {
        return departmentUserIds(departmentCode).stream()
                .filter(userId -> userRepo.findById(userId)
                        .filter(account -> !account.isDeleted()
                                && "active".equals(account.getStatus()))
                        .map(permissionResolver::permsOf)
                        .map(permissions -> permissions.contains(authority))
                        .orElse(false))
                .toList();
    }

    private void sendToUser(UUID userId, String type, String title, String content) {
        sendToUser(userId, type, title, content, null, null);
    }

    /** 停用/删除账号跳过；写入失败交给 Outbox 整体回滚重试。 */
    private void sendToUser(UUID userId, String type, String title, String content, String actionRoute) {
        sendToUser(userId, type, title, content, actionRoute, null);
    }

    private void sendToUser(UUID userId, String type, String title, String content,
                            String actionRoute, String sourceEvent) {
        sendToUser(userId, type, title, content, actionRoute, sourceEvent, null);
    }

    private void sendToUser(UUID userId, String type, String title, String content,
                            String actionRoute, String sourceEvent,
                            String explicitPriority) {
        UserAccount u = userRepo.findById(userId).orElse(null);
        if (u == null || !"active".equals(u.getStatus()) || u.isDeleted()) return;
        String effectiveSourceEvent = sourceEvent;
        if (effectiveSourceEvent == null || effectiveSourceEvent.isBlank()) {
            effectiveSourceEvent = OUTBOX_EVENT.get();
        }
        if (explicitPriority == null) {
            noticeService.publishForUser(
                    userId,
                    title,
                    content,
                    type,
                    PUBLISHER,
                    actionRoute,
                    effectiveSourceEvent);
        } else {
            noticeService.publishForUser(
                    userId,
                    title,
                    content,
                    type,
                    PUBLISHER,
                    actionRoute,
                    effectiveSourceEvent,
                    explicitPriority);
        }
    }

    // ---------- 研发任务 / BOM 维护 通知 ----------

    /** BOM 维护完成（GoodsBomService create/update/delete 后发）：若 BOM 已就绪，自动完成对应未完成 BOM 任务 + 通知生产转发人。 */
    public void notifyBomUpdated(UUID goodsId) {
        deliverAtomically(() -> {
            // 删除清空 BOM 时不应误完成——仅当确实已有可用 BOM 行才处理。
            Integer ready = jdbc.queryForObject(
                    "SELECT COUNT(*) FROM goods_bom_items WHERE goods_id = ? AND is_deleted = false",
                    Integer.class, goodsId);
            if (ready == null || ready == 0) return;
            List<UUID> reporters = rdTaskService.openBomTaskReporters(goodsId);
            int updated = rdTaskService.resolveOpenBomTasksForGoods(goodsId, "BOM已维护，自动完成");
            if (updated == 0) return;
            String goodsLabel = oneStr(
                    "SELECT COALESCE(code,'') || ' ' || COALESCE(name,'') FROM goods WHERE id = ?",
                    goodsId);
            for (UUID empId : reporters) {
                UUID uid = userIdOfEmployee(empId);
                if (uid != null) {
                    sendToUser(uid, TYPE_TASK,
                            "BOM 已维护：" + goodsLabel,
                            "工程研发部已维护该货品的组装物料，可继续排产。",
                            "/production/schedule");
                }
            }
        });
    }

    /** 研发任务手动完成（RdTaskService.resolve 发）：通知制单人/转发人。 */
    public void notifyRdTaskResolved(UUID taskId) {
        deliverAtomically(() -> {
            Map<String, Object> t = one("""
                    SELECT r.title, r.reporter_employee_id,
                           g.code AS goods_code, g.name AS goods_name
                    FROM rd_tasks r LEFT JOIN goods g ON g.id = r.goods_id
                    WHERE r.id = ? AND r.is_deleted = false
                    """, taskId);
            if (t == null) return;
            UUID uid = userIdOfEmployee((UUID) t.get("reporter_employee_id"));
            if (uid == null) return;
            String goodsLabel = str(t.get("goods_code")) + " " + str(t.get("goods_name"));
            sendToUser(uid, TYPE_TASK,
                    "研发任务已完成：" + goodsLabel,
                    "工程研发部已标记完成：" + str(t.get("title"))
                            + "。若为 BOM 维护任务，可继续排产。",
                    "/production/schedule");
        });
    }

    // ---------- Outbox 原子送达 ----------

    /** 只允许已锁定 Outbox 事件的处理事务执行真实通知写入。 */
    private void deliverAtomically(Runnable task) {
        if (!isOutboxDelivery()) {
            throw new IllegalStateException("Notice delivery must be invoked by the outbox processor");
        }
        task.run();
    }

    private boolean isOutboxDelivery() {
        return Boolean.TRUE.equals(OUTBOX_DELIVERY.get());
    }

    // ---------- 查询小工具 ----------

    private Map<String, Object> one(String sql, Object... args) {
        List<Map<String, Object>> rows = jdbc.queryForList(sql, args);
        return rows.isEmpty() ? null : rows.get(0);
    }

    private static String str(Object v) {
        return v == null ? "" : v.toString();
    }

    /** 将持久化的业务发生时间统一展示为 Asia/Shanghai，而不是通知异步投递时间。 */
    private static String businessEventTime(Object value) {
        if (value instanceof OffsetDateTime time) {
            return EVENT_TIME_FORMAT.format(time.atZoneSameInstant(BusinessTime.ZONE));
        }
        if (value instanceof Instant time) {
            return EVENT_TIME_FORMAT.format(time.atZone(BusinessTime.ZONE));
        }
        if (value instanceof java.sql.Timestamp time) {
            return EVENT_TIME_FORMAT.format(time.toInstant().atZone(BusinessTime.ZONE));
        }
        return str(value);
    }

    /**
     * 单值查询：SQL 只投影一列时取该列的值。{@link #one} 返回整行 {@code Map<String,Object>}，
     * 之前多处直接 {@code str(one(...))} 把整行 Map 的 toString()（如 {@code {bill_no=SJ26080016}}）
     * 拼进通知文案，用户能在通知卡片里看到裸的字段名（问题 #12）；改用本方法只取列值。
     */
    private String oneStr(String sql, Object... args) {
        Map<String, Object> row = one(sql, args);
        if (row == null || row.isEmpty()) return "";
        return str(row.values().iterator().next());
    }

    private static BigDecimal bd(Object v) {
        return v instanceof BigDecimal b ? b : BigDecimal.ZERO;
    }

    private static BigDecimal decimal(String value) {
        try {
            return value == null || value.isBlank()
                    ? BigDecimal.ZERO : new BigDecimal(value);
        } catch (NumberFormatException ignored) {
            return BigDecimal.ZERO;
        }
    }

    private static UUID uuidOrNull(String value) {
        try {
            return value == null || value.isBlank()
                    ? null : UUID.fromString(value);
        } catch (IllegalArgumentException ignored) {
            return null;
        }
    }

    private static String qty(BigDecimal v) {
        return v.stripTrailingZeros().toPlainString();
    }

    private record FinishedInboundSnapshot(
            UUID orderId,
            String orderBillNo,
            String documentNo,
            String goods,
            BigDecimal batchQty,
            BigDecimal producedQty,
            BigDecimal orderQty,
            String shipmentPolicy) {
        Map<String, String> payload() {
            return Map.of(
                    "orderId", orderId.toString(),
                    "orderBillNo", orderBillNo,
                    "documentNo", documentNo,
                    "goods", goods,
                    "batchQty", qty(batchQty),
                    "producedQty", qty(producedQty),
                    "orderQty", qty(orderQty),
                    "shipmentPolicy", shipmentPolicy);
        }
    }
}

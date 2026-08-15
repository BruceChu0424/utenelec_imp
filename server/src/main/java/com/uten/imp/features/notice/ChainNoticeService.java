package com.uten.imp.features.notice;

import com.fasterxml.jackson.databind.JsonNode;
import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.application.port.FinanceReviewerEligibilityPort;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.features.rbac.UserRoleRepository;
import com.uten.imp.features.rd_task.RdTaskService;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;

import java.math.BigDecimal;
import java.time.Instant;
import java.time.LocalDate;
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
    static final String EVENT_REMAKE_CREATED = "PRODUCTION_REMAKE_CREATED";
    static final String EVENT_SEGMENT_READY = "PRODUCTION_SEGMENT_READY";
    static final String EVENT_SEGMENT_DISPATCHED = "PRODUCTION_SEGMENT_DISPATCHED";
    static final String EVENT_SEGMENT_STARTED = "PRODUCTION_SEGMENT_STARTED";
    static final String EVENT_SHIPMENT_APPROVED = "SALES_SHIPMENT_APPROVED";
    static final String EVENT_SHIPMENT_PENDING_PICK =
            "SALES_SHIPMENT_PENDING_PICK";
    static final String EVENT_SHIPMENT_REJECTED = "SALES_SHIPMENT_REJECTED";
    static final String EVENT_MATERIAL_ANALYSIS_READY =
            "PRODUCTION_MATERIAL_ANALYSIS_READY";
    static final String EVENT_ORDER_CANCELED = "SALES_ORDER_CANCELED";
    static final String EVENT_ORDER_APPROVED = "SALES_ORDER_APPROVED";
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
    static final String EVENT_RD_TASK_FORWARDED = "RD_TASK_FORWARDED";
    static final String EVENT_RD_TASK_RESOLVED = "RD_TASK_RESOLVED";
    private static final ThreadLocal<Boolean> OUTBOX_DELIVERY =
            ThreadLocal.withInitial(() -> false);


    private final NoticeService noticeService;
    private final UserAccountRepository userRepo;
    private final UserRoleRepository userRoleRepo;
    private final JdbcTemplate jdbc;
    private final BusinessEventPublisher outbox;
    private final RdTaskService rdTaskService;
    private final FinanceReviewerEligibilityPort financeReviewerEligibility;

    public ChainNoticeService(NoticeService noticeService,
                              UserAccountRepository userRepo,
                              UserRoleRepository userRoleRepo,
                              JdbcTemplate jdbc,
                              BusinessEventPublisher outbox,
                              RdTaskService rdTaskService,
                              FinanceReviewerEligibilityPort financeReviewerEligibility) {
        this.noticeService = noticeService;
        this.userRepo = userRepo;
        this.userRoleRepo = userRoleRepo;
        this.jdbc = jdbc;
        this.outbox = outbox;
        this.rdTaskService = rdTaskService;
        this.financeReviewerEligibility = financeReviewerEligibility;
    }

    /** Called only by the locked outbox processor inside its delivery transaction. */
    public void deliverOutboxEvent(String eventType, UUID aggregateId, JsonNode payload) {
        OUTBOX_DELIVERY.set(true);
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
                case EVENT_MATERIAL_ANALYSIS_READY ->
                        deliverMaterialAnalysisReady(aggregateId, payload);
                case EVENT_ORDER_CANCELED -> notifyOrderCanceled(aggregateId);
                case EVENT_ORDER_APPROVED -> notifyOrderApproved(aggregateId);
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
                case EVENT_RD_TASK_FORWARDED -> notifyRdTaskForwarded(aggregateId);
                case EVENT_RD_TASK_RESOLVED -> notifyRdTaskResolved(aggregateId);
                case EVENT_BOM_UPDATED -> notifyBomUpdated(aggregateId);
                default -> throw new IllegalArgumentException(
                        "Unsupported business outbox event: " + eventType);
            }
        } finally {
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
                                + " 已排产 " + qty(e.getValue()) + "（计划单 " + planNo + "）。",
                        o.route());
                if (shortage) {
                    notifyUser(o.ownerUserId(), TYPE_URGENT,
                            "生产缺料：" + o.billNo(),
                            "订单 " + o.billNo() + " 的计划单 " + planNo
                                    + " 已核验存在及时物料缺口，采购/调度已收到处理任务；"
                                    + "销售端排产进度会随到料、开工和完工继续更新。",
                            o.route());
                }
            }
            if (shortage) {
                notifyRoles(List.of("buyer", "planner"), TYPE_TASK,
                        "缺料提醒：" + planNo,
                        "计划单 " + planNo + " 审核后 BOM 净需求不足（订单行状态=待物料），请采购/调度跟进备料。",
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
                        (reportedComplete ? "生产报工完成（待入库）：" : "生产进度更新：")
                                + order.billNo(),
                        "订单 " + order.billNo() + " 货品 " + str(r.get("goods"))
                                + " 的报工单 " + reportNo + " 已审核，累计合格 "
                                + qty(produced) + "/已排产 " + qty(planned)
                                + "（订单数量 " + qty(bd(r.get("order_qty"))) + "）。"
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
                        + allocation.goods() + " 已完成成品入库（入库单 "
                        + allocation.documentNo() + "）。" + availability
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
                    + (sourceNo.isBlank() ? "" : "（来源报工 " + sourceNo + "）")
                    + " 已生成并等待仓库审核"
                    + (warehouse.isBlank() ? "。" : "，目标仓库 " + warehouse + "。")
                    + "请核对实物、数量和库位后处理；通知不代替库存审核。";
            for (UUID warehouseUser : departmentUserIds("SUB_WH")) {
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
            String sourceDocumentId = payload.path("sourceDocumentId")
                    .asText("");
            notifyUser(
                    makerUserId,
                    TYPE_TASK,
                    "剩余物料已可下达：新增 " + qty(delta),
                    sourceLabel + "后，本物料分析新增可完工下达数量 "
                            + qty(delta) + "，当前累计可完工下达 "
                            + qty(readyQty)
                            + (sourceDocumentId.isBlank()
                                    ? "。"
                                    : "（来源单据 " + sourceDocumentId + "）。")
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
                                + "，已自动生成补产计划 " + str(r.get("plan_no")) + "（报工单 " + reportBillNo
                                + "），待调度审核排产。",
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
                                + "（计划 " + str(segment.get("plan_no"))
                                + "，子任务 " + str(segment.get("segment_code"))
                                + "，计划 " + begin + " 至 " + end + "）。",
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
                        "订单 " + o.billNo() + " 已发货 " + qty(e.getValue()) + "（出货单 " + str(h.get("bill_no"))
                                + (wh.isEmpty() ? "" : "，仓库 " + wh) + "）。",
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
                        "出货单 " + billNo + " 被仓库驳回（" + (reason == null || reason.isBlank() ? "备货异常" : reason)
                                + "），订单 " + o.billNo() + " 缺口 " + qty(bd(r.get("qty")))
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

    /** ⑦.5 新订单待物料分析：订单审核后通知计划员，但不在通知链创建分析事实。 */
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
                    "订单 " + o.billNo() + " 已审核，共 " + lines + " 行货品（" + goods
                            + "）待分析，最早交货日 " + deliver
                            + "。请先核对库存并按采购、委外、自制拆分需求，再下达生产计划。",
                    "/production/material-analysis");
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
            sendToUser(uid, TYPE_URGENT, title, content, route);
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
                sendToUser(uid, TYPE_URGENT, title, content, route);
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
        sendToUser(o.ownerUserId(), TYPE_URGENT, title, content, o.route());
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
        notifyUser(o.ownerUserId(), TYPE_URGENT,
                "库存被让单重排：" + o.billNo(),
                "订单 " + o.billNo() + " 货品 " + str(row.get("goods")) + " 的现货预留 "
                        + (qtyText == null || qtyText.isBlank() ? "" : qtyText + " ")
                        + "已被主管让单给" + (yielderOrderNo == null || yielderOrderNo.isBlank() ? "急单" : "订单 " + yielderOrderNo)
                        + "（原因：" + why + "）。缺口已自动回到调度待排产，将转生产补足，进度会在排产后更新。",
                o.route());
    }

    private void notifyProcurementFinanceEvent(
            String eventType, UUID approvalCaseId) {
        deliverAtomically(() -> {
            Map<String, Object> approval = one("""
                    SELECT approval_case.bill_no_snapshot,
                           approval_case.amount_snapshot,
                           approval_case.order_type,
                           approval_case.assignee_user_id,
                           approval_case.submitted_by_user_id,
                           approval_case.rejection_reason,
                           expectation.expected_date,
                           warehouse.name AS warehouse_name
                    FROM procurement_order_approval_cases approval_case
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
                notifyUser(
                        (UUID) approval.get("submitted_by_user_id"),
                        TYPE_URGENT,
                        "财务驳回：" + billNo,
                        orderLabel + " " + billNo + " 未通过财务审核。原因："
                                + str(approval.get("rejection_reason"))
                                + "。请修改后重新提交。",
                        "/finance/procurement-approvals");
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
                for (UUID reviewer : financeReviewerUserIds()) {
                    sendToUser(reviewer, TYPE_URGENT, title, content,
                            "/finance/procurement-arrival-exceptions");
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
            sendToUser(uid, type, title, content, route);
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
            sendToUser(uid, type, title, content, actionRoute);
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
     * 当前可审批财务任务的接收人池：财务部门树内在职、账号启用且持有
     * finance_order_approval:review 的全部用户（ADR-027 审核组模型）。
     */
    private List<UUID> financeReviewerUserIds() {
        return financeReviewerEligibility.allEligible().stream()
                .map(FinanceReviewerEligibilityPort.EligibleFinanceReviewer::userId)
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
        UserAccount u = userRepo.findById(userId).orElse(null);
        if (u == null || !"active".equals(u.getStatus()) || u.isDeleted()) return;
        noticeService.publishForUser(userId, title, content, type, PUBLISHER, actionRoute, sourceEvent);
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

    /** 生产转发 BOM 缺失（RdTaskService.forwardBomGap 发）：通知工程研发部（DEPT_ENG 子树）。 */
    public void notifyRdTaskForwarded(UUID taskId) {
        deliverAtomically(() -> {
            Map<String, Object> t = one("""
                    SELECT r.title, g.code AS goods_code, g.name AS goods_name
                    FROM rd_tasks r LEFT JOIN goods g ON g.id = r.goods_id
                    WHERE r.id = ? AND r.is_deleted = false
                    """, taskId);
            if (t == null) return;
            String goodsLabel = str(t.get("goods_code")) + " " + str(t.get("goods_name"));
            String title = "新 BOM 维护任务：" + goodsLabel;
            String content = "生产排产转发了该货品的 BOM 缺失请求：" + str(t.get("title"))
                    + "，请尽快维护组装物料。";
            for (UUID uid : departmentUserIds("DEPT_ENG")) {
                sendToUser(uid, TYPE_TASK, title, content, "/rd/tasks");
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

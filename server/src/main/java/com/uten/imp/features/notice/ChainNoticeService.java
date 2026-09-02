package com.uten.imp.features.notice;

import com.uten.imp.application.port.SubcontractChainNoticePort;
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
import java.time.temporal.ChronoUnit;
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
public class ChainNoticeService implements SubcontractChainNoticePort {

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
    static final String EVENT_PRODUCTION_FINISHED_ARRIVAL_PENDING =
            "PRODUCTION_FINISHED_ARRIVAL_PENDING";
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
    static final String EVENT_SHIPMENT_PENDING_FINANCE =
            "SALES_SHIPMENT_PENDING_FINANCE_AUDIT";
    static final String EVENT_SHIPMENT_PENDING_PICK =
            "SALES_SHIPMENT_PENDING_PICK";
    static final String EVENT_SHIPMENT_FINANCE_REVOKED =
            "SALES_SHIPMENT_FINANCE_RELEASE_REVOKED";
    static final String EVENT_SHIPMENT_REJECTED = "SALES_SHIPMENT_REJECTED";
    static final String EVENT_PREPLAN_SUPPLY_ACTION_CREATED =
            "PREPLAN_SUPPLY_ACTION_CREATED";
    static final String EVENT_SUBCONTRACT_PREPARATION_REQUIRED =
            "SUBCONTRACT_PREPARATION_REQUIRED";
    static final String EVENT_SUBCONTRACT_PREPARE_SHORTAGE =
            "SUBCONTRACT_PREPARE_SHORTAGE";
    static final String EVENT_SUBCONTRACT_MAKE_TASK_CREATED =
            "SUBCONTRACT_MAKE_TASK_CREATED";
    static final String EVENT_SUBCONTRACT_MAKE_NOTIFIED =
            "SUBCONTRACT_MAKE_NOTIFIED";
    static final String EVENT_SUBCONTRACT_OUTBOUND_READY =
            "SUBCONTRACT_OUTBOUND_READY";
    static final String EVENT_SUBCONTRACT_OUTBOUND_COMPLETED =
            "SUBCONTRACT_OUTBOUND_COMPLETED";
    static final String EVENT_SUBCONTRACT_OUTBOUND_REVERSED =
            "SUBCONTRACT_OUTBOUND_REVERSED";
    static final String EVENT_SUBCONTRACT_RETURN_DUE =
            "SUBCONTRACT_RETURN_DUE";
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
    /** V459 订单全部完工（累计成品入库 ≥ 订货量）→ 通知负责销售可发货。 */
    static final String EVENT_ORDER_FULLY_PRODUCED_READY_TO_SHIP =
            "SALES_ORDER_FULLY_PRODUCED_READY_TO_SHIP";
    static final String EVENT_IQC_RESOLVED = "PROCUREMENT_IQC_RESOLVED";
    static final String EVENT_IQC_STOCK_IN_PENDING =
            "PROCUREMENT_IQC_STOCK_IN_PENDING";
    static final String EVENT_SUBCONTRACT_LOSS_OPENED =
            "SUBCONTRACT_LOSS_CLAIM_OPENED";
    static final String EVENT_SUBCONTRACT_LOSS_DECIDED =
            "SUBCONTRACT_LOSS_CLAIM_DECIDED";
    static final String EVENT_SUBCONTRACT_LOSS_FULFILLED =
            "SUBCONTRACT_LOSS_CLAIM_FULFILLED";
    static final String EVENT_SUBCONTRACT_LOSS_REVERSED =
            "SUBCONTRACT_LOSS_CLAIM_REVERSED";
    static final String EVENT_PROCUREMENT_IQC_REJECTION_OPENED =
            "PROCUREMENT_IQC_REJECTION_OPENED";
    static final String EVENT_PROCUREMENT_IQC_REJECTION_DETECTED =
            "PROCUREMENT_IQC_REJECTION_DETECTED";
    static final String EVENT_PROCUREMENT_IQC_REJECTION_RETURNED =
            "PROCUREMENT_IQC_REJECTION_RETURNED";
    static final String EVENT_PROCUREMENT_IQC_CREDIT_CONFIRMED =
            "PROCUREMENT_IQC_CREDIT_CONFIRMED";
    static final String EVENT_PROCUREMENT_IQC_REJECTION_NO_CREDIT =
            "PROCUREMENT_IQC_REJECTION_NO_CREDIT";
    static final String EVENT_PROCUREMENT_IQC_REJECTION_REVERSED =
            "PROCUREMENT_IQC_REJECTION_REVERSED";
    static final String EVENT_PROCUREMENT_IQC_REJECTION_FINANCE_EXCEPTION =
            "PROCUREMENT_IQC_REJECTION_FINANCE_EXCEPTION";
    private static final String IQC_VIEW_AUTHORITY = "procurement_inspection:view";
    private static final String WAREHOUSE_IQC_STOCK_IN_VIEW_AUTHORITY =
            "warehouse_iqc_stock_in:view";
    private static final String NOTICE_READ_AUTHORITY = "notice:read";
    private static final String IQC_REJECTION_VIEW_AUTHORITY =
            "procurement_iqc_rejection:view";
    private static final String IQC_REJECTION_VIEW_ALL_AUTHORITY =
            "procurement_iqc_rejection:view_all";
    private static final String IQC_REJECTION_CONFIRM_CREDIT_AUTHORITY =
            "procurement_iqc_rejection:confirm_credit";
    private static final String IQC_REJECTION_RECORD_RETURN_AUTHORITY =
            "procurement_iqc_rejection:record_return";
    private static final String IQC_REJECTION_CLOSE_NO_CREDIT_AUTHORITY =
            "procurement_iqc_rejection:close_no_credit";
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
                case EVENT_PRODUCTION_FINISHED_ARRIVAL_PENDING ->
                        notifyProductionFinishedArrivalPending(aggregateId);
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
                case EVENT_SHIPMENT_PENDING_FINANCE ->
                        notifyShipmentPendingFinanceAudit(aggregateId);
                case EVENT_SHIPMENT_PENDING_PICK ->
                        notifyShipmentPendingPick(aggregateId);
                case EVENT_SHIPMENT_FINANCE_REVOKED ->
                        notifyShipmentFinanceReleaseRevoked(aggregateId);
                case EVENT_SHIPMENT_REJECTED ->
                        notifyShipmentRejected(aggregateId, payload.path("reason").asText(""));
                case EVENT_PREPLAN_SUPPLY_ACTION_CREATED ->
                        notifyPreplanSupplyActionCreated(aggregateId);
                case EVENT_SUBCONTRACT_PREPARATION_REQUIRED ->
                        notifySubcontractPreparationRequired(aggregateId);
                case EVENT_SUBCONTRACT_PREPARE_SHORTAGE ->
                        notifySubcontractPrepareShortage(aggregateId);
                case EVENT_SUBCONTRACT_MAKE_TASK_CREATED ->
                        notifySubcontractMakeTaskCreated(aggregateId);
                case EVENT_SUBCONTRACT_MAKE_NOTIFIED ->
                        notifySubcontractMakeNotified(aggregateId);
                case EVENT_SUBCONTRACT_OUTBOUND_READY ->
                        notifySubcontractOutboundReady(aggregateId);
                case EVENT_SUBCONTRACT_OUTBOUND_COMPLETED ->
                        notifySubcontractOutboundCompleted(aggregateId);
                case EVENT_SUBCONTRACT_OUTBOUND_REVERSED ->
                        notifySubcontractOutboundReversed(aggregateId);
                case EVENT_SUBCONTRACT_RETURN_DUE ->
                        notifySubcontractReturnDue(aggregateId);
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
                case EVENT_IQC_STOCK_IN_PENDING ->
                        notifyIqcStockInPendingForWarehouse(
                                aggregateId,
                                payload.path("receiptType").asText(""),
                                uuidOrNull(payload.path("receiptId").asText(null)));
                case EVENT_IQC_RESOLVED ->
                        notifyIqcResolvedForPutaway(
                                aggregateId, payload.path("receiptType").asText(""));
                case EVENT_SUBCONTRACT_LOSS_OPENED,
                     EVENT_SUBCONTRACT_LOSS_DECIDED,
                     EVENT_SUBCONTRACT_LOSS_FULFILLED,
                     EVENT_SUBCONTRACT_LOSS_REVERSED ->
                        notifySubcontractLossClaimEvent(eventType, aggregateId);
                case EVENT_PROCUREMENT_IQC_REJECTION_OPENED,
                     EVENT_PROCUREMENT_IQC_REJECTION_RETURNED,
                     EVENT_PROCUREMENT_IQC_CREDIT_CONFIRMED,
                     EVENT_PROCUREMENT_IQC_REJECTION_NO_CREDIT,
                     EVENT_PROCUREMENT_IQC_REJECTION_REVERSED,
                     EVENT_PROCUREMENT_IQC_REJECTION_FINANCE_EXCEPTION ->
                        notifyProcurementIqcRejectionEvent(eventType, aggregateId);
                case EVENT_PROCUREMENT_IQC_REJECTION_DETECTED -> {
                    // Internal projection trigger. The domain handler freezes
                    // the rejection case first and emits OPENED (or a safe
                    // FINANCE_EXCEPTION) afterwards; it must not notify twice.
                }
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
                        (reportedComplete
                                ? "生产报工完成(待仓库登记/质检/点收)："
                                : "生产进度更新：")
                                + order.billNo(),
                        "订单 " + order.billNo() + " 货品 " + str(r.get("goods"))
                                + " 的报工单 " + reportNo
                                + " 已审核，累计完工申报 "
                                + qty(produced) + "/已排产 " + qty(planned)
                                + "(订单数量 " + qty(bd(r.get("order_qty"))) + ")。"
                                + (reportedComplete
                                ? "等待仓库登记送检、品质放行和最终点收；"
                                + "只有最终点收增加可用库存并更新可发货状态。"
                                : ""),
                        order.route(), EVENT_PRODUCTION_REPORTED);
            }
        });
    }

    /** ②③ 完工/部分完工通知销售：仓库最终点收后，按本单补的预留溯源订单行。 */
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
                // V459 累计入库满足订货量 → 「全部完成生产，可以发货」审核卡
                // （归属人定向：仅负责销售本人；开立出货单后撤回）。
                if (allocation.orderQty().signum() > 0
                        && allocation.producedQty()
                                .compareTo(allocation.orderQty()) >= 0) {
                    notifyFullyProducedReadyToShip(order, orderNo);
                }
            }
        });
    }

    /**
     * V459 全部完工可发货（R12）：同一订单同事件存在未办结通知则不重发
     * （分批入库多次触发只有第一次生效；出货单开立或订单终态后撤回）。
     */
    private void notifyFullyProducedReadyToShip(OrderRef order, String orderNo) {
        Integer existing = jdbc.queryForObject("""
                SELECT COUNT(*) FROM notices
                WHERE source_event = ?
                  AND aggregate_kind = 'SALES_ORDER'
                  AND aggregate_id = ?
                  AND resolved_at IS NULL
                """, Integer.class,
                EVENT_ORDER_FULLY_PRODUCED_READY_TO_SHIP, order.orderId());
        if (existing != null && existing > 0) return;
        sendToUser(
                order.ownerUserId(),
                TYPE_TASK,
                "全部完成生产，可以发货：" + orderNo,
                "订单 " + orderNo + " 的累计成品入库已满足订货量，全部完成生产，"
                        + "可以发货。请及时开出货单；财务放行后仓库即可出库。",
                order.route(),
                EVENT_ORDER_FULLY_PRODUCED_READY_TO_SHIP,
                "important",
                order.orderId());
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

    /** 新执行段报工审核后，可靠投递仓库目标仓/库位送检登记待办。 */
    public void notifyProductionFinishedArrivalPending(UUID reportId) {
        Map<String, Object> report = pendingProductionFinishedArrival(reportId);
        if (report == null) return;
        String reportNo = str(report.get("bill_no"));
        if (!isOutboxDelivery()) {
            outbox.publishOnce(
                    EVENT_PRODUCTION_FINISHED_ARRIVAL_PENDING,
                    "PRODUCTION_DAILY_REPORT",
                    reportId,
                    Map.of("reportId", reportId, "reportNo", reportNo),
                    EVENT_PRODUCTION_FINISHED_ARRIVAL_PENDING + ':' + reportId);
            return;
        }
        deliverAtomically(() -> {
            for (UUID warehouseUser : departmentUserIdsWithAuthorities(
                    "SUB_WH", "stock_doc:view", "stock_doc:approve")) {
                sendToUser(
                        warehouseUser,
                        TYPE_TASK,
                        "待登记生产成品送检：" + reportNo,
                        "生产报工单 " + reportNo
                                + " 已审核，请仓库核对实物并登记成品目标仓、库位，"
                                + "然后送品质终检。通知不代替仓库任务队列、品质放行或库存事实。",
                        "/warehouse/production-finished-in/tasks",
                        EVENT_PRODUCTION_FINISHED_ARRIVAL_PENDING);
            }
        });
    }

    private Map<String, Object> pendingProductionFinishedArrival(UUID reportId) {
        if (reportId == null) return null;
        return one("""
                SELECT report.id, report.bill_no
                FROM production_daily_reports report
                WHERE report.id = ?
                  AND report.status = 1
                  AND report.is_deleted = FALSE
                  AND EXISTS (
                      SELECT 1
                      FROM production_daily_report_items report_item
                      WHERE report_item.report_id = report.id
                        AND report_item.is_deleted = FALSE)
                  AND NOT EXISTS (
                      SELECT 1
                      FROM production_daily_report_items report_item
                      WHERE report_item.report_id = report.id
                        AND report_item.is_deleted = FALSE
                        AND report_item.execution_segment_id IS NULL)
                  AND NOT EXISTS (
                      SELECT 1
                      FROM production_finished_arrival_registrations registration
                      WHERE registration.source_report_id = report.id)
                  AND NOT EXISTS (
                      SELECT 1
                      FROM production_fqc_inspections inspection
                      WHERE inspection.source_report_id = report.id)
                  AND NOT EXISTS (
                      SELECT 1
                      FROM production_fqc_legacy_exemptions exemption
                      WHERE exemption.source_report_id = report.id)
                """, reportId);
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
                // V459 审核待办弹卡：aggregate 绑定 (IQC_INSPECTION, receiptId)，
                // 检验完成（全部行 PASS/处置完毕）时批量撤回。
                sendToUser(
                        qualityUser,
                        TYPE_TASK,
                        "待检处置：" + billNo,
                        content,
                        "/quality/task-center",
                        EVENT_IQC_PENDING,
                        null,
                        receiptId);
            }
        });
    }

    /**
     * Every quality PASS slice immediately becomes a durable warehouse task.
     * The notification is only a permission-filtered reminder; remaining
     * quantity and action authority are always re-read from the task API.
     */
    public void notifyIqcStockInPendingForWarehouse(
            UUID passEventId, String receiptType, UUID receiptId) {
        if (!isOutboxDelivery()) {
            if (passEventId == null || receiptId == null) return;
            outbox.publishOnce(
                    EVENT_IQC_STOCK_IN_PENDING,
                    "PROCUREMENT_INSPECTION_PASS",
                    passEventId,
                    Map.of("receiptType", receiptType, "receiptId", receiptId),
                    EVENT_IQC_STOCK_IN_PENDING + ':' + passEventId);
            return;
        }
        deliverAtomically(() -> {
            boolean purchase = "PURCHASE".equals(receiptType);
            if ((!purchase && !"SUBCONTRACT".equals(receiptType))
                    || passEventId == null || receiptId == null) {
                return;
            }
            Map<String, Object> task = one("""
                    SELECT receipt.bill_no,
                           supplier.name AS supplier_name,
                           warehouse.name AS warehouse_name,
                           goods.code AS goods_code,
                           goods.name AS goods_name,
                           COALESCE(base_unit.name, source_unit.name) AS unit_name,
                           event.base_qty
                               - COALESCE(stocked.stocked_qty, 0) AS remaining_qty
                    FROM procurement_inspection_events event
                    JOIN procurement_inspection_items inspection
                      ON inspection.id = event.inspection_item_id
                     AND inspection.receipt_type = ?
                     AND inspection.receipt_id = ?
                     AND inspection.status <> 'REVERSED'
                    JOIN %s receipt
                      ON receipt.id = inspection.receipt_id
                     AND COALESCE(receipt.is_deleted, FALSE) = FALSE
                    LEFT JOIN suppliers supplier ON supplier.id = receipt.supplier_id
                    LEFT JOIN warehouses warehouse
                      ON warehouse.id = inspection.warehouse_id
                    LEFT JOIN goods ON goods.id = inspection.goods_id
                    LEFT JOIN units source_unit
                      ON source_unit.id = inspection.unit_id
                    LEFT JOIN units base_unit ON base_unit.id = goods.unit_id
                    LEFT JOIN LATERAL (
                        SELECT COALESCE(SUM(item.base_qty), 0) AS stocked_qty
                        FROM procurement_iqc_stock_in_batch_items item
                        WHERE item.pass_event_id = event.id
                    ) stocked ON TRUE
                    WHERE event.id = ?
                      AND event.action = 'PASS'
                      AND event.requires_warehouse_stock_in = TRUE
                    """.formatted(purchase
                            ? "purchase_receipts" : "subcontract_receipts"),
                    receiptType, receiptId, passEventId);
            if (task == null) return;
            BigDecimal remaining = bd(task.get("remaining_qty"));
            if (remaining.signum() <= 0) return;
            String billNo = str(task.get("bill_no"));
            String goodsLabel = (str(task.get("goods_code")) + " "
                    + str(task.get("goods_name"))).strip();
            String unitName = str(task.get("unit_name"));
            String content = (purchase ? "采购收货单 " : "委外进仓单 ")
                    + billNo
                    + (str(task.get("supplier_name")).isBlank()
                            ? "" : "(" + str(task.get("supplier_name")) + ")")
                    + " 的 " + goodsLabel + " 已由品质部放行，待仓库确认入库 "
                    + qty(remaining)
                    + (unitName.isBlank() ? "(基本单位)" : " " + unitName)
                    + (str(task.get("warehouse_name")).isBlank()
                            ? "。" : "，目标仓库「" + str(task.get("warehouse_name")) + "」。")
                    + "请核对实物数量和实际库位；确认前不会增加可用库存。";
            String route = "/warehouse/iqc-stock-ins/" + receiptType + '/' + receiptId;
            for (UUID warehouseUser : departmentUserIdsWithAuthorities(
                    "SUB_WH", NOTICE_READ_AUTHORITY,
                    WAREHOUSE_IQC_STOCK_IN_VIEW_AUTHORITY)) {
                sendToUser(
                        warehouseUser,
                        TYPE_TASK,
                        "品质已放行，待仓库入库：" + billNo,
                        content,
                        route,
                        EVENT_IQC_STOCK_IN_PENDING);
            }
        });
    }

    /**
     * 采购/委外收货 IQC 整单结案结果回执。合格不等于已入库；仓库任务投影
     * 与 warehouse_stocked_base_qty 才是实际入库权威。
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
            BigDecimal passed = sums == null
                    ? BigDecimal.ZERO : bd(sums.get("passed"));
            BigDecimal failed = sums == null
                    ? BigDecimal.ZERO : bd(sums.get("failed"));
            String billNo = str(receipt.get("bill_no"));
            String supplier = str(receipt.get("supplier_name"));
            String warehouse = str(receipt.get("warehouse_name"));
            String content = (purchase ? "采购收货单 " : "委外进仓单 ") + billNo
                    + (supplier.isBlank() ? "" : "(" + supplier + ")")
                    + " 品质部检验已结案。合格量是否已经进入可用库存，"
                    + "必须以仓库确认入库任务为准"
                    + (warehouse.isBlank() ? "" : " 至「" + warehouse + "」")
                    + (failed.signum() > 0
                            ? "；本单含不合格实物，请同时跟进退回处置。"
                            : "。请在仓库专属页面核对剩余待入库切片。");
            if (hasWarehouseIqcStockInTask(passed)) {
                String route = "/warehouse/iqc-stock-ins/"
                        + receiptType + '/' + receiptId;
                for (UUID warehouseUser : departmentUserIdsWithAuthorities(
                        "SUB_WH", NOTICE_READ_AUTHORITY,
                        WAREHOUSE_IQC_STOCK_IN_VIEW_AUTHORITY)) {
                    sendToUser(
                            warehouseUser,
                            TYPE_WORKFLOW,
                            (failed.signum() > 0
                                    ? "品质检验已结案（含不合格）："
                                    : "品质检验已结案：") + billNo,
                            content,
                            route,
                            EVENT_IQC_RESOLVED);
                }
            }
            if (!purchase) {
                notifySubcontractIqcResolvedStakeholders(
                        receiptId, billNo, passed, failed);
            }
        });
    }

    /**
     * 委外 IQC 结案除仓库上架回执外，还需回到订单归属人及原物料分析归属人。
     * 两条链均只按 UUID 外键重读；通知不携带供应商或商业金额。
     */
    private void notifySubcontractIqcResolvedStakeholders(
            UUID receiptId,
            String receiptBillNo,
            BigDecimal passed,
            BigDecimal failed) {
        String result = subcontractIqcResolutionMessage(
                receiptBillNo, passed, failed);
        for (Map<String, Object> order : jdbc.queryForList("""
                SELECT DISTINCT order_header.id AS order_id,
                       order_header.bill_no AS order_bill_no,
                       order_header.maker_id
                FROM subcontract_receipt_items receipt_item
                JOIN subcontract_order_items order_item
                  ON order_item.id = receipt_item.order_item_id
                 AND COALESCE(order_item.is_deleted, FALSE) = FALSE
                JOIN subcontract_orders order_header
                  ON order_header.id = order_item.order_id
                 AND COALESCE(order_header.is_deleted, FALSE) = FALSE
                WHERE receipt_item.receipt_id = ?
                  AND COALESCE(receipt_item.is_deleted, FALSE) = FALSE
                ORDER BY order_header.id
                """, receiptId)) {
            UUID makerUserId = subcontractMakerUserId(
                    (UUID) order.get("maker_id"));
            notifyUser(
                    makerUserId,
                    failed.signum() > 0 ? TYPE_URGENT : TYPE_WORKFLOW,
                    "委外回厂 IQC 已结案：" + str(order.get("order_bill_no")),
                    result,
                    "/subcontract/orders/" + order.get("order_id"),
                    EVENT_IQC_RESOLVED);
        }
        notifySubcontractAnalysisMakersIqcResolved(
                receiptId, receiptBillNo, passed, failed, result);
    }

    private void notifySubcontractAnalysisMakersIqcResolved(
            UUID receiptId,
            String receiptBillNo,
            BigDecimal passed,
            BigDecimal failed,
            String result) {
        for (Map<String, Object> analysis : jdbc.queryForList("""
                SELECT DISTINCT material_analysis.id AS analysis_id,
                       material_analysis.maker_id
                FROM subcontract_receipt_items receipt_item
                JOIN subcontract_order_items order_item
                  ON order_item.id = receipt_item.order_item_id
                 AND COALESCE(order_item.is_deleted, FALSE) = FALSE
                JOIN subcontract_application_items application_item
                  ON application_item.id = order_item.application_item_id
                 AND COALESCE(application_item.is_deleted, FALSE) = FALSE
                JOIN subcontract_applications application
                  ON application.id = application_item.application_id
                 AND COALESCE(application.is_deleted, FALSE) = FALSE
                JOIN preplan_supply_action_allocations allocation
                  ON allocation.external_item_id = application_item.id
                JOIN preplan_supply_actions supply_action
                  ON supply_action.id = allocation.action_id
                 AND supply_action.route = 'SUBCONTRACT'
                 AND supply_action.status <> 'CANCELLED'
                 AND supply_action.external_document_type =
                     'SUBCONTRACT_APPLICATION'
                 AND supply_action.external_document_id = application.id
                JOIN production_material_analyses material_analysis
                  ON material_analysis.id = supply_action.analysis_id
                 AND material_analysis.is_deleted = FALSE
                WHERE receipt_item.receipt_id = ?
                  AND COALESCE(receipt_item.is_deleted, FALSE) = FALSE
                ORDER BY material_analysis.id
                """, receiptId)) {
            UUID makerUserId = userIdOfEmployee(
                    (UUID) analysis.get("maker_id"));
            notifyUser(
                    makerUserId,
                    failed.signum() > 0 ? TYPE_URGENT : TYPE_WORKFLOW,
                    "委外供给 IQC 已结案：" + receiptBillNo,
                    result + (failed.signum() > 0
                            ? "请复核不合格量对当前可下达数量和补足需求的影响。"
                            : "请在原物料分析中查看最新可下达数量。"),
                    "/production/material-analyses/"
                            + analysis.get("analysis_id") + "/summary",
                    EVENT_IQC_RESOLVED);
        }
    }

    static boolean hasWarehouseIqcStockInTask(BigDecimal passed) {
        return passed != null && passed.signum() > 0;
    }

    static String subcontractIqcResolutionMessage(
            String receiptBillNo, BigDecimal passed, BigDecimal failed) {
        boolean hasPass = hasWarehouseIqcStockInTask(passed);
        boolean hasFail = failed != null && failed.signum() > 0;
        return "委外进仓单 " + receiptBillNo + " 的 IQC 已结案："
                + (hasPass
                ? "存在合格量" + (hasFail ? "，同时存在不合格量。" : "。")
                    + "合格量只有经仓库确认后才进入可用库存；"
                : "未形成合格量，不会生成仓库待入库任务；")
                + "通知不代表委外订单或原物料分析任务已全部完成。";
    }

    /** 销售创建出货草稿后，只通知具备出货财审权限的人员。 */
    public void notifyShipmentPendingFinanceAudit(UUID shipmentId) {
        if (!isOutboxDelivery()) {
            outbox.publishOnce(
                    EVENT_SHIPMENT_PENDING_FINANCE,
                    "SALES_SHIPMENT",
                    shipmentId,
                    Map.of(),
                    EVENT_SHIPMENT_PENDING_FINANCE + ':' + shipmentId);
            return;
        }
        deliverAtomically(() -> {
            String billNo = oneStr("""
                    SELECT bill_no
                    FROM sales_shipments
                    WHERE id = ?
                      AND status = 0
                      AND COALESCE(is_deleted, FALSE) = FALSE
                      AND COALESCE(rejected, FALSE) = FALSE
                      AND finance_audit = 0
                      AND warehouse_work_status = 'PENDING_PICK'
                    """, shipmentId);
            if (billNo == null || billNo.isBlank()) return;
            for (UUID userId : userIdsWithPermissions(
                    "finance_shipment_audit", NOTICE_READ_AUTHORITY)) {
                sendToUser(
                        userId,
                        TYPE_APPROVAL,
                        "待出货财务审核：" + billNo,
                        "销售出货单 " + billNo
                                + " 已提交财务审核；财务放行后才会通知仓库拣货。",
                        "/sales/shipments/" + shipmentId,
                        EVENT_SHIPMENT_PENDING_FINANCE);
            }
        });
    }

    /** 财务放行后，给仓库部门投递待拣货任务。 */
    public void notifyShipmentPendingPick(UUID shipmentId) {
        notifyShipmentPendingPick(shipmentId, null);
    }

    /** 每次真实财务放行使用审核时间形成独立幂等键，允许反审后重新放行再通知。 */
    public void notifyShipmentPendingPick(
            UUID shipmentId, java.time.OffsetDateTime financeAuditedAt) {
        if (!isOutboxDelivery()) {
            String releaseIdentity = financeAuditedAt == null
                    ? "legacy"
                    : financeAuditedAt.toInstant().toString();
            outbox.publishOnce(
                    EVENT_SHIPMENT_PENDING_PICK,
                    "SALES_SHIPMENT",
                    shipmentId,
                    Map.of(),
                    EVENT_SHIPMENT_PENDING_PICK + ':' + shipmentId + ':' + releaseIdentity);
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
                      AND COALESCE(shipment.rejected, FALSE) = FALSE
                      AND shipment.finance_audit = 1
                    GROUP BY shipment.bill_no, warehouse.name
                    """, shipmentId);
            if (shipment == null) return;
            String billNo = str(shipment.get("bill_no"));
            String warehouse = str(shipment.get("warehouse_name"));
            String content = "发货单 " + billNo + " 已进入待拣货，数量 "
                    + qty(bd(shipment.get("shipment_qty")))
                    + (warehouse.isBlank() ? "。" : "，出库仓库 " + warehouse + "。")
                    + "请按仓库作业流程核对库存并拣货；通知不代表已占用或已出库。";
            for (UUID warehouseUser : departmentUserIdsWithAuthorities(
                    "SUB_WH", NOTICE_READ_AUTHORITY,
                    "sales_shipment:warehouse-work")) {
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

    /** 财务在拣货开始前撤回放行时，通知仓库暂停该任务。 */
    public void notifyShipmentFinanceReleaseRevoked(UUID shipmentId) {
        if (!isOutboxDelivery()) {
            outbox.publish(
                    EVENT_SHIPMENT_FINANCE_REVOKED,
                    "SALES_SHIPMENT",
                    shipmentId,
                    Map.of());
            return;
        }
        deliverAtomically(() -> {
            String billNo = oneStr("""
                    SELECT bill_no
                    FROM sales_shipments
                    WHERE id = ?
                      AND status = 0
                      AND COALESCE(is_deleted, FALSE) = FALSE
                      AND finance_audit = 0
                      AND warehouse_work_status = 'PENDING_PICK'
                    """, shipmentId);
            if (billNo == null || billNo.isBlank()) return;
            for (UUID warehouseUser : departmentUserIdsWithAuthorities(
                    "SUB_WH", NOTICE_READ_AUTHORITY,
                    "sales_shipment:warehouse-work")) {
                sendToUser(
                        warehouseUser,
                        TYPE_URGENT,
                        "出货财务放行已撤回：" + billNo,
                        "出货单 " + billNo + " 的财务放行已撤回，请暂停拣货并等待重新审核。",
                        "/sales/shipments/" + shipmentId,
                        EVENT_SHIPMENT_FINANCE_REVOKED);
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
     * V458：物料分析对有子层级的委外件下达了前置自制任务。
     * 委外部此时不参与；提醒计划/生产按正常自制链完成齐套、领料、报工、
     * FQC 与成品实收入库。账本行仍是权威，本通知只是提醒。
     */
    public void notifySubcontractMakeTaskCreated(UUID taskId) {
        if (!isOutboxDelivery()) {
            outbox.publishOnce(
                    EVENT_SUBCONTRACT_MAKE_TASK_CREATED,
                    "PREPLAN_SUBCONTRACT_MAKE_TASK",
                    taskId,
                    Map.of(),
                    EVENT_SUBCONTRACT_MAKE_TASK_CREATED + ':' + taskId);
            return;
        }
        deliverAtomically(() -> {
            Map<String, Object> task = one("""
                    SELECT make_task.analysis_id,
                           make_task.required_qty,
                           goods.code AS goods_code, goods.name AS goods_name
                    FROM preplan_subcontract_make_tasks make_task
                    JOIN goods ON goods.id = make_task.goods_id
                    WHERE make_task.id = ?
                      AND make_task.status = 'ACTIVE'
                    """, taskId);
            if (task == null) return;
            UUID analysisId = (UUID) task.get("analysis_id");
            String goodsLabel = subcontractGoodsLabel(task);
            String quantity = qty(bd(task.get("required_qty")));
            Set<UUID> recipients = new LinkedHashSet<>();
            recipients.addAll(departmentUserIdsWithAuthorities(
                    "SUB_PLAN",
                    NOTICE_READ_AUTHORITY,
                    "production_material_analysis:view"));
            recipients.addAll(departmentUserIdsWithAuthorities(
                    "DEPT_PROD",
                    NOTICE_READ_AUTHORITY,
                    "production_material_analysis:view"));
            for (UUID recipient : recipients) {
                sendToUser(
                        recipient,
                        TYPE_TASK,
                        "委外件前置自制待安排：" + goodsLabel,
                        "有子层级的委外件 " + goodsLabel + "，需求量 " + quantity
                                + " 已转为前置自制任务。请按正常自制流程检查子层级、"
                                + "安排生产并完成领料、报工、FQC 和成品实收入库；"
                                + "自制成品入库并通知委外前，委外部不会收到任何申请。"
                                + "可执行操作以物料分析实时状态为准。",
                        "/production/material-analyses/" + analysisId + "/summary",
                        EVENT_SUBCONTRACT_MAKE_TASK_CREATED);
            }
        });
    }

    /**
     * V458：前置自制成品入库后按账本生成了委外申请（满批自动或手动分批）。
     * 委外部自此开始参与：到委外任务中心分解订货。
     */
    public void notifySubcontractMakeNotified(UUID batchId) {
        if (!isOutboxDelivery()) {
            outbox.publishOnce(
                    EVENT_SUBCONTRACT_MAKE_NOTIFIED,
                    "PREPLAN_SUBCONTRACT_MAKE_TASK_BATCH",
                    batchId,
                    Map.of(),
                    EVENT_SUBCONTRACT_MAKE_NOTIFIED + ':' + batchId);
            return;
        }
        deliverAtomically(() -> {
            Map<String, Object> batch = one("""
                    SELECT batch.application_id, batch.notify_qty,
                           application.bill_no,
                           make_task.analysis_id,
                           make_task.required_qty, make_task.produced_qty,
                           make_task.notified_qty,
                           goods.code AS goods_code, goods.name AS goods_name
                    FROM preplan_subcontract_make_task_batches batch
                    JOIN preplan_subcontract_make_tasks make_task
                      ON make_task.id = batch.task_id
                    JOIN subcontract_applications application
                      ON application.id = batch.application_id
                     AND application.is_deleted = FALSE
                    JOIN goods ON goods.id = make_task.goods_id
                    WHERE batch.id = ?
                    """, batchId);
            if (batch == null) return;
            UUID applicationId = (UUID) batch.get("application_id");
            String billNo = str(batch.get("bill_no"));
            String goodsLabel = subcontractGoodsLabel(batch);
            String quantity = qty(bd(batch.get("notify_qty")));
            String produced = qty(bd(batch.get("produced_qty")));
            String required = qty(bd(batch.get("required_qty")));
            notifyPreplanSupplyRecipients(
                    TYPE_TASK,
                    "新委外需求（前置自制已入库）：" + billNo,
                    "委外件 " + goodsLabel + " 的前置自制成品已入库（累计 " + produced
                            + " / 需求 " + required + "），计划部已通知委外 "
                            + quantity + "。请到委外申请详情核对，并从委外任务中心"
                            + "分解订货；本通知不代表已订货或已出仓。",
                    "/subcontract/applications/" + applicationId,
                    SUBCONTRACT_APPLICATION_VIEW_AUTHORITY);
        });
    }

    /**
     * A target item with active BOM children must complete the normal MAKE
     * chain before warehouse outbound. The database task remains authoritative;
     * this event only points eligible planning/production users to that task.
     */
    public void notifySubcontractPreparationRequired(UUID planItemId) {
        if (!isOutboxDelivery()) {
            outbox.publishOnce(
                    EVENT_SUBCONTRACT_PREPARATION_REQUIRED,
                    "SUBCONTRACT_MATERIAL_PLAN_ITEM",
                    planItemId,
                    Map.of(),
                    EVENT_SUBCONTRACT_PREPARATION_REQUIRED + ':' + planItemId);
            return;
        }
        deliverAtomically(() -> {
            Map<String, Object> item = subcontractPreparationRequiredSnapshot(
                    planItemId);
            if (item == null) return;
            UUID orderId = (UUID) item.get("order_id");
            String orderNo = str(item.get("order_bill_no"));
            String goods = subcontractGoodsLabel(item);
            String quantity = qty(bd(item.get("planned_qty")));
            String taskRoute = "/subcontract/preparations?planItemId="
                    + planItemId;
            String taskContent = "委外订货单 " + orderNo + " 的目标件 "
                    + goods + "，数量 " + quantity
                    + " 存在有效子层级，不能直接委外出仓。请在委外前置自制任务队列"
                    + "启动物料分析，并按正常自制链完成领料、生产、报工、品质检验和"
                    + "仓库实收入库；可执行操作以任务实时 allowedActions 为准。";
            Set<UUID> productionRecipients = new LinkedHashSet<>();
            productionRecipients.addAll(departmentUserIdsWithAuthorities(
                    "SUB_PLAN",
                    NOTICE_READ_AUTHORITY,
                    "subcontract_preparation:view",
                    "subcontract_preparation:start"));
            productionRecipients.addAll(departmentUserIdsWithAuthorities(
                    "DEPT_PROD",
                    NOTICE_READ_AUTHORITY,
                    "subcontract_preparation:view",
                    "subcontract_preparation:start"));
            for (UUID recipient : productionRecipients) {
                sendToUser(
                        recipient,
                        TYPE_TASK,
                        "待启动委外前置自制：" + orderNo,
                        taskContent,
                        taskRoute,
                        EVENT_SUBCONTRACT_PREPARATION_REQUIRED);
            }

            UUID makerUserId = subcontractMakerUserId(
                    (UUID) item.get("maker_id"));
            notifyUser(
                    makerUserId,
                    TYPE_WORKFLOW,
                    "委外前置自制待安排：" + orderNo,
                    "委外订货单 " + orderNo + " 的目标件 " + goods
                            + " 需先完成正常自制流程。计划/生产岗位已收到前置任务；"
                            + "只有品质放行并经仓库实收入库后，目标件才会转入委外出仓。"
                            + "本通知仅作进度提醒，不代表已领料、已完工或已入库。",
                    "/subcontract/orders/" + orderId,
                    EVENT_SUBCONTRACT_PREPARATION_REQUIRED);
        });
    }

    /**
     * 直下单销售式供货：有子层目标件批准时按全局可用量拆行，仅缺口部分保留
     * 前置自制（计划行量=缺口）；现货直发行另行触发 OUTBOUND_READY。本事件把
     * 缺口指向计划/生产岗位，数据库任务仍是权威。
     */
    public void notifySubcontractPrepareShortage(UUID planItemId) {
        if (!isOutboxDelivery()) {
            outbox.publishOnce(
                    EVENT_SUBCONTRACT_PREPARE_SHORTAGE,
                    "SUBCONTRACT_MATERIAL_PLAN_ITEM",
                    planItemId,
                    Map.of(),
                    EVENT_SUBCONTRACT_PREPARE_SHORTAGE + ':' + planItemId);
            return;
        }
        deliverAtomically(() -> {
            Map<String, Object> item = subcontractPreparationRequiredSnapshot(
                    planItemId);
            if (item == null) return;
            UUID orderId = (UUID) item.get("order_id");
            String orderNo = str(item.get("order_bill_no"));
            String goods = subcontractGoodsLabel(item);
            String shortage = qty(bd(item.get("planned_qty")));
            String taskRoute = "/subcontract/preparations?planItemId="
                    + planItemId;
            String taskContent = "委外订货单 " + orderNo + " 的目标件 "
                    + goods + " 仓库现货不足，缺口 " + shortage
                    + "(基本单位) 需按自制链补产（现货部分已另行通知仓库直接出仓）。"
                    + "请在委外前置自制任务队列启动物料分析，并按正常自制链完成领料、"
                    + "生产、报工、品质检验和仓库实收入库；可执行操作以任务实时"
                    + " allowedActions 为准。";
            Set<UUID> productionRecipients = new LinkedHashSet<>();
            productionRecipients.addAll(departmentUserIdsWithAuthorities(
                    "SUB_PLAN",
                    NOTICE_READ_AUTHORITY,
                    "subcontract_preparation:view",
                    "subcontract_preparation:start"));
            productionRecipients.addAll(departmentUserIdsWithAuthorities(
                    "DEPT_PROD",
                    NOTICE_READ_AUTHORITY,
                    "subcontract_preparation:view",
                    "subcontract_preparation:start"));
            for (UUID recipient : productionRecipients) {
                sendToUser(
                        recipient,
                        TYPE_TASK,
                        "待补产委外缺口：" + orderNo,
                        taskContent,
                        taskRoute,
                        EVENT_SUBCONTRACT_PREPARE_SHORTAGE);
            }

            UUID makerUserId = subcontractMakerUserId(
                    (UUID) item.get("maker_id"));
            notifyUser(
                    makerUserId,
                    TYPE_WORKFLOW,
                    "委外目标件存在生产缺口：" + orderNo,
                    "委外订货单 " + orderNo + " 的目标件 " + goods
                            + " 仓库现货不足，缺口 " + shortage
                            + " 已交计划/生产岗位补产；现货部分已直接安排委外出仓。"
                            + "本通知仅作进度提醒，不代表已领料、已完工或已入库。",
                    "/subcontract/orders/" + orderId,
                    EVENT_SUBCONTRACT_PREPARE_SHORTAGE);
        });
    }

    /** A prepared target item is now visible in the warehouse outbound queue. */
    public void notifySubcontractOutboundReady(UUID planItemId) {
        if (!isOutboxDelivery()) {
            outbox.publishOnce(
                    EVENT_SUBCONTRACT_OUTBOUND_READY,
                    "SUBCONTRACT_MATERIAL_PLAN_ITEM",
                    planItemId,
                    Map.of(),
                    EVENT_SUBCONTRACT_OUTBOUND_READY + ':' + planItemId);
            return;
        }
        deliverAtomically(() -> {
            Map<String, Object> item = subcontractOutboundReadySnapshot(planItemId);
            if (item == null) return;
            UUID planId = (UUID) item.get("plan_id");
            UUID orderId = (UUID) item.get("order_id");
            String orderNo = str(item.get("order_bill_no"));
            String goods = subcontractGoodsLabel(item);
            BigDecimal remaining = bd(item.get("prepared_qty"))
                    .min(bd(item.get("planned_qty")))
                    .subtract(bd(item.get("issued_qty")))
                    .max(BigDecimal.ZERO);
            String warehouseContent = "委外订货单 " + orderNo + " 的目标件 "
                    + goods + " 当前可出仓 " + qty(remaining)
                    + "(基本单位)。请打开委外出仓任务核对来源仓、库位和实物后拣货并"
                    + "审核出仓；通知不代表已预留、已拣货或已出仓，可执行操作以任务"
                    + "实时 allowedActions 为准。";
            for (UUID warehouseUser : departmentUserIdsWithAuthorities(
                    "SUB_WH",
                    NOTICE_READ_AUTHORITY,
                    "subcontract_outbound:view",
                    "subcontract_outbound:execute")) {
                sendToUser(
                        warehouseUser,
                        TYPE_TASK,
                        "待执行委外目标件出仓：" + orderNo,
                        warehouseContent,
                        "/warehouse/subcontract-outbound/" + planId,
                        EVENT_SUBCONTRACT_OUTBOUND_READY);
            }

            UUID makerUserId = subcontractMakerUserId(
                    (UUID) item.get("maker_id"));
            notifyUser(
                    makerUserId,
                    TYPE_WORKFLOW,
                    "委外目标件已可出仓：" + orderNo,
                    "委外订货单 " + orderNo + " 的目标件 " + goods
                            + " 已达到委外出仓条件，仓储部已收到出仓任务。"
                            + "本通知仅作进度提醒，不代表目标件已经出仓。",
                    "/subcontract/orders/" + orderId,
                    EVENT_SUBCONTRACT_OUTBOUND_READY);
        });
    }

    /** Approved target-item outbound receipt for the subcontract order maker. */
    public void notifySubcontractOutboundCompleted(UUID issueId) {
        if (!isOutboxDelivery()) {
            outbox.publishOnce(
                    EVENT_SUBCONTRACT_OUTBOUND_COMPLETED,
                    "SUBCONTRACT_MATERIAL_ISSUE",
                    issueId,
                    Map.of(),
                    EVENT_SUBCONTRACT_OUTBOUND_COMPLETED + ':' + issueId);
            return;
        }
        deliverAtomically(() -> {
            List<Map<String, Object>> orders = jdbc.queryForList("""
                    SELECT plan.order_id, plan.order_bill_no,
                           order_header.maker_id,
                           issue.bill_no AS issue_bill_no,
                           SUM(issue_item.qty * COALESCE(issue_item.unit_rate, 1))
                               AS issued_base_qty,
                           MIN(concat_ws(' ', goods.code, goods.name)) AS first_goods,
                           COUNT(DISTINCT plan_item.goods_id) AS goods_count
                    FROM subcontract_material_issues issue
                    JOIN subcontract_material_issue_items issue_item
                      ON issue_item.issue_id = issue.id
                    JOIN subcontract_material_plan_items plan_item
                      ON plan_item.id = issue_item.plan_item_id
                     AND plan_item.is_deleted = FALSE
                     AND plan_item.flow_mode IN (
                         'DIRECT_OUTBOUND', 'MAKE_THEN_OUTBOUND', 'PREPARED_OUTBOUND')
                    JOIN subcontract_material_plans plan
                      ON plan.id = plan_item.plan_id
                     AND plan.is_deleted = FALSE
                    JOIN subcontract_orders order_header
                      ON order_header.id = plan.order_id
                     AND order_header.status = 1
                     AND order_header.is_deleted = FALSE
                    JOIN goods ON goods.id = plan_item.goods_id
                    WHERE issue.id = ?
                      AND issue.status = 1
                      AND issue.is_deleted = FALSE
                    GROUP BY plan.order_id, plan.order_bill_no,
                             order_header.maker_id, issue.bill_no
                    ORDER BY plan.order_id
                    """, issueId);
            for (Map<String, Object> order : orders) {
                UUID makerUserId = subcontractMakerUserId(
                        (UUID) order.get("maker_id"));
                UUID orderId = (UUID) order.get("order_id");
                String orderNo = str(order.get("order_bill_no"));
                String firstGoods = str(order.get("first_goods"));
                long goodsCount = ((Number) order.get("goods_count")).longValue();
                String goods = firstGoods
                        + (goodsCount > 1 ? " 等 " + goodsCount + " 项" : "");
                if (makerUserId != null) {
                    sendToUser(
                            makerUserId,
                            TYPE_WORKFLOW,
                            "委外目标件已出仓：" + orderNo,
                            "委外出仓单 " + str(order.get("issue_bill_no"))
                                    + " 已审核，目标件 " + goods + " 已完成出仓 "
                                    + qty(bd(order.get("issued_base_qty")))
                                    + "(基本单位)。请在订单进度中跟进加工交期、回厂收货和"
                                    + "IQC；通知不代表已回厂或品质已结案。",
                            "/subcontract/orders/" + orderId,
                            EVENT_SUBCONTRACT_OUTBOUND_COMPLETED);
                }
                for (UUID warehouseUser : departmentUserIdsWithAuthorities(
                        "SUB_WH", NOTICE_READ_AUTHORITY, "warehouse_inbound:view")) {
                    sendToUser(
                            warehouseUser,
                            TYPE_TASK,
                            "委外预计回厂：" + orderNo,
                            "委外出仓单 " + str(order.get("issue_bill_no"))
                                    + " 已审核，目标件 " + goods + " 本批已真实出仓 "
                                    + qty(bd(order.get("issued_base_qty")))
                                    + "(基本单位)，现在可能回厂。请在预计到货任务中心登记"
                                    + "实际回厂；通知不代表已经到货。",
                            "/warehouse/inbound/expectations",
                            EVENT_SUBCONTRACT_OUTBOUND_COMPLETED);
                }
            }
            for (Map<String, Object> analysis : jdbc.queryForList("""
                    SELECT DISTINCT material_analysis.id AS analysis_id,
                           material_analysis.maker_id,
                           issue.bill_no AS issue_bill_no
                    FROM subcontract_material_issues issue
                    JOIN subcontract_material_issue_items issue_item
                      ON issue_item.issue_id = issue.id
                    JOIN subcontract_material_plan_items plan_item
                      ON plan_item.id = issue_item.plan_item_id
                     AND plan_item.is_deleted = FALSE
                     AND plan_item.flow_mode IN (
                         'DIRECT_OUTBOUND', 'MAKE_THEN_OUTBOUND', 'PREPARED_OUTBOUND')
                    JOIN subcontract_order_items order_item
                      ON order_item.id = issue_item.order_item_id
                     AND COALESCE(order_item.is_deleted, FALSE) = FALSE
                    JOIN subcontract_application_items application_item
                      ON application_item.id = order_item.application_item_id
                     AND COALESCE(application_item.is_deleted, FALSE) = FALSE
                    JOIN subcontract_applications application
                      ON application.id = application_item.application_id
                     AND COALESCE(application.is_deleted, FALSE) = FALSE
                    JOIN preplan_supply_action_allocations allocation
                      ON allocation.external_item_id = application_item.id
                    JOIN preplan_supply_actions supply_action
                      ON supply_action.id = allocation.action_id
                     AND supply_action.route = 'SUBCONTRACT'
                     AND supply_action.status <> 'CANCELLED'
                     AND supply_action.external_document_type =
                         'SUBCONTRACT_APPLICATION'
                     AND supply_action.external_document_id = application.id
                    JOIN production_material_analyses material_analysis
                      ON material_analysis.id = supply_action.analysis_id
                     AND material_analysis.is_deleted = FALSE
                    WHERE issue.id = ?
                      AND issue.status = 1
                      AND issue.is_deleted = FALSE
                    ORDER BY material_analysis.id
                    """, issueId)) {
                UUID makerUserId = userIdOfEmployee(
                        (UUID) analysis.get("maker_id"));
                notifyUser(
                        makerUserId,
                        TYPE_WORKFLOW,
                        "委外供给已出仓：" + str(analysis.get("issue_bill_no")),
                        "委外目标件已完成审核出仓，现等待委外加工、回厂收货和 IQC。"
                                + "请在原物料分析查看该供给行动进度；本通知不代表已回厂或"
                                + "品质已结案。",
                        "/production/material-analyses/"
                                + analysis.get("analysis_id") + "/summary",
                        EVENT_SUBCONTRACT_OUTBOUND_COMPLETED);
            }
        });
    }

    /** 已审目标件出仓被红冲后，补偿此前“可能回厂”通知并要求以实时任务为准。 */
    public void notifySubcontractOutboundReversed(UUID issueId) {
        if (!isOutboxDelivery()) {
            outbox.publishOnce(
                    EVENT_SUBCONTRACT_OUTBOUND_REVERSED,
                    "SUBCONTRACT_MATERIAL_ISSUE",
                    issueId,
                    Map.of(),
                    EVENT_SUBCONTRACT_OUTBOUND_REVERSED + ':' + issueId);
            return;
        }
        deliverAtomically(() -> {
            List<Map<String, Object>> orders = jdbc.queryForList("""
                    SELECT plan.order_id, plan.order_bill_no,
                           order_header.maker_id,
                           issue.bill_no AS issue_bill_no,
                           SUM(issue_item.qty * COALESCE(issue_item.unit_rate, 1))
                               AS reversed_base_qty
                    FROM subcontract_material_issues issue
                    JOIN subcontract_material_issue_items issue_item
                      ON issue_item.issue_id = issue.id
                     AND issue_item.is_deleted = FALSE
                    JOIN subcontract_material_plan_items plan_item
                      ON plan_item.id = issue_item.plan_item_id
                     AND plan_item.is_deleted = FALSE
                     AND plan_item.flow_mode IN (
                         'DIRECT_OUTBOUND','MAKE_THEN_OUTBOUND','PREPARED_OUTBOUND')
                    JOIN subcontract_material_plans plan
                      ON plan.id = plan_item.plan_id
                     AND plan.is_deleted = FALSE
                    JOIN subcontract_orders order_header
                      ON order_header.id = plan.order_id
                     AND order_header.is_deleted = FALSE
                    WHERE issue.id = ?
                      AND issue.status = -1
                      AND issue.is_deleted = FALSE
                    GROUP BY plan.order_id, plan.order_bill_no,
                             order_header.maker_id, issue.bill_no
                    ORDER BY plan.order_id
                    """, issueId);
            for (Map<String, Object> order : orders) {
                UUID orderId = (UUID) order.get("order_id");
                String orderNo = str(order.get("order_bill_no"));
                String issueNo = str(order.get("issue_bill_no"));
                String reversedQty = qty(bd(order.get("reversed_base_qty")));
                UUID makerUserId = subcontractMakerUserId(
                        (UUID) order.get("maker_id"));
                notifyUser(
                        makerUserId,
                        TYPE_URGENT,
                        "委外目标件出仓已红冲：" + orderNo,
                        "委外出仓单 " + issueNo + " 已红冲，本批目标件出仓 "
                                + reversedQty + "(基本单位)已撤销。请重新跟进目标件准备和"
                                + "出仓；实时订单/任务投影为准。",
                        "/subcontract/orders/" + orderId,
                        EVENT_SUBCONTRACT_OUTBOUND_REVERSED);
                for (UUID warehouseUser : departmentUserIdsWithAuthorities(
                        "SUB_WH", NOTICE_READ_AUTHORITY, "warehouse_inbound:view")) {
                    sendToUser(
                            warehouseUser,
                            TYPE_URGENT,
                            "委外预计回厂已撤回：" + orderNo,
                            "委外出仓单 " + issueNo + " 已红冲，本批出仓事实已撤销。"
                                    + "请刷新预计到货任务中心；若其它有效出仓批次仍有容量，"
                                    + "对应任务会继续保留。",
                            "/warehouse/inbound/expectations",
                            EVENT_SUBCONTRACT_OUTBOUND_REVERSED);
                }
            }
        });
    }

    /**
     * Daily supplier-return warning. Delivery rechecks the physical facts so a
     * delayed event cannot report an order that has already returned in full.
     * IQC is intentionally not part of this warning; physically returned goods
     * belong to the quality queue even while inspection remains pending.
     */
    private void notifySubcontractReturnDue(UUID orderId) {
        deliverAtomically(() -> {
            LocalDate today = BusinessTime.today();
            SubcontractReturnDueFacts.Snapshot order =
                    SubcontractReturnDueFacts.findCurrent(
                            jdbc,
                            orderId,
                            today.plusDays(SubcontractReturnDueScheduler.DUE_DAYS));
            if (order == null || order.deliverDate() == null) return;

            Set<UUID> recipients = new LinkedHashSet<>();
            UUID orderMaker = subcontractMakerUserId(order.makerEmployeeId());
            if (orderMaker != null) recipients.add(orderMaker);
            for (Map<String, Object> analysis : jdbc.queryForList("""
                    SELECT DISTINCT material_analysis.maker_id
                    FROM subcontract_order_items order_item
                    JOIN subcontract_application_items application_item
                      ON application_item.id = order_item.application_item_id
                     AND COALESCE(application_item.is_deleted, FALSE) = FALSE
                    JOIN subcontract_applications application
                      ON application.id = application_item.application_id
                     AND COALESCE(application.is_deleted, FALSE) = FALSE
                    JOIN preplan_supply_action_allocations allocation
                      ON allocation.external_item_id = application_item.id
                    JOIN preplan_supply_actions supply_action
                      ON supply_action.id = allocation.action_id
                     AND supply_action.route = 'SUBCONTRACT'
                     AND supply_action.status <> 'CANCELLED'
                     AND supply_action.external_document_type =
                         'SUBCONTRACT_APPLICATION'
                     AND supply_action.external_document_id = application.id
                    JOIN production_material_analyses material_analysis
                      ON material_analysis.id = supply_action.analysis_id
                     AND material_analysis.is_deleted = FALSE
                    WHERE order_item.order_id = ?
                      AND COALESCE(order_item.is_deleted, FALSE) = FALSE
                    ORDER BY material_analysis.maker_id
                    """, orderId)) {
                UUID analysisMaker = userIdOfEmployee(
                        (UUID) analysis.get("maker_id"));
                if (analysisMaker != null) recipients.add(analysisMaker);
            }
            if (recipients.isEmpty()) return;

            long daysLeft = ChronoUnit.DAYS.between(today, order.deliverDate());
            String timing = daysLeft < 0
                    ? "已逾期 " + (-daysLeft) + " 天"
                    : daysLeft == 0
                            ? "今日到期"
                            : "距约定回厂日 " + daysLeft + " 天";
            String title = (daysLeft < 0
                    ? "委外回厂已逾期："
                    : "委外回厂交期提醒：") + order.billNo();
            String content = "委外订货单 " + order.billNo() + " " + timing
                    + "。该单已有审核通过的委外出仓，但仍有加工件尚未物理回厂。"
                    + "请跟进委外商，并在实物到厂后由仓库登记回厂。"
                    + "本通知仅作交期提醒，不代表已回厂、IQC 已结案或订单完成；"
                    + "实际状态以订单全链路进度为准。";
            String route = "/subcontract/orders/" + orderId;
            String priority = daysLeft < 0 ? "important" : "normal";
            for (UUID recipient : recipients) {
                sendToUser(
                        recipient,
                        TYPE_URGENT,
                        title,
                        content,
                        route,
                        EVENT_SUBCONTRACT_RETURN_DUE,
                        priority);
            }
        });
    }

    private Map<String, Object> subcontractPreparationRequiredSnapshot(
            UUID planItemId) {
        return one("""
                SELECT item.plan_id, plan.order_id, plan.order_bill_no,
                       order_header.maker_id, item.planned_qty,
                       goods.code AS goods_code, goods.name AS goods_name
                FROM subcontract_material_plan_items item
                JOIN subcontract_material_plans plan
                  ON plan.id = item.plan_id
                 AND plan.status = 'OPEN'
                 AND plan.is_deleted = FALSE
                JOIN subcontract_orders order_header
                  ON order_header.id = plan.order_id
                 AND order_header.status = 1
                 AND order_header.is_deleted = FALSE
                JOIN goods ON goods.id = item.goods_id
                WHERE item.id = ?
                  AND item.is_deleted = FALSE
                  AND item.flow_mode = 'MAKE_THEN_OUTBOUND'
                  AND item.preparation_status = 'ACTION_REQUIRED'
                  AND item.planned_qty > 0
                """, planItemId);
    }

    private Map<String, Object> subcontractOutboundReadySnapshot(UUID planItemId) {
        return one("""
                SELECT item.plan_id, plan.order_id, plan.order_bill_no,
                       order_header.maker_id, item.planned_qty,
                       item.prepared_qty, item.issued_qty,
                       goods.code AS goods_code, goods.name AS goods_name
                FROM subcontract_material_plan_items item
                JOIN subcontract_material_plans plan
                  ON plan.id = item.plan_id
                 AND plan.status = 'OPEN'
                 AND plan.is_deleted = FALSE
                JOIN subcontract_orders order_header
                  ON order_header.id = plan.order_id
                 AND order_header.status = 1
                 AND order_header.is_deleted = FALSE
                JOIN goods ON goods.id = item.goods_id
                WHERE item.id = ?
                  AND item.is_deleted = FALSE
                  AND item.flow_mode IN ('DIRECT_OUTBOUND', 'MAKE_THEN_OUTBOUND', 'PREPARED_OUTBOUND')
                  AND item.preparation_status = 'READY_OUTBOUND'
                  AND LEAST(item.planned_qty, item.prepared_qty) > item.issued_qty
                """, planItemId);
    }

    private static String subcontractGoodsLabel(Map<String, Object> item) {
        String label = (str(item.get("goods_code")) + " "
                + str(item.get("goods_name"))).strip();
        return label.isBlank() ? "目标件" : label;
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
            // V459 审核待办弹卡：直达单据级财务审核页；aggregate 绑定订单，
            // 办结（确认/驳回）时按 (SALES_ORDER, orderId) 批量撤回全部接收人的弹卡。
            List<UUID> confirmers = salesOrderFinanceConfirmers.eligibleUserIds();
            for (UUID userId : confirmers) {
                sendToUser(userId, TYPE_APPROVAL,
                        "待财务确认：" + o.billNo(),
                        "销售订货单 " + o.billNo() + " 已审核，待财务确认；确认后计划部才可见并排产。",
                        "/finance/sales-order-confirmations/" + orderId,
                        EVENT_ORDER_PENDING_FINANCE, null, orderId);
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
                    // V459 审核待办弹卡：aggregate 绑定审批 case，批准/驳回时批量撤回。
                    sendToUser(reviewer, TYPE_APPROVAL, title, content,
                            "/finance/procurement-approvals",
                            EVENT_PROCUREMENT_FINANCE_SUBMITTED, null, approvalCaseId);
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
            UUID orderId = (UUID) approval.get("order_id");
            boolean subcontract = "SUBCONTRACT".equals(str(approval.get("order_type")));
            String actionRoute = subcontract
                    ? "/subcontract/orders/" + orderId
                    : "/purchase/orders/" + orderId;
            String approvedResult = subcontract
                    ? "已生成目标件准备/待出仓任务；有子层级的目标件须先完成前置自制，"
                            + "目标件真实审核出仓后才进入仓库预计到货。"
                    : "仓储部已收到预计到货提醒。";
            notifyUser(
                    (UUID) approval.get("submitted_by_user_id"),
                    TYPE_WORKFLOW,
                    "财务通过：" + billNo,
                    orderLabel + " " + billNo
                            + " 已通过财务审核并正式生效，" + approvedResult,
                    actionRoute);
            if (!subcontract) {
                String warehouseName = str(approval.get("warehouse_name"));
                String expectedDate = str(approval.get("expected_date"));
                for (UUID warehouseUser : departmentUserIdsWithAuthorities(
                        "SUB_WH", NOTICE_READ_AUTHORITY, "warehouse_inbound:view")) {
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
                broadcastToProcurementReturnFollowers(
                        str(arrival.get("order_type")), ownerUser,
                        TYPE_TASK, "供应商退回任务：" + orderNo,
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
                broadcastToProcurementReturnFollowers(
                        str(arrival.get("order_type")), ownerUser, TYPE_TASK,
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
            for (UUID warehouseUser : departmentUserIdsWithAuthorities(
                    "SUB_WH", NOTICE_READ_AUTHORITY, "warehouse_inbound:stock_in")) {
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

    /** 采购沿用采购池；委外按当前有效任务权限解析，不再硬编码到采购部。 */
    private void broadcastToProcurementReturnFollowers(
            String orderType,
            UUID excludeUser,
            String type,
            String title,
            String content,
            String route) {
        Set<UUID> targets = "SUBCONTRACT".equals(orderType)
                ? userIdsWithPermissions(
                        "supplier_return_task:view", NOTICE_READ_AUTHORITY)
                : new LinkedHashSet<>(departmentUserIds("SUB_PURCHASE"));
        for (UUID uid : targets) {
            if (excludeUser != null && excludeUser.equals(uid)) continue;
            sendToUser(uid, type, title, content, route, null, "normal");
        }
    }

    private Set<UUID> userIdsWithPermissions(String... required) {
        Set<String> permissions = Set.of(required);
        Set<UUID> result = new LinkedHashSet<>();
        for (UserAccount user : userRepo.findAll()) {
            if (user == null || user.isDeleted() || !"active".equals(user.getStatus())) continue;
            if (permissionResolver.permsOf(user).containsAll(permissions)) {
                result.add(user.getId());
            }
        }
        return result;
    }

    /** Active users with notice read plus at least one all-case/action permission. */
    private Set<UUID> userIdsWithNoticeAndAnyPermission(
            String... anyPermission) {
        Set<String> alternatives = Set.of(anyPermission);
        Set<UUID> result = new LinkedHashSet<>();
        for (UserAccount user : userRepo.findAll()) {
            if (user == null
                    || user.isDeleted()
                    || !"active".equals(user.getStatus())) {
                continue;
            }
            Set<String> permissions = permissionResolver.permsOf(user);
            if (!permissions.contains(NOTICE_READ_AUTHORITY)) continue;
            if (alternatives.stream().anyMatch(permissions::contains)) {
                result.add(user.getId());
            }
        }
        return result;
    }

    /** IQC task notices must open successfully: notice read + exact page view + one role action. */
    private Set<UUID> userIdsWithIqcViewAndAnyPermission(
            String... anyPermission) {
        Set<UUID> result = userIdsWithNoticeAndAnyPermission(anyPermission);
        result.removeIf(userId -> !userHasPermissions(
                userId,
                NOTICE_READ_AUTHORITY,
                IQC_REJECTION_VIEW_AUTHORITY));
        return result;
    }

    private boolean userHasPermissions(UUID userId, String... required) {
        if (userId == null) return false;
        Set<String> permissions = Set.of(required);
        return userRepo.findById(userId)
                .filter(user -> !user.isDeleted()
                        && "active".equals(user.getStatus()))
                .map(permissionResolver::permsOf)
                .map(authorities -> authorities.containsAll(permissions))
                .orElse(false);
    }

    private void notifySubcontractLossClaimEvent(String eventType, UUID caseId) {
        deliverAtomically(() -> {
            Map<String, Object> claim = one("""
                    SELECT loss.waste_bill_no,loss.status,supplier.name AS supplier_name
                    FROM subcontract_loss_cases loss
                    JOIN suppliers supplier ON supplier.id=loss.supplier_id
                    WHERE loss.id=?
                    """, caseId);
            if (claim == null) return;
            String wasteNo = str(claim.get("waste_bill_no"));
            String supplier = str(claim.get("supplier_name"));
            String status = str(claim.get("status"));
            String title;
            String content;
            String type;
            if (EVENT_SUBCONTRACT_LOSS_OPENED.equals(eventType)) {
                title = "委外超耗待财务决定：" + wasteNo;
                content = "委外商 " + supplier + " 的损耗单 " + wasteNo
                        + " 已形成超耗责任单。请核对公司承担、索赔、合法抵销、现金或实物补偿；"
                        + "损耗事实本身不会自动冲应付。";
                type = TYPE_APPROVAL;
                for (UUID reviewer : userIdsWithPermissions(
                        "subcontract_loss_claim:review", NOTICE_READ_AUTHORITY)) {
                    sendToUser(reviewer, type, title, content, "/finance/payables");
                }
                return;
            }
            if (EVENT_SUBCONTRACT_LOSS_DECIDED.equals(eventType)) {
                title = "委外超耗责任已决定：" + wasteNo;
                content = "委外商 " + supplier + " 的超耗责任已更新为 " + status
                        + "。待履约方案必须继续关联真实资金或实物证据。";
                type = TYPE_WORKFLOW;
            } else if (EVENT_SUBCONTRACT_LOSS_FULFILLED.equals(eventType)) {
                title = "委外超耗履约已登记：" + wasteNo;
                content = "委外商 " + supplier + " 的超耗补偿履约已登记，当前状态 "
                        + status + "。请按责任单核对抵销、到账或实物单据。";
                type = TYPE_WORKFLOW;
            } else {
                title = "委外超耗责任已反向：" + wasteNo;
                content = "委外商 " + supplier + " 的超耗责任/履约发生受控反向，当前状态 "
                        + status + "。请重新核对后续应付、资金和实物事实。";
                type = TYPE_URGENT;
            }

            Set<UUID> financeTargets = new LinkedHashSet<>(userIdsWithPermissions(
                    "subcontract_loss_claim:view", NOTICE_READ_AUTHORITY));
            if ("AWAITING_FULFILLMENT".equals(status)) {
                financeTargets.addAll(userIdsWithPermissions(
                        "subcontract_loss_claim:fulfill", NOTICE_READ_AUTHORITY));
            }
            for (UUID target : financeTargets) {
                sendToUser(target, type, title, content, "/finance/payables");
            }
            List<Map<String, Object>> owners = jdbc.queryForList("""
                    SELECT DISTINCT owner_user.id AS user_id,orders.id AS order_id
                    FROM subcontract_loss_case_lines line
                    JOIN subcontract_order_items order_item ON order_item.id=line.order_item_id
                    JOIN subcontract_orders orders ON orders.id=order_item.order_id
                    JOIN users owner_user ON owner_user.employee_id=orders.maker_id
                    WHERE line.case_id=?
                      AND owner_user.status='active'
                      AND COALESCE(owner_user.is_deleted,FALSE)=FALSE
                    """, caseId);
            for (Map<String, Object> owner : owners) {
                UUID ownerUserId = (UUID) owner.get("user_id");
                if (financeTargets.contains(ownerUserId)) continue;
                sendToUser(
                        ownerUserId,
                        type,
                        title,
                        content,
                        "/subcontract/orders/" + owner.get("order_id"));
            }
        });
    }

    /**
     * IQC failure, physical supplier return and the AP/credit decision are
     * separate facts. Notifications therefore point to the durable rejection
     * case and never copy commercial prices, exchange rates or credit amounts.
     *
     * <p>Ordinary {@code :view} is row-scoped: only the order owner may receive
     * that case. Global finance broadcasts require {@code notice:read} plus an
     * explicit all-case/action permission, so a user who can read only their
     * own orders cannot learn another order's rejection details.</p>
     */
    private void notifyProcurementIqcRejectionEvent(
            String eventType, UUID caseId) {
        deliverAtomically(() -> {
            Map<String, Object> rejection = one("""
                    SELECT rejection.receipt_type,
                           rejection.receipt_bill_no,
                           rejection.order_bill_no,
                           rejection.status,
                           rejection.owner_user_id,
                           rejection.failed_qty,
                           goods.code AS goods_code,
                           goods.name AS goods_name,
                           unit.name AS unit_name
                    FROM procurement_iqc_rejection_cases rejection
                    JOIN goods ON goods.id = rejection.goods_id
                    LEFT JOIN units unit ON unit.id = rejection.unit_id
                    WHERE rejection.id = ?
                      AND COALESCE(rejection.is_deleted, FALSE) = FALSE
                    """, caseId);
            if (rejection == null) return;

            String orderNo = str(rejection.get("order_bill_no"));
            String receiptNo = str(rejection.get("receipt_bill_no"));
            String goods = (str(rejection.get("goods_code")) + " "
                    + str(rejection.get("goods_name"))).strip();
            String failedQty = qty(bd(rejection.get("failed_qty")));
            String unit = str(rejection.get("unit_name"));
            String sourceLabel = ("SUBCONTRACT".equals(
                    str(rejection.get("receipt_type")))
                    ? "委外订货单 " : "采购订货单 ")
                    + (orderNo.isBlank() ? "（单号缺失）" : orderNo)
                    + " 的收货单 "
                    + (receiptNo.isBlank() ? "（单号缺失）" : receiptNo);
            String goodsLabel = goods.isBlank()
                    ? ""
                    : "，物料 " + goods + "，不合格数量 " + failedQty
                            + (unit.isBlank() ? "" : " " + unit);
            String route = "/procurement/iqc-rejections/" + caseId;

            String title;
            String content;
            String type;
            Set<UUID> recipients;
            if (EVENT_PROCUREMENT_IQC_REJECTION_OPENED.equals(eventType)) {
                title = "IQC不合格待处置：" + displayNo(orderNo, receiptNo);
                content = sourceLabel + goodsLabel
                        + " 已形成独立退回/贷项任务。IQC不合格不会进入可用库存，"
                        + "实物退回与供应商贷项必须分别留痕；请在任务详情跟进。";
                type = TYPE_TASK;
                recipients = userIdsWithIqcViewAndAnyPermission(
                        IQC_REJECTION_VIEW_ALL_AUTHORITY,
                        IQC_REJECTION_RECORD_RETURN_AUTHORITY,
                        IQC_REJECTION_CONFIRM_CREDIT_AUTHORITY,
                        IQC_REJECTION_CLOSE_NO_CREDIT_AUTHORITY);
                UUID ownerUserId = (UUID) rejection.get("owner_user_id");
                if (userHasPermissions(
                        ownerUserId,
                        NOTICE_READ_AUTHORITY,
                        IQC_REJECTION_VIEW_AUTHORITY)) {
                    recipients.add(ownerUserId);
                }
            } else if (EVENT_PROCUREMENT_IQC_REJECTION_RETURNED.equals(eventType)) {
                title = "IQC退回已登记，待财务结案："
                        + displayNo(orderNo, receiptNo);
                content = sourceLabel + goodsLabel
                        + " 的实物退回证据已登记。请财务核对后选择确认供应商贷项"
                        + "或无贷项结案；通知不代表应付已自动冲减。";
                type = TYPE_APPROVAL;
                recipients = userIdsWithIqcViewAndAnyPermission(
                        IQC_REJECTION_CONFIRM_CREDIT_AUTHORITY,
                        IQC_REJECTION_CLOSE_NO_CREDIT_AUTHORITY);
                UUID ownerUserId = (UUID) rejection.get("owner_user_id");
                if (userHasPermissions(
                        ownerUserId,
                        NOTICE_READ_AUTHORITY,
                        IQC_REJECTION_VIEW_AUTHORITY)) {
                    recipients.add(ownerUserId);
                }
            } else if (EVENT_PROCUREMENT_IQC_REJECTION_FINANCE_EXCEPTION.equals(
                    eventType)) {
                title = "IQC财务处置异常待复核："
                        + displayNo(orderNo, receiptNo);
                content = sourceLabel + goodsLabel
                        + " 的财务动作未完成，任务仍停留在持久状态 "
                        + str(rejection.get("status"))
                        + "。请从任务详情核对来源应付、贷项和抵销事实；"
                        + "不得据此通知手工修改应付余额。";
                type = TYPE_URGENT;
                recipients = userIdsWithIqcViewAndAnyPermission(
                        IQC_REJECTION_VIEW_ALL_AUTHORITY,
                        IQC_REJECTION_CONFIRM_CREDIT_AUTHORITY,
                        IQC_REJECTION_CLOSE_NO_CREDIT_AUTHORITY);
            } else {
                recipients = new LinkedHashSet<>(userIdsWithPermissions(
                        NOTICE_READ_AUTHORITY,
                        IQC_REJECTION_VIEW_ALL_AUTHORITY));
                UUID ownerUserId = (UUID) rejection.get("owner_user_id");
                if (userHasPermissions(
                        ownerUserId,
                        NOTICE_READ_AUTHORITY,
                        IQC_REJECTION_VIEW_AUTHORITY)) {
                    recipients.add(ownerUserId);
                }
                if (EVENT_PROCUREMENT_IQC_CREDIT_CONFIRMED.equals(eventType)) {
                    title = "IQC供应商贷项已确认："
                            + displayNo(orderNo, receiptNo);
                    content = sourceLabel + goodsLabel
                            + " 的供应商贷项与来源应付抵销已受控确认。"
                            + "具体商业数据仅在持权任务详情中查看。";
                    type = TYPE_WORKFLOW;
                } else if (EVENT_PROCUREMENT_IQC_REJECTION_NO_CREDIT.equals(
                        eventType)) {
                    title = "IQC无贷项已结案："
                            + displayNo(orderNo, receiptNo);
                    content = sourceLabel + goodsLabel
                            + " 已按留痕原因完成无贷项结案，未生成供应商贷项或自动应付抵销。"
                            + "具体商业数据仅在持权任务详情中查看。";
                    type = TYPE_WORKFLOW;
                } else {
                    title = "IQC拒收处置已反向："
                            + displayNo(orderNo, receiptNo);
                    content = sourceLabel + goodsLabel
                            + " 的退回/贷项处置发生受控反向，当前持久状态 "
                            + str(rejection.get("status"))
                            + "。请按任务详情重新执行后续步骤；通知本身不改变库存或应付。";
                    type = TYPE_URGENT;
                }
            }
            for (UUID recipient : recipients) {
                sendToUser(
                        recipient,
                        type,
                        title,
                        content,
                        route,
                        eventType);
            }
        });
    }

    private static String displayNo(String orderNo, String receiptNo) {
        return orderNo == null || orderNo.isBlank() ? receiptNo : orderNo;
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

    /** Current subcontract maker_id is an employee UUID, never a user UUID. */
    private UUID subcontractMakerUserId(UUID makerIdentity) {
        return userIdOfEmployee(makerIdentity);
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
        return departmentUserIdsWithAuthorities(departmentCode, authority);
    }

    /** 部门树候选与多个当前有效权限取交集。 */
    private List<UUID> departmentUserIdsWithAuthorities(
            String departmentCode, String... authorities) {
        Set<String> required = Set.of(authorities);
        return departmentUserIds(departmentCode).stream()
                .filter(userId -> userRepo.findById(userId)
                        .filter(account -> !account.isDeleted()
                                && "active".equals(account.getStatus()))
                        .map(permissionResolver::permsOf)
                        .map(permissions -> permissions.containsAll(required))
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
        sendToUser(userId, type, title, content, actionRoute, sourceEvent,
                explicitPriority, null);
    }

    /**
     * V459 审核待办入口：显式 aggregateId。sourceEvent 在
     * {@link ReviewNoticeCatalog} 注册时绑定聚合（办结撤回 + 弹卡认领状态查询）；
     * 未注册事件等价于普通 sendToUser。
     */
    private void sendToUser(UUID userId, String type, String title, String content,
                            String actionRoute, String sourceEvent,
                            String explicitPriority, UUID aggregateId) {
        UserAccount u = userRepo.findById(userId).orElse(null);
        if (u == null || !"active".equals(u.getStatus()) || u.isDeleted()) return;
        String effectiveSourceEvent = sourceEvent;
        if (effectiveSourceEvent == null || effectiveSourceEvent.isBlank()) {
            effectiveSourceEvent = OUTBOX_EVENT.get();
        }
        if (aggregateId == null) {
            // 无聚合：保持历史调用形态（7/8 参重载），既有测试与语义零变化。
            if (explicitPriority == null) {
                noticeService.publishForUser(
                        userId, title, content, type, PUBLISHER,
                        actionRoute, effectiveSourceEvent);
            } else {
                noticeService.publishForUser(
                        userId, title, content, type, PUBLISHER,
                        actionRoute, effectiveSourceEvent, explicitPriority);
            }
            return;
        }
        noticeService.publishForUser(
                userId, title, content, type, PUBLISHER, actionRoute,
                effectiveSourceEvent, explicitPriority, aggregateId);
    }

    /**
     * V459 办结撤回（业务落点统一入口）：审核通过/驳回/取消/开单等完成动作后，
     * 按 (aggregateKind, aggregateId) 批量 resolve 全部接收人的待审通知——
     * 弹卡停止展示、收件台计数归零、通知中心灰显「已办结」。幂等。
     */
    public int resolveReviewNotices(
            String aggregateKind, UUID aggregateId, String reason) {
        return noticeService.resolveReviewNotices(aggregateKind, aggregateId, reason);
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

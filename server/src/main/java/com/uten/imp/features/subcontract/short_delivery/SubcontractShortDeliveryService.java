package com.uten.imp.features.subcontract.short_delivery;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.application.port.SubcontractShortDeliveryPort;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.finance.procurement.ProcurementApprovalContracts;
import com.uten.imp.features.subcontract.SubcontractDocumentAccessPolicy;
import com.uten.imp.features.subcontract.order.SubcontractOrderService;
import com.uten.imp.features.subcontract.short_delivery.SubcontractShortDeliveryContracts.CaseDetail;
import com.uten.imp.features.subcontract.short_delivery.SubcontractShortDeliveryContracts.CaseEvent;
import com.uten.imp.features.subcontract.short_delivery.SubcontractShortDeliveryContracts.CaseRow;
import com.uten.imp.features.subcontract.short_delivery.SubcontractShortDeliveryContracts.Counts;
import com.uten.imp.features.subcontract.short_delivery.SubcontractShortDeliveryContracts.DecisionRequest;
import com.uten.imp.features.subcontract.short_delivery.SubcontractShortDeliveryContracts.GoodsLossRow;
import com.uten.imp.features.subcontract.short_delivery.SubcontractShortDeliveryContracts.SupplierLossSummary;
import com.uten.imp.features.subcontract.waste.SubcontractWasteService;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.sql.Timestamp;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.ArrayList;
import java.util.Collection;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

/**
 * ADR-098 委外回厂短交案件：登记评估、案件状态机、判定(分批到货 / 接受损耗结案)、判定页读模型、
 * 供应商损耗汇总。数量全部按订货单位; 累计回厂口径 = received − returned − IQC 已退回不合格量,
 * 与预计到货 accepted_qty 一致但不封顶。
 *
 * <p>「接受损耗结案」三步顺序固定(ADR-098 §2.3)：损耗单(核销供应商处剩料, 允许量按允许损耗) →
 * ADR-072 受控改量到累计回厂量(来源申请余量回到待下单、预计到货关闭、财务复核) → 案件记损耗率。
 * 通知一律走 Outbox 事件, 由 ChainNoticeService 发卡/撤卡。
 */
@Service
public class SubcontractShortDeliveryService
        implements SubcontractShortDeliveryPort, SubcontractShortDeliveryOrderHooks {

    public static final String AGGREGATE_KIND = "SUBCONTRACT_SHORT_DELIVERY_CASE";
    public static final String EVENT_DETECTED = "SUBCONTRACT_SHORT_DELIVERY_DETECTED";
    public static final String EVENT_WAIT_OVERDUE = "SUBCONTRACT_SHORT_DELIVERY_WAIT_OVERDUE";
    public static final String EVENT_RESOLVED = "SUBCONTRACT_SHORT_DELIVERY_RESOLVED";
    public static final String DECIDE_AUTHORITY = "subcontract_short_delivery:decide";
    public static final String VIEW_AUTHORITY = "subcontract_order:view";

    static final String STATUS_PENDING = "PENDING_OWNER";
    static final String STATUS_WAITING = "WAITING_MORE";
    static final String STATUS_ACCEPTED = "ACCEPTED_LOSS";
    static final String STATUS_COMPLETED = "COMPLETED";
    static final String STATUS_CANCELED = "CANCELED";
    static final String DECISION_WAIT = "WAIT_MORE";
    static final String DECISION_ACCEPT = "ACCEPT_LOSS";

    /** 有效状态：分批等待过了预计到齐日视同待判定(逾期)。 */
    static final String EFFECTIVE_STATUS_SQL = """
            CASE WHEN c.status = 'WAITING_MORE' AND c.expected_complete_by < CURRENT_DATE
                 THEN 'PENDING_OWNER' ELSE c.status END""";
    /** 待判定(红)：低于允许下限的两档待判定, 或分批等待过了预计到齐日。 */
    static final String PENDING_PREDICATE = """
            ((c.status = 'PENDING_OWNER' AND c.severity IN ('SEVERE', 'BELOW_FLOOR'))
             OR (c.status = 'WAITING_MORE' AND c.expected_complete_by < CURRENT_DATE))""";
    /** 容差内待结案(中性)：容差内 / 未设允许损耗的短交, 不急但要有人结案。 */
    static final String TOLERANT_PREDICATE =
            "(c.status = 'PENDING_OWNER' AND c.severity IN ('WITHIN_TOLERANCE', 'UNSET_TOLERANCE'))";
    static final String WAITING_PREDICATE =
            "(c.status = 'WAITING_MORE' AND c.expected_complete_by >= CURRENT_DATE)";
    static final String HISTORY_PREDICATE =
            "c.status IN ('ACCEPTED_LOSS', 'COMPLETED', 'CANCELED')";

    private static final Set<String> SEGMENTS = Set.of("PENDING", "TOLERANT", "WAITING", "HISTORY");
    private static final String DELIVERED_SQL = """
            GREATEST(COALESCE(oi.received_qty, 0) - COALESCE(oi.returned_qty, 0)
                     - COALESCE((
                         SELECT SUM(rejection.failed_qty)
                         FROM procurement_iqc_rejection_cases rejection
                         WHERE rejection.receipt_type = 'SUBCONTRACT'
                           AND rejection.order_item_id = oi.id
                           AND rejection.is_deleted = FALSE
                           AND rejection.return_recorded_at IS NOT NULL
                           AND rejection.status IN ('RETURN_RECORDED', 'CREDIT_CONFIRMED',
                                                    'CLOSED_NO_CREDIT', 'FINANCE_EXCEPTION')
                     ), 0), 0)""";
    private static final String FACT_SQL = """
            SELECT oi.id, oi.order_id, order_doc.bill_no, order_doc.supplier_id, order_doc.maker_id,
                   order_doc.purchaser_id, oi.goods_id, oi.color_id, oi.unit_id,
                   COALESCE(oi.goods_code_snapshot, goods.code), COALESCE(oi.goods_name_snapshot, goods.name),
                   color.name, unit.name, oi.line_no, oi.qty, oi.allowed_loss_pct,
                   COALESCE(oi.unit_rate, 1),
                   %s AS delivered_qty,
                   NOT EXISTS (
                       SELECT 1
                       FROM subcontract_material_plan_items plan_item
                       JOIN subcontract_material_plans plan
                         ON plan.id = plan_item.plan_id
                        AND plan.status = 'OPEN'
                        AND plan.is_deleted = FALSE
                       WHERE plan_item.order_item_id = oi.id
                         AND plan_item.is_deleted = FALSE
                         AND plan_item.issued_qty
                             < LEAST(plan_item.planned_qty, plan_item.prepared_qty)
                   ) AS material_fully_issued
            FROM subcontract_order_items oi
            JOIN subcontract_orders order_doc ON order_doc.id = oi.order_id
            JOIN goods ON goods.id = oi.goods_id
            LEFT JOIN colors color ON color.id = oi.color_id
            LEFT JOIN units unit ON unit.id = oi.unit_id
            WHERE oi.id IN (%s) AND oi.is_deleted = FALSE
            ORDER BY oi.order_id, oi.line_no, oi.id
            """;

    private final JdbcTemplate jdbc;
    private final EntityManager em;
    private final TxSessionVars tx;
    private final SecurityContextCurrentUser currentUser;
    private final BusinessEventPublisher events;
    private final SubcontractDocumentAccessPolicy access;
    private final SubcontractWasteService wasteService;
    private final SubcontractOrderService orderService;
    private final com.uten.imp.features.subcontract.plan.SubcontractMaterialPlanService materialPlans;
    private final EmployeeNameResolver nameResolver;
    private final ObjectMapper objectMapper;

    public SubcontractShortDeliveryService(
            JdbcTemplate jdbc,
            EntityManager em,
            TxSessionVars tx,
            SecurityContextCurrentUser currentUser,
            BusinessEventPublisher events,
            SubcontractDocumentAccessPolicy access,
            SubcontractWasteService wasteService,
            SubcontractOrderService orderService,
            com.uten.imp.features.subcontract.plan.SubcontractMaterialPlanService materialPlans,
            EmployeeNameResolver nameResolver,
            ObjectMapper objectMapper) {
        this.jdbc = jdbc;
        this.em = em;
        this.tx = tx;
        this.currentUser = currentUser;
        this.events = events;
        this.access = access;
        this.wasteService = wasteService;
        this.orderService = orderService;
        this.materialPlans = materialPlans;
        this.nameResolver = nameResolver;
        this.objectMapper = objectMapper;
    }

    // ===================== 到货登记：评估与记录 =====================

    @Override
    @Transactional(readOnly = true)
    public List<ShortDeliveryFinding> evaluateArrival(List<ArrivalQuantity> lines) {
        Map<UUID, BigDecimal> declared = new LinkedHashMap<>();
        for (ArrivalQuantity line : lines == null ? List.<ArrivalQuantity>of() : lines) {
            if (line == null || line.orderItemId() == null || line.qty() == null) continue;
            declared.merge(line.orderItemId(), line.qty(), BigDecimal::add);
        }
        if (declared.isEmpty()) return List.of();
        List<ShortDeliveryFinding> findings = new ArrayList<>();
        Map<UUID, OpenCase> openCases = openCases(declared.keySet(), false);
        for (ItemFacts fact : loadFacts(declared.keySet(), false)) {
            BigDecimal now = declared.getOrDefault(fact.orderItemId(), BigDecimal.ZERO);
            BigDecimal after = fact.deliveredQty().add(now);
            String severity = severityOf(fact, after);
            if (severity == null) continue;
            OpenCase open = openCases.get(fact.orderItemId());
            boolean waitingActive = open != null && STATUS_WAITING.equals(open.status())
                    && open.expectedCompleteBy() != null
                    && !open.expectedCompleteBy().isBefore(BusinessTime.today());
            findings.add(new ShortDeliveryFinding(
                    fact.orderItemId(), fact.orderBillNo(), fact.goodsLabel(), fact.unitName(),
                    fact.orderedQty(), fact.allowedLossPct(),
                    SubcontractShortDeliveryPolicy.floorQty(fact.orderedQty(), fact.allowedLossPct()),
                    fact.deliveredQty(), now, after,
                    SubcontractShortDeliveryPolicy.shortfallQty(fact.orderedQty(), after),
                    SubcontractShortDeliveryPolicy.shortfallPct(fact.orderedQty(), after),
                    severity, waitingActive, open == null ? null : open.expectedCompleteBy()));
        }
        return List.copyOf(findings);
    }

    /**
     * 入库放行闸(ADR-098 修订, 用户口径「先锁住, 先不入库」)：这张收货单里**哪一行**还有待
     * 委外判定的回厂短交(含分批等待已过预计到齐日), 就先不放行入库；委外判定成「分批到货」
     * 或「接受损耗」之后自动解锁。中性档(容差内 / 未设允许损耗)既不通知也不锁。
     *
     * <p>ADR-101 把关联口径从「同一张订货单」收到「同一行订货明细」：一张委外单多个货品时,
     * 一行短交不该把同单其它已经足额到齐的货一起冻在待入库——那与「分批发货、分批入库」
     * 直接冲突, 仓库会看到一批完全正常的货莫名其妙上不了架。
     */
    @Override
    @Transactional(readOnly = true)
    public String stockInHoldReason(UUID receiptId) {
        if (receiptId == null) return null;
        List<Map<String, Object>> rows = jdbc.queryForList("""
                SELECT DISTINCT order_doc.bill_no AS order_bill_no,
                       c.goods_name_snapshot AS goods_name,
                       c.goods_code_snapshot AS goods_code,
                       unit.name AS unit_name,
                       c.ordered_qty, c.delivered_qty, c.shortfall_qty,
                       (c.status = 'WAITING_MORE') AS overdue_wait
                FROM subcontract_receipt_items receipt_item
                JOIN subcontract_order_items order_item ON order_item.id = receipt_item.order_item_id
                JOIN subcontract_orders order_doc ON order_doc.id = order_item.order_id
                JOIN subcontract_short_delivery_cases c
                  ON c.order_item_id = receipt_item.order_item_id
                LEFT JOIN units unit ON unit.id = c.unit_id
                WHERE receipt_item.receipt_id = ?
                  AND COALESCE(receipt_item.is_deleted, FALSE) = FALSE
                  AND %s
                ORDER BY goods_name
                """.formatted(PENDING_PREDICATE), receiptId);
        if (rows.isEmpty()) return null;
        Map<String, Object> first = rows.getFirst();
        String unit = first.get("unit_name") == null ? "" : " " + first.get("unit_name");
        String goods = String.valueOf(first.get("goods_name"))
                + (first.get("goods_code") == null ? "" : " " + first.get("goods_code"));
        boolean overdue = Boolean.TRUE.equals(first.get("overdue_wait"));
        String more = rows.size() > 1 ? "等 " + rows.size() + " 项" : "";
        return "委外订货单 " + first.get("order_bill_no") + " 的「" + goods + "」" + more
                + "回厂比订货少 " + plain(decimal(first.get("shortfall_qty"))) + unit
                + "(订 " + plain(decimal(first.get("ordered_qty"))) + unit
                + ", 累计到 " + plain(decimal(first.get("delivered_qty"))) + unit + "), "
                + (overdue ? "此前判定的分批到货已过预计到齐日, " : "")
                + "已通知委外判定是分批到货还是接受损耗; 判定完成前这批先不入库, 货先留在待入库不要上架。";
    }

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void recordArrival(UUID receiptId, String receiptBillNo, boolean acknowledged) {
        List<UUID> orderItemIds = jdbc.queryForList("""
                SELECT DISTINCT order_item_id
                FROM subcontract_receipt_items
                WHERE receipt_id = ? AND order_item_id IS NOT NULL
                  AND COALESCE(is_deleted, FALSE) = FALSE
                ORDER BY order_item_id
                """, UUID.class, receiptId);
        if (orderItemIds.isEmpty()) return;
        UUID actorUser = currentUser.requireId();
        UUID actorEmployee = currentUser.requireEmployeeId();
        Map<UUID, OpenCase> openCases = openCases(orderItemIds, true);
        for (ItemFacts fact : loadFacts(orderItemIds, false)) {
            OpenCase open = openCases.get(fact.orderItemId());
            String severity = SubcontractShortDeliveryPolicy.severity(
                    fact.orderedQty(), fact.allowedLossPct(), fact.deliveredQty());
            if (severity == null) {
                if (open != null) {
                    closeCase(open, STATUS_COMPLETED, "COMPLETED", actorUser, actorEmployee,
                            snapshot(fact, receiptBillNo, "累计回厂已到齐"));
                }
                continue;
            }
            if (open == null) {
                // ADR-101：料还没全部发给委外商时不开案件——供应商手上只有已经发过去的那部分，
                // 这时候回厂少是分批发料的常态，不是短交。料发完之后由下一次登记，或者
                // settleAfterStockIn(仓库确认入库那一刻)补开。
                if (!fact.materialFullyIssued()) continue;
                openCase(fact, receiptId, receiptBillNo, severity, actorUser, actorEmployee, acknowledged);
                continue;
            }
            refreshOpenCase(open, fact, receiptId, receiptBillNo, severity, actorUser, actorEmployee,
                    acknowledged);
        }
    }

    // ===================== 订货单生命周期回调 =====================

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void reevaluateAfterOrderQuantityChange(UUID orderId) {
        List<UUID> orderItemIds = jdbc.queryForList("""
                SELECT order_item_id FROM subcontract_short_delivery_cases
                WHERE order_id = ? AND status IN ('PENDING_OWNER', 'WAITING_MORE')
                ORDER BY order_item_id
                """, UUID.class, orderId);
        if (orderItemIds.isEmpty()) return;
        UUID actorUser = currentUser.requireId();
        UUID actorEmployee = currentUser.requireEmployeeId();
        Map<UUID, OpenCase> openCases = openCases(orderItemIds, true);
        for (ItemFacts fact : loadFacts(orderItemIds, false)) {
            OpenCase open = openCases.get(fact.orderItemId());
            if (open == null) continue;
            String severity = SubcontractShortDeliveryPolicy.severity(
                    fact.orderedQty(), fact.allowedLossPct(), fact.deliveredQty());
            if (severity == null) {
                closeCase(open, STATUS_COMPLETED, "COMPLETED", actorUser, actorEmployee,
                        snapshot(fact, null, "订货量改为不高于累计回厂量"));
            } else {
                updateFigures(open.id(), fact, severity, null, null, false);
            }
        }
    }

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void cancelOpenCasesForOrder(UUID orderId, String reason) {
        List<UUID> orderItemIds = jdbc.queryForList("""
                SELECT order_item_id FROM subcontract_short_delivery_cases
                WHERE order_id = ? AND status IN ('PENDING_OWNER', 'WAITING_MORE')
                ORDER BY order_item_id
                """, UUID.class, orderId);
        if (orderItemIds.isEmpty()) return;
        UUID actorUser = currentUser.requireId();
        UUID actorEmployee = currentUser.requireEmployeeId();
        for (OpenCase open : openCases(orderItemIds, true).values()) {
            closeCase(open, STATUS_CANCELED, "CANCELED", actorUser, actorEmployee,
                    Map.of("reason", reason == null ? "" : reason));
        }
    }

    // ===================== 判定 =====================

    @Transactional
    public CaseDetail decide(UUID caseId, DecisionRequest request) {
        tx.bind();
        LockedCase locked = lockCase(caseId);
        if (!STATUS_PENDING.equals(locked.status()) && !STATUS_WAITING.equals(locked.status())) {
            throw new ApiException(ErrorCode.CONFLICT, "该短交案件已结案或已作废，请刷新后查看最新状态");
        }
        if (request.expectedVersion() == null || request.expectedVersion() != locked.version()) {
            throw new ApiException(ErrorCode.CONFLICT, "该短交案件已被其他人更新，请刷新后重试");
        }
        access.requireWritable(locked.ownerEmployeeId(), "只能判定本人负责的委外订货单的短交案件");
        UUID actorUser = currentUser.requireId();
        UUID actorEmployee = currentUser.requireEmployeeId();
        ItemFacts fact = loadFacts(List.of(locked.orderItemId()), true).stream().findFirst()
                .orElseThrow(() -> new ApiException(ErrorCode.CONFLICT, "订货明细已不存在，无法判定"));
        String note = request.note() == null ? null : request.note().strip();
        if (DECISION_WAIT.equals(request.decision())) {
            LocalDate expected = request.expectedCompleteBy();
            if (expected == null) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "分批到货必须填写预计到齐日期");
            }
            if (expected.isBefore(BusinessTime.today())) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "预计到齐日期不能早于今天");
            }
            jdbc.update("""
                    UPDATE subcontract_short_delivery_cases
                    SET status = 'WAITING_MORE', decision = 'WAIT_MORE', expected_complete_by = ?,
                        decision_note = ?, decided_by_user_id = ?, decided_by_employee_id = ?,
                        decided_at = now(), version = version + 1, updated_at = now()
                    WHERE id = ?
                    """, expected, blankToNull(note), actorUser, actorEmployee, caseId);
            Map<String, Object> snapshot = new LinkedHashMap<>(snapshot(fact, null, null));
            snapshot.put("expectedCompleteBy", expected.toString());
            if (note != null && !note.isBlank()) snapshot.put("note", note);
            appendEvent(caseId, "WAIT_MORE_DECIDED", actorUser, actorEmployee, snapshot);
            publishResolved(caseId, locked.version() + 1, "WAIT_MORE_DECIDED");
            return detail(caseId);
        }
        return acceptLoss(caseId, locked, fact, note, actorUser, actorEmployee, false);
    }

    /**
     * 「接受损耗·结案」的本体：损耗单 → 案件落 ACCEPTED_LOSS → 受控改量到累计回厂量。
     * 人工判定({@link #decide})与容差内自动结案({@link #settleAfterStockIn})共用，
     * 权限/归属校验在各自入口做完。
     *
     * <p>{@code systemInitiated} 区分第三步受控改量走哪条入口：人工判定是本人在操作自己
     * 负责的单, 照旧过订货单属主守卫; 容差内自动结案跑在**仓库确认入库的同一个事务**里,
     * 发起人是仓库账号 —— 它既不是委外订货单的制单人, 通常也没有 subcontract:view:all,
     * 走属主守卫必拿 FORBIDDEN, 而这段异常会把整个事务标成只能回滚, 货就入不了库。
     * 自动结案是锦上添花, 绝不能反过来把仓库正常的入库动作搞失败。
     */
    private CaseDetail acceptLoss(UUID caseId, LockedCase locked, ItemFacts fact, String note,
                                  UUID actorUser, UUID actorEmployee, boolean systemInitiated) {
        BigDecimal shortfall = SubcontractShortDeliveryPolicy.shortfallQty(fact.orderedQty(), fact.deliveredQty());
        if (shortfall.signum() <= 0) {
            closeCase(new OpenCase(caseId, locked.status(), null, locked.version(), locked.ownerEmployeeId()),
                    STATUS_COMPLETED, "COMPLETED", actorUser, actorEmployee,
                    snapshot(fact, null, "判定时累计回厂已到齐"));
            return detail(caseId);
        }
        if (fact.deliveredQty().signum() <= 0) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "该行累计回厂为 0，不能按接受损耗结案；请红冲订货单或用受控改量处理");
        }
        String severity = SubcontractShortDeliveryPolicy.severity(
                fact.orderedQty(), fact.allowedLossPct(), fact.deliveredQty());
        if (SubcontractShortDeliveryPolicy.isBelowFloor(severity) && (note == null || note.isBlank())) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "低于允许损耗下限的短交结案必须填写说明");
        }
        BigDecimal allowedShortfall = SubcontractShortDeliveryPolicy.allowedLossQty(
                fact.orderedQty(), fact.allowedLossPct()).min(shortfall);
        String cause = "委外回厂短交结案(订货单 " + fact.orderBillNo() + " 第 " + fact.lineNo() + " 行，短交 "
                + plain(shortfall) + (fact.unitName() == null ? "" : " " + fact.unitName()) + ")";
        // 顺序固定(ADR-098 §2.3)：① 损耗单核销供应商处剩料 → ② 案件先落 ACCEPTED_LOSS(记损耗) →
        // ③ 受控改量到累计回厂量(改量回调重评时案件已终态, 不会被当成自然到齐)→ ④ 记改量 id。
        UUID wasteId = wasteService.recordShortDeliveryLoss(
                fact.orderItemId(), fact.orderUnitRate(), shortfall, allowedShortfall,
                fact.allowedLossPct(), cause, BusinessTime.today());
        BigDecimal lossPct = SubcontractShortDeliveryPolicy.shortfallPct(fact.orderedQty(), fact.deliveredQty());
        int changed = jdbc.update("""
                UPDATE subcontract_short_delivery_cases
                SET status = 'ACCEPTED_LOSS', decision = 'ACCEPT_LOSS', expected_complete_by = NULL,
                    decision_note = ?, decided_by_user_id = ?, decided_by_employee_id = ?,
                    decided_at = now(), closed_at = now(), loss_qty = ?, loss_pct = ?,
                    waste_id = ?,
                    ordered_qty = ?, delivered_qty = ?, shortfall_qty = ?, shortfall_pct = ?, severity = ?,
                    last_evaluated_at = now(), version = version + 1, updated_at = now()
                WHERE id = ? AND status IN ('PENDING_OWNER', 'WAITING_MORE')
                """, blankToNull(note), actorUser, actorEmployee, shortfall, lossPct, wasteId,
                fact.orderedQty(), fact.deliveredQty(), shortfall, lossPct, severity, caseId);
        if (changed != 1) {
            throw new ApiException(ErrorCode.CONFLICT, "该短交案件状态已变化，请刷新后重试");
        }
        var qtyChange = new ProcurementApprovalContracts.OrderQtyChangeRequest(List.of(
                new ProcurementApprovalContracts.OrderQtyChangeItem(
                        fact.orderItemId(), fact.deliveredQty())));
        if (systemInitiated) {
            orderService.changeQtyForShortDeliveryBySystem(fact.orderId(), qtyChange);
        } else {
            orderService.changeQtyForShortDelivery(fact.orderId(), qtyChange);
        }
        UUID changeLogId = jdbc.query("""
                SELECT id FROM procurement_order_qty_change_logs
                WHERE order_type = 'SUBCONTRACT' AND order_item_id = ?
                ORDER BY changed_at DESC LIMIT 1
                """, rs -> rs.next() ? rs.getObject("id", UUID.class) : null, fact.orderItemId());
        if (changeLogId != null) {
            jdbc.update("UPDATE subcontract_short_delivery_cases SET qty_change_log_id = ? WHERE id = ?",
                    changeLogId, caseId);
        }
        Map<String, Object> snapshot = new LinkedHashMap<>(snapshot(fact, null, null));
        snapshot.put("lossQty", shortfall);
        snapshot.put("lossPct", lossPct);
        snapshot.put("allowedShortfallQty", allowedShortfall);
        if (wasteId != null) snapshot.put("wasteId", wasteId.toString());
        if (changeLogId != null) snapshot.put("qtyChangeLogId", changeLogId.toString());
        if (note != null && !note.isBlank()) snapshot.put("note", note);
        appendEvent(caseId, "ACCEPT_LOSS_DECIDED", actorUser, actorEmployee, snapshot);
        publishResolved(caseId, locked.version() + 1, "ACCEPT_LOSS_DECIDED");
        if (systemInitiated) {
            // 与 SubcontractOrderService.changeQtyInternal 末尾同一道理: 自动结案的返回值在
            // settleAfterStockIn 那里就被丢弃, 而 detail(caseId) 走的是
            // nativeReadScope(owner_employee_id, VIEW_AUTHORITY=subcontract_order:view) —— 案件
            // 归属人是订货单制单人, 仓库账号既没有这个权限点也不在可见归属集里, 会抛
            // NOT_FOUND「短交案件不存在或无权查看」, 把仓库确认入库的整个事务毒死。
            return null;
        }
        return detail(caseId);
    }

    /**
     * ADR-101(推翻 ADR-098 §四「不做容差内自动结案」)：仓库把货确认入库的那一刻，
     * 累计回厂已经落在允许损耗范围内、并且本行的料已经全部发出去了，就直接按接受损耗结案。
     *
     * <p>用户口径：「需要 1000 个、损耗比 10%，我仓库收货只要大于 900 就能正常入库，然后这个
     * 单子结束，不需要再等那 100 个了，但这 100 个算损耗件。」允许损耗本身就是双方事先约定
     * 的「交到这个数就算交完」，所以它就是 ADR-098 当初说缺的那个「供应商说交完了」的信号；
     * 再要人去判定页点一次，只是把一件已经谈好的事又挂起来等人。
     *
     * <p>只自动结 WITHIN_TOLERANCE 一档：没填允许损耗(UNSET_TOLERANCE)时没有约定可依，
     * 低于下限的两档本来就要委外自己判分批还是认损耗，都保持人工。
     *
     * <p>同一张收货单可能一次结掉同一订货单的多行。逐行结案能走通，靠的是
     * {@code changeQtyForShortDelivery} 不再受「无在办财务复核」那道闸约束——否则第二行会被
     * 第一行自己开出来的复核 case 挡死，连它刚开的损耗单一起回滚。
     */
    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void settleAfterStockIn(UUID receiptId) {
        if (receiptId == null) return;
        List<UUID> orderItemIds = jdbc.queryForList("""
                SELECT DISTINCT order_item_id
                FROM subcontract_receipt_items
                WHERE receipt_id = ? AND order_item_id IS NOT NULL
                  AND COALESCE(is_deleted, FALSE) = FALSE
                ORDER BY order_item_id
                """, UUID.class, receiptId);
        if (orderItemIds.isEmpty()) return;
        UUID actorUser = currentUser.requireId();
        UUID actorEmployee = currentUser.requireEmployeeId();
        Map<UUID, OpenCase> openCases = openCases(orderItemIds, true);
        List<ItemFacts> tolerant = new ArrayList<>();
        for (ItemFacts fact : loadFacts(orderItemIds, false)) {
            if (!fact.materialFullyIssued()) continue;
            String severity = SubcontractShortDeliveryPolicy.severity(
                    fact.orderedQty(), fact.allowedLossPct(), fact.deliveredQty());
            OpenCase open = openCases.get(fact.orderItemId());
            if (severity == null) {
                // 到齐即完结。补开路径(settleAfterStockIn)开的案件没有「登记 → recordArrival」
                // 替它落 COMPLETED——这里不收口，它就永远挂在「容差内待结案」(ADR-098 中性档
                // 零通知, 没有人会被提醒)。与 recordArrival 的「累计回厂已到齐」同款收口。
                if (open != null) {
                    closeCase(open, STATUS_COMPLETED, "COMPLETED", actorUser, actorEmployee,
                            snapshot(fact, null, "累计回厂已到齐"));
                }
                continue;
            }
            if (open == null) {
                // 料是在最后一批货到齐之后才发完的：登记那一刻还判不出短交，这里补开。
                openCase(fact, receiptId, null, severity, actorUser, actorEmployee, true);
                open = openCases(List.of(fact.orderItemId()), true).get(fact.orderItemId());
                if (open == null) continue;
            }
            if (SubcontractShortDeliveryPolicy.WITHIN_TOLERANCE.equals(severity)
                    && STATUS_PENDING.equals(open.status())
                    && fact.deliveredQty().signum() > 0
                    && autoCloseWouldSucceed(fact)) {
                tolerant.add(fact);
            }
        }
        if (tolerant.isEmpty()) return;
        for (ItemFacts fact : tolerant) {
            OpenCase open = openCases(List.of(fact.orderItemId()), true).get(fact.orderItemId());
            if (open == null) continue;
            acceptLoss(open.id(),
                    new LockedCase(open.id(), open.status(), fact.orderItemId(), fact.orderId(),
                            open.version(), open.ownerEmployeeId(),
                            SubcontractShortDeliveryPolicy.WITHIN_TOLERANCE),
                    fact, "累计回厂已在本单允许损耗范围内，系统按约定的允许损耗自动结案",
                    actorUser, actorEmployee, true);
        }
    }

    // ===================== 读模型 =====================

    @Transactional(readOnly = true)
    public PageResponse<CaseRow> list(String segment, String keyword, UUID supplierId, UUID orderId,
                                      LocalDate dateFrom, LocalDate dateTo, int page, int size) {
        String normalized = segment == null ? "PENDING" : segment.strip().toUpperCase();
        if (!SEGMENTS.contains(normalized)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "短交案件分段无效");
        }
        int safePage = Math.max(page, 1);
        int safeSize = Math.min(Math.max(size, 1), 200);
        var scope = access.nativeReadScope("c.owner_employee_id", "owners", VIEW_AUTHORITY);
        String predicate = switch (normalized) {
            case "PENDING" -> PENDING_PREDICATE;
            case "TOLERANT" -> TOLERANT_PREDICATE;
            case "WAITING" -> WAITING_PREDICATE;
            default -> HISTORY_PREDICATE;
        };
        String orderBy = switch (normalized) {
            case "PENDING" -> """
                    CASE c.severity WHEN 'SEVERE' THEN 0 WHEN 'BELOW_FLOOR' THEN 1
                         WHEN 'UNSET_TOLERANCE' THEN 2 ELSE 3 END, c.detected_at DESC""";
            case "TOLERANT" -> "c.detected_at DESC";
            case "WAITING" -> "c.expected_complete_by ASC, c.detected_at DESC";
            default -> "c.closed_at DESC NULLS LAST, c.detected_at DESC";
        };
        String where = predicate + " AND " + scope.predicate() + """
                 AND (CAST(:supplierId AS uuid) IS NULL OR c.supplier_id = CAST(:supplierId AS uuid))
                 AND (CAST(:orderId AS uuid) IS NULL OR c.order_id = CAST(:orderId AS uuid))
                 AND (:keyword = '' OR LOWER(
                      COALESCE(c.order_bill_no_snapshot, '') || ' ' || COALESCE(supplier.name, '') || ' ' ||
                      COALESCE(c.goods_code_snapshot, goods.code, '') || ' ' ||
                      COALESCE(c.goods_name_snapshot, goods.name, '') || ' ' ||
                      COALESCE(c.receipt_bill_no_snapshot, '')) LIKE :keywordLike)
                 AND (CAST(:dateFrom AS date) IS NULL OR COALESCE(c.closed_at, c.detected_at) >= CAST(:dateFrom AS date))
                 AND (CAST(:dateTo AS date) IS NULL
                      OR COALESCE(c.closed_at, c.detected_at) < CAST(:dateTo AS date) + INTERVAL '1 day')
                """;
        Query rows = em.createNativeQuery(ROW_SELECT + " WHERE " + where + " ORDER BY " + orderBy
                + " OFFSET :offset LIMIT :limit");
        Query count = em.createNativeQuery("SELECT COUNT(*) " + ROW_FROM + " WHERE " + where);
        for (Query query : List.of(rows, count)) {
            scope.bind(query);
            query.setParameter("supplierId", supplierId == null ? null : supplierId.toString());
            query.setParameter("orderId", orderId == null ? null : orderId.toString());
            String kw = keyword == null ? "" : keyword.strip().toLowerCase();
            query.setParameter("keyword", kw);
            query.setParameter("keywordLike", "%" + kw + "%");
            query.setParameter("dateFrom", dateFrom == null ? null : dateFrom.toString());
            query.setParameter("dateTo", dateTo == null ? null : dateTo.toString());
        }
        rows.setParameter("offset", (long) (safePage - 1) * safeSize);
        rows.setParameter("limit", safeSize);
        boolean decideAuthority = access.hasAuthority(DECIDE_AUTHORITY);
        List<CaseRow> items = NativeQueryResults.objectArrayRows(rows).stream()
                .map(row -> mapRow(row, decideAuthority)).toList();
        long total = ((Number) count.getSingleResult()).longValue();
        return new PageResponse<>(items, safePage, safeSize, total,
                (int) Math.ceil(total / (double) safeSize));
    }

    @Transactional(readOnly = true)
    public Counts counts() {
        if (!access.hasAuthority(VIEW_AUTHORITY)) return new Counts(0, 0, 0);
        var scope = access.nativeReadScope("c.owner_employee_id", "owners", VIEW_AUTHORITY);
        Query query = em.createNativeQuery("""
                SELECT COUNT(*) FILTER (WHERE %s), COUNT(*) FILTER (WHERE %s), COUNT(*) FILTER (WHERE %s)
                FROM subcontract_short_delivery_cases c
                WHERE c.status IN ('PENDING_OWNER', 'WAITING_MORE') AND %s
                """.formatted(PENDING_PREDICATE, TOLERANT_PREDICATE, WAITING_PREDICATE, scope.predicate()));
        scope.bind(query);
        Object[] row = (Object[]) query.getSingleResult();
        return new Counts(((Number) row[0]).longValue(), ((Number) row[1]).longValue(),
                ((Number) row[2]).longValue());
    }

    @Transactional(readOnly = true)
    public CaseDetail detail(UUID caseId) {
        var scope = access.nativeReadScope("c.owner_employee_id", "owners", VIEW_AUTHORITY);
        Query query = em.createNativeQuery(ROW_SELECT + " WHERE c.id = :id AND " + scope.predicate());
        scope.bind(query);
        query.setParameter("id", caseId);
        List<Object[]> rows = NativeQueryResults.objectArrayRows(query);
        if (rows.isEmpty()) {
            throw new ApiException(ErrorCode.NOT_FOUND, "短交案件不存在或无权查看");
        }
        CaseRow row = mapRow(rows.getFirst(), access.hasAuthority(DECIDE_AUTHORITY));
        List<CaseEvent> caseEvents = jdbc.query("""
                SELECT id, event_type, actor_employee_id, created_at, event_snapshot::text
                FROM subcontract_short_delivery_case_events
                WHERE case_id = ? ORDER BY created_at, id
                """, (rs, n) -> new CaseEvent(
                        rs.getObject("id", UUID.class),
                        rs.getString("event_type"),
                        nameResolver.nameOf(rs.getObject("actor_employee_id", UUID.class)),
                        offset(rs.getTimestamp("created_at")),
                        readSnapshot(rs.getString("event_snapshot"))), caseId);
        return new CaseDetail(row, caseEvents);
    }

    @Transactional(readOnly = true)
    public SupplierLossSummary supplierSummary(UUID supplierId) {
        if (supplierId == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "供应商 ID 不能为空");
        }
        Map<String, Object> summary = jdbc.query("""
                SELECT settled_line_count, accepted_loss_count, ordered_qty, loss_qty, loss_pct,
                       max_loss_pct, last_loss_at
                FROM v_subcontract_supplier_loss_summary WHERE supplier_id = ?
                """, rs -> {
                    if (!rs.next()) return null;
                    Map<String, Object> m = new LinkedHashMap<>();
                    m.put("settled", rs.getLong(1));
                    m.put("accepted", rs.getLong(2));
                    m.put("ordered", rs.getBigDecimal(3));
                    m.put("loss", rs.getBigDecimal(4));
                    m.put("lossPct", rs.getBigDecimal(5));
                    m.put("maxLossPct", rs.getBigDecimal(6));
                    m.put("lastLossAt", rs.getTimestamp(7));
                    return m;
                }, supplierId);
        List<GoodsLossRow> byGoods = jdbc.query("""
                SELECT v.goods_id, goods.code, goods.name, v.settled_line_count, v.accepted_loss_count,
                       v.ordered_qty, v.loss_qty, v.loss_pct, v.max_loss_pct, v.last_loss_at
                FROM v_subcontract_supplier_goods_loss_summary v
                JOIN goods ON goods.id = v.goods_id
                WHERE v.supplier_id = ?
                ORDER BY v.loss_pct DESC, v.loss_qty DESC, goods.code
                LIMIT 50
                """, (rs, n) -> new GoodsLossRow(
                        rs.getObject(1, UUID.class), rs.getString(2), rs.getString(3),
                        rs.getLong(4), rs.getLong(5), rs.getBigDecimal(6), rs.getBigDecimal(7),
                        rs.getBigDecimal(8), rs.getBigDecimal(9), offset(rs.getTimestamp(10))),
                supplierId);
        List<CaseRow> recent = list("HISTORY", null, supplierId, null, null, null, 1, 10).getItems().stream()
                .filter(row -> STATUS_ACCEPTED.equals(row.status())).toList();
        if (summary == null) {
            return new SupplierLossSummary(supplierId, 0, 0, BigDecimal.ZERO, BigDecimal.ZERO,
                    BigDecimal.ZERO, BigDecimal.ZERO, null, byGoods, recent);
        }
        return new SupplierLossSummary(supplierId,
                (Long) summary.get("settled"), (Long) summary.get("accepted"),
                (BigDecimal) summary.get("ordered"), (BigDecimal) summary.get("loss"),
                (BigDecimal) summary.get("lossPct"), (BigDecimal) summary.get("maxLossPct"),
                offset((Timestamp) summary.get("lastLossAt")), byGoods, recent);
    }

    /** 供应商列表「损耗率(%)」列：一次查页内供应商的加权损耗率(无结清行的供应商不出现)。 */
    @Transactional(readOnly = true)
    public Map<UUID, BigDecimal> lossPctBySupplier(Collection<UUID> supplierIds) {
        if (supplierIds == null || supplierIds.isEmpty()) return Map.of();
        List<UUID> ids = List.copyOf(supplierIds);
        Map<UUID, BigDecimal> result = new LinkedHashMap<>();
        jdbc.query("SELECT supplier_id, loss_pct FROM v_subcontract_supplier_loss_summary WHERE supplier_id IN ("
                        + placeholders(ids.size()) + ")",
                rs -> { result.put(rs.getObject(1, UUID.class), rs.getBigDecimal(2)); },
                ids.toArray());
        return result;
    }

    /** 逾期扫描(调度器)：分批等待过了预计到齐日的案件, 每个业务日最多投递一次重要通知; 不改状态(有效状态按读计算)。 */
    @Transactional
    public int publishOverdueWaiting(LocalDate businessDate) {
        List<Object[]> due = jdbc.query("""
                SELECT id, version FROM subcontract_short_delivery_cases c
                WHERE c.status = 'WAITING_MORE' AND c.expected_complete_by < ?
                ORDER BY c.expected_complete_by, c.id
                """, (rs, n) -> new Object[]{rs.getObject(1, UUID.class), rs.getLong(2)}, businessDate);
        for (Object[] row : due) {
            UUID caseId = (UUID) row[0];
            events.publishOnce(EVENT_WAIT_OVERDUE, AGGREGATE_KIND, caseId,
                    Map.of("businessDate", businessDate.toString(), "version", row[1]),
                    EVENT_WAIT_OVERDUE + ':' + caseId + ':' + businessDate);
        }
        return due.size();
    }

    // ===================== 内部 =====================

    private static final String ROW_FROM = """
            FROM subcontract_short_delivery_cases c
            JOIN subcontract_order_items oi ON oi.id = c.order_item_id
            JOIN goods ON goods.id = c.goods_id
            LEFT JOIN suppliers supplier ON supplier.id = c.supplier_id
            LEFT JOIN colors color ON color.id = c.color_id
            LEFT JOIN units unit ON unit.id = c.unit_id
            LEFT JOIN subcontract_wastes waste ON waste.id = c.waste_id
            """;
    private static final String ROW_SELECT = """
            SELECT c.id, c.order_id, c.order_bill_no_snapshot, c.order_item_id, oi.line_no,
                   c.supplier_id, supplier.name, c.goods_id,
                   COALESCE(c.goods_code_snapshot, goods.code), COALESCE(c.goods_name_snapshot, goods.name),
                   color.name, unit.name, c.receipt_id, c.receipt_bill_no_snapshot,
                   c.ordered_qty, c.allowed_loss_pct, c.floor_qty, c.delivered_qty, c.shortfall_qty, c.shortfall_pct,
                   c.severity, c.status, %s AS effective_status,
                   (c.status = 'WAITING_MORE' AND c.expected_complete_by < CURRENT_DATE) AS overdue,
                   c.decision, c.expected_complete_by, c.decision_note, c.arrival_count,
                   c.owner_employee_id, c.decided_by_employee_id, c.detected_at, c.last_evaluated_at,
                   c.decided_at, c.closed_at, c.loss_qty, c.loss_pct, c.waste_id, waste.bill_no, c.version
            """.formatted(EFFECTIVE_STATUS_SQL) + ROW_FROM;

    private CaseRow mapRow(Object[] r, boolean decideAuthority) {
        UUID ownerEmployee = (UUID) r[28];
        String status = (String) r[21];
        boolean open = STATUS_PENDING.equals(status) || STATUS_WAITING.equals(status);
        return new CaseRow(
                (UUID) r[0], (UUID) r[1], (String) r[2], (UUID) r[3], r[4] == null ? null : ((Number) r[4]).intValue(),
                (UUID) r[5], (String) r[6], (UUID) r[7], (String) r[8], (String) r[9], (String) r[10], (String) r[11],
                (UUID) r[12], (String) r[13],
                decimal(r[14]), (BigDecimal) r[15], (BigDecimal) r[16], decimal(r[17]), decimal(r[18]), decimal(r[19]),
                (String) r[20], status, (String) r[22], Boolean.TRUE.equals(r[23]),
                (String) r[24], localDate(r[25]), (String) r[26], r[27] == null ? 0 : ((Number) r[27]).intValue(),
                nameResolver.nameOf(ownerEmployee), nameResolver.nameOf((UUID) r[29]),
                offset(r[30]), offset(r[31]), offset(r[32]), offset(r[33]),
                (BigDecimal) r[34], (BigDecimal) r[35], (UUID) r[36], (String) r[37],
                ((Number) r[38]).longValue(),
                open && decideAuthority && access.canWrite(ownerEmployee));
    }

    private record ItemFacts(
            UUID orderItemId, UUID orderId, String orderBillNo, UUID supplierId, UUID makerId, UUID purchaserId,
            UUID goodsId, UUID colorId, UUID unitId, String goodsCode, String goodsName, String colorName,
            String unitName, Integer lineNo, BigDecimal orderedQty, BigDecimal allowedLossPct,
            BigDecimal orderUnitRate, BigDecimal deliveredQty,
            /** 本行的料是不是已经全部发给委外商了(没有 OPEN 计划行还留着未发的量)。 */
            boolean materialFullyIssued) {
        String goodsLabel() {
            StringBuilder label = new StringBuilder();
            if (goodsName != null && !goodsName.isBlank()) label.append(goodsName);
            if (goodsCode != null && !goodsCode.isBlank()) label.append(label.isEmpty() ? "" : " ").append(goodsCode);
            if (colorName != null && !colorName.isBlank()) label.append(label.isEmpty() ? "" : " ").append(colorName);
            return label.toString();
        }
    }

    /**
     * 自动结案的前置体检：结案第三步的受控改量有一条下限——订货量不得低于「供应商手上还
     * 没交代的料」。结案第一步的损耗单会把短交那一份核销掉，所以只要供应商手上的料不超过
     * 原订货量，改量就一定过得去。
     *
     * <p>为什么必须先体检而不是 try/catch：这段跑在**仓库确认入库的同一个事务**里，
     * changeQtyForShortDelivery 一旦抛异常就会把整个事务标成只能回滚——货就入不了库了。
     * 自动结案是锦上添花，绝不能反过来把仓库正常的入库动作搞失败。体检没过的行原样留着，
     * 由人去判定页按 ADR-098 的老路处理(多半是供应商手上还有多发的料，要先退料或记损耗)。
     */
    private boolean autoCloseWouldSucceed(ItemFacts fact) {
        try {
            BigDecimal supplierHeld = materialPlans.minimumOrderQtyFromIssued(
                    fact.orderItemId(), fact.orderUnitRate());
            return supplierHeld == null || supplierHeld.compareTo(fact.orderedQty()) <= 0;
        } catch (ApiException probeFailed) {
            // 历史行缺冻结单耗之类推算不出来的，一律留给人工，不在入库路径上冒险。
            return false;
        }
    }

    /**
     * 程度判定的唯一入口(ADR-101)：本行的料还没全部发给委外商时一律不判短交。
     *
     * <p>委外是「先发料、后回厂」，分批发料时供应商手上只有已经发过去的那部分，回厂自然
     * 少于订货量。此前按整张订货行的数量直判，于是每一批回厂都会被判成严重短交、开红档
     * 案件、通知委外、并把整单锁住不让入库——分批发货在这条口径下根本走不通。
     * 料发完之后(含仓库「不再出仓」关掉余量)再判，口径与用户给的 1000 / 10% / 900 完全一致。
     */
    private String severityOf(ItemFacts fact, BigDecimal deliveredQty) {
        if (!fact.materialFullyIssued()) return null;
        return SubcontractShortDeliveryPolicy.severity(
                fact.orderedQty(), fact.allowedLossPct(), deliveredQty);
    }

    private record OpenCase(UUID id, String status, LocalDate expectedCompleteBy, long version,
                            UUID ownerEmployeeId) {}

    private record LockedCase(UUID id, String status, UUID orderItemId, UUID orderId, long version,
                              UUID ownerEmployeeId, String severity) {}

    private List<ItemFacts> loadFacts(Collection<UUID> orderItemIds, boolean forUpdate) {
        List<UUID> ids = List.copyOf(orderItemIds);
        String sql = FACT_SQL.formatted(DELIVERED_SQL, placeholders(ids.size()))
                + (forUpdate ? " FOR UPDATE OF oi" : "");
        return jdbc.query(sql, (rs, n) -> new ItemFacts(
                rs.getObject(1, UUID.class), rs.getObject(2, UUID.class), rs.getString(3),
                rs.getObject(4, UUID.class), rs.getObject(5, UUID.class), rs.getObject(6, UUID.class),
                rs.getObject(7, UUID.class), rs.getObject(8, UUID.class), rs.getObject(9, UUID.class),
                rs.getString(10), rs.getString(11), rs.getString(12), rs.getString(13),
                rs.getObject(14) == null ? null : rs.getInt(14),
                rs.getBigDecimal(15), rs.getBigDecimal(16), rs.getBigDecimal(17), rs.getBigDecimal(18),
                rs.getBoolean(19)),
                ids.toArray());
    }

    private Map<UUID, OpenCase> openCases(Collection<UUID> orderItemIds, boolean forUpdate) {
        List<UUID> ids = List.copyOf(orderItemIds);
        Map<UUID, OpenCase> result = new LinkedHashMap<>();
        jdbc.query("""
                SELECT id, status, expected_complete_by, version, owner_employee_id, order_item_id
                FROM subcontract_short_delivery_cases
                WHERE order_item_id IN (%s) AND status IN ('PENDING_OWNER', 'WAITING_MORE')
                ORDER BY id
                """.formatted(placeholders(ids.size())) + (forUpdate ? " FOR UPDATE" : ""),
                rs -> {
                    result.put(rs.getObject("order_item_id", UUID.class), new OpenCase(
                            rs.getObject("id", UUID.class), rs.getString("status"),
                            rs.getObject("expected_complete_by", LocalDate.class), rs.getLong("version"),
                            rs.getObject("owner_employee_id", UUID.class)));
                }, ids.toArray());
        return result;
    }

    private LockedCase lockCase(UUID caseId) {
        return jdbc.query("""
                SELECT id, status, order_item_id, order_id, version, owner_employee_id, severity
                FROM subcontract_short_delivery_cases WHERE id = ? FOR UPDATE
                """, rs -> {
                    if (!rs.next()) throw new ApiException(ErrorCode.NOT_FOUND, "短交案件不存在");
                    return new LockedCase(rs.getObject(1, UUID.class), rs.getString(2), rs.getObject(3, UUID.class),
                            rs.getObject(4, UUID.class), rs.getLong(5), rs.getObject(6, UUID.class), rs.getString(7));
                }, caseId);
    }

    private void openCase(ItemFacts fact, UUID receiptId, String receiptBillNo, String severity,
                          UUID actorUser, UUID actorEmployee, boolean acknowledged) {
        UUID caseId = UUID.randomUUID();
        BigDecimal shortfall = SubcontractShortDeliveryPolicy.shortfallQty(fact.orderedQty(), fact.deliveredQty());
        jdbc.update("""
                INSERT INTO subcontract_short_delivery_cases (
                    id, order_id, order_item_id, order_bill_no_snapshot, supplier_id, goods_id, color_id, unit_id,
                    goods_code_snapshot, goods_name_snapshot, receipt_id, receipt_bill_no_snapshot,
                    ordered_qty, allowed_loss_pct, floor_qty, delivered_qty, shortfall_qty, shortfall_pct,
                    severity, status, arrival_count, owner_employee_id, owner_user_id,
                    detected_by_user_id, detected_by_employee_id)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'PENDING_OWNER', 1, ?, ?, ?, ?)
                """, caseId, fact.orderId(), fact.orderItemId(), fact.orderBillNo(), fact.supplierId(),
                fact.goodsId(), fact.colorId(), fact.unitId(), fact.goodsCode(), fact.goodsName(),
                receiptId, receiptBillNo, fact.orderedQty(), fact.allowedLossPct(),
                SubcontractShortDeliveryPolicy.floorQty(fact.orderedQty(), fact.allowedLossPct()),
                fact.deliveredQty(), shortfall,
                SubcontractShortDeliveryPolicy.shortfallPct(fact.orderedQty(), fact.deliveredQty()),
                severity, fact.makerId(), activeUserOfEmployee(fact.makerId()), actorUser, actorEmployee);
        Map<String, Object> snapshot = new LinkedHashMap<>(snapshot(fact, receiptBillNo, null));
        snapshot.put("acknowledgedByWarehouse", acknowledged);
        appendEvent(caseId, "DETECTED", actorUser, actorEmployee, snapshot);
        if (SubcontractShortDeliveryPolicy.isBelowFloor(severity)) {
            publishDetected(caseId, 1);
        }
    }

    private void refreshOpenCase(OpenCase open, ItemFacts fact, UUID receiptId, String receiptBillNo,
                                 String severity, UUID actorUser, UUID actorEmployee, boolean acknowledged) {
        boolean waitingActive = STATUS_WAITING.equals(open.status())
                && open.expectedCompleteBy() != null
                && !open.expectedCompleteBy().isBefore(BusinessTime.today());
        updateFigures(open.id(), fact, severity, receiptId, receiptBillNo, true);
        Map<String, Object> snapshot = new LinkedHashMap<>(snapshot(fact, receiptBillNo, null));
        snapshot.put("acknowledgedByWarehouse", acknowledged);
        snapshot.put("waitingMoreActive", waitingActive);
        appendEvent(open.id(), "REDETECTED", actorUser, actorEmployee, snapshot);
        // 已判定分批到货且未过预计日：只刷新数字, 不再打扰; 其余情况低于下限就再通知一次。
        if (!waitingActive && SubcontractShortDeliveryPolicy.isBelowFloor(severity)) {
            publishDetected(open.id(), open.version() + 1);
        }
    }

    private void updateFigures(UUID caseId, ItemFacts fact, String severity, UUID receiptId,
                               String receiptBillNo, boolean countArrival) {
        BigDecimal shortfall = SubcontractShortDeliveryPolicy.shortfallQty(fact.orderedQty(), fact.deliveredQty());
        jdbc.update("""
                UPDATE subcontract_short_delivery_cases
                SET ordered_qty = ?, allowed_loss_pct = ?, floor_qty = ?, delivered_qty = ?,
                    shortfall_qty = ?, shortfall_pct = ?, severity = ?,
                    receipt_id = COALESCE(?, receipt_id), receipt_bill_no_snapshot = COALESCE(?, receipt_bill_no_snapshot),
                    arrival_count = arrival_count + ?, last_evaluated_at = now(),
                    version = version + 1, updated_at = now()
                WHERE id = ?
                """, fact.orderedQty(), fact.allowedLossPct(),
                SubcontractShortDeliveryPolicy.floorQty(fact.orderedQty(), fact.allowedLossPct()),
                fact.deliveredQty(), shortfall,
                SubcontractShortDeliveryPolicy.shortfallPct(fact.orderedQty(), fact.deliveredQty()),
                severity, receiptId, receiptBillNo, countArrival ? 1 : 0, caseId);
    }

    private void closeCase(OpenCase open, String status, String eventType, UUID actorUser, UUID actorEmployee,
                           Map<String, Object> snapshot) {
        int changed = jdbc.update("""
                UPDATE subcontract_short_delivery_cases
                SET status = ?, closed_at = now(), last_evaluated_at = now(),
                    version = version + 1, updated_at = now()
                WHERE id = ? AND status IN ('PENDING_OWNER', 'WAITING_MORE')
                """, status, open.id());
        if (changed != 1) return;
        appendEvent(open.id(), eventType, actorUser, actorEmployee, snapshot);
        publishResolved(open.id(), open.version() + 1, eventType);
    }

    private void appendEvent(UUID caseId, String eventType, UUID actorUser, UUID actorEmployee,
                             Map<String, Object> snapshot) {
        jdbc.update("""
                INSERT INTO subcontract_short_delivery_case_events (
                    id, case_id, event_type, actor_user_id, actor_employee_id, event_snapshot)
                VALUES (?, ?, ?, ?, ?, CAST(? AS jsonb))
                """, UUID.randomUUID(), caseId, eventType, actorUser, actorEmployee, writeSnapshot(snapshot));
    }

    private void publishDetected(UUID caseId, long version) {
        events.publishOnce(EVENT_DETECTED, AGGREGATE_KIND, caseId, Map.of("version", version),
                EVENT_DETECTED + ':' + caseId + ':' + version);
    }

    private void publishResolved(UUID caseId, long version, String reason) {
        events.publishOnce(EVENT_RESOLVED, AGGREGATE_KIND, caseId,
                Map.of("version", version, "reason", reason),
                EVENT_RESOLVED + ':' + caseId + ':' + version);
    }

    private Map<String, Object> snapshot(ItemFacts fact, String receiptBillNo, String note) {
        Map<String, Object> snapshot = new LinkedHashMap<>();
        snapshot.put("orderBillNo", fact.orderBillNo());
        snapshot.put("goods", fact.goodsLabel());
        snapshot.put("orderedQty", fact.orderedQty());
        snapshot.put("allowedLossPct", fact.allowedLossPct());
        snapshot.put("deliveredQty", fact.deliveredQty());
        snapshot.put("shortfallQty", SubcontractShortDeliveryPolicy.shortfallQty(fact.orderedQty(), fact.deliveredQty()));
        if (receiptBillNo != null) snapshot.put("receiptBillNo", receiptBillNo);
        if (note != null) snapshot.put("note", note);
        return snapshot;
    }

    private UUID activeUserOfEmployee(UUID employeeId) {
        if (employeeId == null) return null;
        return jdbc.query("""
                SELECT id FROM users WHERE employee_id = ? AND status = 'active' AND is_deleted = FALSE LIMIT 1
                """, rs -> rs.next() ? rs.getObject(1, UUID.class) : null, employeeId);
    }

    private String writeSnapshot(Map<String, Object> snapshot) {
        try {
            return objectMapper.writeValueAsString(snapshot == null ? Map.of() : snapshot);
        } catch (JsonProcessingException e) {
            throw new IllegalStateException("short delivery snapshot serialization failed", e);
        }
    }

    private Map<String, Object> readSnapshot(String json) {
        if (json == null || json.isBlank()) return Map.of();
        try {
            @SuppressWarnings("unchecked")
            Map<String, Object> parsed = objectMapper.readValue(json, Map.class);
            return parsed;
        } catch (JsonProcessingException e) {
            return Map.of();
        }
    }

    private static String placeholders(int count) {
        return String.join(",", java.util.Collections.nCopies(count, "?"));
    }

    private static String blankToNull(String value) {
        return value == null || value.isBlank() ? null : value;
    }

    private static String plain(BigDecimal value) {
        return value == null ? "0" : value.stripTrailingZeros().toPlainString();
    }

    private static BigDecimal decimal(Object value) {
        return value == null ? BigDecimal.ZERO : new BigDecimal(value.toString());
    }

    private static LocalDate localDate(Object value) {
        if (value == null) return null;
        if (value instanceof LocalDate date) return date;
        return ((java.sql.Date) value).toLocalDate();
    }

    private static OffsetDateTime offset(Object value) {
        if (value == null) return null;
        if (value instanceof OffsetDateTime dateTime) return dateTime.withOffsetSameInstant(ZoneOffset.UTC);
        if (value instanceof java.time.Instant instant) return instant.atOffset(ZoneOffset.UTC);
        if (value instanceof Timestamp timestamp) return timestamp.toInstant().atOffset(ZoneOffset.UTC);
        return null;
    }

    static BigDecimal scaleQty(BigDecimal value) {
        return value == null ? null : value.setScale(4, RoundingMode.HALF_UP);
    }
}

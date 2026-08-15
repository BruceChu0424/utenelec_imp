package com.uten.imp.features.finance.procurement;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.application.port.ProcurementOrderApprovalPort;
import com.uten.imp.application.port.ProcurementOrderApprovalPort.ItemSnapshot;
import com.uten.imp.application.port.ProcurementOrderApprovalPort.OrderSnapshot;
import com.uten.imp.common.util.HashUtil;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.admin.workflow.WorkflowReviewerEligibility;
import com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.ApprovalTask;
import com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.FinanceApproval;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.function.Function;
import java.util.stream.Collectors;

/**
 * 采购/委外订货单财务审批服务（PURCHASE/SUBCONTRACT 多 port）。
 *
 * <p>提交 = 锁定订单 + 财务快照（规范 JSON + sha256）+ 写入 PENDING case；
 * 审批/驳回 = 财务部门审核组资格校验 + 悲观锁 + version CAS + 快照一致性校验，
 * 防止审批期订货单被改动。通过时创建到货预期（{@code inbound_expectations}）并发布领域事件。
 */
@Service
public class ProcurementFinanceApprovalService {

    public static final String EVENT_SUBMITTED = "PROCUREMENT_FINANCE_SUBMITTED";
    public static final String EVENT_APPROVED = "PROCUREMENT_FINANCE_APPROVED";
    public static final String EVENT_REJECTED = "PROCUREMENT_FINANCE_REJECTED";

    private final Map<String, ProcurementOrderApprovalPort> ports;
    private final JdbcTemplate jdbc;
    private final ObjectMapper objectMapper;
    private final BusinessEventPublisher events;
    private final WorkflowReviewerEligibility reviewerEligibility;
    private final ProcurementApprovalProjectionQuery projection;
    private final SecurityContextCurrentUser currentUser;
    private final TxSessionVars tx;

    public ProcurementFinanceApprovalService(
            List<ProcurementOrderApprovalPort> availablePorts,
            JdbcTemplate jdbc,
            ObjectMapper objectMapper,
            BusinessEventPublisher events,
            WorkflowReviewerEligibility reviewerEligibility,
            ProcurementApprovalProjectionQuery projection,
            SecurityContextCurrentUser currentUser,
            TxSessionVars tx) {
        this.ports = availablePorts.stream().collect(Collectors.toUnmodifiableMap(
                port -> ProcurementApprovalProjectionQuery.requireOrderType(port.orderType()),
                Function.identity()));
        this.jdbc = jdbc;
        this.objectMapper = objectMapper;
        this.events = events;
        this.reviewerEligibility = reviewerEligibility;
        this.projection = projection;
        this.currentUser = currentUser;
        this.tx = tx;
    }

    /** 提交财务审批：锁定订货单 + 规范 JSON 快照（sha256）+ 写 PENDING case（attempt 逐次递增，驳回后重提交自增），并预校验存在有资格的财务审核人，避免无人可批的死单。 */
    @Transactional
    public FinanceApproval submit(String rawOrderType, UUID orderId) {
        tx.bind();
        String orderType = ProcurementApprovalProjectionQuery.requireOrderType(rawOrderType);
        ProcurementOrderApprovalPort port = requirePort(orderType);
        OrderSnapshot snapshot = port.lockAndValidateFinanceSubmission(orderId);
        requireNoPendingCase(orderType, orderId);

        requireReviewerPoolAvailable();

        int attempt = nextAttempt(orderType, orderId);
        UUID caseId = UUID.randomUUID();
        UUID actorUser = currentUser.requireId();
        UUID actorEmployee = currentUser.requireEmployeeId();
        String snapshotJson = canonicalSnapshotJson(snapshot);
        String snapshotHash = HashUtil.sha256(snapshotJson);

        jdbc.update("""
                INSERT INTO procurement_order_approval_cases(
                    id, order_type, order_id, attempt, bill_no_snapshot,
                    amount_snapshot, submission_snapshot, snapshot_hash,
                    submitted_by_user_id, submitted_by_employee_id,
                    assignee_user_id, assignee_employee_id, assignee_name_snapshot,
                    status, version
                )
                VALUES (?, ?, ?, ?, ?, ?, CAST(? AS jsonb), ?, ?, ?, ?, ?, ?, 'PENDING', 1)
                """,
                caseId,
                orderType,
                orderId,
                attempt,
                snapshot.billNo(),
                snapshot.totalLocal(),
                snapshotJson,
                snapshotHash,
                actorUser,
                actorEmployee,
                null,
                null,
                null);
        appendEvent(
                caseId,
                "SUBMITTED",
                actorUser,
                actorEmployee,
                null,
                null,
                null,
                Map.of("attempt", attempt, "snapshotHash", snapshotHash));
        publish(EVENT_SUBMITTED, caseId, orderType, "PENDING", 1);
        return projection.latestForOrder(orderType, orderId, (short) 0);
    }

    @Transactional
    public FinanceApproval approve(
            String rawOrderType, UUID orderId, long expectedVersion) {
        tx.bind();
        String orderType = ProcurementApprovalProjectionQuery.requireOrderType(rawOrderType);
        requireEligibleReviewer();
        ProcurementOrderApprovalPort port = requirePort(orderType);
        OrderSnapshot currentSnapshot =
                port.lockAndValidateFinanceSubmission(orderId);
        ApprovalCase approvalCase = lockPendingCase(orderType, orderId);
        requireVersion(approvalCase, expectedVersion);
        requireUnchangedSnapshot(approvalCase, currentSnapshot);

        UUID actorUser = currentUser.requireId();
        UUID actorEmployee = currentUser.requireEmployeeId();
        port.applyFinanceApproval(orderId, actorEmployee);
        int changed = jdbc.update("""
                UPDATE procurement_order_approval_cases
                SET status = 'APPROVED',
                    decided_by_user_id = ?,
                    decided_by_employee_id = ?,
                    decided_at = now(),
                    version = version + 1,
                    updated_at = now()
                WHERE id = ? AND status = 'PENDING' AND version = ?
                """,
                actorUser,
                actorEmployee,
                approvalCase.caseId(),
                expectedVersion);
        if (changed != 1) {
            throw concurrentChange();
        }
        appendEvent(
                approvalCase.caseId(),
                "APPROVED",
                actorUser,
                actorEmployee,
                null,
                null,
                null,
                Map.of("snapshotHash", approvalCase.snapshotHash()));
        createInboundExpectation(approvalCase.caseId(), currentSnapshot, actorUser);
        publish(
                EVENT_APPROVED,
                approvalCase.caseId(),
                orderType,
                "APPROVED",
                expectedVersion + 1);
        return projection.latestForOrder(orderType, orderId, (short) 1);
    }

    /** 驳回：财务审核组资格 + 悲观锁 + version CAS + 快照一致性校验（订货单自提交起未变），驳回原因必填（≤1000 字）。 */
    @Transactional
    public FinanceApproval reject(
            String rawOrderType,
            UUID orderId,
            long expectedVersion,
            String rawReason) {
        tx.bind();
        String orderType = ProcurementApprovalProjectionQuery.requireOrderType(rawOrderType);
        requireEligibleReviewer();
        String reason = normalizeReason(rawReason);
        ProcurementOrderApprovalPort port = requirePort(orderType);
        OrderSnapshot currentSnapshot =
                port.lockAndValidateFinanceSubmission(orderId);
        ApprovalCase approvalCase = lockPendingCase(orderType, orderId);
        requireVersion(approvalCase, expectedVersion);
        requireUnchangedSnapshot(approvalCase, currentSnapshot);

        UUID actorUser = currentUser.requireId();
        UUID actorEmployee = currentUser.requireEmployeeId();
        int changed = jdbc.update("""
                UPDATE procurement_order_approval_cases
                SET status = 'REJECTED',
                    rejection_reason = ?,
                    decided_by_user_id = ?,
                    decided_by_employee_id = ?,
                    decided_at = now(),
                    version = version + 1,
                    updated_at = now()
                WHERE id = ? AND status = 'PENDING' AND version = ?
                """,
                reason,
                actorUser,
                actorEmployee,
                approvalCase.caseId(),
                expectedVersion);
        if (changed != 1) {
            throw concurrentChange();
        }
        appendEvent(
                approvalCase.caseId(),
                "REJECTED",
                actorUser,
                actorEmployee,
                null,
                null,
                reason,
                Map.of("snapshotHash", approvalCase.snapshotHash()));
        publish(
                EVENT_REJECTED,
                approvalCase.caseId(),
                orderType,
                "REJECTED",
                expectedVersion + 1);
        return projection.latestForOrder(orderType, orderId, (short) 0);
    }

    @Transactional(readOnly = true)
    public PageResponse<ApprovalTask> tasks(int page, int size) {
        int safePage = Math.max(1, page);
        int safeSize = Math.max(1, Math.min(size, 200));
        long total = countTasks();
        List<ApprovalTask> items = jdbc.query("""
                SELECT c.id AS case_id,
                       c.order_type,
                       c.order_id,
                       c.bill_no_snapshot,
                       c.amount_snapshot,
                       supplier.name AS supplier_name,
                       warehouse.name AS warehouse_name,
                       COALESCE(po.deliver_date, so.deliver_date) AS expected_date,
                       c.attempt,
                       c.version,
                       c.submitted_by_employee_id,
                       submitter.full_name AS submitted_by_name,
                       c.submitted_at
                FROM procurement_order_approval_cases c
                LEFT JOIN purchase_orders po
                  ON c.order_type = 'PURCHASE' AND po.id = c.order_id
                LEFT JOIN subcontract_orders so
                  ON c.order_type = 'SUBCONTRACT' AND so.id = c.order_id
                LEFT JOIN suppliers supplier
                  ON supplier.id = COALESCE(po.supplier_id, so.supplier_id)
                LEFT JOIN warehouses warehouse
                  ON warehouse.id = COALESCE(po.warehouse_id, so.warehouse_id)
                LEFT JOIN employees submitter
                  ON submitter.id = c.submitted_by_employee_id
                WHERE c.status = 'PENDING'
                ORDER BY c.submitted_at, c.id
                LIMIT ? OFFSET ?
                """,
                (rs, rowNum) -> new ApprovalTask(
                        rs.getObject("case_id", UUID.class),
                        rs.getString("order_type"),
                        rs.getObject("order_id", UUID.class),
                        rs.getString("bill_no_snapshot"),
                        rs.getBigDecimal("amount_snapshot"),
                        rs.getString("supplier_name"),
                        rs.getString("warehouse_name"),
                        rs.getObject("expected_date", LocalDate.class),
                        rs.getInt("attempt"),
                        rs.getLong("version"),
                        rs.getObject("submitted_by_employee_id", UUID.class),
                        rs.getString("submitted_by_name"),
                        rs.getObject("submitted_at", OffsetDateTime.class),
                        List.of("APPROVE", "REJECT")),
                safeSize,
                (safePage - 1) * safeSize);
        int totalPages = total == 0
                ? 0
                : (int) ((total + safeSize - 1) / safeSize);
        return new PageResponse<>(
                items, safePage, safeSize, total, totalPages);
    }

    @Transactional(readOnly = true)
    public long countTasks() {
        Long count = jdbc.queryForObject("""
                SELECT COUNT(*)
                FROM procurement_order_approval_cases
                WHERE status = 'PENDING'
                """, Long.class);
        return count == null ? 0 : count;
    }

    private void requireReviewerPoolAvailable() {
        if (reviewerEligibility.allEligible().isEmpty()) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "暂无持有审批权限的在职财务人员，请先在权限管理中授权 finance_order_approval:review");
        }
    }

    private void requireEligibleReviewer() {
        UUID actor = currentUser.requireId();
        reviewerEligibility.findEligible(actor).orElseThrow(() -> new ApiException(
                ErrorCode.FORBIDDEN,
                "仅财务部门在职且持有 finance_order_approval:review 的人员可审批"));
    }

    private void requireNoPendingCase(String orderType, UUID orderId) {
        Boolean pending = jdbc.queryForObject("""
                SELECT EXISTS(
                    SELECT 1
                    FROM procurement_order_approval_cases
                    WHERE order_type = ? AND order_id = ? AND status = 'PENDING'
                )
                """, Boolean.class, orderType, orderId);
        if (Boolean.TRUE.equals(pending)) {
            throw new ApiException(ErrorCode.CONFLICT, "订货单已在财务审核中");
        }
    }

    private int nextAttempt(String orderType, UUID orderId) {
        Integer attempt = jdbc.queryForObject("""
                SELECT COALESCE(MAX(attempt), 0) + 1
                FROM procurement_order_approval_cases
                WHERE order_type = ? AND order_id = ?
                """, Integer.class, orderType, orderId);
        return attempt == null ? 1 : attempt;
    }

    private ApprovalCase lockPendingCase(String orderType, UUID orderId) {
        List<ApprovalCase> rows = jdbc.query("""
                SELECT id, order_id, version, snapshot_hash
                FROM procurement_order_approval_cases
                WHERE order_type = ? AND order_id = ? AND status = 'PENDING'
                FOR UPDATE
                """,
                (rs, rowNum) -> new ApprovalCase(
                        rs.getObject("id", UUID.class),
                        rs.getObject("order_id", UUID.class),
                        rs.getLong("version"),
                        rs.getString("snapshot_hash")),
                orderType,
                orderId);
        if (rows.isEmpty()) {
            throw new ApiException(ErrorCode.CONFLICT, "订货单当前没有待处理的财务审批");
        }
        return rows.getFirst();
    }

    private static void requireVersion(
            ApprovalCase approvalCase, long expectedVersion) {
        if (expectedVersion < 1
                || approvalCase.version() != expectedVersion) {
            throw concurrentChange();
        }
    }

    private void requireUnchangedSnapshot(
            ApprovalCase approvalCase, OrderSnapshot currentSnapshot) {
        String currentHash = HashUtil.sha256(
                canonicalSnapshotJson(currentSnapshot));
        if (!approvalCase.snapshotHash().equals(currentHash)) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "订货单内容与提交财务时不一致，请驳回后重新提交");
        }
    }

    private void createInboundExpectation(
            UUID caseId, OrderSnapshot snapshot, UUID actorUser) {
        UUID expectationId = UUID.randomUUID();
        UUID ownerEmployee = snapshot.purchaserEmployeeId() != null
                ? snapshot.purchaserEmployeeId()
                : snapshot.makerEmployeeId();
        LocalDate expectedDate = snapshot.items().stream()
                .map(ItemSnapshot::deliverDate)
                .filter(java.util.Objects::nonNull)
                .min(Comparator.naturalOrder())
                .orElse(snapshot.deliverDate());
        jdbc.update("""
                INSERT INTO inbound_expectations(
                    id, order_type, order_id, approval_case_id,
                    bill_no_snapshot, supplier_id, warehouse_id,
                    expected_date, owner_employee_id, status, created_by
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'OPEN', ?)
                """,
                expectationId,
                snapshot.orderType(),
                snapshot.orderId(),
                caseId,
                snapshot.billNo(),
                snapshot.supplierId(),
                snapshot.warehouseId(),
                expectedDate,
                ownerEmployee,
                actorUser);
        for (ItemSnapshot item : sortedItems(snapshot)) {
            jdbc.update("""
                    INSERT INTO inbound_expectation_items(
                        id, expectation_id, order_item_id, line_no,
                        goods_id, color_id, unit_id, unit_rate,
                        ordered_qty, accepted_qty, expected_date
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?)
                    """,
                    UUID.randomUUID(),
                    expectationId,
                    item.itemId(),
                    item.lineNo(),
                    item.goodsId(),
                    item.colorId(),
                    item.unitId(),
                    item.unitRate(),
                    item.qty(),
                    item.deliverDate() == null
                            ? snapshot.deliverDate()
                            : item.deliverDate());
        }
    }

    private void appendEvent(
            UUID caseId,
            String eventType,
            UUID actorUser,
            UUID actorEmployee,
            UUID fromAssignee,
            UUID toAssignee,
            String reason,
            Map<String, ?> snapshot) {
        jdbc.update("""
                INSERT INTO procurement_order_approval_events(
                    id, case_id, event_type, actor_user_id, actor_employee_id,
                    from_assignee_user_id, to_assignee_user_id, reason,
                    event_snapshot
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, CAST(? AS jsonb))
                """,
                UUID.randomUUID(),
                caseId,
                eventType,
                actorUser,
                actorEmployee,
                fromAssignee,
                toAssignee,
                reason,
                json(snapshot));
    }

    private void publish(
            String eventType,
            UUID caseId,
            String orderType,
            String status,
            long version) {
        events.publishOnce(
                eventType,
                "PROCUREMENT_APPROVAL_CASE",
                caseId,
                Map.of(
                        "orderType", orderType,
                        "status", status,
                        "version", version),
                eventType + ":" + caseId + ":" + version);
    }

    private String canonicalSnapshotJson(OrderSnapshot snapshot) {
        Map<String, Object> header = new LinkedHashMap<>();
        header.put("orderType", snapshot.orderType());
        header.put("orderId", snapshot.orderId());
        header.put("billNo", snapshot.billNo());
        header.put("billDate", snapshot.billDate());
        header.put("supplierId", snapshot.supplierId());
        header.put("warehouseId", snapshot.warehouseId());
        header.put("currencyId", snapshot.currencyId());
        header.put("exchangeRate", snapshot.exchangeRate());
        header.put("taxRate", snapshot.taxRate());
        header.put("purchaserEmployeeId", snapshot.purchaserEmployeeId());
        header.put("makerEmployeeId", snapshot.makerEmployeeId());
        header.put("deliverDate", snapshot.deliverDate());
        header.put("totalOriginal", snapshot.totalOriginal());
        header.put("totalLocal", snapshot.totalLocal());
        header.put("items", sortedItems(snapshot).stream()
                .map(this::canonicalItem)
                .toList());
        return json(header);
    }

    private Map<String, Object> canonicalItem(ItemSnapshot item) {
        Map<String, Object> row = new LinkedHashMap<>();
        row.put("itemId", item.itemId());
        row.put("lineNo", item.lineNo());
        row.put("sourceItemId", item.sourceItemId());
        row.put("goodsId", item.goodsId());
        row.put("colorId", item.colorId());
        row.put("unitId", item.unitId());
        row.put("unitRate", item.unitRate());
        row.put("qty", item.qty());
        row.put("price", item.price());
        row.put("amountOriginal", item.amountOriginal());
        row.put("amountLocal", item.amountLocal());
        row.put("deliverDate", item.deliverDate());
        return row;
    }

    private static List<ItemSnapshot> sortedItems(OrderSnapshot snapshot) {
        return snapshot.items().stream()
                .sorted(Comparator
                        .comparing(
                                ItemSnapshot::lineNo,
                                Comparator.nullsLast(Integer::compareTo))
                        .thenComparing(ItemSnapshot::itemId))
                .toList();
    }

    private String json(Object value) {
        try {
            return objectMapper.writeValueAsString(value);
        } catch (JsonProcessingException error) {
            throw new IllegalStateException("审批快照无法序列化", error);
        }
    }

    private ProcurementOrderApprovalPort requirePort(String orderType) {
        ProcurementOrderApprovalPort port = ports.get(orderType);
        if (port == null) {
            throw new IllegalStateException(
                    "Missing procurement approval port for " + orderType);
        }
        return port;
    }

    private static String normalizeReason(String value) {
        String reason = value == null ? "" : value.trim();
        if (reason.isEmpty() || reason.length() > 1000) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "驳回原因必填且不能超过1000字");
        }
        return reason;
    }

    private static ApiException concurrentChange() {
        return new ApiException(
                ErrorCode.CONFLICT,
                "审批任务已被处理或版本已变化，请刷新后重试");
    }

    private record ApprovalCase(
            UUID caseId,
            UUID orderId,
            long version,
            String snapshotHash) {
    }
}

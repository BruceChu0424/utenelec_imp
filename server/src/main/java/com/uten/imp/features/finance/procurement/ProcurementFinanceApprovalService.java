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
import com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.BatchDecisionItem;
import com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.BatchDecisionResponse;
import com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.FinanceApproval;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
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
    @PreAuthorize("hasAnyAuthority('purchase_order:submit_finance','subcontract_order:submit_finance')")
    public FinanceApproval submit(String rawOrderType, UUID orderId) {
        tx.bind();
        String orderType = ProcurementApprovalProjectionQuery.requireOrderType(rawOrderType);
        requireSubmitAuthority(orderType);
        ProcurementOrderApprovalPort port = requirePort(orderType);
        port.requireFinanceSubmitterWritable(orderId);
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
    @PreAuthorize("hasAuthority('finance_order_approval:approve')")
    public FinanceApproval approve(
            String rawOrderType, UUID orderId, long expectedVersion) {
        tx.bind();
        requireEligibleReviewer();
        return approveOne(rawOrderType, orderId, expectedVersion, null);
    }

    /**
     * 批量通过使用一个事务和稳定的订货类型/UUID 顺序。任一项的 case、版本、
     * 快照或副作用失败都会回滚整批，禁止客户端循环单笔接口形成半批事实。
     */
    @Transactional
    @PreAuthorize("hasAuthority('finance_order_approval:approve')")
    public BatchDecisionResponse approveBatch(List<BatchDecisionItem> rawItems) {
        tx.bind();
        requireEligibleReviewer();
        List<ResolvedBatchItem> items = resolveBatchItems(rawItems);
        List<FinanceApproval> decisions = new ArrayList<>(items.size());
        for (ResolvedBatchItem item : items) {
            decisions.add(approveOne(
                    item.orderType(),
                    item.orderId(),
                    item.expectedVersion(),
                    item.caseId()));
        }
        return new BatchDecisionResponse(decisions.size(), decisions);
    }

    private FinanceApproval approveOne(
            String rawOrderType,
            UUID orderId,
            long expectedVersion,
            UUID expectedCaseId) {
        String orderType = ProcurementApprovalProjectionQuery.requireOrderType(rawOrderType);
        ProcurementOrderApprovalPort port = requirePort(orderType);
        OrderSnapshot currentSnapshot =
                port.lockAndValidateFinanceSubmission(orderId);
        ApprovalCase approvalCase = lockPendingCase(orderType, orderId);
        requireCaseIdentity(approvalCase, expectedCaseId);
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
    @PreAuthorize("hasAuthority('finance_order_approval:reject')")
    public FinanceApproval reject(
            String rawOrderType,
            UUID orderId,
            long expectedVersion,
            String rawReason) {
        tx.bind();
        requireEligibleReviewer();
        return rejectOne(
                rawOrderType,
                orderId,
                expectedVersion,
                null,
                normalizeReason(rawReason));
    }

    /** 批量驳回共用一个明确原因，并与全部 case/order 副作用保持原子。 */
    @Transactional
    @PreAuthorize("hasAuthority('finance_order_approval:reject')")
    public BatchDecisionResponse rejectBatch(
            List<BatchDecisionItem> rawItems,
            String rawReason) {
        tx.bind();
        requireEligibleReviewer();
        String reason = normalizeReason(rawReason);
        List<ResolvedBatchItem> items = resolveBatchItems(rawItems);
        List<FinanceApproval> decisions = new ArrayList<>(items.size());
        for (ResolvedBatchItem item : items) {
            decisions.add(rejectOne(
                    item.orderType(),
                    item.orderId(),
                    item.expectedVersion(),
                    item.caseId(),
                    reason));
        }
        return new BatchDecisionResponse(decisions.size(), decisions);
    }

    private FinanceApproval rejectOne(
            String rawOrderType,
            UUID orderId,
            long expectedVersion,
            UUID expectedCaseId,
            String reason) {
        String orderType = ProcurementApprovalProjectionQuery.requireOrderType(rawOrderType);
        ProcurementOrderApprovalPort port = requirePort(orderType);
        OrderSnapshot currentSnapshot =
                port.lockAndValidateFinanceSubmission(orderId);
        ApprovalCase approvalCase = lockPendingCase(orderType, orderId);
        requireCaseIdentity(approvalCase, expectedCaseId);
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
    @PreAuthorize("hasAuthority('finance_order_approval:view')")
    public PageResponse<ApprovalTask> tasks(
            int page,
            int size,
            String orderType,
            String keyword) {
        int safePage = Math.max(1, page);
        int safeSize = Math.max(1, Math.min(size, 200));
        // 类型分段（全部/采购/委外）：空 = 全部；非法值 fail-closed。
        String normalizedType = normalizeOrderType(orderType);
        String normalizedKeyword = normalizeKeyword(keyword);
        long total = countTasks(normalizedType, normalizedKeyword);
        String typeFilter = normalizedType.isEmpty() ? "" : " AND c.order_type = ?\n";
        String keywordFilter = normalizedKeyword == null
                ? ""
                : """
                   AND (LOWER(COALESCE(c.bill_no_snapshot, '')) LIKE ?
                     OR LOWER(COALESCE(supplier.name, '')) LIKE ?
                     OR LOWER(COALESCE(submitter.full_name, '')) LIKE ?)
                  """;
        List<Object> params = new ArrayList<>();
        if (!normalizedType.isEmpty()) {
            params.add(normalizedType);
        }
        if (normalizedKeyword != null) {
            params.add(normalizedKeyword);
            params.add(normalizedKeyword);
            params.add(normalizedKeyword);
        }
        params.add(safeSize);
        params.add((safePage - 1) * safeSize);
        List<String> allowedActions = currentReviewerActions();
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
                """ + typeFilter + keywordFilter + """
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
                        allowedActions),
                params.toArray());
        int totalPages = total == 0
                ? 0
                : (int) ((total + safeSize - 1) / safeSize);
        return new PageResponse<>(
                items, safePage, safeSize, total, totalPages);
    }

    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('finance_order_approval:view')")
    public long countTasks() {
        return countTasks("");
    }

    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('finance_order_approval:view')")
    public long countTasks(String orderType) {
        return countTasks(normalizeOrderType(orderType), null);
    }

    private long countTasks(String normalizedType, String normalizedKeyword) {
        String typeFilter = normalizedType.isEmpty() ? "" : " AND c.order_type = ?\n";
        String keywordFilter = normalizedKeyword == null
                ? ""
                : """
                   AND (LOWER(COALESCE(c.bill_no_snapshot, '')) LIKE ?
                     OR LOWER(COALESCE(supplier.name, '')) LIKE ?
                     OR LOWER(COALESCE(submitter.full_name, '')) LIKE ?)
                  """;
        List<Object> params = new ArrayList<>();
        if (!normalizedType.isEmpty()) {
            params.add(normalizedType);
        }
        if (normalizedKeyword != null) {
            params.add(normalizedKeyword);
            params.add(normalizedKeyword);
            params.add(normalizedKeyword);
        }
        Long count = jdbc.queryForObject("""
                SELECT COUNT(*)
                FROM procurement_order_approval_cases c
                LEFT JOIN purchase_orders po
                  ON c.order_type = 'PURCHASE' AND po.id = c.order_id
                LEFT JOIN subcontract_orders so
                  ON c.order_type = 'SUBCONTRACT' AND so.id = c.order_id
                LEFT JOIN suppliers supplier
                  ON supplier.id = COALESCE(po.supplier_id, so.supplier_id)
                LEFT JOIN employees submitter
                  ON submitter.id = c.submitted_by_employee_id
                WHERE c.status = 'PENDING'
                """ + typeFilter + keywordFilter,
                Long.class,
                params.toArray());
        return count == null ? 0 : count;
    }

    /** 待审任务按订货类型计数（顶部类型筛选卡口径：全部 PENDING，不受当前筛选影响）。 */
    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('finance_order_approval:view')")
    public Map<String, Long> countTasksByType() {
        Map<String, Long> counts = new LinkedHashMap<>();
        jdbc.query("""
                SELECT order_type, COUNT(*)
                FROM procurement_order_approval_cases
                WHERE status = 'PENDING'
                GROUP BY order_type
                """, rs -> {
            counts.put(rs.getString(1), rs.getLong(2));
        });
        return counts;
    }

    /** 订货类型筛选值：空 = 全部；只允许 PURCHASE/SUBCONTRACT，其余 fail-closed。 */
    private static String normalizeOrderType(String orderType) {
        String normalized = orderType == null ? "" : orderType.strip().toUpperCase();
        return switch (normalized) {
            case "", "PURCHASE", "SUBCONTRACT" -> normalized;
            default -> throw new ApiException(ErrorCode.VALIDATION_FAILED, "订货类型无效");
        };
    }

    private static String normalizeKeyword(String keyword) {
        String normalized = keyword == null ? "" : keyword.strip();
        if (normalized.length() > 100) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "搜索关键词不能超过100字");
        }
        return normalized.isEmpty()
                ? null
                : "%" + normalized.toLowerCase(Locale.ROOT) + "%";
    }

    /**
     * 批量项必须精确绑定 case/order/version，并以稳定顺序获取订单与 case 锁。
     * 同一 case 或同一订货单重复出现都直接拒绝，避免二次执行与死锁顺序漂移。
     */
    private List<ResolvedBatchItem> resolveBatchItems(
            List<BatchDecisionItem> rawItems) {
        if (rawItems == null || rawItems.isEmpty() || rawItems.size() > 100) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "批量审批必须选择1至100笔任务");
        }
        Map<UUID, Long> expectedVersions = new LinkedHashMap<>();
        for (BatchDecisionItem item : rawItems) {
            if (item == null
                    || item.caseId() == null
                    || item.expectedVersion() == null
                    || item.expectedVersion() < 1) {
                throw new ApiException(
                        ErrorCode.VALIDATION_FAILED,
                        "批量审批任务身份或版本无效");
            }
            if (expectedVersions.putIfAbsent(
                    item.caseId(), item.expectedVersion()) != null) {
                throw new ApiException(
                        ErrorCode.VALIDATION_FAILED,
                        "批量审批不能重复选择同一任务");
            }
        }

        String placeholders = String.join(
                ",", Collections.nCopies(expectedVersions.size(), "?"));
        List<ResolvedBatchItem> resolved = jdbc.query("""
                SELECT id, order_type, order_id, version
                FROM procurement_order_approval_cases
                WHERE status = 'PENDING' AND id IN (
                """ + placeholders + ")",
                (rs, rowNum) -> new ResolvedBatchItem(
                        rs.getObject("id", UUID.class),
                        rs.getString("order_type"),
                        rs.getObject("order_id", UUID.class),
                        rs.getLong("version")),
                expectedVersions.keySet().toArray());
        if (resolved.size() != expectedVersions.size()) {
            throw concurrentChange();
        }

        Set<String> orderKeys = new HashSet<>();
        List<ResolvedBatchItem> normalized = new ArrayList<>(resolved.size());
        for (ResolvedBatchItem item : resolved) {
            String orderType = ProcurementApprovalProjectionQuery.requireOrderType(
                    item.orderType());
            String orderKey = orderType + "|" + item.orderId();
            if (!orderKeys.add(orderKey)) {
                throw new ApiException(
                        ErrorCode.VALIDATION_FAILED,
                        "批量审批不能重复选择同一订货单");
            }
            Long expectedVersion = expectedVersions.get(item.caseId());
            if (expectedVersion == null
                    || item.expectedVersion() != expectedVersion) {
                throw concurrentChange();
            }
            normalized.add(new ResolvedBatchItem(
                    item.caseId(),
                    orderType,
                    item.orderId(),
                    expectedVersion));
        }
        normalized.sort(Comparator
                .comparing(ResolvedBatchItem::orderType)
                .thenComparing(item -> item.orderId().toString()));
        return List.copyOf(normalized);
    }

    private void requireSubmitAuthority(String orderType) {
        String permission = "PURCHASE".equals(orderType)
                ? "purchase_order:submit_finance"
                : "subcontract_order:submit_finance";
        boolean allowed = currentUser.get()
                .map(user -> user.isSuperAdmin() || user.getAuthorities().stream()
                        .anyMatch(authority -> permission.equals(authority.getAuthority())))
                .orElse(false);
        if (!allowed) {
            throw new ApiException(ErrorCode.FORBIDDEN, "缺少对应订货类型的提交财务权限");
        }
    }

    private List<String> currentReviewerActions() {
        return currentUser.get()
                .map(user -> reviewerActions(
                        reviewerEligibility.findEligible(user.getId()).isPresent(),
                        user.getPermissions()))
                .orElseGet(List::of);
    }

    static List<String> reviewerActions(boolean eligible, Set<String> permissions) {
        if (!eligible) return List.of();
        List<String> actions = new ArrayList<>(2);
        if (permissions.contains(WorkflowReviewerEligibility.APPROVE_PERMISSION)) {
            actions.add("APPROVE");
        }
        if (permissions.contains(WorkflowReviewerEligibility.REJECT_PERMISSION)) {
            actions.add("REJECT");
        }
        return List.copyOf(actions);
    }

    private void requireReviewerPoolAvailable() {
        if (reviewerEligibility.eligibleReviewersFor(WorkflowReviewerEligibility.APPROVE_PERMISSION).isEmpty()) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "暂无持有订货批准权限的在职财务人员，请先授权 finance_order_approval:approve");
        }
    }

    private void requireEligibleReviewer() {
        UUID actor = currentUser.requireId();
        reviewerEligibility.findEligible(actor).orElseThrow(() -> new ApiException(
                ErrorCode.FORBIDDEN,
                "仅财务审核组内且持有对应批准或驳回权限的人员可处理"));
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

    private static void requireCaseIdentity(
            ApprovalCase approvalCase, UUID expectedCaseId) {
        if (expectedCaseId != null
                && !approvalCase.caseId().equals(expectedCaseId)) {
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
        header.put("exchangeRate", canonicalDecimal(snapshot.exchangeRate()));
        header.put("settlementMethodId", snapshot.settlementMethodId());
        header.put("taxRate", canonicalDecimal(snapshot.taxRate()));
        header.put("purchaserEmployeeId", snapshot.purchaserEmployeeId());
        header.put("makerEmployeeId", snapshot.makerEmployeeId());
        header.put("deliverDate", snapshot.deliverDate());
        header.put("totalOriginal", canonicalDecimal(snapshot.totalOriginal()));
        header.put("totalLocal", canonicalDecimal(snapshot.totalLocal()));
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
        row.put("unitRate", canonicalDecimal(item.unitRate()));
        row.put("qty", canonicalDecimal(item.qty()));
        row.put("price", canonicalDecimal(item.price()));
        row.put("amountOriginal", canonicalDecimal(item.amountOriginal()));
        row.put("amountLocal", canonicalDecimal(item.amountLocal()));
        row.put("deliverDate", item.deliverDate());
        return row;
    }

    /**
     * 快照数值规范形。BigDecimal 的 Jackson 序列化保留 scale：同一数值在「提交时内存
     * 归一（unitRate 缺省补 ONE，scale 0）」与「审批时从 numeric(18,6) 列重读
     * （scale 6）」两种来源下会得到 1 与 1.000000 两个不同 JSON，requireUnchangedSnapshot
     * 因此永久 409，approve/reject 双堵死。统一 stripTrailingZeros 的 plain string 归一，
     * 历史哈希（按 scale 0 计算的存量 PENDING 案）与新计算重新一致，已卡死单据可驳回。
     */
    private static Object canonicalDecimal(java.math.BigDecimal value) {
        if (value == null) {
            return null;
        }
        return value.stripTrailingZeros().toPlainString();
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

    private record ResolvedBatchItem(
            UUID caseId,
            String orderType,
            UUID orderId,
            long expectedVersion) {
    }
}

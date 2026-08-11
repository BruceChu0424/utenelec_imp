package com.uten.imp.features.finance.procurement;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.application.port.FinanceReviewerEligibilityPort;
import com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.FinanceApproval;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.OffsetDateTime;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

@Service
@RequiredArgsConstructor
public class ProcurementApprovalProjectionQuery {

    private final NamedParameterJdbcTemplate jdbc;
    private final SecurityContextCurrentUser currentUser;
    private final FinanceReviewerEligibilityPort reviewerEligibility;

    @Transactional(readOnly = true)
    public FinanceApproval latestForOrder(
            String orderType, UUID orderId, short orderStatus) {
        return latestForOrders(orderType, Map.of(orderId, orderStatus)).get(orderId);
    }

    @Transactional(readOnly = true)
    public Map<UUID, FinanceApproval> latestForOrders(
            String orderType, Map<UUID, Short> orderStatuses) {
        if (orderStatuses.isEmpty()) {
            return Map.of();
        }
        Map<UUID, CaseRow> rows = new LinkedHashMap<>();
        jdbc.query("""
                SELECT DISTINCT ON (order_id)
                       order_id, id, status, attempt, version,
                       assignee_user_id, assignee_employee_id,
                       assignee_name_snapshot, rejection_reason, submitted_at
                FROM procurement_order_approval_cases
                WHERE order_type = :orderType
                  AND order_id IN (:orderIds)
                ORDER BY order_id, attempt DESC
                """,
                new MapSqlParameterSource()
                        .addValue("orderType", requireOrderType(orderType))
                        .addValue("orderIds", orderStatuses.keySet()),
                rs -> {
                    UUID orderId = rs.getObject("order_id", UUID.class);
                    rows.put(orderId, new CaseRow(
                            rs.getObject("id", UUID.class),
                            rs.getString("status"),
                            rs.getInt("attempt"),
                            rs.getLong("version"),
                            rs.getObject("assignee_user_id", UUID.class),
                            rs.getObject("assignee_employee_id", UUID.class),
                            rs.getString("assignee_name_snapshot"),
                            rs.getString("rejection_reason"),
                            rs.getObject("submitted_at", OffsetDateTime.class)));
                });

        Map<UUID, FinanceApproval> result = new LinkedHashMap<>();
        orderStatuses.forEach((orderId, status) -> result.put(
                orderId,
                toProjection(orderType, status, rows.get(orderId))));
        return Map.copyOf(result);
    }

    /**
     * A finance reviewer may open an otherwise owner-hidden order only while
     * that exact order has an actionable approval task. This deliberately does
     * not widen the purchase/subcontract list scope.
     */
    @Transactional(readOnly = true)
    public boolean canCurrentActorReviewPending(String orderType, UUID orderId) {
        String normalizedOrderType = requireOrderType(orderType);
        if (!isCurrentActorEligibleReviewer()) {
            return false;
        }
        Boolean pending = jdbc.queryForObject("""
                SELECT EXISTS(
                    SELECT 1
                    FROM procurement_order_approval_cases
                    WHERE order_type = :orderType
                      AND order_id = :orderId
                      AND status = 'PENDING'
                )
                """,
                new MapSqlParameterSource()
                        .addValue("orderType", normalizedOrderType)
                        .addValue("orderId", orderId),
                Boolean.class);
        return Boolean.TRUE.equals(pending);
    }

    /** Current actor satisfies the authoritative finance reviewer pool. */
    @Transactional(readOnly = true)
    public boolean isCurrentActorEligibleReviewer() {
        AuthUser actor = currentUser.get().orElse(null);
        return actor != null
                && reviewerEligibility.findEligible(actor.getId()).isPresent();
    }

    @Transactional(readOnly = true)
    public void requireMutable(String orderType, UUID orderId) {
        Boolean pending = jdbc.getJdbcTemplate().queryForObject("""
                SELECT EXISTS(
                    SELECT 1
                    FROM procurement_order_approval_cases
                    WHERE order_type = ? AND order_id = ? AND status = 'PENDING'
                )
                """, Boolean.class, requireOrderType(orderType), orderId);
        if (Boolean.TRUE.equals(pending)) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "订货单已提交财务审核，驳回后方可修改或删除");
        }
    }

    private FinanceApproval toProjection(
            String orderType, short orderStatus, CaseRow row) {
        if (row == null) {
            String status = orderStatus == 1
                    ? "LEGACY_EFFECTIVE"
                    : orderStatus == -1 ? "LEGACY_REVERSED" : "DRAFT";
            return new FinanceApproval(
                    null, status, 0, 0,
                    null, null, null, null, null,
                    draftActions(orderType, orderStatus));
        }
        return new FinanceApproval(
                row.caseId(),
                row.status(),
                row.attempt(),
                row.version(),
                row.assigneeUserId(),
                row.assigneeEmployeeId(),
                row.assigneeName(),
                row.rejectionReason(),
                row.submittedAt(),
                caseActions(orderType, orderStatus, row));
    }

    private List<String> draftActions(String orderType, short orderStatus) {
        if (orderStatus != 0 || !has(submitPermission(orderType))) {
            return List.of();
        }
        return List.of("SUBMIT_FINANCE");
    }

    private List<String> caseActions(
            String orderType, short orderStatus, CaseRow row) {
        if ("PENDING".equals(row.status())) {
            AuthUser actor = currentUser.get().orElse(null);
            if (actor != null
                    && reviewerEligibility.findEligible(actor.getId()).isPresent()) {
                return List.of("APPROVE", "REJECT");
            }
            return List.of();
        }
        if (orderStatus == 0
                && Set.of("REJECTED", "CANCELED").contains(row.status())
                && has(submitPermission(orderType))) {
            return List.of("SUBMIT_FINANCE");
        }
        return List.of();
    }

    private boolean has(String permission) {
        return currentUser.get()
                .map(AuthUser::getPermissions)
                .orElseGet(Set::of)
                .contains(permission);
    }

    private static String submitPermission(String orderType) {
        return "PURCHASE".equals(requireOrderType(orderType))
                ? "purchase_order:submit_finance"
                : "subcontract_order:submit_finance";
    }

    static String requireOrderType(String raw) {
        String value = raw == null ? "" : raw.trim().toUpperCase();
        if (!Set.of("PURCHASE", "SUBCONTRACT").contains(value)) {
            throw new ApiException(ErrorCode.NOT_FOUND, "不支持的订货类型");
        }
        return value;
    }

    private record CaseRow(
            UUID caseId,
            String status,
            int attempt,
            long version,
            UUID assigneeUserId,
            UUID assigneeEmployeeId,
            String assigneeName,
            String rejectionReason,
            OffsetDateTime submittedAt) {
    }
}

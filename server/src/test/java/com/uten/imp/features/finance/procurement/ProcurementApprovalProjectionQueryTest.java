package com.uten.imp.features.finance.procurement;

import com.uten.imp.application.port.FinanceReviewerEligibilityPort;
import com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.FinanceApproval;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.RowCallbackHandler;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.core.namedparam.SqlParameterSource;

import java.sql.ResultSet;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.doAnswer;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

class ProcurementApprovalProjectionQueryTest {

    @Test
    void rejectedDraftOffersOnlyResubmitToAuthorizedPurchaser() throws Exception {
        UUID orderId = UUID.randomUUID();
        UUID caseId = UUID.randomUUID();
        UUID assigneeUserId = UUID.randomUUID();
        UUID assigneeEmployeeId = UUID.randomUUID();
        OffsetDateTime submittedAt = OffsetDateTime.now();
        UUID actorId = UUID.randomUUID();
        SecurityContextCurrentUser currentUser = currentUser(
                actorId,
                Set.of("purchase_order:submit_finance"),
                false);
        ProcurementApprovalProjectionQuery query = queryWithCase(
                currentUser,
                actorId,
                false,
                orderId,
                caseId,
                "REJECTED",
                2,
                4,
                assigneeUserId,
                assigneeEmployeeId,
                submittedAt);

        FinanceApproval result =
                query.latestForOrder("PURCHASE", orderId, (short) 0);

        assertEquals(caseId, result.caseId());
        assertEquals("REJECTED", result.status());
        assertEquals(2, result.attempt());
        assertEquals(4, result.version());
        assertEquals(assigneeUserId, result.assigneeUserId());
        assertEquals(assigneeEmployeeId, result.assigneeEmployeeId());
        assertEquals("财务负责人", result.assigneeName());
        assertEquals("金额需修正", result.rejectionReason());
        assertEquals(submittedAt, result.submittedAt());
        assertEquals(List.of("SUBMIT_FINANCE"), result.allowedActions());
    }

    @Test
    void pendingCaseOffersOnlyGrantedApproveActionToEligibleReviewer() throws Exception {
        UUID orderId = UUID.randomUUID();
        UUID reviewerId = UUID.randomUUID();
        SecurityContextCurrentUser currentUser = currentUser(
                reviewerId,
                Set.of("finance_order_approval:approve"),
                false);
        ProcurementApprovalProjectionQuery query = queryWithCase(
                currentUser,
                reviewerId,
                true,
                orderId,
                UUID.randomUUID(),
                "PENDING",
                1,
                1,
                UUID.randomUUID(),
                UUID.randomUUID(),
                OffsetDateTime.now());

        FinanceApproval result =
                query.latestForOrder("PURCHASE", orderId, (short) 0);

        assertEquals(List.of("APPROVE"), result.allowedActions());
    }
    @Test
    void pendingCaseOffersOnlyGrantedRejectActionToEligibleReviewer() throws Exception {
        UUID orderId = UUID.randomUUID();
        UUID reviewerId = UUID.randomUUID();
        SecurityContextCurrentUser currentUser = currentUser(
                reviewerId,
                Set.of("finance_order_approval:reject"),
                false);
        ProcurementApprovalProjectionQuery query = queryWithCase(
                currentUser,
                reviewerId,
                true,
                orderId,
                UUID.randomUUID(),
                "PENDING",
                1,
                1,
                UUID.randomUUID(),
                UUID.randomUUID(),
                OffsetDateTime.now());

        FinanceApproval result =
                query.latestForOrder("PURCHASE", orderId, (short) 0);

        assertEquals(List.of("REJECT"), result.allowedActions());
    }


    @Test
    void pendingCaseHidesActionsFromNonEligibleSuperAdmin() throws Exception {
        // V229/ADR-027：审批 gate 是「财务部门持 review 权限的审核组」资格，而非纯权限或超管标记。
        // 超管不在财务部门 → 资格失败 → 即便持有 review 权限也不可见审批动作（保留 ADR-019 的安全边界）。
        UUID orderId = UUID.randomUUID();
        UUID superAdminId = UUID.randomUUID();
        SecurityContextCurrentUser currentUser = currentUser(
                superAdminId,
                Set.of(
                        "finance_order_approval:approve",
                        "finance_order_approval:reject",
                        "purchase_order:submit_finance"),
                true);
        ProcurementApprovalProjectionQuery query = queryWithCase(
                currentUser,
                superAdminId,
                false,
                orderId,
                UUID.randomUUID(),
                "PENDING",
                1,
                1,
                UUID.randomUUID(),
                UUID.randomUUID(),
                OffsetDateTime.now());

        FinanceApproval result =
                query.latestForOrder("PURCHASE", orderId, (short) 0);

        assertEquals(List.of(), result.allowedActions());
    }

    @Test
    void approvedOrderWithoutCaseIsExposedAsLegacyEffective() {
        NamedParameterJdbcTemplate jdbc =
                mock(NamedParameterJdbcTemplate.class);
        SecurityContextCurrentUser currentUser = currentUser(
                UUID.randomUUID(),
                Set.of("purchase_order:submit_finance"),
                false);
        ProcurementApprovalProjectionQuery query =
                new ProcurementApprovalProjectionQuery(
                        jdbc, currentUser, noEligibleReviewer());
        UUID orderId = UUID.randomUUID();

        FinanceApproval result =
                query.latestForOrder("PURCHASE", orderId, (short) 1);

        assertNull(result.caseId());
        assertEquals("LEGACY_EFFECTIVE", result.status());
        assertEquals(0, result.attempt());
        assertEquals(0, result.version());
        assertEquals(List.of(), result.allowedActions());
    }

    @Test
    void financeTaskDetailAccessRequiresBothEligibleReviewerAndPendingCase() {
        UUID actorId = UUID.randomUUID();
        UUID pendingOrderId = UUID.randomUUID();
        UUID decidedOrderId = UUID.randomUUID();
        NamedParameterJdbcTemplate jdbc = mock(NamedParameterJdbcTemplate.class);
        when(jdbc.queryForObject(
                anyString(), any(SqlParameterSource.class), eq(Boolean.class)))
                .thenReturn(true, false);
        FinanceReviewerEligibilityPort eligibility = mock(FinanceReviewerEligibilityPort.class);
        when(eligibility.findEligible(actorId)).thenReturn(Optional.of(
                new FinanceReviewerEligibilityPort.EligibleFinanceReviewer(
                        actorId, UUID.randomUUID(), "finance reviewer")));
        ProcurementApprovalProjectionQuery query = new ProcurementApprovalProjectionQuery(
                jdbc, currentUser(actorId, Set.of("finance_order_approval:reject"), false), eligibility);

        assertTrue(query.canCurrentActorReviewPending("PURCHASE", pendingOrderId));
        assertFalse(query.canCurrentActorReviewPending("PURCHASE", decidedOrderId));
        assertTrue(query.isCurrentActorEligibleReviewer());
    }

    @Test
    void ineligibleActorCannotProbeWhetherAnOrderHasPendingReview() {
        UUID actorId = UUID.randomUUID();
        NamedParameterJdbcTemplate jdbc = mock(NamedParameterJdbcTemplate.class);
        FinanceReviewerEligibilityPort eligibility = mock(FinanceReviewerEligibilityPort.class);
        when(eligibility.findEligible(actorId)).thenReturn(Optional.empty());
        ProcurementApprovalProjectionQuery query = new ProcurementApprovalProjectionQuery(
                jdbc, currentUser(actorId, Set.of("finance_order_approval:approve"), true), eligibility);

        assertFalse(query.canCurrentActorReviewPending("SUBCONTRACT", UUID.randomUUID()));
        assertFalse(query.isCurrentActorEligibleReviewer());
        verifyNoInteractions(jdbc);
    }

    private static ProcurementApprovalProjectionQuery queryWithCase(
            SecurityContextCurrentUser currentUser,
            UUID actorId,
            boolean actorEligible,
            UUID orderId,
            UUID caseId,
            String status,
            int attempt,
            long version,
            UUID assigneeUserId,
            UUID assigneeEmployeeId,
            OffsetDateTime submittedAt) throws Exception {
        NamedParameterJdbcTemplate jdbc =
                mock(NamedParameterJdbcTemplate.class);
        ResultSet row = mock(ResultSet.class);
        when(row.getObject("order_id", UUID.class)).thenReturn(orderId);
        when(row.getObject("id", UUID.class)).thenReturn(caseId);
        when(row.getString("status")).thenReturn(status);
        when(row.getInt("attempt")).thenReturn(attempt);
        when(row.getLong("version")).thenReturn(version);
        when(row.getObject("assignee_user_id", UUID.class))
                .thenReturn(assigneeUserId);
        when(row.getObject("assignee_employee_id", UUID.class))
                .thenReturn(assigneeEmployeeId);
        when(row.getString("assignee_name_snapshot"))
                .thenReturn("财务负责人");
        when(row.getString("rejection_reason")).thenReturn("金额需修正");
        when(row.getObject("submitted_at", OffsetDateTime.class))
                .thenReturn(submittedAt);
        doAnswer(invocation -> {
            RowCallbackHandler callback = invocation.getArgument(2);
            callback.processRow(row);
            return null;
        }).when(jdbc).query(
                anyString(),
                any(SqlParameterSource.class),
                any(RowCallbackHandler.class));
        FinanceReviewerEligibilityPort reviewerEligibility =
                mock(FinanceReviewerEligibilityPort.class);
        if (actorEligible) {
            when(reviewerEligibility.findEligible(actorId)).thenReturn(
                    Optional.of(new FinanceReviewerEligibilityPort
                            .EligibleFinanceReviewer(
                            actorId, UUID.randomUUID(), "财务审核员")));
        } else {
            when(reviewerEligibility.findEligible(actorId))
                    .thenReturn(Optional.empty());
        }
        return new ProcurementApprovalProjectionQuery(
                jdbc, currentUser, reviewerEligibility);
    }

    private static FinanceReviewerEligibilityPort noEligibleReviewer() {
        FinanceReviewerEligibilityPort port =
                mock(FinanceReviewerEligibilityPort.class);
        when(port.findEligible(any(UUID.class))).thenReturn(Optional.empty());
        return port;
    }

    private static SecurityContextCurrentUser currentUser(
            UUID userId, Set<String> permissions, boolean superAdmin) {
        SecurityContextCurrentUser current =
                mock(SecurityContextCurrentUser.class);
        AuthUser actor = new AuthUser(
                userId,
                UUID.randomUUID(),
                "tester",
                Set.of(),
                permissions,
                false,
                true,
                superAdmin);
        when(current.get()).thenReturn(Optional.of(actor));
        return current;
    }
}

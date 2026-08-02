package com.uten.imp.features.finance.procurement;

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
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.doAnswer;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class ProcurementApprovalProjectionQueryTest {

    @Test
    void rejectedDraftOffersOnlyResubmitToAuthorizedPurchaser() throws Exception {
        UUID orderId = UUID.randomUUID();
        UUID caseId = UUID.randomUUID();
        UUID assigneeUserId = UUID.randomUUID();
        UUID assigneeEmployeeId = UUID.randomUUID();
        OffsetDateTime submittedAt = OffsetDateTime.now();
        SecurityContextCurrentUser currentUser = currentUser(
                UUID.randomUUID(),
                Set.of("purchase_order:submit_finance"),
                false);
        ProcurementApprovalProjectionQuery query = queryWithCase(
                currentUser,
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
    void pendingCaseOffersReviewActionsOnlyToExactAssignee() throws Exception {
        UUID orderId = UUID.randomUUID();
        UUID assigneeUserId = UUID.randomUUID();
        SecurityContextCurrentUser currentUser = currentUser(
                assigneeUserId,
                Set.of("finance_order_approval:review"),
                false);
        ProcurementApprovalProjectionQuery query = queryWithCase(
                currentUser,
                orderId,
                UUID.randomUUID(),
                "PENDING",
                1,
                1,
                assigneeUserId,
                UUID.randomUUID(),
                OffsetDateTime.now());

        FinanceApproval result =
                query.latestForOrder("PURCHASE", orderId, (short) 0);

        assertEquals(List.of("APPROVE", "REJECT"), result.allowedActions());
    }

    @Test
    void superAdminDoesNotBypassExactAssigneeCheck() throws Exception {
        UUID orderId = UUID.randomUUID();
        SecurityContextCurrentUser currentUser = currentUser(
                UUID.randomUUID(),
                Set.of(
                        "finance_order_approval:review",
                        "purchase_order:submit_finance"),
                true);
        ProcurementApprovalProjectionQuery query = queryWithCase(
                currentUser,
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
                new ProcurementApprovalProjectionQuery(jdbc, currentUser);
        UUID orderId = UUID.randomUUID();

        FinanceApproval result =
                query.latestForOrder("PURCHASE", orderId, (short) 1);

        assertNull(result.caseId());
        assertEquals("LEGACY_EFFECTIVE", result.status());
        assertEquals(0, result.attempt());
        assertEquals(0, result.version());
        assertEquals(List.of(), result.allowedActions());
    }

    private static ProcurementApprovalProjectionQuery queryWithCase(
            SecurityContextCurrentUser currentUser,
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
        return new ProcurementApprovalProjectionQuery(jdbc, currentUser);
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

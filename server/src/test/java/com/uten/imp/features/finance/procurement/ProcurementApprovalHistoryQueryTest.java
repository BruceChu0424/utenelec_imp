package com.uten.imp.features.finance.procurement;

import com.uten.imp.application.port.FinanceReviewerEligibilityPort.EligibleFinanceReviewer;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.admin.workflow.WorkflowReviewerEligibility;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.RowMapper;

import java.sql.ResultSet;
import java.util.List;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class ProcurementApprovalHistoryQueryTest {
    @Test
    @SuppressWarnings("unchecked")
    void approvedRoundsAreReadonlyEvenForAnEligibleApproverAndUseOneStatusInCountAndList() throws Exception {
        JdbcTemplate jdbc = mock(JdbcTemplate.class);
        when(jdbc.queryForObject(anyString(), eq(Long.class), any(Object[].class))).thenReturn(1L);
        ResultSet rs = mock(ResultSet.class);
        when(rs.getString("status")).thenReturn("APPROVED");
        when(rs.getString("order_type")).thenReturn("PURCHASE");
        when(jdbc.query(anyString(), any(RowMapper.class), any(Object[].class))).thenAnswer(call -> {
            RowMapper<ProcurementApprovalContracts.ApprovalTask> mapper = call.getArgument(1);
            return List.of(mapper.mapRow(rs, 0));
        });
        var result = service(jdbc).tasks(1, 20, "PURCHASE", "Supplier", null, null, "PO1", "APPROVED");
        assertEquals("APPROVED", result.getItems().getFirst().status());
        assertTrue(result.getItems().getFirst().allowedActions().isEmpty());
        var countSql = ArgumentCaptor.forClass(String.class);
        verify(jdbc).queryForObject(countSql.capture(), eq(Long.class), any(Object[].class));
        var listSql = ArgumentCaptor.forClass(String.class);
        verify(jdbc).query(listSql.capture(), any(RowMapper.class), any(Object[].class));
        for (String statement : List.of(countSql.getValue(), listSql.getValue())) {
            assertTrue(statement.contains("c.status = 'APPROVED'"));
            assertFalse(statement.contains("WHERE c.status = 'PENDING'"));
            assertTrue(statement.contains("c.bill_no_snapshot = ?"));
            assertTrue(statement.contains("LOWER(COALESCE(c.display_snapshot ->> 'supplierName'"));
        }
        assertTrue(listSql.getValue().contains("COALESCE(c.finance_exchange_rate"));
    }

    @Test
    void invalidHistoryStatusFailsBeforeAnyQuery() {
        JdbcTemplate jdbc = mock(JdbcTemplate.class);
        assertThrows(ApiException.class, () -> service(jdbc).tasks(1, 20, "", "", null, null, null, "anything"));
        verifyNoInteractions(jdbc);
        assertEquals("ALL", ProcurementFinanceApprovalService.normalizeQueueStatus(" all "));
    }

    private static ProcurementFinanceApprovalService service(JdbcTemplate jdbc) {
        UUID userId = UUID.randomUUID();
        var user = mock(AuthUser.class);
        when(user.getId()).thenReturn(userId);
        when(user.getPermissions()).thenReturn(Set.of("finance_order_approval:approve"));
        var current = mock(SecurityContextCurrentUser.class);
        when(current.get()).thenReturn(Optional.of(user));
        var eligibility = mock(WorkflowReviewerEligibility.class);
        when(eligibility.findEligible(userId)).thenReturn(Optional.of(new EligibleFinanceReviewer(userId, UUID.randomUUID(), "财务")));
        return new ProcurementFinanceApprovalService(List.of(), jdbc, null, null, eligibility, null, current,
                null, null, null, null, null);
    }
}

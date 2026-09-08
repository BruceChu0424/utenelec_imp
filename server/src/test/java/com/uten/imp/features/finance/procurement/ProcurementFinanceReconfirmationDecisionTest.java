package com.uten.imp.features.finance.procurement;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.SerializationFeature;
import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.application.port.ProcurementOrderApprovalPort;
import com.uten.imp.application.port.ProcurementOrderApprovalPort.OrderSnapshot;
import com.uten.imp.common.util.HashUtil;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.admin.workflow.WorkflowReviewerEligibility;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.RowMapper;

import java.lang.reflect.InvocationTargetException;
import java.math.BigDecimal;
import java.sql.ResultSet;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.contains;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.*;

class ProcurementFinanceReconfirmationDecisionTest {
    @Test
    void reconfirmationCanBeRejectedWithoutRunningDraftValidationOrReapplyingTheOrder() throws Exception {
        Fixture fixture = fixture(false);
        invoke(fixture, "rejectOne");
        verify(fixture.port()).lockFinanceReconfirmationSnapshot(fixture.orderId());
        verify(fixture.port(), never()).lockAndValidateFinanceSubmission(any());
        verify(fixture.port(), never()).applyFinanceApproval(any(), any());
        verify(fixture.jdbc()).update(contains("SET status = 'REJECTED'"), any(Object[].class));
        verify(fixture.projection()).latestForOrder("PURCHASE", fixture.orderId(), (short) 1);
    }

    @Test
    void reconfirmationApprovalChecksTheSnapshotWithoutDuplicatingInboundExpectation() throws Exception {
        Fixture fixture = fixture(false);
        invoke(fixture, "approveOne");
        verify(fixture.port()).lockFinanceReconfirmationSnapshot(fixture.orderId());
        verify(fixture.port(), never()).applyFinanceApproval(any(), any());
        verify(fixture.jdbc(), never()).update(contains("INSERT INTO inbound_expectations"), any(Object[].class));
    }

    @Test
    void changedCommercialSnapshotPreventsReconfirmationDecision() throws Exception {
        Fixture fixture = fixture(true);
        InvocationTargetException error = assertThrows(InvocationTargetException.class,
                () -> invoke(fixture, "approveOne"));
        assertThat(error.getCause()).isInstanceOf(ApiException.class);
        verify(fixture.jdbc(), never()).update(anyString(), any(Object[].class));
    }

    private static void invoke(Fixture fixture, String action) throws Exception {
        var method = ProcurementFinanceApprovalService.class.getDeclaredMethod(action,
                String.class, UUID.class, long.class, UUID.class, String.class);
        method.setAccessible(true);
        method.invoke(fixture.service(), "PURCHASE", fixture.orderId(), 1L, fixture.caseId(), "核对金额");
    }

    private static Fixture fixture(boolean mismatched) throws Exception {
        UUID orderId = UUID.randomUUID();
        UUID caseId = UUID.randomUUID();
        ProcurementOrderApprovalPort port = mock(ProcurementOrderApprovalPort.class);
        when(port.orderType()).thenReturn("PURCHASE");
        when(port.isFinanceApproved(orderId)).thenReturn(true);
        ObjectMapper mapper = new ObjectMapper().findAndRegisterModules()
                .disable(SerializationFeature.WRITE_DATES_AS_TIMESTAMPS);
        OrderSnapshot snapshot = new OrderSnapshot("PURCHASE", orderId, "CG-REV-1",
                LocalDate.of(2026, 9, 7), UUID.randomUUID(), null, UUID.randomUUID(),
                BigDecimal.ONE, null, BigDecimal.ZERO, null, UUID.randomUUID(),
                LocalDate.of(2026, 9, 10), BigDecimal.TEN, BigDecimal.TEN, List.of());
        String json = ProcurementApprovalSnapshot.json(snapshot, mapper);
        assertThat(json).contains("\"billDate\":\"2026-09-07\"");
        when(port.lockFinanceReconfirmationSnapshot(orderId)).thenReturn(snapshot);
        ResultSet row = mock(ResultSet.class);
        when(row.getObject("id", UUID.class)).thenReturn(caseId);
        when(row.getObject("order_id", UUID.class)).thenReturn(orderId);
        when(row.getLong("version")).thenReturn(1L);
        when(row.getString("snapshot_hash")).thenReturn(mismatched ? "old-hash" : HashUtil.sha256(json));
        JdbcTemplate jdbc = mock(JdbcTemplate.class);
        when(jdbc.query(anyString(), any(RowMapper.class), eq("PURCHASE"), eq(orderId)))
                .thenAnswer(invocation -> List.of(((RowMapper<?>) invocation.getArgument(1)).mapRow(row, 0)));
        when(jdbc.update(anyString(), any(Object[].class))).thenReturn(1);
        when(jdbc.queryForObject(anyString(), eq(Long.class), any(Object[].class))).thenReturn(0L);
        SecurityContextCurrentUser actor = mock(SecurityContextCurrentUser.class);
        when(actor.requireId()).thenReturn(UUID.randomUUID());
        when(actor.requireEmployeeId()).thenReturn(UUID.randomUUID());
        ProcurementApprovalProjectionQuery projection = mock(ProcurementApprovalProjectionQuery.class);
        ProcurementFinanceApprovalService service = new ProcurementFinanceApprovalService(
                List.of(port), jdbc, mapper, mock(BusinessEventPublisher.class),
                mock(WorkflowReviewerEligibility.class), projection, actor, mock(TxSessionVars.class),
                mock(com.uten.imp.features.notice.ChainNoticeService.class),
                        org.mockito.Mockito.mock(com.uten.imp.features.common.taskclaim.TaskClaimService.class),
                        org.mockito.Mockito.mock(com.uten.imp.common.concurrency.ProcurementMutationLocks.class, org.mockito.Mockito.RETURNS_DEEP_STUBS));
        return new Fixture(service, port, jdbc, projection, orderId, caseId);
    }

    private record Fixture(ProcurementFinanceApprovalService service, ProcurementOrderApprovalPort port,
            JdbcTemplate jdbc, ProcurementApprovalProjectionQuery projection, UUID orderId, UUID caseId) {}
}

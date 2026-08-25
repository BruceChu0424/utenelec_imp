package com.uten.imp.features.finance.procurement;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.application.port.FinanceReviewerEligibilityPort.EligibleFinanceReviewer;
import com.uten.imp.application.port.ProcurementOrderApprovalPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.admin.workflow.WorkflowReviewerEligibility;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.JdbcTemplate;

import java.util.List;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.clearInvocations;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

class ProcurementFinanceSubmitterOwnerGuardTest {

    @Test
    void readOnlySubmitterStopsBeforeSnapshotAndCaseWrites() {
        Fixture fixture = fixture(Set.of("purchase_order:submit_finance"), false);
        UUID orderId = UUID.randomUUID();
        doThrow(new ApiException(ErrorCode.FORBIDDEN, "read only"))
                .when(fixture.port()).requireFinanceSubmitterWritable(orderId);

        ApiException denied = assertThrows(
                ApiException.class,
                () -> fixture.service().submit("PURCHASE", orderId));

        assertEquals(ErrorCode.FORBIDDEN, denied.getCode());
        verify(fixture.port()).requireFinanceSubmitterWritable(orderId);
        verify(fixture.port(), never()).lockAndValidateFinanceSubmission(any());
        verifyNoInteractions(fixture.jdbc(), fixture.projection());
    }

    @Test
    void pooledFinanceReviewerDoesNotUseSubmitterOwnerGuard() {
        Fixture fixture = fixture(Set.of("finance_order_approval:approve"), true);
        UUID orderId = UUID.randomUUID();
        doThrow(new ApiException(ErrorCode.CONFLICT, "stop after reviewer gate"))
                .when(fixture.port()).lockAndValidateFinanceSubmission(orderId);

        ApiException stopped = assertThrows(
                ApiException.class,
                () -> fixture.service().approve("PURCHASE", orderId, 1L));

        assertEquals(ErrorCode.CONFLICT, stopped.getCode());
        verify(fixture.port(), never()).requireFinanceSubmitterWritable(any());
        verify(fixture.port()).lockAndValidateFinanceSubmission(orderId);
        verifyNoInteractions(fixture.jdbc(), fixture.projection());
    }

    private static Fixture fixture(Set<String> permissions, boolean eligible) {
        UUID userId = UUID.randomUUID();
        UUID employeeId = UUID.randomUUID();
        ProcurementOrderApprovalPort port = mock(ProcurementOrderApprovalPort.class);
        when(port.orderType()).thenReturn("PURCHASE");
        JdbcTemplate jdbc = mock(JdbcTemplate.class);
        WorkflowReviewerEligibility eligibility = mock(WorkflowReviewerEligibility.class);
        if (eligible) {
            when(eligibility.findEligible(userId)).thenReturn(Optional.of(
                    new EligibleFinanceReviewer(userId, employeeId, "财务审核员")));
        } else {
            when(eligibility.findEligible(userId)).thenReturn(Optional.empty());
        }
        ProcurementApprovalProjectionQuery projection =
                mock(ProcurementApprovalProjectionQuery.class);
        SecurityContextCurrentUser currentUser = mock(SecurityContextCurrentUser.class);
        AuthUser user = new AuthUser(
                userId, employeeId, "tester", Set.of(), permissions,
                false, true, false);
        when(currentUser.get()).thenReturn(Optional.of(user));
        when(currentUser.requireId()).thenReturn(userId);
        when(currentUser.requireEmployeeId()).thenReturn(employeeId);
        ProcurementFinanceApprovalService service =
                new ProcurementFinanceApprovalService(
                        List.of(port),
                        jdbc,
                        new ObjectMapper(),
                        mock(BusinessEventPublisher.class),
                        eligibility,
                        projection,
                        currentUser,
                        mock(TxSessionVars.class));
        clearInvocations(port, jdbc, projection, eligibility, currentUser);
        return new Fixture(service, port, jdbc, projection);
    }

    private record Fixture(
            ProcurementFinanceApprovalService service,
            ProcurementOrderApprovalPort port,
            JdbcTemplate jdbc,
            ProcurementApprovalProjectionQuery projection) {
    }
}

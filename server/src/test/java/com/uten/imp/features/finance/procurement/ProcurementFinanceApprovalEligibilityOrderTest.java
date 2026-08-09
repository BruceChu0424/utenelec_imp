package com.uten.imp.features.finance.procurement;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.application.port.ProcurementOrderApprovalPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.admin.workflow.WorkflowReviewerEligibility;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.JdbcTemplate;

import java.util.List;
import java.util.Optional;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.Mockito.clearInvocations;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

class ProcurementFinanceApprovalEligibilityOrderTest {

    @Test
    void revokedReviewerIsRejectedBeforeApproveTouchesOrderOrCase() {
        Fixture fixture = fixture();

        ApiException denied = assertThrows(
                ApiException.class,
                () -> fixture.service().approve(
                        "PURCHASE", UUID.randomUUID(), 1L));

        assertEquals(ErrorCode.FORBIDDEN, denied.getCode());
        verify(fixture.eligibility()).findEligible(fixture.actorId());
        verify(fixture.port(), never())
                .lockAndValidateFinanceSubmission(org.mockito.ArgumentMatchers.any());
        verifyNoInteractions(fixture.jdbc(), fixture.projection());
    }

    @Test
    void revokedReviewerIsRejectedBeforeRejectTouchesOrderOrCase() {
        Fixture fixture = fixture();

        ApiException denied = assertThrows(
                ApiException.class,
                () -> fixture.service().reject(
                        "PURCHASE", UUID.randomUUID(), 1L, "reason"));

        assertEquals(ErrorCode.FORBIDDEN, denied.getCode());
        verify(fixture.eligibility()).findEligible(fixture.actorId());
        verify(fixture.port(), never())
                .lockAndValidateFinanceSubmission(org.mockito.ArgumentMatchers.any());
        verifyNoInteractions(fixture.jdbc(), fixture.projection());
    }

    private static Fixture fixture() {
        UUID actorId = UUID.randomUUID();
        ProcurementOrderApprovalPort port = mock(ProcurementOrderApprovalPort.class);
        when(port.orderType()).thenReturn("PURCHASE");
        JdbcTemplate jdbc = mock(JdbcTemplate.class);
        WorkflowReviewerEligibility eligibility =
                mock(WorkflowReviewerEligibility.class);
        when(eligibility.findEligible(actorId)).thenReturn(Optional.empty());
        ProcurementApprovalProjectionQuery projection =
                mock(ProcurementApprovalProjectionQuery.class);
        SecurityContextCurrentUser currentUser =
                mock(SecurityContextCurrentUser.class);
        when(currentUser.requireId()).thenReturn(actorId);
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
        return new Fixture(
                actorId, service, port, jdbc, eligibility, projection);
    }

    private record Fixture(
            UUID actorId,
            ProcurementFinanceApprovalService service,
            ProcurementOrderApprovalPort port,
            JdbcTemplate jdbc,
            WorkflowReviewerEligibility eligibility,
            ProcurementApprovalProjectionQuery projection) {
    }
}

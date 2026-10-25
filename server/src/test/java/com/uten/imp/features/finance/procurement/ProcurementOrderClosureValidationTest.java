package com.uten.imp.features.finance.procurement;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.application.port.ProcurementClosureNoticePort;
import com.uten.imp.application.port.ProcurementOrderApprovalPort;
import com.uten.imp.application.port.ProcurementOrderTerminationSourcePort;
import com.uten.imp.application.port.TaskClaimMutationGuardPort;
import com.uten.imp.common.concurrency.ProcurementMutationLocks;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.admin.workflow.WorkflowReviewerEligibility;
import com.uten.imp.features.finance.procurement.ProcurementOrderClosureService.ClosureRequest;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.NullAndEmptySource;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.jdbc.core.JdbcTemplate;

import java.util.List;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

class ProcurementOrderClosureValidationTest {
    private final JdbcTemplate jdbc=mock(JdbcTemplate.class);
    private final EntityManager em=mock(EntityManager.class);
    private final ProcurementMutationLocks locks=mock(ProcurementMutationLocks.class);
    private final SecurityContextCurrentUser current=mock(SecurityContextCurrentUser.class);
    private final TxSessionVars tx=mock(TxSessionVars.class);
    private final ProcurementOrderApprovalPort port=mock(ProcurementOrderApprovalPort.class);

    private ProcurementOrderClosureService service(Set<String> permissions) {
        when(current.get()).thenReturn(Optional.of(new AuthUser(UUID.randomUUID(),UUID.randomUUID(),
                "closure-validation",permissions,false,true,false)));
        when(port.orderType()).thenReturn("PURCHASE");
        return new ProcurementOrderClosureService(jdbc,em,new ObjectMapper(),List.of(port),locks,current,tx,
                mock(WorkflowReviewerEligibility.class),mock(BusinessEventPublisher.class),
                mock(ProcurementClosureNoticePort.class),mock(TaskClaimMutationGuardPort.class),
                mock(ProcurementOrderTerminationSourcePort.class));
    }

    @Test void nullRequestIsValidationFailureBeforeOrderLockOrDatabaseAccess() {
        var service=service(Set.of("purchase_order:view","purchase_order:submit_finance"));
        assertThatThrownBy(()->service.submit("PURCHASE",UUID.randomUUID(),null))
                .isInstanceOfSatisfying(ApiException.class,error->org.assertj.core.api.Assertions.assertThat(error.getCode())
                        .isEqualTo(ErrorCode.VALIDATION_FAILED));
        verify(tx).bind();
        verifyNoInteractions(jdbc,em,locks);
        verify(port,never()).requireFinanceSubmitterWritable(any());
    }

    @ParameterizedTest @NullAndEmptySource @ValueSource(strings={"UNKNOWN"," "})
    void missingOrUnknownModeCannotReachOrderMutation(String mode) {
        var service=service(Set.of("purchase_order:view","purchase_order:submit_finance"));
        assertThatThrownBy(()->service.submit("PURCHASE",UUID.randomUUID(),new ClosureRequest(mode,"reason","fingerprint")))
                .isInstanceOfSatisfying(ApiException.class,error->org.assertj.core.api.Assertions.assertThat(error.getCode())
                        .isEqualTo(ErrorCode.VALIDATION_FAILED));
        verifyNoInteractions(jdbc,em,locks);
        verify(port,never()).requireFinanceSubmitterWritable(any());
    }

    @Test void permissionRejectionStillPrecedesNullRequestValidation() {
        var service=service(Set.of());
        assertThatThrownBy(()->service.submit("PURCHASE",UUID.randomUUID(),null))
                .isInstanceOfSatisfying(ApiException.class,error->org.assertj.core.api.Assertions.assertThat(error.getCode())
                        .isEqualTo(ErrorCode.FORBIDDEN));
        verifyNoInteractions(jdbc,em,locks);
        verify(port,never()).requireFinanceSubmitterWritable(any());
    }
}

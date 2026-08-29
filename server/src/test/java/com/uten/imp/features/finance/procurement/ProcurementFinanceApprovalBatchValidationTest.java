package com.uten.imp.features.finance.procurement;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.application.port.FinanceReviewerEligibilityPort.EligibleFinanceReviewer;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.admin.workflow.WorkflowReviewerEligibility;
import com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.BatchDecisionItem;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.RowMapper;
import org.springframework.transaction.annotation.Transactional;

import java.util.ArrayList;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.contains;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.AdditionalMatchers.aryEq;
import static org.mockito.Mockito.doReturn;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class ProcurementFinanceApprovalBatchValidationTest {

    @Test
    void rejectsEmptyDuplicateAndOverLimitBeforeAnyDatabaseMutation() {
        Fixture fixture = fixture();
        UUID caseId = UUID.randomUUID();

        assertThrows(ApiException.class,
                () -> fixture.service().approveBatch(List.of()));
        assertThrows(ApiException.class,
                () -> fixture.service().approveBatch(List.of(
                        new BatchDecisionItem(caseId, 1L),
                        new BatchDecisionItem(caseId, 1L))));

        List<BatchDecisionItem> tooMany = new ArrayList<>();
        for (int index = 0; index < 101; index++) {
            tooMany.add(new BatchDecisionItem(UUID.randomUUID(), 1L));
        }
        assertThrows(ApiException.class,
                () -> fixture.service().approveBatch(tooMany));
        assertThrows(ApiException.class,
                () -> fixture.service().rejectBatch(
                        List.of(new BatchDecisionItem(caseId, 1L)), " "));

        verifyNoInteractions(fixture.jdbc());
    }

    @Test
    @SuppressWarnings({"rawtypes", "unchecked"})
    void staleCaseIdFailsBeforeAnOrderPortCanBeResolved() {
        Fixture fixture = fixture();
        doReturn(List.of()).when(fixture.jdbc()).query(
                anyString(), any(RowMapper.class), any(Object[].class));

        assertThrows(ApiException.class,
                () -> fixture.service().approveBatch(List.of(
                        new BatchDecisionItem(UUID.randomUUID(), 1L))));
    }

    @Test
    void bothBatchCommandsDeclareTransactionBoundaries() throws Exception {
        assertNotNull(ProcurementFinanceApprovalService.class
                .getMethod("approveBatch", List.class)
                .getAnnotation(Transactional.class));
        assertNotNull(ProcurementFinanceApprovalService.class
                .getMethod("rejectBatch", List.class, String.class)
                .getAnnotation(Transactional.class));
    }

    @Test
    @SuppressWarnings({"rawtypes", "unchecked"})
    void taskSearchUsesTheSameTypeAndKeywordForCountAndRows() {
        Fixture fixture = fixture();
        when(fixture.jdbc().queryForObject(
                anyString(), eq(Long.class), any(Object[].class)))
                .thenReturn(0L);
        doReturn(List.of()).when(fixture.jdbc()).query(
                anyString(), any(RowMapper.class), any(Object[].class));

        fixture.service().tasks(2, 30, "PURCHASE", " Vendor A ");

        verify(fixture.jdbc()).queryForObject(
                contains("LOWER(COALESCE(supplier.name"),
                eq(Long.class),
                aryEq(new Object[]{
                        "PURCHASE",
                        "%vendor a%",
                        "%vendor a%",
                        "%vendor a%"
                }));
        verify(fixture.jdbc()).query(
                contains("ORDER BY c.submitted_at, c.id"),
                any(RowMapper.class),
                aryEq(new Object[]{
                        "PURCHASE",
                        "%vendor a%",
                        "%vendor a%",
                        "%vendor a%",
                        30,
                        30
                }));
    }

    private static Fixture fixture() {
        JdbcTemplate jdbc = mock(JdbcTemplate.class);
        WorkflowReviewerEligibility reviewer =
                mock(WorkflowReviewerEligibility.class);
        SecurityContextCurrentUser currentUser =
                mock(SecurityContextCurrentUser.class);
        UUID userId = UUID.randomUUID();
        when(currentUser.requireId()).thenReturn(userId);
        when(currentUser.get()).thenReturn(Optional.empty());
        when(reviewer.findEligible(userId)).thenReturn(Optional.of(
                new EligibleFinanceReviewer(
                        userId, UUID.randomUUID(), "审核员")));
        ProcurementFinanceApprovalService service =
                new ProcurementFinanceApprovalService(
                        List.of(),
                        jdbc,
                        mock(ObjectMapper.class),
                        mock(BusinessEventPublisher.class),
                        reviewer,
                        mock(ProcurementApprovalProjectionQuery.class),
                        currentUser,
                        mock(TxSessionVars.class));
        return new Fixture(service, jdbc);
    }

    private record Fixture(
            ProcurementFinanceApprovalService service,
            JdbcTemplate jdbc) {
    }
}

package com.uten.imp.common.web;

import com.uten.imp.audit.AuditActorDirectory;
import com.uten.imp.features.finance.asset.application.*;
import com.uten.imp.features.finance.receivables.CustomerPrepaymentQueryService;
import com.uten.imp.features.finance.receivables.SalesOrderMoneyPositionQuery;
import com.uten.imp.features.sales.SalesDocumentAccessPolicy;
import com.uten.imp.features.sales.order.SalesOrderService;
import com.uten.imp.responsibility.DataHandoverCandidateService;
import com.uten.imp.responsibility.EmployeeHandoverAuthorization;
import com.uten.imp.security.DocumentAccessPolicy.NativeReadScope;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.test.util.ReflectionTestUtils;

import java.math.BigDecimal;
import java.util.List;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

/** Exercises public reader methods, including the old long-to-int cast paths. */
class JpaReaderOffsetTest {
    private final EntityManager em = mock(EntityManager.class);
    private final Query query = mock(Query.class, RETURNS_SELF);

    private void queries() {
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.getSingleResult()).thenReturn(0L);
    }

    private void rejectsWrappedPage(org.assertj.core.api.ThrowableAssert.ThrowingCallable action) {
        assertThatThrownBy(action).isInstanceOfSatisfying(ApiException.class,
                error -> assertThat(error.getCode()).isEqualTo(ErrorCode.VALIDATION_FAILED));
        verify(query, never()).setFirstResult(anyInt());
        verify(query, never()).getResultList();
    }

    @Test void handoverCandidateReaderCannotSelectAnotherPageAfterIntegerOverflow() {
        queries();
        var authorization = mock(EmployeeHandoverAuthorization.class);
        when(authorization.candidateScope()).thenReturn(new EmployeeHandoverAuthorization.CandidateScope(true, UUID.randomUUID()));
        var service = new DataHandoverCandidateService(em, authorization);
        rejectsWrappedPage(() -> service.search("source", "", Integer.MAX_VALUE, 100));
    }

    @Test void auditActorDirectoryCannotNarrowALongPageableOffsetIntoANegativeInt() {
        queries();
        var directory = new AuditActorDirectory();
        ReflectionTestUtils.setField(directory, "entityManager", em);
        rejectsWrappedPage(() -> directory.findActors(null, Integer.MAX_VALUE, 100));
    }

    @ParameterizedTest @ValueSource(booleans = {false, true})
    void bothAssetReadersRejectTheSameLongToIntBoundary(boolean deferred) {
        queries();
        var service = new FinanceAssetQueryService(em, mock(FinanceAssetAuthorization.class),
                mock(FinanceAssetFeatureGate.class), mock(FinanceAssetReviewRevisionService.class));
        rejectsWrappedPage(() -> {
            if (deferred) service.listDeferredExpenses(null, null, null, null, Integer.MAX_VALUE, 100);
            else service.listFixedAssets(null, null, null, null, Integer.MAX_VALUE, 100);
        });
    }

    @Test void prepaymentReaderRetainsItsTwoHundredRowContractButRejectsOverflow() {
        queries();
        var service = new CustomerPrepaymentQueryService(em, mock(SalesOrderMoneyPositionQuery.class));
        rejectsWrappedPage(() -> service.list(null, null, null, Integer.MAX_VALUE, 200));
    }

    @Test void orderProgressCannotWrapIntoAnEarlierAuthorizedPage() {
        queries();
        var access = mock(SalesDocumentAccessPolicy.class);
        when(access.nativeReadScope("o.owner_employee_id", "salesOwners"))
                .thenReturn(new NativeReadScope("o.owner_employee_id IN (:salesOwners)", "salesOwners", Set.of(UUID.randomUUID())));
        var service = mock(SalesOrderService.class, CALLS_REAL_METHODS);
        ReflectionTestUtils.setField(service, "em", em);
        ReflectionTestUtils.setField(service, "accessPolicy", access);
        rejectsWrappedPage(() -> service.progress(Integer.MAX_VALUE, 100, "OPEN", null, null, null, null, null, null));
    }

    @Test void aValidTwoHundredRowPrepaymentPageIsNotSilentlyChangedToTheCommonHundredRowMaximum() {
        Query count = mock(Query.class), rows = mock(Query.class, RETURNS_SELF), summary = mock(Query.class);
        when(count.getSingleResult()).thenReturn(0L);
        when(rows.getResultList()).thenReturn(List.of());
        when(summary.getSingleResult()).thenReturn(new Object[]{BigDecimal.ZERO, BigDecimal.ZERO,
                BigDecimal.ZERO, BigDecimal.ZERO, BigDecimal.ZERO, BigDecimal.ZERO});
        when(em.createNativeQuery(anyString())).thenReturn(count, rows, summary);
        var service = new CustomerPrepaymentQueryService(em, mock(SalesOrderMoneyPositionQuery.class));
        var result = service.list(null, null, null, 2, 200);
        assertThat(result.page()).isEqualTo(2); assertThat(result.size()).isEqualTo(200);
        verify(rows).setFirstResult(200); verify(rows).setMaxResults(200);
    }
}

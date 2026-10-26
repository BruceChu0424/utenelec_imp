package com.uten.imp.common.web;

import com.uten.imp.features.common.taskclaim.TaskClaimService;
import com.uten.imp.features.production.schedule.ProductionScheduleService;
import com.uten.imp.features.sales.order.SalesOrderFinanceConfirmService;
import com.uten.imp.features.sales.quote.SalesQuoteFinanceService;
import com.uten.imp.features.subcontract.SubcontractDocumentAccessPolicy;
import com.uten.imp.features.subcontract.draw.SubcontractDrawQueryService;
import com.uten.imp.security.DocumentAccessPolicy.NativeReadScope;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.springframework.test.util.ReflectionTestUtils;

import java.util.List;
import java.util.Set;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

/** SQL can represent deeper offsets than JPA's int first-result method. */
class NativeSqlOffsetTest {
    private final EntityManager em = mock(EntityManager.class);
    private final Query query = mock(Query.class, RETURNS_SELF);
    private static final long HUNDRED_ROW_OFFSET = ((long) Integer.MAX_VALUE - 1) * 100;

    private void queries(long count) {
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.getSingleResult()).thenReturn(count);
        when(query.getResultList()).thenReturn(List.of());
    }

    @Test void schedulingRetainsItsNativeLongPageWithoutReturningAnEarlierPage() {
        queries((long) Integer.MAX_VALUE * 100);
        var result = new ProductionScheduleService(em, null, null).pending(
                Integer.MAX_VALUE, Integer.MAX_VALUE, "", null, null, null, null, null, null);
        assertThat(result.getPage()).isEqualTo(Integer.MAX_VALUE); assertThat(result.getSize()).isEqualTo(100);
        verify(query).setParameter("off", HUNDRED_ROW_OFFSET);
    }

    @Test void schedulingStillNormalizesNegativePageAndSizeToTheFirstSingleRow() {
        queries(0);
        var result = new ProductionScheduleService(em, null, null).pending(
                Integer.MIN_VALUE, Integer.MIN_VALUE, "", null, null, null, null, null, null);
        assertThat(result.getPage()).isEqualTo(1); assertThat(result.getSize()).isEqualTo(1);
        verify(query).setParameter("off", 0L); verify(query).setParameter("lim", 1);
    }

    @Test void quoteFinanceQueuePassesALongOffsetAfterItsExistingLastPagePolicy() {
        queries((long) Integer.MAX_VALUE * 100);
        var service = mock(SalesQuoteFinanceService.class, CALLS_REAL_METHODS);
        ReflectionTestUtils.setField(service, "em", em);
        ReflectionTestUtils.setField(service, "claimViews", mock(TaskClaimService.class));
        var result = service.list("pending", null, Integer.MAX_VALUE, Integer.MAX_VALUE);
        assertThat(result.getPage()).isEqualTo(Integer.MAX_VALUE); assertThat(result.getSize()).isEqualTo(100);
        verify(query).setParameter("off", HUNDRED_ROW_OFFSET);
    }

    @Test void orderFinanceQueueDoesNotWrapTheNativeOffsetToANegativeInt() {
        queries((long) Integer.MAX_VALUE * 100);
        var service = mock(SalesOrderFinanceConfirmService.class, CALLS_REAL_METHODS);
        ReflectionTestUtils.setField(service, "em", em);
        var result = service.pending(Integer.MAX_VALUE, Integer.MAX_VALUE, null, null, null);
        assertThat(result.getPage()).isEqualTo(Integer.MAX_VALUE); assertThat(result.getSize()).isEqualTo(100);
        verify(query).setParameter("off", HUNDRED_ROW_OFFSET);
    }

    @Test void subcontractDrawRetainsItsSeparateTwoHundredRowMaximumAndLongOffset() {
        queries(0);
        var access = mock(SubcontractDocumentAccessPolicy.class);
        when(access.nativeReadScope("o.maker_id", "readOwners"))
                .thenReturn(new NativeReadScope("1=1", null, Set.of()));
        new SubcontractDrawQueryService(em, access).tasks(Integer.MAX_VALUE, Integer.MAX_VALUE,
                "", "ALL", null, List.of());
        verify(query).setParameter("pageLimit", 200);
        verify(query).setParameter("pageOffset", ((long) Integer.MAX_VALUE - 1) * 200);
    }
}

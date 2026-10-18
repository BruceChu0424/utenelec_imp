package com.uten.imp.features.sales.order;

import com.uten.imp.features.admin.workflow.SalesOrderFinanceConfirmerEligibility;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.springframework.test.util.ReflectionTestUtils;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;
import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class FinanceTaskAudienceCountTest {
    @Test void viewOnlyAndIneligibleFinanceReadersHaveNoPendingTask() {
        for (boolean confirm : new boolean[] {false, true}) {
            var em = mock(EntityManager.class);
            var eligibility = mock(SalesOrderFinanceConfirmerEligibility.class);
            var service = service(em, eligibility, confirm);
            assertThat(service.pendingCount(null)).containsEntry("count", 0L);
            verifyNoInteractions(em);
            if (!confirm) verifyNoInteractions(eligibility);
        }
    }

    @Test void eligibleConfirmerStillReceivesThePendingBusinessPool() {
        var em = mock(EntityManager.class);
        var eligibility = mock(SalesOrderFinanceConfirmerEligibility.class);
        when(eligibility.isEligible(any())).thenReturn(true);
        Query query = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.getSingleResult()).thenReturn(4L);
        assertThat(service(em, eligibility, true).pendingCount(null)).containsEntry("count", 4L);
    }

    private static SalesOrderFinanceConfirmService service(EntityManager em,
            SalesOrderFinanceConfirmerEligibility eligibility, boolean confirm) {
        var service = mock(SalesOrderFinanceConfirmService.class, CALLS_REAL_METHODS);
        var current = mock(SecurityContextCurrentUser.class);
        Set<String> permissions = confirm ? Set.of("sales_order_finance:view", "sales_order_finance:confirm")
                : Set.of("sales_order_finance:view");
        when(current.get()).thenReturn(Optional.of(new AuthUser(UUID.randomUUID(), UUID.randomUUID(),
                "finance", permissions, false, true, false)));
        ReflectionTestUtils.setField(service, "currentUser", current);
        ReflectionTestUtils.setField(service, "confirmerEligibility", eligibility);
        ReflectionTestUtils.setField(service, "em", em);
        return service;
    }
}

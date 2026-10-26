package com.uten.imp.features.production.schedule;

import com.uten.imp.common.web.TableFacets;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;

import java.util.Arrays;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class ProductionScheduleFacetBoundTest {
    @Test void boundsBillNumberChoicesWhileKeepingTheFullUrgencyTotals() {
        EntityManager em = mock(EntityManager.class);
        Query totals = mock(Query.class, RETURNS_SELF), bills = mock(Query.class, RETURNS_SELF);
        when(em.createNativeQuery(anyString())).thenReturn(totals, bills);
        when(totals.getSingleResult()).thenReturn(new Object[]{9000L, 5000L});
        when(bills.getMaxResults()).thenReturn(Integer.MAX_VALUE);
        when(bills.getResultList()).thenReturn(Arrays.asList(new Object[]{"SO0001", 12L}, new Object[]{"SO0002", 7L}));

        var result = new ProductionScheduleService(em, null, null).pendingFacets("", null, null);

        assertThat(result.get("status")).extracting(row -> row.get("count")).containsExactly(9000L, 5000L);
        assertThat(result.get("orderBillNo")).extracting(row -> row.get("value")).containsExactly("SO0001", "SO0002");
        assertThat(result.get("orderBillNo")).extracting(row -> row.get("count")).containsExactly(12L, 7L);
        var ordered = inOrder(bills);
        ordered.verify(bills).setMaxResults(TableFacets.DEFAULT_LIMIT);
        ordered.verify(bills).getResultList();
        verify(totals, never()).setMaxResults(anyInt());
    }
}

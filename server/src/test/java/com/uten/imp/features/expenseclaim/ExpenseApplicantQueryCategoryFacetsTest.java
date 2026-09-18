package com.uten.imp.features.expenseclaim;

import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * 报销 facets「类别」桶（2026-09-16）：expense_claim_items 按类别聚合、
 * DISTINCT claim_id 计单数（一单多类别在多桶各计一次），状态集走命名参数绑定。
 */
class ExpenseApplicantQueryCategoryFacetsTest {

    @Test
    @SuppressWarnings("unchecked")
    void categoryFacetsAggregateItemsByCategoryWithBoundStatuses() {
        EntityManager em = mock(EntityManager.class);
        Query query = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        when(query.getResultList()).thenReturn(List.of(
                new Object[]{"TRANSPORT", 3L}, new Object[]{"MEAL", 1L}));

        var rows = new ExpenseApplicantQuery(em).categoryFacets(List.of("SUBMITTED"));

        var sql = ArgumentCaptor.forClass(String.class);
        verify(em).createNativeQuery(sql.capture());
        assertThat(sql.getValue())
                .contains("FROM expense_claim_items i")
                .contains("JOIN expense_claims c ON c.id = i.claim_id")
                .contains("c.status IN (:statuses)")
                .contains("COUNT(DISTINCT i.claim_id)")
                .contains("GROUP BY i.category");
        verify(query).setParameter(eq("statuses"), any());

        assertThat(rows).hasSize(2);
        assertThat(rows.get(0).value()).isEqualTo("TRANSPORT");
        assertThat(rows.get(0).count()).isEqualTo(3L);
        assertThat(rows.get(1).value()).isEqualTo("MEAL");
    }

    @Test
    void emptyStatusesShortCircuitToNoBucket() {
        EntityManager em = mock(EntityManager.class);
        assertThat(new ExpenseApplicantQuery(em).categoryFacets(List.of())).isEmpty();
    }
}

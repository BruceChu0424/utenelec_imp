package com.uten.imp.audit;

import jakarta.persistence.EntityManager;
import jakarta.persistence.TypedQuery;
import jakarta.persistence.criteria.CriteriaBuilder;
import jakarta.persistence.criteria.CriteriaQuery;
import jakarta.persistence.criteria.Predicate;
import jakarta.persistence.criteria.Root;
import org.junit.jupiter.api.Test;
import org.mockito.Answers;
import org.springframework.data.jpa.domain.Specification;
import org.springframework.test.util.ReflectionTestUtils;

import java.time.LocalDate;
import java.util.List;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class AuditSummaryAggregationTest {

    @Test
    @SuppressWarnings("unchecked")
    void usesOneOverviewAggregateAndOneBeijingDayGroupQuery() {
        EntityManager entityManager = mock(EntityManager.class);
        CriteriaBuilder cb = mock(CriteriaBuilder.class, Answers.RETURNS_DEEP_STUBS);
        CriteriaQuery<Object[]> overviewCriteria = mock(
                CriteriaQuery.class, Answers.RETURNS_DEEP_STUBS);
        CriteriaQuery<Object[]> dailyCriteria = mock(
                CriteriaQuery.class, Answers.RETURNS_DEEP_STUBS);
        Root<AuditLog> overviewRoot = mock(Root.class, Answers.RETURNS_DEEP_STUBS);
        Root<AuditLog> dailyRoot = mock(Root.class, Answers.RETURNS_DEEP_STUBS);
        TypedQuery<Object[]> overviewQuery = mock(TypedQuery.class);
        TypedQuery<Object[]> dailyQuery = mock(TypedQuery.class);
        when(entityManager.getCriteriaBuilder()).thenReturn(cb);
        when(cb.createQuery(Object[].class)).thenReturn(overviewCriteria, dailyCriteria);
        when(overviewCriteria.from(AuditLog.class)).thenReturn(overviewRoot);
        when(dailyCriteria.from(AuditLog.class)).thenReturn(dailyRoot);
        when(entityManager.createQuery(overviewCriteria)).thenReturn(overviewQuery);
        when(entityManager.createQuery(dailyCriteria)).thenReturn(dailyQuery);
        when(overviewQuery.getSingleResult()).thenReturn(new Object[]{10L, 2L, 1L, 3L, 4L});
        when(dailyQuery.getResultList()).thenReturn(List.of(
                new Object[]{LocalDate.parse("2026-08-01"), 4L, 1L},
                new Object[]{LocalDate.parse("2026-08-03"), 6L, 1L}));
        Specification<AuditLog> specification = mock(Specification.class);
        when(specification.toPredicate(any(), any(), any()))
                .thenReturn(mock(Predicate.class));
        AuditSummaryAggregation aggregation = new AuditSummaryAggregation();
        ReflectionTestUtils.setField(aggregation, "entityManager", entityManager);

        AuditSummary result = aggregation.summarize(
                specification, specification, specification, specification, specification,
                LocalDate.parse("2026-08-01"), LocalDate.parse("2026-08-03"));

        assertEquals(10, result.total());
        assertEquals(4, result.dataChangeCount());
        assertEquals(3, result.dailyTrend().size());
        assertEquals(0, result.dailyTrend().get(1).total());
        verify(entityManager, times(2)).createQuery(any(CriteriaQuery.class));
    }
}

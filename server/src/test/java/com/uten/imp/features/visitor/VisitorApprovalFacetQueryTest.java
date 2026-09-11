package com.uten.imp.features.visitor;

import com.uten.imp.features.visitor.dto.VisitorApplyDto.VisitorApprovalFacets;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

import java.util.Collection;
import java.util.List;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/** HR 访客审批列表表头筛选桶（2026-09-10）：默认状态集、桶映射与参数化。 */
class VisitorApprovalFacetQueryTest {

    @Test
    void blankStatusAggregatesThePendingWorkQueueStatusSet() {
        EntityManager entityManager = mock(EntityManager.class);
        Query statuses = mock(Query.class);
        Query departments = mock(Query.class);
        when(entityManager.createNativeQuery(anyString())).thenReturn(statuses, departments);
        when(statuses.setParameter(anyString(), any())).thenReturn(statuses);
        when(departments.setParameter(anyString(), any())).thenReturn(departments);
        UUID departmentId = UUID.randomUUID();
        when(statuses.getResultList()).thenReturn(List.<Object[]>of(
                new Object[]{"hostReviewing", 2L},
                new Object[]{"pending", 5L}));
        // 注意 varargs 陷阱：List.of(new Object[]{a,b,c}) 会把数组摊成三个元素，
        // 必须显式类型见证 List.<Object[]>of(...) 才是「一行三列」。
        when(departments.getResultList()).thenReturn(List.<Object[]>of(
                new Object[]{departmentId, "研发部", 4L}));

        VisitorApprovalFacets facets = new VisitorApprovalFacetQuery(entityManager).facets("  ");

        assertEquals(2, facets.statuses().size());
        assertEquals("hostReviewing", facets.statuses().get(0).value());
        assertEquals("hostReviewing", facets.statuses().get(0).label());
        assertEquals(2L, facets.statuses().get(0).count());
        assertEquals(1, facets.departments().size());
        assertEquals(departmentId.toString(), facets.departments().get(0).value());
        assertEquals("研发部", facets.departments().get(0).label());
        assertEquals(4L, facets.departments().get(0).count());

        // 空状态 = 待办状态集（与 listForApproval 默认口径一致）
        ArgumentCaptor<Object> captor = ArgumentCaptor.forClass(Object.class);
        verify(statuses).setParameter(eq("statuses"), captor.capture());
        assertEquals(Set.of("pending", "hostReviewing"),
                Set.copyOf((Collection<?>) captor.getValue()));

        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verify(entityManager, times(2)).createNativeQuery(sql.capture());
        String combined = String.join(" ", sql.getAllValues()).toLowerCase();
        assertTrue(combined.contains("is_deleted = false"), "软删行不进桶");
        assertTrue(combined.contains(":statuses"), "状态集必须参数化，不拼字符串");
        assertTrue(combined.contains("join departments d"), "部门名来自 departments 表");
    }

    @Test
    void explicitStatusNarrowsBothBucketsToThatStatus() {
        EntityManager entityManager = mock(EntityManager.class);
        Query statuses = mock(Query.class);
        Query departments = mock(Query.class);
        when(entityManager.createNativeQuery(anyString())).thenReturn(statuses, departments);
        when(statuses.setParameter(anyString(), any())).thenReturn(statuses);
        when(departments.setParameter(anyString(), any())).thenReturn(departments);
        when(statuses.getResultList())
                .thenReturn(List.<Object[]>of(new Object[]{"approved", 9L}));
        when(departments.getResultList()).thenReturn(List.of());

        VisitorApprovalFacets facets =
                new VisitorApprovalFacetQuery(entityManager).facets(" approved ");

        assertEquals(1, facets.statuses().size());
        assertEquals(9L, facets.statuses().get(0).count());
        assertTrue(facets.departments().isEmpty());

        ArgumentCaptor<Object> statusCaptor = ArgumentCaptor.forClass(Object.class);
        verify(statuses).setParameter(eq("statuses"), statusCaptor.capture());
        assertEquals(Set.of("approved"), Set.copyOf((Collection<?>) statusCaptor.getValue()));

        ArgumentCaptor<Object> deptCaptor = ArgumentCaptor.forClass(Object.class);
        verify(departments).setParameter(eq("statuses"), deptCaptor.capture());
        assertEquals(Set.of("approved"), Set.copyOf((Collection<?>) deptCaptor.getValue()));
    }
}

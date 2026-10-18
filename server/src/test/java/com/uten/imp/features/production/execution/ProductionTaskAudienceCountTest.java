package com.uten.imp.features.production.execution;

import com.uten.imp.features.production.ProductionDocumentAccessPolicy;
import com.uten.imp.features.production.ProductionWorkshopMembership;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.OwnerVisibility;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.springframework.test.util.ReflectionTestUtils;
import java.util.*;
import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class ProductionTaskAudienceCountTest {
    @Test void readOnlyPlannerDoesNotReceiveInProgressResponsibility() {
        var em = mock(EntityManager.class);
        var service = service(em, Set.of("production_execution:overview"), UUID.randomUUID());
        assertThat(service.inProgressRootCount()).isZero();
        verifyNoInteractions(em);
    }

    @Test void planningProgressExcludesManuallyObservedAndOwnerlessRoots() {
        UUID self = UUID.randomUUID();
        var em = mock(EntityManager.class);
        Query query = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        when(query.getSingleResult()).thenReturn(2L);
        var service = service(em, Set.of("production_execution:overview", "production_plan:edit"), self);
        assertThat(service.inProgressRootCount()).isEqualTo(2);
        verify(query).setParameter("rootOwners", Set.of(self));
        verify(em).createNativeQuery(argThat(sql -> sql.contains("root.owner_employee_id IS NOT NULL")
                && sql.contains("root.owner_employee_id IN (:rootOwners)")));
    }

    @Test void workshopBucketsUseTheRelevantActionsAndKeepAssignmentScope() {
        for (boolean start : new boolean[] {false, true}) {
            UUID self = UUID.randomUUID();
            var em = mock(EntityManager.class);
            Query query = mock(Query.class);
            Map<String, Object> params = new HashMap<>();
            var sqlText = new java.util.concurrent.atomic.AtomicReference<String>();
            when(em.createNativeQuery(anyString())).thenAnswer(call -> {
                sqlText.set(call.getArgument(0)); return query;
            });
            when(query.setParameter(anyString(), any())).thenAnswer(call -> {
                assertThat(sqlText.get()).contains(":" + call.<String>getArgument(0));
                params.put(call.getArgument(0), call.getArgument(1)); return query;
            });
            when(query.getResultList()).thenAnswer(call -> Collections.singletonList(new Object[] {
                    99L, Boolean.TRUE.equals(params.get("countPreparing")) ? 2L : 0L, 3L, 1L}));
            Set<String> permissions = new HashSet<>(Set.of("production_execution:view",
                    "production_daily_report:view", "production_daily_report:create"));
            if (start) permissions.add("production_execution:start");
            var counts = service(em, permissions, self).workshopTaskCountBreakdown();
            assertThat(counts.preparing()).isEqualTo(start ? 2 : 0);
            assertThat(counts.inProgress()).isEqualTo(3);
            assertThat(counts.reportInspection()).isEqualTo(1);
            assertThat(counts.total()).isEqualTo(start ? 6 : 4);
            assertThat(params).containsEntry("employeeId", self).containsEntry("countPreparing", start);
            verify(em).createNativeQuery(argThat(sql -> sql.contains("task.responsible_employee_id=employee.id")
                    && sql.contains("employee.id=:employeeId")));
        }
    }

    @Test void reportActionWithoutItsPageReadDoesNotSubscribeToWorkshopTasks() {
        var em = mock(EntityManager.class);
        var service = service(em, Set.of("production_execution:view", "production_daily_report:create"), UUID.randomUUID());
        assertThat(service.workshopTaskCountBreakdown().total()).isZero();
        verifyNoInteractions(em);
    }

    private static ProductionExecutionWorkbenchService service(EntityManager em, Set<String> permissions, UUID self) {
        var current = mock(SecurityContextCurrentUser.class);
        when(current.get()).thenReturn(Optional.of(new AuthUser(UUID.randomUUID(), self, "planner", permissions,
                false, true, false)));
        when(current.employeeId()).thenReturn(Optional.of(self));
        var owners = mock(OwnerVisibility.class);
        when(owners.evaluate(anyString(), anyString())).thenReturn(new OwnerVisibility.OwnerScope(
                false, Set.of(self, UUID.randomUUID()), Set.of(self)));
        var membership = mock(ProductionWorkshopMembership.class);
        when(membership.isActiveOperator()).thenReturn(true);
        var service = mock(ProductionExecutionWorkbenchService.class, CALLS_REAL_METHODS);
        ReflectionTestUtils.setField(service, "em", em);
        ReflectionTestUtils.setField(service, "productionAccess", new ProductionDocumentAccessPolicy(owners, current));
        ReflectionTestUtils.setField(service, "currentUser", current);
        ReflectionTestUtils.setField(service, "workshopMembership", membership);
        return service;
    }
}

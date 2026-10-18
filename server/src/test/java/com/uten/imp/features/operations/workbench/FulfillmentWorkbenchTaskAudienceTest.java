package com.uten.imp.features.operations.workbench;

import com.uten.imp.application.port.WarehouseTaskScopePort.WarehouseTaskScope;
import com.uten.imp.security.BusinessTaskRead;
import com.uten.imp.security.DocumentAccessPolicy.NativeReadScope;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

import java.util.List;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.*;

class FulfillmentWorkbenchTaskAudienceTest {
    @Test
    void readOnlyAccountsDoNotQueryPendingOrRunningTasksInEitherModule() {
        var em = mock(EntityManager.class);
        var access = mock(FulfillmentWorkbenchAccessPolicy.class);
        when(access.documentAccess(anyString(), anyString()))
                .thenReturn(new FulfillmentWorkbenchAccessPolicy.DocumentAccess(true, false));
        var service = new FulfillmentWorkbenchQueryService(em, access);
        for (String department : List.of("PURCHASE", "SUBCONTRACT")) {
            assertEquals(0, service.countPending(department));
            assertEquals(0, service.countInProgress(department));
        }
        verifyNoInteractions(em);
    }

    @Test
    void decisionOnlyRoleHasAValidSqlBranchAndTheSameCaseOwnerScopeAsDeciding() {
        var em = mock(EntityManager.class);
        var query = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.getSingleResult()).thenReturn(new Object[]{2L, 0L, 0L, 2L});
        var access = mock(FulfillmentWorkbenchAccessPolicy.class);
        UUID owner = UUID.randomUUID();
        when(access.canDecideSubcontractShortDelivery()).thenReturn(true);
        when(access.orderTaskScope("SUBCONTRACT", "short_case.owner_employee_id", "task_case_owners"))
                .thenReturn(new NativeReadScope("short_case.owner_employee_id IN (:task_case_owners)",
                        "task_case_owners", Set.of(owner)));

        var counts = new FulfillmentWorkbenchQueryService(em, access)
                .pendingTaskCounts("SUBCONTRACT", WarehouseTaskScope.ALL);

        assertEquals(new FulfillmentWorkbenchQueryService.PendingTaskCounts(2, 0, 0, 2), counts);
        var sql = ArgumentCaptor.forClass(String.class);
        verify(em).createNativeQuery(sql.capture());
        assertFalse(sql.getValue().contains("IN ()"));
        assertTrue(sql.getValue().contains("short_case.owner_employee_id IN (:task_case_owners)"));
        assertFalse(sql.getValue().contains("fn_subcontract_draw_edges"));
        assertFalse(sql.getValue().contains("FROM subcontract_orders task_order"));
        verify(query).setParameter("task_case_owners", Set.of(owner));
    }

    @Test
    void orderReworkAndRunningTasksShareTheCurrentOrderResponsibilityScope() {
        for (String department : List.of("PURCHASE", "SUBCONTRACT")) {
            var em = mock(EntityManager.class);
            var query = mock(Query.class);
            when(em.createNativeQuery(anyString())).thenReturn(query);
            when(query.getSingleResult()).thenReturn(new Object[]{1L, 0L, 1L, 0L}, 3L);
            var access = mock(FulfillmentWorkbenchAccessPolicy.class);
            UUID owner = UUID.randomUUID();
            when(access.documentAccess(department, "ORDER"))
                    .thenReturn(new FulfillmentWorkbenchAccessPolicy.DocumentAccess(true, true));
            when(access.orderTaskScope(department, "task_order.maker_id", "task_order_owners"))
                    .thenReturn(new NativeReadScope("task_order.maker_id IN (:task_order_owners)",
                            "task_order_owners", Set.of(owner)));
            var service = new FulfillmentWorkbenchQueryService(em, access);

            assertEquals(1, service.countPending(department));
            assertEquals(3, service.countInProgress(department));

            var sql = ArgumentCaptor.forClass(String.class);
            verify(em, times(2)).createNativeQuery(sql.capture());
            for (String statement : sql.getAllValues()) {
                assertTrue(statement.contains("task_order.maker_id IN (:task_order_owners)"));
                assertTrue(statement.contains("AND NOT task_order.is_deleted"));
            }
            verify(query, times(2)).setParameter("task_order_owners", Set.of(owner));
        }
    }

    @Test
    void publicRequestsNeedNoExistingOrderScopeAndRequireTheFullCreateCapability() {
        var em = mock(EntityManager.class);
        var query = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.getSingleResult()).thenReturn(new Object[]{4L, 4L, 0L, 0L});
        var access = mock(FulfillmentWorkbenchAccessPolicy.class);
        when(access.canCreateSubcontractOrder()).thenReturn(true);
        var counts = new FulfillmentWorkbenchQueryService(em, access)
                .pendingTaskCounts("SUBCONTRACT", WarehouseTaskScope.ALL);
        assertEquals(4, counts.waitingOrder());
        verify(access, never()).orderTaskScope(anyString(), anyString(), anyString());
    }

    @Test
    void taskEndpointsUseTheBusinessAudienceWhileBrowsingRetainsItsOwnAuthority() throws Exception {
        assertNotNull(FulfillmentWorkbenchController.class.getMethod("purchaseCount").getAnnotation(BusinessTaskRead.class));
        assertNotNull(FulfillmentWorkbenchController.class.getMethod("subcontractCount").getAnnotation(BusinessTaskRead.class));
        assertTrue(java.util.Arrays.stream(FulfillmentWorkbenchController.class.getMethods())
                .filter(method -> Set.of("purchase", "subcontract").contains(method.getName()))
                .noneMatch(method -> method.isAnnotationPresent(BusinessTaskRead.class)));
    }
}

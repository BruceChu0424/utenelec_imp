package com.uten.imp.features.operations.workbench;

import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.security.access.prepost.PreAuthorize;

import java.lang.reflect.Method;
import java.math.BigDecimal;
import java.util.Collections;
import java.util.List;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class FulfillmentWorkbenchQueryServiceTest {

    @Test
    void exceptionFilterAndOptionsAreEvaluatedByTheDatabaseNotTheCurrentPage() {
        EntityManager em = mock(EntityManager.class);
        Query rows = mock(Query.class);
        Query summary = mock(Query.class);
        Query statuses = mock(Query.class);
        Query exceptions = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(rows, summary, statuses, exceptions);
        when(rows.getResultList()).thenReturn(List.of());
        when(summary.getSingleResult()).thenReturn(new Object[]{
                5L, 2L, 4L, new BigDecimal("12")
        });
        when(statuses.getResultList()).thenReturn(
                Collections.singletonList(new Object[]{"UNPEGGED", 3L}));
        when(exceptions.getResultList()).thenReturn(
                Collections.singletonList(new Object[]{"OVERDUE_SHORTAGE", 2L}));

        FulfillmentWorkbenchPage result = new FulfillmentWorkbenchQueryService(em)
                .query("PURCHASE", "UNPEGGED", "轴套", "OVERDUE_ANY", 2, 20);

        verify(rows).setParameter("exception", "OVERDUE_ANY");
        verify(summary).setParameter("exception", "OVERDUE_ANY");
        verify(statuses).setParameter("exception", "OVERDUE_ANY");
        verify(exceptions).setParameter("exception", "");
        assertEquals(2L, result.summary().exceptionCounts().get("OVERDUE_SHORTAGE"));

        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verify(em, times(4)).createNativeQuery(sql.capture());
        assertTrue(sql.getAllValues().getFirst().contains("OVERDUE_ANY"));
        assertTrue(sql.getAllValues().getLast().contains("exception_code IS NOT NULL"));
    }

    @Test
    void countPendingCountsUnpeggedAndWaitingSupplyTasks() {
        EntityManager em = mock(EntityManager.class);
        Query countQuery = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(countQuery);
        when(countQuery.getSingleResult()).thenReturn(7L);

        long count = new FulfillmentWorkbenchQueryService(em).countPending("PURCHASE");

        assertEquals(7L, count);
        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verify(em).createNativeQuery(sql.capture());
        String captured = sql.getValue();
        assertTrue(captured.contains("v_fulfillment_workbench_actions"));
        assertTrue(captured.contains("'UNPEGGED'"));
        assertTrue(captured.contains("'WAITING_SUPPLY'"));
        verify(countQuery).setParameter("department", "PURCHASE");
    }

    @Test
    void purchaseCountEndpointGuardsPurchaseReadPermissions() throws Exception {
        Method method = FulfillmentWorkbenchController.class.getDeclaredMethod("purchaseCount");
        assertEquals(
                "hasAnyAuthority('purchase_request:view','purchase_order:view','purchase_receipt:view','purchase_return:view')",
                method.getAnnotation(PreAuthorize.class).value());
    }

    @Test
    void controllerReadPermissionsMatchFlutterAnyPermissionGuards() throws Exception {
        assertPermission(
                "warehouse",
                "hasAnyAuthority('stock_doc:view')");
        assertPermission(
                "purchase",
                "hasAnyAuthority('purchase_request:view','purchase_order:view','purchase_receipt:view','purchase_return:view')");
        assertPermission(
                "subcontract",
                "hasAnyAuthority('subcontract_inquiry:view','subcontract_application:view','subcontract_order:view','subcontract_receipt:view','subcontract_material_issue:view','subcontract_return:view','subcontract_material_return:view','subcontract_waste:view')");
    }

    private static void assertPermission(String methodName, String expected) throws Exception {
        Method method = FulfillmentWorkbenchController.class.getDeclaredMethod(
                methodName, String.class, String.class, String.class, int.class, int.class);
        assertEquals(expected, method.getAnnotation(PreAuthorize.class).value());
    }
}

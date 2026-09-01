package com.uten.imp.features.warehouse.finishedin;

import com.uten.imp.security.ProductionStockTaskAccessPolicy;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.Collections;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

class ProductionFinishedInboundTaskServiceTest {

    @Test
    void nonWarehouseActorGetsSafeEmptyProjection() {
        EntityManager em = mock(EntityManager.class);
        ProductionStockTaskAccessPolicy access =
                mock(ProductionStockTaskAccessPolicy.class);
        when(access.canAccessWarehouseTasks()).thenReturn(false);
        ProductionFinishedInboundTaskService service =
                new ProductionFinishedInboundTaskService(em, access);

        assertEquals(0, service.countPending());
        assertTrue(service.list("", 1, 40).getItems().isEmpty());
        verifyNoInteractions(em);
    }

    @Test
    void queueMapsProductionDraftAndResidualEvidence() {
        EntityManager em = mock(EntityManager.class);
        ProductionStockTaskAccessPolicy access =
                mock(ProductionStockTaskAccessPolicy.class);
        when(access.canAccessWarehouseTasks()).thenReturn(true);
        Query count = query();
        when(count.getSingleResult()).thenReturn(1L);
        Query rows = query();
        UUID documentId = UUID.randomUUID();
        UUID reportId = UUID.randomUUID();
        when(rows.getResultList()).thenReturn(
                Collections.singletonList(new Object[]{
                        "FINAL_COUNT",
                        documentId,
                        reportId,
                        documentId,
                        "CPRK202608280001",
                        LocalDate.of(2026, 8, 28),
                        UUID.randomUUID(),
                        "半成品仓",
                        UUID.randomUUID(),
                        "SJ202608280001",
                        "RB202608280001",
                        "V5多功能三极插座E极插套(酸洗)",
                        1,
                        new BigDecimal("1000.0000"),
                        OffsetDateTime.parse(
                                "2026-08-28T05:00:00Z"),
                        true
                }));
        when(em.createNativeQuery(anyString())).thenReturn(count, rows);
        ProductionFinishedInboundTaskService service =
                new ProductionFinishedInboundTaskService(em, access);

        var page = service.list("V51043", 1, 40);

        assertEquals(1, page.getTotal());
        assertEquals("FINAL_COUNT", page.getItems().getFirst().taskStage());
        assertEquals(documentId, page.getItems().getFirst().taskId());
        assertEquals(reportId, page.getItems().getFirst().reportId());
        assertEquals(documentId, page.getItems().getFirst().documentId());
        assertEquals(
                new BigDecimal("1000.0000"),
                page.getItems().getFirst().pendingQty());
        assertTrue(page.getItems().getFirst().residualTask());

        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verify(em, org.mockito.Mockito.times(2))
                .createNativeQuery(sql.capture());
        assertTrue(sql.getAllValues().stream().allMatch(
                value -> value.contains(
                        "document.doc_type = 'FINISHED_IN'")
                        && value.contains("document.status = 0")
                        && value.contains("'ARRIVAL_REGISTRATION'::text")
                        && value.contains(
                        "production_finished_arrival_registrations")
                        && value.contains(
                        "source_daily_report_item_id IS NOT NULL")));
    }

    @Test
    void queueMapsArrivalRegistrationWithNullableDocumentAndWarehouse() {
        EntityManager em = mock(EntityManager.class);
        ProductionStockTaskAccessPolicy access =
                mock(ProductionStockTaskAccessPolicy.class);
        when(access.canAccessWarehouseTasks()).thenReturn(true);
        Query count = query();
        when(count.getSingleResult()).thenReturn(1L);
        Query rows = query();
        UUID reportId = UUID.randomUUID();
        UUID planId = UUID.randomUUID();
        when(rows.getResultList()).thenReturn(
                Collections.singletonList(new Object[]{
                        "ARRIVAL_REGISTRATION",
                        reportId,
                        reportId,
                        null,
                        null,
                        LocalDate.of(2026, 8, 30),
                        null,
                        null,
                        planId,
                        "SJ202608300001",
                        "RB202608300001",
                        "V5多功能三极插座E极插套(酸洗)",
                        1,
                        new BigDecimal("10000.0000"),
                        OffsetDateTime.parse("2026-08-30T05:00:00Z"),
                        false
                }));
        when(em.createNativeQuery(anyString())).thenReturn(count, rows);
        ProductionFinishedInboundTaskService service =
                new ProductionFinishedInboundTaskService(em, access);

        var task = service.list("RB202608300001", 1, 40)
                .getItems().getFirst();

        assertEquals("ARRIVAL_REGISTRATION", task.taskStage());
        assertEquals(reportId, task.taskId());
        assertEquals(reportId, task.reportId());
        assertEquals(null, task.documentId());
        assertEquals(null, task.documentNo());
        assertEquals(null, task.warehouseId());
        assertEquals(planId, task.planId());
        assertEquals(new BigDecimal("10000.0000"), task.pendingQty());
    }

    private static Query query() {
        Query query = mock(Query.class);
        when(query.setParameter(anyString(), any()))
                .thenReturn(query);
        return query;
    }
}

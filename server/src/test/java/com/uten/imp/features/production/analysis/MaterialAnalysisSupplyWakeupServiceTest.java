package com.uten.imp.features.production.analysis;

import com.uten.imp.application.port.BusinessEventPublisher;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.mockito.stubbing.OngoingStubbing;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

class MaterialAnalysisSupplyWakeupServiceTest {

    @Test
    void unexpectedCallbackSourceStopsBeforeAnalysisWritesOrNotifications() {
        EntityManager em = mock(EntityManager.class);
        MaterialAnalysisService analysis = mock(MaterialAnalysisService.class);
        BusinessEventPublisher events = mock(BusinessEventPublisher.class);
        var locks = com.uten.imp.support.FulfillmentMutationLockTestSupport.locks();
        var footprints = mock(com.uten.imp.application.port.ProductionMutationFootprintPort.class);
        UUID target = UUID.randomUUID();
        var needed = new com.uten.imp.application.concurrency.FulfillmentMutationLockPlan(
                java.util.Set.of(),java.util.Set.of(),java.util.Set.of(),java.util.Set.of(target),"callback-target");
        when(footprints.forAnalyses(List.of(target))).thenReturn(needed);
        doThrow(new com.uten.imp.common.web.ApiException(
                com.uten.imp.common.web.ErrorCode.CONFLICT,"source changed"))
                .when(locks).requireCovered(needed);
        routeQueries(em,query(List.<Object[]>of(new Object[]{target,UUID.randomUUID()})),query(List.of()));
        var service = new MaterialAnalysisSupplyWakeupService(em,analysis,events,locks,footprints);

        assertThrows(com.uten.imp.common.web.ApiException.class,
                () -> service.afterPurchaseReceiptApproved(UUID.randomUUID()));

        verify(footprints).forAnalyses(List.of(target));
        verify(locks).requireCovered(needed);
        verifyNoInteractions(analysis,events);
    }

    @Test
    void qualifiedPurchaseRefreshPublishesOnlyTheRealFinishIncreaseAndStableDedupe() {
        EntityManager em = mock(EntityManager.class);
        MaterialAnalysisService analysis = mock(MaterialAnalysisService.class);
        BusinessEventPublisher events = mock(BusinessEventPublisher.class);
        UUID analysisId = UUID.randomUUID();
        UUID makerId = UUID.randomUUID();
        UUID receiptId = UUID.randomUUID();
        UUID firstItem = UUID.randomUUID();
        UUID secondItem = UUID.randomUUID();
        Query candidates = query(List.<Object[]>of(new Object[]{analysisId, makerId}));
        Query readiness = querySequence(
                List.<Object[]>of(
                        new Object[]{firstItem, new BigDecimal("2")},
                        new Object[]{secondItem, new BigDecimal("1")}),
                List.<Object[]>of(
                        new Object[]{firstItem, new BigDecimal("5")},
                        new Object[]{secondItem, new BigDecimal("2")}));
        List<String> statements = routeQueries(em, candidates, readiness);
        MaterialAnalysisSupplyWakeupService service =
                new MaterialAnalysisSupplyWakeupService(em, analysis, events,
                com.uten.imp.support.FulfillmentMutationLockTestSupport.locks(),
                org.mockito.Mockito.mock(com.uten.imp.application.port.ProductionMutationFootprintPort.class));

        service.afterPurchaseReceiptApproved(receiptId);

        verify(analysis).refreshLocked(analysisId);
        verify(events).publishOnce(
                MaterialAnalysisSupplyWakeupService.EVENT_READY,
                MaterialAnalysisSupplyWakeupService.AGGREGATE_TYPE,
                analysisId,
                Map.of(
                        "makerEmployeeId", makerId.toString(),
                        "sourceType", "PURCHASE",
                        "sourceDocumentId", receiptId.toString(),
                        "sourceDocumentNo", "CJ26080001",
                        "analysisItemId", firstItem.toString(),
                        "readyFinishDelta", "3",
                        "readyFinishQty", "5"),
                MaterialAnalysisSupplyWakeupService.EVENT_READY + ':' + analysisId
                        + ':' + firstItem + ":PURCHASE:" + receiptId);
        verify(events).publishOnce(
                MaterialAnalysisSupplyWakeupService.EVENT_READY,
                MaterialAnalysisSupplyWakeupService.AGGREGATE_TYPE,
                analysisId,
                Map.of(
                        "makerEmployeeId", makerId.toString(),
                        "sourceType", "PURCHASE",
                        "sourceDocumentId", receiptId.toString(),
                        "sourceDocumentNo", "CJ26080001",
                        "analysisItemId", secondItem.toString(),
                        "readyFinishDelta", "1",
                        "readyFinishQty", "2"),
                MaterialAnalysisSupplyWakeupService.EVENT_READY + ':' + analysisId
                        + ':' + secondItem + ":PURCHASE:" + receiptId);
        assertThat(statements.getFirst())
                .contains("inspection.status = 'RESOLVED'")
                .contains("receipt.status = 1")
                .contains("analysis.status IN ('ACTIVE','PARTIALLY_PLANNED')")
                .contains("material.active = TRUE")
                .contains("dimension.color_id")
                .contains("IS NOT DISTINCT FROM material.color_id")
                .contains("ORDER BY analysis.id")
                .doesNotContain("FOR UPDATE")
                .doesNotContain("material.unit_id =");
        verify(candidates).setParameter("includeLegacyFallback", false);
    }

    @Test
    void partialWarehouseStockInRefreshesOncePerConfirmedBatchWithStableEventLineage() {
        EntityManager em = mock(EntityManager.class);
        MaterialAnalysisService analysis = mock(MaterialAnalysisService.class);
        BusinessEventPublisher events = mock(BusinessEventPublisher.class);
        UUID analysisId = UUID.randomUUID();
        UUID makerId = UUID.randomUUID();
        UUID receiptId = UUID.randomUUID();
        UUID inspectionItemId = UUID.randomUUID();
        UUID firstBatchId = UUID.randomUUID();
        UUID analysisItemId = UUID.randomUUID();
        Query candidates = query(List.<Object[]>of(
                new Object[]{analysisId, makerId}));
        Query readiness = querySequence(
                List.<Object[]>of(new Object[]{analysisItemId, BigDecimal.ZERO}),
                List.<Object[]>of(new Object[]{analysisItemId, new BigDecimal("5")}),
                List.<Object[]>of(new Object[]{analysisItemId, new BigDecimal("5")}),
                List.<Object[]>of(new Object[]{analysisItemId, new BigDecimal("5")}));
        List<String> statements = routeQueries(em, candidates, readiness);
        MaterialAnalysisSupplyWakeupService service =
                new MaterialAnalysisSupplyWakeupService(em, analysis, events,
                com.uten.imp.support.FulfillmentMutationLockTestSupport.locks(),
                org.mockito.Mockito.mock(com.uten.imp.application.port.ProductionMutationFootprintPort.class));

        service.afterInspectionStockInConfirmed(
                "PURCHASE", receiptId, firstBatchId, List.of(inspectionItemId));
        service.afterInspectionStockInConfirmed(
                "PURCHASE", receiptId, UUID.randomUUID(), List.of(inspectionItemId));

        verify(analysis, times(2)).refreshLocked(analysisId);
        verify(events).publishOnce(
                MaterialAnalysisSupplyWakeupService.EVENT_READY,
                MaterialAnalysisSupplyWakeupService.AGGREGATE_TYPE,
                analysisId,
                Map.of(
                        "makerEmployeeId", makerId.toString(),
                        "sourceType", "PURCHASE",
                        "sourceDocumentId", receiptId.toString(),
                        "sourceDocumentNo", "CJ26080001",
                        "sourceEventId", firstBatchId.toString(),
                        "analysisItemId", analysisItemId.toString(),
                        "readyFinishDelta", "5",
                        "readyFinishQty", "5"),
                MaterialAnalysisSupplyWakeupService.EVENT_READY + ':' + analysisId
                        + ':' + analysisItemId + ":PURCHASE:" + receiptId
                        + ":IQC_STOCK_IN:" + firstBatchId);
        assertThat(statements.getFirst())
                .contains("inspection.id IN (:inspectionItemIds)")
                .contains("inspection.receipt_type = :sourceType")
                .contains("inspection.status IN ('PARTIAL', 'RESOLVED')")
                .contains("inspection.warehouse_stocked_base_qty > 0")
                .contains("receipt.status = 1")
                .contains("ORDER BY analysis.id")
                .doesNotContain("FOR UPDATE");
        verify(candidates, times(2)).setParameter(
                "inspectionItemIds", List.of(inspectionItemId));
        verify(candidates, times(2)).setParameter("sourceType", "PURCHASE");
    }

    @Test
    void partialSubcontractWarehouseStockInUsesTheApprovedReceiptDimension() {
        EntityManager em = mock(EntityManager.class);
        MaterialAnalysisService analysis = mock(MaterialAnalysisService.class);
        BusinessEventPublisher events = mock(BusinessEventPublisher.class);
        UUID receiptId = UUID.randomUUID();
        UUID inspectionItemId = UUID.randomUUID();
        Query candidates = query(List.of());
        List<String> statements = routeQueries(
                em, candidates, querySequence(List.of(), List.of()));
        MaterialAnalysisSupplyWakeupService service =
                new MaterialAnalysisSupplyWakeupService(em, analysis, events,
                com.uten.imp.support.FulfillmentMutationLockTestSupport.locks(),
                org.mockito.Mockito.mock(com.uten.imp.application.port.ProductionMutationFootprintPort.class));

        service.afterInspectionStockInConfirmed(
                "SUBCONTRACT", receiptId, UUID.randomUUID(),
                List.of(inspectionItemId));

        assertThat(statements.getFirst())
                .contains(":sourceType = 'SUBCONTRACT'")
                .contains("FROM subcontract_receipts receipt")
                .contains("receipt.status = 1");
        verify(candidates).setParameter("sourceType", "SUBCONTRACT");
        verifyNoInteractions(analysis, events);
    }

    @Test
    void lineReallocationWithoutTotalIncreaseDoesNotPublishReadyEvent() {
        EntityManager em = mock(EntityManager.class);
        MaterialAnalysisService analysis = mock(MaterialAnalysisService.class);
        BusinessEventPublisher events = mock(BusinessEventPublisher.class);
        UUID analysisId = UUID.randomUUID();
        UUID firstItem = UUID.randomUUID();
        UUID secondItem = UUID.randomUUID();
        Query candidates = query(List.<Object[]>of(
                new Object[]{analysisId, UUID.randomUUID()}));
        Query readiness = querySequence(
                List.<Object[]>of(
                        new Object[]{firstItem, new BigDecimal("5")},
                        new Object[]{secondItem, new BigDecimal("5")}),
                List.<Object[]>of(
                        new Object[]{firstItem, new BigDecimal("6")},
                        new Object[]{secondItem, new BigDecimal("3")}));
        routeQueries(em, candidates, readiness);
        MaterialAnalysisSupplyWakeupService service =
                new MaterialAnalysisSupplyWakeupService(em, analysis, events,
                com.uten.imp.support.FulfillmentMutationLockTestSupport.locks(),
                org.mockito.Mockito.mock(com.uten.imp.application.port.ProductionMutationFootprintPort.class));

        service.afterPurchaseReceiptApproved(UUID.randomUUID());

        verify(analysis).refreshLocked(analysisId);
        verifyNoInteractions(events);
    }

    @Test
    void fullyRejectedReceiptStillRefreshesShortageWithoutReadyNotice() {
        EntityManager em = mock(EntityManager.class);
        MaterialAnalysisService analysis = mock(MaterialAnalysisService.class);
        BusinessEventPublisher events = mock(BusinessEventPublisher.class);
        UUID analysisId = UUID.randomUUID();
        UUID itemId = UUID.randomUUID();
        Query candidates = query(List.<Object[]>of(
                new Object[]{analysisId, UUID.randomUUID()}));
        Query readiness = querySequence(
                List.<Object[]>of(new Object[]{itemId, BigDecimal.ZERO}),
                List.<Object[]>of(new Object[]{itemId, BigDecimal.ZERO}));
        List<String> statements = routeQueries(em, candidates, readiness);
        MaterialAnalysisSupplyWakeupService service =
                new MaterialAnalysisSupplyWakeupService(em, analysis, events,
                com.uten.imp.support.FulfillmentMutationLockTestSupport.locks(),
                org.mockito.Mockito.mock(com.uten.imp.application.port.ProductionMutationFootprintPort.class));

        service.afterSubcontractReceiptApproved(UUID.randomUUID());

        verify(analysis).refreshLocked(analysisId);
        assertThat(statements.getFirst())
                .contains("inspection.status = 'RESOLVED'")
                .doesNotContain("passed_base_qty > 0");
        verifyNoInteractions(events);
    }

    @Test
    void reversalRefreshesAfterLegacyFallbackButNeverPublishesIncrease() {
        EntityManager em = mock(EntityManager.class);
        MaterialAnalysisService analysis = mock(MaterialAnalysisService.class);
        BusinessEventPublisher events = mock(BusinessEventPublisher.class);
        UUID analysisId = UUID.randomUUID();
        UUID itemId = UUID.randomUUID();
        Query candidates = query(List.<Object[]>of(
                new Object[]{analysisId, UUID.randomUUID()}));
        Query readiness = querySequence(
                List.<Object[]>of(new Object[]{itemId, new BigDecimal("5")}),
                List.<Object[]>of(new Object[]{itemId, BigDecimal.ZERO}));
        routeQueries(em, candidates, readiness);
        MaterialAnalysisSupplyWakeupService service =
                new MaterialAnalysisSupplyWakeupService(em, analysis, events,
                com.uten.imp.support.FulfillmentMutationLockTestSupport.locks(),
                org.mockito.Mockito.mock(com.uten.imp.application.port.ProductionMutationFootprintPort.class));

        service.afterPurchaseReceiptReversed(UUID.randomUUID());

        verify(candidates).setParameter("includeLegacyFallback", true);
        verify(analysis).refreshLocked(analysisId);
        verifyNoInteractions(events);
    }

    @Test
    void terminalOrWarehouseLessAnalysesAreSkippedByCandidateQuery() {
        EntityManager em = mock(EntityManager.class);
        MaterialAnalysisService analysis = mock(MaterialAnalysisService.class);
        BusinessEventPublisher events = mock(BusinessEventPublisher.class);
        Query candidates = query(List.of());
        List<String> statements = routeQueries(
                em, candidates, querySequence(List.of(), List.of()));
        MaterialAnalysisSupplyWakeupService service =
                new MaterialAnalysisSupplyWakeupService(em, analysis, events,
                com.uten.imp.support.FulfillmentMutationLockTestSupport.locks(),
                org.mockito.Mockito.mock(com.uten.imp.application.port.ProductionMutationFootprintPort.class));

        service.afterFinishedInboundApproved(UUID.randomUUID());

        assertThat(statements.getFirst())
                .contains("analysis.status IN ('ACTIVE','PARTIALLY_PLANNED')")
                .contains("analysis.warehouse_id IS NOT NULL")
                .contains("item.is_deleted = FALSE")
                .contains("document.doc_type = 'FINISHED_IN'")
                .contains("document.status = :requiredStatus");
        verify(candidates).setParameter("requiredStatus", 1);
        verifyNoInteractions(analysis, events);
    }

    @Test
    void finishedInboundReversalRequiresTerminalReversedSource() {
        EntityManager em = mock(EntityManager.class);
        MaterialAnalysisService analysis = mock(MaterialAnalysisService.class);
        BusinessEventPublisher events = mock(BusinessEventPublisher.class);
        Query candidates = query(List.of());
        routeQueries(em, candidates, querySequence(List.of(), List.of()));
        MaterialAnalysisSupplyWakeupService service =
                new MaterialAnalysisSupplyWakeupService(em, analysis, events,
                com.uten.imp.support.FulfillmentMutationLockTestSupport.locks(),
                org.mockito.Mockito.mock(com.uten.imp.application.port.ProductionMutationFootprintPort.class));

        service.afterFinishedInboundReversed(UUID.randomUUID());

        verify(candidates).setParameter("requiredStatus", -1);
        verifyNoInteractions(analysis, events);
    }

    @Test
    void firstRefreshFailureEscapesAndStopsTheStableCandidatePass() {
        EntityManager em = mock(EntityManager.class);
        MaterialAnalysisService analysis = mock(MaterialAnalysisService.class);
        BusinessEventPublisher events = mock(BusinessEventPublisher.class);
        UUID first = UUID.randomUUID();
        UUID second = UUID.randomUUID();
        Query candidates = query(List.<Object[]>of(
                new Object[]{first, UUID.randomUUID()},
                new Object[]{second, UUID.randomUUID()}));
        Query readiness = query(List.<Object[]>of(
                new Object[]{UUID.randomUUID(), BigDecimal.ZERO}));
        routeQueries(em, candidates, readiness);
        doThrow(new IllegalStateException("refresh failed"))
                .when(analysis).refreshLocked(first);
        MaterialAnalysisSupplyWakeupService service =
                new MaterialAnalysisSupplyWakeupService(em, analysis, events,
                com.uten.imp.support.FulfillmentMutationLockTestSupport.locks(),
                org.mockito.Mockito.mock(com.uten.imp.application.port.ProductionMutationFootprintPort.class));

        assertThrows(IllegalStateException.class,
                () -> service.afterSubcontractReceiptApproved(UUID.randomUUID()));

        verify(analysis).refreshLocked(first);
        verify(analysis, never()).refreshLocked(second);
        verifyNoInteractions(events);
    }

    private static List<String> routeQueries(
            EntityManager em, Query candidates, Query readiness) {
        List<String> statements = new ArrayList<>();
        Query billNo = query(List.of("CJ26080001"));
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            String sql = invocation.getArgument(0);
            statements.add(sql);
            if (sql.contains("SELECT bill_no")) {
                return billNo;
            }
            return sql.contains("SELECT id, ready_finish_qty")
                    ? readiness : candidates;
        });
        return statements;
    }

    @SafeVarargs
    @SuppressWarnings("rawtypes")
    private static Query querySequence(List<Object[]>... rows) {
        Query query = mock(Query.class);
        when(query.setParameter(anyString(), org.mockito.ArgumentMatchers.any()))
                .thenReturn(query);
        OngoingStubbing<List> results = when(query.getResultList())
                .thenReturn(rows[0]);
        for (int i = 1; i < rows.length; i++) {
            results = results.thenReturn(rows[i]);
        }
        return query;
    }

    private static Query query(List<?> rows) {
        Query query = mock(Query.class);
        when(query.setParameter(anyString(), org.mockito.ArgumentMatchers.any()))
                .thenReturn(query);
        when(query.getResultList()).thenReturn(rows);
        return query;
    }
}

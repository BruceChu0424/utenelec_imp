package com.uten.imp.features.production.analysis;

import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;

import java.util.ArrayList;
import java.util.List;
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
        var locks = com.uten.imp.support.FulfillmentMutationLockTestSupport.locks();
        var footprints = mock(com.uten.imp.application.port.ProductionMutationFootprintPort.class);
        UUID target = UUID.randomUUID();
        var needed = new com.uten.imp.application.concurrency.FulfillmentMutationLockPlan(
                java.util.Set.of(),java.util.Set.of(),java.util.Set.of(),java.util.Set.of(target),"callback-target");
        when(footprints.forAnalyses(List.of(target))).thenReturn(needed);
        doThrow(new com.uten.imp.common.web.ApiException(
                com.uten.imp.common.web.ErrorCode.CONFLICT,"source changed"))
                .when(locks).requireCovered(needed);
        routeQueries(em,query(List.<Object[]>of(new Object[]{target,UUID.randomUUID()})));
        var service = new MaterialAnalysisSupplyWakeupService(em,analysis,locks,footprints);

        assertThrows(com.uten.imp.common.web.ApiException.class,
                () -> service.afterPurchaseReceiptApproved(UUID.randomUUID()));

        verify(footprints).forAnalyses(List.of(target));
        verify(locks).requireCovered(needed);
        verifyNoInteractions(analysis);
    }

    @Test
    void qualifiedPurchaseRefreshesWithoutPerItemNotificationQueries() {
        EntityManager em = mock(EntityManager.class);
        MaterialAnalysisService analysis = mock(MaterialAnalysisService.class);
        UUID analysisId = UUID.randomUUID();
        UUID makerId = UUID.randomUUID();
        UUID receiptId = UUID.randomUUID();
        Query candidates = query(List.<Object[]>of(new Object[]{analysisId, makerId}));
        List<String> statements = routeQueries(em, candidates);
        MaterialAnalysisSupplyWakeupService service =
                new MaterialAnalysisSupplyWakeupService(em, analysis,
                com.uten.imp.support.FulfillmentMutationLockTestSupport.locks(),
                org.mockito.Mockito.mock(com.uten.imp.application.port.ProductionMutationFootprintPort.class));

        service.afterPurchaseReceiptApproved(receiptId);

        verify(analysis).refreshLocked(analysisId);
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
        assertThat(statements).hasSize(1);
        verify(candidates).setParameter("sourceDocumentId", receiptId);
    }

    @Test
    void partialWarehouseStockInCoalescesReceiptAndInspectionTargetsOncePerBatch() {
        EntityManager em = mock(EntityManager.class);
        MaterialAnalysisService analysis = mock(MaterialAnalysisService.class);
        UUID analysisId = UUID.randomUUID();
        UUID makerId = UUID.randomUUID();
        UUID receiptId = UUID.randomUUID();
        UUID inspectionItemId = UUID.randomUUID();
        UUID firstBatchId = UUID.randomUUID();
        Query candidates = query(List.<Object[]>of(
                new Object[]{analysisId, makerId}));
        List<String> statements = routeQueries(em, candidates);
        MaterialAnalysisSupplyWakeupService service =
                new MaterialAnalysisSupplyWakeupService(em, analysis,
                com.uten.imp.support.FulfillmentMutationLockTestSupport.locks(),
                org.mockito.Mockito.mock(com.uten.imp.application.port.ProductionMutationFootprintPort.class));

        service.afterInspectionStockInConfirmed(
                "PURCHASE", receiptId, firstBatchId, List.of(inspectionItemId));
        service.afterInspectionStockInConfirmed(
                "PURCHASE", receiptId, UUID.randomUUID(), List.of(inspectionItemId));

        verify(analysis, times(2)).refreshLocked(analysisId);
        assertThat(statements).hasSize(2);
        assertThat(statements.getFirst())
                .contains("inspection.id IN (:inspectionItemIds)")
                .contains("inspection.receipt_type = 'PURCHASE'")
                .contains("inspection.status = 'PARTIAL'")
                .contains("inspection.warehouse_stocked_base_qty > 0")
                .contains("receipt.status = 1")
                .contains("ORDER BY analysis.id")
                .doesNotContain("FOR UPDATE");
        verify(candidates, times(2)).setParameter(
                "inspectionItemIds", List.of(inspectionItemId));
        verify(candidates, times(2)).setParameter("purchaseReceiptIds", receiptId.toString());
    }

    @Test
    void partialSubcontractWarehouseStockInUsesTheApprovedReceiptDimension() {
        EntityManager em = mock(EntityManager.class);
        MaterialAnalysisService analysis = mock(MaterialAnalysisService.class);
        UUID receiptId = UUID.randomUUID();
        UUID inspectionItemId = UUID.randomUUID();
        Query candidates = query(List.of());
        List<String> statements = routeQueries(
                em, candidates);
        MaterialAnalysisSupplyWakeupService service =
                new MaterialAnalysisSupplyWakeupService(em, analysis,
                com.uten.imp.support.FulfillmentMutationLockTestSupport.locks(),
                org.mockito.Mockito.mock(com.uten.imp.application.port.ProductionMutationFootprintPort.class));

        service.afterInspectionStockInConfirmed(
                "SUBCONTRACT", receiptId, UUID.randomUUID(),
                List.of(inspectionItemId));

        assertThat(statements.getFirst())
                .contains("inspection.receipt_type = 'SUBCONTRACT'")
                .contains("FROM subcontract_receipts receipt")
                .contains("receipt.status = 1");
        verify(candidates).setParameter("subcontractReceiptIds", receiptId.toString());
        verify(candidates).setParameter("purchaseReceiptIds", "");
        verifyNoInteractions(analysis);
    }

    @Test
    void mixedReceiptsResolveDimensionsOnceAndRefreshEachAnalysisOnce() {
        EntityManager em = mock(EntityManager.class);
        MaterialAnalysisService analysis = mock(MaterialAnalysisService.class);
        UUID first = new UUID(0, 1);
        UUID second = new UUID(0, 2);
        UUID purchase = UUID.randomUUID();
        UUID subcontract = UUID.randomUUID();
        Query candidates = query(List.<Object[]>of(
                new Object[]{second, UUID.randomUUID()},
                new Object[]{first, UUID.randomUUID()},
                new Object[]{second, UUID.randomUUID()}));
        List<String> statements = routeQueries(em, candidates);
        var service = new MaterialAnalysisSupplyWakeupService(em, analysis,
                com.uten.imp.support.FulfillmentMutationLockTestSupport.locks(),
                mock(com.uten.imp.application.port.ProductionMutationFootprintPort.class));
        var batches = new ArrayList<com.uten.imp.application.port.ProductionInspectionStockInPort.ReceiptStockIn>();
        for (int i = 0; i < 100; i++) {
            batches.add(new com.uten.imp.application.port.ProductionInspectionStockInPort.ReceiptStockIn(
                    i % 2 == 0 ? "PURCHASE" : "SUBCONTRACT",
                    i % 2 == 0 ? purchase : subcontract, UUID.randomUUID(), List.of(UUID.randomUUID())));
        }

        service.afterInspectionStockInConfirmed(batches);

        assertThat(statements).hasSize(1);
        verify(candidates).setParameter("purchaseReceiptIds", purchase.toString());
        verify(candidates).setParameter("subcontractReceiptIds", subcontract.toString());
        var order = org.mockito.Mockito.inOrder(analysis);
        order.verify(analysis).refreshLocked(first);
        order.verify(analysis).refreshLocked(second);
        order.verifyNoMoreInteractions();
    }

    @Test
    void emptyOrUnconfirmedStockInDoesNotRefresh() {
        EntityManager em = mock(EntityManager.class);
        MaterialAnalysisService analysis = mock(MaterialAnalysisService.class);
        var service = new MaterialAnalysisSupplyWakeupService(em, analysis,
                com.uten.imp.support.FulfillmentMutationLockTestSupport.locks(),
                mock(com.uten.imp.application.port.ProductionMutationFootprintPort.class));
        service.afterInspectionStockInConfirmed("PURCHASE", UUID.randomUUID(), null, List.of(UUID.randomUUID()));
        service.afterInspectionStockInConfirmed("PURCHASE", UUID.randomUUID(), UUID.randomUUID(), List.of());
        service.afterInspectionStockInConfirmed("PURCHASE", UUID.randomUUID(), UUID.randomUUID(), null);
        verifyNoInteractions(em, analysis);
    }

    @Test
    void fullyRejectedReceiptStillRefreshesShortageWithoutReadyNotice() {
        EntityManager em = mock(EntityManager.class);
        MaterialAnalysisService analysis = mock(MaterialAnalysisService.class);
        UUID analysisId = UUID.randomUUID();
        Query candidates = query(List.<Object[]>of(
                new Object[]{analysisId, UUID.randomUUID()}));
        List<String> statements = routeQueries(em, candidates);
        MaterialAnalysisSupplyWakeupService service =
                new MaterialAnalysisSupplyWakeupService(em, analysis,
                com.uten.imp.support.FulfillmentMutationLockTestSupport.locks(),
                org.mockito.Mockito.mock(com.uten.imp.application.port.ProductionMutationFootprintPort.class));

        service.afterSubcontractReceiptApproved(UUID.randomUUID());

        verify(analysis).refreshLocked(analysisId);
        assertThat(statements.getFirst())
                .contains("inspection.status = 'RESOLVED'")
                .doesNotContain("passed_base_qty > 0");
    }

    @Test
    void reversalRefreshesWithLegacyFallback() {
        EntityManager em = mock(EntityManager.class);
        MaterialAnalysisService analysis = mock(MaterialAnalysisService.class);
        UUID analysisId = UUID.randomUUID();
        Query candidates = query(List.<Object[]>of(
                new Object[]{analysisId, UUID.randomUUID()}));
        routeQueries(em, candidates);
        MaterialAnalysisSupplyWakeupService service =
                new MaterialAnalysisSupplyWakeupService(em, analysis,
                com.uten.imp.support.FulfillmentMutationLockTestSupport.locks(),
                org.mockito.Mockito.mock(com.uten.imp.application.port.ProductionMutationFootprintPort.class));

        service.afterPurchaseReceiptReversed(UUID.randomUUID());

        verify(candidates).setParameter("includeLegacyFallback", true);
        verify(analysis).refreshLocked(analysisId);
    }

    @Test
    void terminalOrWarehouseLessAnalysesAreSkippedByCandidateQuery() {
        EntityManager em = mock(EntityManager.class);
        MaterialAnalysisService analysis = mock(MaterialAnalysisService.class);
        Query candidates = query(List.of());
        List<String> statements = routeQueries(
                em, candidates);
        MaterialAnalysisSupplyWakeupService service =
                new MaterialAnalysisSupplyWakeupService(em, analysis,
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
        verifyNoInteractions(analysis);
    }

    @Test
    void finishedInboundReversalRequiresTerminalReversedSource() {
        EntityManager em = mock(EntityManager.class);
        MaterialAnalysisService analysis = mock(MaterialAnalysisService.class);
        Query candidates = query(List.of());
        routeQueries(em, candidates);
        MaterialAnalysisSupplyWakeupService service =
                new MaterialAnalysisSupplyWakeupService(em, analysis,
                com.uten.imp.support.FulfillmentMutationLockTestSupport.locks(),
                org.mockito.Mockito.mock(com.uten.imp.application.port.ProductionMutationFootprintPort.class));

        service.afterFinishedInboundReversed(UUID.randomUUID());

        verify(candidates).setParameter("requiredStatus", -1);
        verifyNoInteractions(analysis);
    }

    @Test
    void finishedInboundBatchResolvesItsWholeDocumentSetOnce() {
        EntityManager em = mock(EntityManager.class);
        MaterialAnalysisService analysis = mock(MaterialAnalysisService.class);
        UUID analysisId = UUID.randomUUID();
        UUID document = UUID.randomUUID();
        Query candidates = query(List.<Object[]>of(new Object[]{analysisId, UUID.randomUUID()}));
        List<String> statements = routeQueries(em, candidates);
        var service = new MaterialAnalysisSupplyWakeupService(em, analysis,
                com.uten.imp.support.FulfillmentMutationLockTestSupport.locks(),
                mock(com.uten.imp.application.port.ProductionMutationFootprintPort.class));

        service.afterFinishedInboundApproved(java.util.Collections.nCopies(100, document));

        assertThat(statements).hasSize(1);
        verify(candidates).setParameter("sourceDocumentIds", List.of(document));
        verify(analysis).refreshLocked(analysisId);
    }

    @Test
    void firstRefreshFailureEscapesAndStopsTheStableCandidatePass() {
        EntityManager em = mock(EntityManager.class);
        MaterialAnalysisService analysis = mock(MaterialAnalysisService.class);
        UUID first = UUID.randomUUID();
        UUID second = UUID.randomUUID();
        Query candidates = query(List.<Object[]>of(
                new Object[]{first, UUID.randomUUID()},
                new Object[]{second, UUID.randomUUID()}));
        routeQueries(em, candidates);
        doThrow(new IllegalStateException("refresh failed"))
                .when(analysis).refreshLocked(first);
        MaterialAnalysisSupplyWakeupService service =
                new MaterialAnalysisSupplyWakeupService(em, analysis,
                com.uten.imp.support.FulfillmentMutationLockTestSupport.locks(),
                org.mockito.Mockito.mock(com.uten.imp.application.port.ProductionMutationFootprintPort.class));

        assertThrows(IllegalStateException.class,
                () -> service.afterSubcontractReceiptApproved(UUID.randomUUID()));

        verify(analysis).refreshLocked(first);
        verify(analysis, never()).refreshLocked(second);
    }

    private static List<String> routeQueries(EntityManager em, Query candidates) {
        List<String> statements = new ArrayList<>();
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            statements.add(invocation.getArgument(0));
            return candidates;
        });
        return statements;
    }

    private static Query query(List<?> rows) {
        Query query = mock(Query.class);
        when(query.setParameter(anyString(), org.mockito.ArgumentMatchers.any()))
                .thenReturn(query);
        when(query.getResultList()).thenReturn(rows);
        return query;
    }
}

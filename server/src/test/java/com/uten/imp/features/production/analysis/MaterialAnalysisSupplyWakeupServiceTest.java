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
                new MaterialAnalysisSupplyWakeupService(em, analysis, events);

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
                .contains("FOR UPDATE OF analysis")
                .doesNotContain("material.unit_id =");
        verify(candidates).setParameter("includeLegacyFallback", false);
    }

    @Test
    void partialInspectionPassRefreshesImmediatelyWithReplayStableEventLineage() {
        EntityManager em = mock(EntityManager.class);
        MaterialAnalysisService analysis = mock(MaterialAnalysisService.class);
        BusinessEventPublisher events = mock(BusinessEventPublisher.class);
        UUID analysisId = UUID.randomUUID();
        UUID makerId = UUID.randomUUID();
        UUID receiptId = UUID.randomUUID();
        UUID inspectionItemId = UUID.randomUUID();
        UUID dispositionEventId = UUID.randomUUID();
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
                new MaterialAnalysisSupplyWakeupService(em, analysis, events);

        service.afterPurchaseInspectionPassed(
                receiptId, inspectionItemId, dispositionEventId);
        service.afterPurchaseInspectionPassed(
                receiptId, inspectionItemId, dispositionEventId);

        verify(analysis, times(2)).refreshLocked(analysisId);
        verify(events).publishOnce(
                MaterialAnalysisSupplyWakeupService.EVENT_READY,
                MaterialAnalysisSupplyWakeupService.AGGREGATE_TYPE,
                analysisId,
                Map.of(
                        "makerEmployeeId", makerId.toString(),
                        "sourceType", "PURCHASE",
                        "sourceDocumentId", receiptId.toString(),
                        "sourceEventId", dispositionEventId.toString(),
                        "analysisItemId", analysisItemId.toString(),
                        "readyFinishDelta", "5",
                        "readyFinishQty", "5"),
                MaterialAnalysisSupplyWakeupService.EVENT_READY + ':' + analysisId
                        + ':' + analysisItemId + ":PURCHASE:" + receiptId
                        + ":IQC_PASS:" + dispositionEventId);
        assertThat(statements.getFirst())
                .contains("inspection.id = :inspectionItemId")
                .contains("inspection.receipt_type = :sourceType")
                .contains("inspection.status IN ('PARTIAL', 'RESOLVED')")
                .contains("inspection.passed_base_qty > 0")
                .contains("receipt.status = 1")
                .contains("ORDER BY analysis.id")
                .contains("FOR UPDATE OF analysis");
        verify(candidates, times(2)).setParameter(
                "inspectionItemId", inspectionItemId);
        verify(candidates, times(2)).setParameter("sourceType", "PURCHASE");
    }

    @Test
    void partialSubcontractPassUsesTheApprovedSubcontractReceiptDimension() {
        EntityManager em = mock(EntityManager.class);
        MaterialAnalysisService analysis = mock(MaterialAnalysisService.class);
        BusinessEventPublisher events = mock(BusinessEventPublisher.class);
        UUID receiptId = UUID.randomUUID();
        UUID inspectionItemId = UUID.randomUUID();
        Query candidates = query(List.of());
        List<String> statements = routeQueries(
                em, candidates, querySequence(List.of(), List.of()));
        MaterialAnalysisSupplyWakeupService service =
                new MaterialAnalysisSupplyWakeupService(em, analysis, events);

        service.afterSubcontractInspectionPassed(
                receiptId, inspectionItemId, UUID.randomUUID());

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
                new MaterialAnalysisSupplyWakeupService(em, analysis, events);

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
                new MaterialAnalysisSupplyWakeupService(em, analysis, events);

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
                new MaterialAnalysisSupplyWakeupService(em, analysis, events);

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
                new MaterialAnalysisSupplyWakeupService(em, analysis, events);

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
                new MaterialAnalysisSupplyWakeupService(em, analysis, events);

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
                new MaterialAnalysisSupplyWakeupService(em, analysis, events);

        assertThrows(IllegalStateException.class,
                () -> service.afterSubcontractReceiptApproved(UUID.randomUUID()));

        verify(analysis).refreshLocked(first);
        verify(analysis, never()).refreshLocked(second);
        verifyNoInteractions(events);
    }

    private static List<String> routeQueries(
            EntityManager em, Query candidates, Query readiness) {
        List<String> statements = new ArrayList<>();
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            String sql = invocation.getArgument(0);
            statements.add(sql);
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

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
        // ADR-107: the wakeup target was expanded and verified by the transaction prefix; the
        // callback only checks, in memory, that the analysis is covered - no second discovery.
        doThrow(new com.uten.imp.common.web.ApiException(
                com.uten.imp.common.web.ErrorCode.CONFLICT,"source changed"))
                .when(locks).requireAnalysesCovered(List.of(target));
        routeQueries(em,query(List.<Object[]>of(new Object[]{target,UUID.randomUUID()})));
        var service = new MaterialAnalysisSupplyWakeupService(em,analysis,locks,footprints,
                org.mockito.Mockito.mock(com.uten.imp.features.notice.ChainNoticeService.class));

        assertThrows(com.uten.imp.common.web.ApiException.class,
                () -> service.afterPurchaseReceiptApproved(UUID.randomUUID()));

        verify(locks).requireAnalysesCovered(List.of(target));
        verifyNoInteractions(footprints);
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
                org.mockito.Mockito.mock(com.uten.imp.application.port.ProductionMutationFootprintPort.class),
                org.mockito.Mockito.mock(com.uten.imp.features.notice.ChainNoticeService.class));

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
                org.mockito.Mockito.mock(com.uten.imp.application.port.ProductionMutationFootprintPort.class),
                org.mockito.Mockito.mock(com.uten.imp.features.notice.ChainNoticeService.class));

        service.afterInspectionStockInConfirmed(
                "PURCHASE", receiptId, firstBatchId, List.of(inspectionItemId));
        service.afterInspectionStockInConfirmed(
                "PURCHASE", receiptId, UUID.randomUUID(), List.of(inspectionItemId));

        verify(analysis, times(2)).refreshLocked(analysisId);
        // 每次入库确认额外执行一次到货维度查询(空结果短路，不发通知)。
        assertThat(statements).hasSize(4);
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
                org.mockito.Mockito.mock(com.uten.imp.application.port.ProductionMutationFootprintPort.class),
                org.mockito.Mockito.mock(com.uten.imp.features.notice.ChainNoticeService.class));

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
                mock(com.uten.imp.application.port.ProductionMutationFootprintPort.class),
                mock(com.uten.imp.features.notice.ChainNoticeService.class));
        var batches = new ArrayList<com.uten.imp.application.port.ProductionInspectionStockInPort.ReceiptStockIn>();
        for (int i = 0; i < 100; i++) {
            batches.add(new com.uten.imp.application.port.ProductionInspectionStockInPort.ReceiptStockIn(
                    i % 2 == 0 ? "PURCHASE" : "SUBCONTRACT",
                    i % 2 == 0 ? purchase : subcontract, UUID.randomUUID(), List.of(UUID.randomUUID())));
        }

        service.afterInspectionStockInConfirmed(batches);

        // 目标解析 1 次 + 到货维度 1 次(空结果短路)。
        assertThat(statements).hasSize(2);
        verify(candidates).setParameter("purchaseReceiptIds", purchase.toString());
        verify(candidates).setParameter("subcontractReceiptIds", subcontract.toString());
        var order = org.mockito.Mockito.inOrder(analysis);
        order.verify(analysis).refreshLocked(first);
        order.verify(analysis).refreshLocked(second);
        order.verifyNoMoreInteractions();
    }

    @Test
    void resolvingQualityCommandSkipsTheRefreshButStillChecksArrivalDimensions() {
        EntityManager em = mock(EntityManager.class);
        MaterialAnalysisService analysis = mock(MaterialAnalysisService.class);
        Query candidates = query(List.<Object[]>of(new Object[]{UUID.randomUUID(), UUID.randomUUID()}));
        List<String> statements = routeQueries(em, candidates);
        var service = new MaterialAnalysisSupplyWakeupService(em, analysis,
                com.uten.imp.support.FulfillmentMutationLockTestSupport.locks(),
                mock(com.uten.imp.application.port.ProductionMutationFootprintPort.class),
                mock(com.uten.imp.features.notice.ChainNoticeService.class));
        var batch = new com.uten.imp.application.port.ProductionInspectionStockInPort.ReceiptStockIn(
                "PURCHASE", UUID.randomUUID(), UUID.randomUUID(), List.of(UUID.randomUUID()));

        // 整单在同一次品质结论里结案：结案回调随后按 RESOLVED 维度刷新，这里只发到货进展通知。
        service.afterInspectionStockInConfirmed(List.of(batch), false);

        verify(analysis, never()).refreshLocked(org.mockito.ArgumentMatchers.any());
        assertThat(statements).hasSize(1);
        assertThat(statements.getFirst()).contains("stock.batch_id IN (:batchIds)");
    }

    @Test
    void emptyOrUnconfirmedStockInDoesNotRefresh() {
        EntityManager em = mock(EntityManager.class);
        MaterialAnalysisService analysis = mock(MaterialAnalysisService.class);
        var service = new MaterialAnalysisSupplyWakeupService(em, analysis,
                com.uten.imp.support.FulfillmentMutationLockTestSupport.locks(),
                mock(com.uten.imp.application.port.ProductionMutationFootprintPort.class),
                mock(com.uten.imp.features.notice.ChainNoticeService.class));
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
                org.mockito.Mockito.mock(com.uten.imp.application.port.ProductionMutationFootprintPort.class),
                org.mockito.Mockito.mock(com.uten.imp.features.notice.ChainNoticeService.class));

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
                org.mockito.Mockito.mock(com.uten.imp.application.port.ProductionMutationFootprintPort.class),
                org.mockito.Mockito.mock(com.uten.imp.features.notice.ChainNoticeService.class));

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
                org.mockito.Mockito.mock(com.uten.imp.application.port.ProductionMutationFootprintPort.class),
                org.mockito.Mockito.mock(com.uten.imp.features.notice.ChainNoticeService.class));

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
                org.mockito.Mockito.mock(com.uten.imp.application.port.ProductionMutationFootprintPort.class),
                org.mockito.Mockito.mock(com.uten.imp.features.notice.ChainNoticeService.class));

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
                mock(com.uten.imp.application.port.ProductionMutationFootprintPort.class),
                mock(com.uten.imp.features.notice.ChainNoticeService.class));

        service.afterFinishedInboundApproved(java.util.Collections.nCopies(100, document));

        // 目标解析 1 次 + 到货维度 1 次(空结果短路)。
        assertThat(statements).hasSize(2);
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
                org.mockito.Mockito.mock(com.uten.imp.application.port.ProductionMutationFootprintPort.class),
                org.mockito.Mockito.mock(com.uten.imp.features.notice.ChainNoticeService.class));

        assertThrows(IllegalStateException.class,
                () -> service.afterSubcontractReceiptApproved(UUID.randomUUID()));

        verify(analysis).refreshLocked(first);
        verify(analysis, never()).refreshLocked(second);
    }

    private static List<String> routeQueries(EntityManager em, Query candidates) {
        List<String> statements = new ArrayList<>();
        // V599 到货进展通知的维度/命中查询也走 createNativeQuery——本测试类的候选行是
        // 两列(analysisId, makerId)，落进通知路径会按 7 列维度解读而越界。通知路径不是
        // 这里要验证的对象：按 SQL 特征路由到空结果，让它自然短路返回。
        Query noArrivals = query(List.of());
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            String sql = invocation.getArgument(0, String.class);
            statements.add(sql);
            if (sql.contains("stock.batch_id IN (:batchIds)")
                    || sql.contains("inspection.receipt_type=:sourceType")
                    || sql.contains("document.id IN (:documentIds)")
                    || sql.contains("JOIN production_planning_packages package")) {
                return noArrivals;
            }
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

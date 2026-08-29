package com.uten.imp.features.stock;

import com.uten.imp.application.port.ProductionCompletionReversePort;
import com.uten.imp.application.port.PreplanAnalysisPegPort;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.production.dailyreport.DailyReportExecutionSegmentGuard;
import com.uten.imp.features.notice.ChainNoticeService;
import com.uten.imp.features.production.dailyreport.ProductionDailyReport;
import com.uten.imp.features.production.dailyreport.ProductionDailyReportItemRepository;
import com.uten.imp.features.production.dailyreport.ProductionDailyReportRepository;
import com.uten.imp.features.production.dailyreport.ProductionDailyReportService;
import com.uten.imp.features.production.plan.PlanOrderItemLinkRepository;
import com.uten.imp.features.production.plan.ProductionPlanItemRepository;
import com.uten.imp.features.production.plan.ProductionPlanRepository;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.ProductionStockTaskAccessPolicy;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.LockModeType;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Optional;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.contains;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.inOrder;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class DocumentDirectLockTest {

    @Test
    void stockDeleteLoadsHeaderDirectlyWithPessimisticWrite() {
        EntityManager em = mock(EntityManager.class);
        StockDocumentRepository documents = mock(StockDocumentRepository.class);
        TxSessionVars tx = mock(TxSessionVars.class);
        StockDocService service = new StockDocService(
                documents,
                mock(StockBalanceAdjustmentCommandRepository.class),
                mock(StockDocumentItemRepository.class),
                mock(StockBalanceRepository.class),
                mock(StockService.class),
                mock(StockReservationService.class),
                tx,
                mock(DocNumberService.class),
                em,
                mock(SecurityContextCurrentUser.class),
                mock(EmployeeNameResolver.class),
                mock(ChainNoticeService.class),
                mock(com.uten.imp.features.stock.allocation.ProductionMaterialStockLedgerService.class),
                mock(ProductionCompletionReversePort.class),
                mock(com.uten.imp.features.common.taskclaim.TaskClaimService.class),
                mock(com.uten.imp.features.stock.StockDocAccessPolicy.class),
                warehouseTaskAccess(),
                // V298 分析备料绑定端口（成品入库路径 no-op mock，不建预留）
                mock(com.uten.imp.application.port.PreplanAnalysisPegPort.class),
                mock(com.uten.imp.application.port.ProductionQualityInspectionPort.class));
        UUID id = UUID.randomUUID();
        StockDocument document = new StockDocument();
        document.setId(id);
        document.setStatus((short) 0);
        when(em.find(StockDocument.class, id, LockModeType.PESSIMISTIC_WRITE))
                .thenReturn(document);
        Query provenance = mock(Query.class);
        when(em.createNativeQuery(contains(
                "fn_is_production_linked_stock_document"))).thenReturn(provenance);
        when(provenance.setParameter("id", id)).thenReturn(provenance);
        when(provenance.getSingleResult()).thenReturn(false);

        service.delete(id);

        verify(em).find(StockDocument.class, id, LockModeType.PESSIMISTIC_WRITE);
        verify(documents).save(document);
        assertThat(document.isDeleted()).isTrue();

        UUID reversedId = UUID.randomUUID();
        StockDocument reversed = new StockDocument();
        reversed.setId(reversedId);
        reversed.setStatus((short) -1);
        when(em.find(StockDocument.class, reversedId, LockModeType.PESSIMISTIC_WRITE))
                .thenReturn(reversed);
        when(provenance.setParameter("id", reversedId)).thenReturn(provenance);

        ApiException denied = assertThrows(ApiException.class,
                () -> service.delete(reversedId));

        assertThat(denied.getCode()).isEqualTo(ErrorCode.BUSINESS);
        assertThat(denied.getMessage()).contains("仅草稿", "红冲历史必须保留");
        verify(documents, never()).save(reversed);
        assertThat(reversed.isDeleted()).isFalse();
    }

    @Test
    void manualFinishedInboundReverseReopensCompletionBeforePersistingReverse() {
        EntityManager em = mock(EntityManager.class);
        StockDocumentRepository documents =
                mock(StockDocumentRepository.class);
        StockDocumentItemRepository items =
                mock(StockDocumentItemRepository.class);
        StockService stock = mock(StockService.class);
        ProductionCompletionReversePort completion =
                mock(ProductionCompletionReversePort.class);
        Query planLinks = mock(Query.class);
        UUID id = UUID.randomUUID();
        StockDocument document = new StockDocument();
        document.setId(id);
        document.setDocType("FINISHED_IN");
        document.setStatus((short) 1);

        when(em.find(
                StockDocument.class, id,
                LockModeType.PESSIMISTIC_WRITE)).thenReturn(document);
        when(items.findByDocIdOrderByLineNoAsc(id))
                .thenReturn(List.of());
        Query provenance = mock(Query.class);
        when(em.createNativeQuery(contains(
                "fn_is_production_linked_stock_document"))).thenReturn(provenance);
        when(provenance.setParameter("id", id)).thenReturn(provenance);
        when(provenance.getSingleResult()).thenReturn(false);
        when(em.createNativeQuery(contains(
                "SELECT DISTINCT l.plan_id"))).thenReturn(planLinks);
        when(planLinks.setParameter("did", id)).thenReturn(planLinks);
        when(planLinks.getResultList()).thenReturn(List.of());
        // 详情投影的来源计划反查（plan_draw_links → production_plans）：默认无关联。
        Query sourcePlan = mock(Query.class);
        when(em.createNativeQuery(contains(
                "JOIN production_plans p ON p.id = l.plan_id"))).thenReturn(sourcePlan);
        when(sourcePlan.setParameter("docId", id)).thenReturn(sourcePlan);
        when(sourcePlan.getResultList()).thenReturn(List.of());
        when(documents.findById(id)).thenReturn(Optional.of(document));

        StockDocService service = new StockDocService(
                documents,
                mock(StockBalanceAdjustmentCommandRepository.class),
                items,
                mock(StockBalanceRepository.class),
                stock,
                mock(StockReservationService.class),
                mock(TxSessionVars.class),
                mock(DocNumberService.class),
                em,
                mock(SecurityContextCurrentUser.class),
                mock(EmployeeNameResolver.class),
                mock(ChainNoticeService.class),
                mock(com.uten.imp.features.stock.allocation.ProductionMaterialStockLedgerService.class),
                completion,
                mock(com.uten.imp.features.common.taskclaim.TaskClaimService.class),
                mock(com.uten.imp.features.stock.StockDocAccessPolicy.class),
                warehouseTaskAccess(),
                // V298 分析备料绑定端口（成品入库路径 no-op mock，不建预留）
                mock(com.uten.imp.application.port.PreplanAnalysisPegPort.class),
                mock(com.uten.imp.application.port.ProductionQualityInspectionPort.class));

        service.reverse(id);

        var ordered = inOrder(completion, documents);
        ordered.verify(completion)
                .beforeFinishedInboundReversed(id);
        ordered.verify(documents).save(document);
        verify(stock).lockInventory(List.of());
        assertThat(document.getStatus()).isEqualTo((short) -1);
    }

    @Test
    void finishedInboundDownstreamGuardLeavesDocumentApproved() {
        EntityManager em = mock(EntityManager.class);
        StockDocumentRepository documents =
                mock(StockDocumentRepository.class);
        StockDocumentItemRepository items =
                mock(StockDocumentItemRepository.class);
        StockService stock = mock(StockService.class);
        StockReservationService reservations =
                mock(StockReservationService.class);
        ProductionCompletionReversePort completion =
                mock(ProductionCompletionReversePort.class);
        Query planLinks = mock(Query.class);
        UUID id = UUID.randomUUID();
        StockDocument document = new StockDocument();
        document.setId(id);
        document.setDocType("FINISHED_IN");
        document.setStatus((short) 1);

        when(em.find(
                StockDocument.class, id,
                LockModeType.PESSIMISTIC_WRITE)).thenReturn(document);
        when(items.findByDocIdOrderByLineNoAsc(id))
                .thenReturn(List.of());
        Query provenance = mock(Query.class);
        when(em.createNativeQuery(contains(
                "fn_is_production_linked_stock_document"))).thenReturn(provenance);
        when(provenance.setParameter("id", id)).thenReturn(provenance);
        when(provenance.getSingleResult()).thenReturn(false);
        when(em.createNativeQuery(contains(
                "SELECT DISTINCT l.plan_id"))).thenReturn(planLinks);
        when(planLinks.setParameter("did", id)).thenReturn(planLinks);
        when(planLinks.getResultList()).thenReturn(List.of());
        // 详情投影的来源计划反查（plan_draw_links → production_plans）：默认无关联。
        Query sourcePlan = mock(Query.class);
        when(em.createNativeQuery(contains(
                "JOIN production_plans p ON p.id = l.plan_id"))).thenReturn(sourcePlan);
        when(sourcePlan.setParameter("docId", id)).thenReturn(sourcePlan);
        when(sourcePlan.getResultList()).thenReturn(List.of());
        when(reservations.releaseBySourceDoc(
                "PRODUCTION_INBOUND", id)).thenThrow(
                new ApiException(
                        ErrorCode.BUSINESS,
                        "该入库货物已有发货记录"));

        StockDocService service = new StockDocService(
                documents,
                mock(StockBalanceAdjustmentCommandRepository.class),
                items,
                mock(StockBalanceRepository.class),
                stock,
                reservations,
                mock(TxSessionVars.class),
                mock(DocNumberService.class),
                em,
                mock(SecurityContextCurrentUser.class),
                mock(EmployeeNameResolver.class),
                mock(ChainNoticeService.class),
                mock(com.uten.imp.features.stock.allocation.ProductionMaterialStockLedgerService.class),
                completion,
                mock(com.uten.imp.features.common.taskclaim.TaskClaimService.class),
                mock(com.uten.imp.features.stock.StockDocAccessPolicy.class),
                warehouseTaskAccess(),
                // V298 分析备料绑定端口（成品入库路径 no-op mock，不建预留）
                mock(com.uten.imp.application.port.PreplanAnalysisPegPort.class),
                mock(com.uten.imp.application.port.ProductionQualityInspectionPort.class));

        assertThrows(ApiException.class, () -> service.reverse(id));

        verify(completion).beforeFinishedInboundReversed(id);
        verify(documents, never()).save(document);
        assertThat(document.getStatus()).isEqualTo((short) 1);
    }

    @Test
    void finishedInboundTransferredPreplanGuardRunsBeforeAnyReverseMutation() {
        EntityManager em = mock(EntityManager.class);
        StockDocumentRepository documents = mock(StockDocumentRepository.class);
        StockDocumentItemRepository items = mock(StockDocumentItemRepository.class);
        StockService stock = mock(StockService.class);
        StockReservationService reservations = mock(StockReservationService.class);
        ProductionCompletionReversePort completion = mock(ProductionCompletionReversePort.class);
        PreplanAnalysisPegPort preplan = mock(PreplanAnalysisPegPort.class);
        UUID id = UUID.randomUUID();
        StockDocument document = new StockDocument();
        document.setId(id);
        document.setDocType("FINISHED_IN");
        document.setStatus((short) 1);

        when(em.find(StockDocument.class, id, LockModeType.PESSIMISTIC_WRITE))
                .thenReturn(document);
        when(items.findByDocIdOrderByLineNoAsc(id)).thenReturn(List.of());
        Query provenance = mock(Query.class);
        when(em.createNativeQuery(contains(
                "fn_is_production_linked_stock_document"))).thenReturn(provenance);
        when(provenance.setParameter("id", id)).thenReturn(provenance);
        when(provenance.getSingleResult()).thenReturn(false);
        doThrow(new ApiException(
                ErrorCode.CONFLICT,
                "成品入库分析归属已转入正式生产需求"))
                .when(preplan).requireFinishedInboundReversible(id);

        StockDocService service = new StockDocService(
                documents,
                mock(StockBalanceAdjustmentCommandRepository.class),
                items,
                mock(StockBalanceRepository.class),
                stock,
                reservations,
                mock(TxSessionVars.class),
                mock(DocNumberService.class),
                em,
                mock(SecurityContextCurrentUser.class),
                mock(EmployeeNameResolver.class),
                mock(ChainNoticeService.class),
                mock(com.uten.imp.features.stock.allocation.ProductionMaterialStockLedgerService.class),
                completion,
                mock(com.uten.imp.features.common.taskclaim.TaskClaimService.class),
                mock(com.uten.imp.features.stock.StockDocAccessPolicy.class),
                warehouseTaskAccess(),
                preplan,
                mock(com.uten.imp.application.port.ProductionQualityInspectionPort.class));

        ApiException error = assertThrows(ApiException.class, () -> service.reverse(id));

        assertThat(error.getCode()).isEqualTo(ErrorCode.CONFLICT);
        verify(preplan).requireFinishedInboundReversible(id);
        verify(completion, never()).beforeFinishedInboundReversed(id);
        verify(reservations, never()).releaseBySourceDoc("PRODUCTION_INBOUND", id);
        verify(stock, never()).recordMovement(any());
        verify(documents, never()).save(document);
        assertThat(document.getStatus()).isEqualTo((short) 1);
    }

    @Test
    void dailyReportDeleteLoadsHeaderDirectlyWithPessimisticWrite() {
        EntityManager em = mock(EntityManager.class);
        ProductionDailyReportRepository reports =
                mock(ProductionDailyReportRepository.class);
        TxSessionVars tx = mock(TxSessionVars.class);
        ProductionDailyReportService service = new ProductionDailyReportService(
                reports,
                mock(ProductionDailyReportItemRepository.class),
                mock(ProductionPlanRepository.class),
                mock(ProductionPlanItemRepository.class),
                mock(PlanOrderItemLinkRepository.class),
                mock(DailyReportExecutionSegmentGuard.class),
                mock(SecurityContextCurrentUser.class),
                mock(EmployeeNameResolver.class),
                tx,
                mock(DocNumberService.class),
                mock(com.uten.imp.features.production.plan.ProductionProductNoAllocator.class),
                em,
                mock(ChainNoticeService.class),
                mock(com.uten.imp.features.production.ProductionDocumentAccessPolicy.class),
                mock(com.uten.imp.application.port.ProductionQualityInspectionPort.class),
                mock(com.uten.imp.application.port.ProductionFqcRecoveryPort.class),
                mock(com.uten.imp.features.production.dailyreport.ProductionLegacyFinishedInboundService.class));
        UUID id = UUID.randomUUID();
        ProductionDailyReport report = new ProductionDailyReport();
        report.setId(id);
        report.setStatus((short) 0);
        when(em.find(ProductionDailyReport.class, id, LockModeType.PESSIMISTIC_WRITE))
                .thenReturn(report);

        service.delete(id);

        verify(em).find(ProductionDailyReport.class, id, LockModeType.PESSIMISTIC_WRITE);
        verify(reports).saveAndFlush(report);
        assertThat(report.isDeleted()).isTrue();

        UUID reversedId = UUID.randomUUID();
        ProductionDailyReport reversed = new ProductionDailyReport();
        reversed.setId(reversedId);
        reversed.setStatus((short) -1);
        when(em.find(ProductionDailyReport.class, reversedId, LockModeType.PESSIMISTIC_WRITE))
                .thenReturn(reversed);

        ApiException denied = assertThrows(ApiException.class,
                () -> service.delete(reversedId));

        assertThat(denied.getCode()).isEqualTo(ErrorCode.BUSINESS);
        assertThat(denied.getMessage()).contains("仅草稿", "红冲历史必须保留");
        verify(reports, never()).save(reversed);
        assertThat(reversed.isDeleted()).isFalse();
    }

    private static ProductionStockTaskAccessPolicy warehouseTaskAccess() {
        ProductionStockTaskAccessPolicy policy =
                mock(ProductionStockTaskAccessPolicy.class);
        when(policy.canAccessWarehouseTasks()).thenReturn(true);
        return policy;
    }
}

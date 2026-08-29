package com.uten.imp.features.stock;

import com.uten.imp.application.port.PreplanAnalysisPegPort;
import com.uten.imp.application.port.ProductionCompletionReversePort;
import com.uten.imp.application.port.ProductionQualityInspectionPort;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.common.taskclaim.TaskClaimService;
import com.uten.imp.features.notice.ChainNoticeService;
import com.uten.imp.features.production.fulfillment.PlanningPackageFingerprint;
import com.uten.imp.features.stock.allocation.ProductionMaterialStockLedgerService;
import com.uten.imp.features.stock.dto.FinishedInboundConfirmRequest;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.ProductionStockTaskAccessPolicy;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.LockModeType;
import jakarta.persistence.Query;
import org.mockito.ArgumentCaptor;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

class StockDocFinishedInboundConfirmationTest {

    private final UUID documentId = UUID.randomUUID();
    private final UUID itemId = UUID.randomUUID();
    private final UUID warehouseId = UUID.randomUUID();
    private final UUID planId = UUID.randomUUID();
    private EntityManager em;
    private StockDocumentRepository documents;
    private StockBalanceAdjustmentCommandRepository balanceAdjustments;
    private StockDocumentItemRepository items;
    private StockService stock;
    private ProductionCompletionReversePort completion;
    private StockDocAccessPolicy access;
    private ProductionStockTaskAccessPolicy taskAccess;
    private SecurityContextCurrentUser currentUser;
    private ChainNoticeService notices;
    private ProductionQualityInspectionPort qualityInspection;
    private StockDocService service;
    private StockDocument document;
    private StockDocumentItem item;

    @BeforeEach
    void setUp() {
        em = mock(EntityManager.class);
        documents = mock(StockDocumentRepository.class);
        balanceAdjustments = mock(StockBalanceAdjustmentCommandRepository.class);
        items = mock(StockDocumentItemRepository.class);
        stock = mock(StockService.class);
        completion = mock(ProductionCompletionReversePort.class);
        access = mock(StockDocAccessPolicy.class);
        currentUser = mock(SecurityContextCurrentUser.class);
        notices = mock(ChainNoticeService.class);
        taskAccess = mock(ProductionStockTaskAccessPolicy.class);
        qualityInspection = mock(ProductionQualityInspectionPort.class);
        when(access.hasAuthority(anyString())).thenReturn(true);
        when(taskAccess.canAccessWarehouseTasks()).thenReturn(true);

        document = new StockDocument();
        document.setId(documentId);
        document.setDocType("FINISHED_IN");
        document.setStatus((short) 0);
        document.setWarehouseId(warehouseId);
        document.setBillNo("CJ-TEST-001");

        item = new StockDocumentItem();
        item.setId(itemId);
        item.setDocId(documentId);
        item.setBillType("FINISHED_IN");
        item.setQty(new BigDecimal("10.0000"));
        item.setUnitRate(BigDecimal.ONE);
        item.setGoodsId(UUID.randomUUID());
        item.setUnitId(UUID.randomUUID());
        item.setSourceDailyReportItemId(UUID.randomUUID());

        when(em.find(
                StockDocument.class, documentId,
                LockModeType.PESSIMISTIC_WRITE)).thenReturn(document);
        when(items.findByDocIdOrderByLineNoAsc(documentId))
                .thenReturn(List.of(item));

        service = new StockDocService(
                documents,
                balanceAdjustments,
                items,
                mock(StockBalanceRepository.class),
                stock,
                mock(StockReservationService.class),
                mock(TxSessionVars.class),
                mock(DocNumberService.class),
                em,
                currentUser,
                mock(EmployeeNameResolver.class),
                notices,
                mock(ProductionMaterialStockLedgerService.class),
                completion,
                mock(TaskClaimService.class),
                access,
                taskAccess,
                mock(PreplanAnalysisPegPort.class),
                qualityInspection);
    }

    @Test
    void genericApproveRejectsProductionLinkedFinishedInboundDraft() {
        Query productionLinked = query();
        when(productionLinked.getSingleResult()).thenReturn(true);
        when(em.createNativeQuery(anyString())).thenReturn(productionLinked);

        ApiException error = assertThrows(
                ApiException.class,
                () -> service.approve(documentId));

        assertThat(error.getMessage()).contains("逐行确认实收数量");
        verifyNoInteractions(stock);
        verify(documents, never()).save(document);
    }

    @Test
    void productionTaskActionPermissionDoesNotBypassWarehouseObjectScope() {
        Query productionLinked = query();
        when(productionLinked.getSingleResult()).thenReturn(true);
        when(em.createNativeQuery(anyString())).thenReturn(productionLinked);
        doThrow(new ApiException(
                com.uten.imp.common.web.ErrorCode.FORBIDDEN,
                "不在仓储组织范围"))
                .when(taskAccess).requireWarehouseTaskAccess(anyString());

        ApiException error = assertThrows(
                ApiException.class,
                () -> service.approve(documentId));

        assertThat(error.getCode())
                .isEqualTo(com.uten.imp.common.web.ErrorCode.FORBIDDEN);
        verifyNoInteractions(stock);
    }

    @Test
    void confirmationRejectsAcceptedQuantityAboveReportedQuantity() {
        arrangeConfirmationQueries(List.of());

        ApiException error = assertThrows(
                ApiException.class,
                () -> service.confirmFinishedInbound(
                        documentId, request("11.0000", null, "confirm-over-0001")));

        assertThat(error.getMessage()).contains("不能超过报工待入库数量");
        verifyNoInteractions(stock);
    }

    @Test
    void missingFqcReleaseStopsBeforeInventoryMutation() {
        arrangeConfirmationQueries(List.of());
        doThrow(new ApiException(
                com.uten.imp.common.web.ErrorCode.CONFLICT,
                "没有足额 FQC PASS 放行来源"))
                .when(qualityInspection)
                .requireInboundReleased(
                        eq(item.getSourceDailyReportItemId()),
                        eq(itemId),
                        eq(new BigDecimal("10.0000")));

        ApiException error = assertThrows(
                ApiException.class,
                () -> service.confirmFinishedInbound(
                        documentId,
                        request(
                                "10.0000",
                                null,
                                "confirm-fqc-denied")));

        assertThat(error.getMessage()).contains("FQC PASS");
        verifyNoInteractions(stock);
    }

    @Test
    void shortConfirmationRequiresAVarianceReason() {
        arrangeConfirmationQueries(List.of());

        ApiException error = assertThrows(
                ApiException.class,
                () -> service.confirmFinishedInbound(
                        documentId, request("6.0000", null, "confirm-short-001")));

        assertThat(error.getMessage()).contains("必须填写差异原因");
        verifyNoInteractions(stock);
    }

    @Test
    void wholeDocumentZeroAcceptanceRequiresAReason() {
        arrangeConfirmationQueries(List.of());

        ApiException error = assertThrows(
                ApiException.class,
                () -> service.confirmFinishedInbound(
                        documentId, request("0.0000", null, "confirm-reject-01")));

        assertThat(error.getMessage()).contains("必须填写差异原因");
        verifyNoInteractions(stock);
        verify(documents, never()).saveAndFlush(document);
    }

    @Test
    void wholeDocumentZeroAcceptanceRecordsRejectedWithoutInventoryPosting() {
        UUID actorId = UUID.randomUUID();
        UUID employeeId = UUID.randomUUID();
        when(currentUser.requireId()).thenReturn(actorId);
        when(currentUser.requireEmployeeId()).thenReturn(employeeId);
        when(documents.findById(documentId)).thenReturn(Optional.of(document));
        when(balanceAdjustments.existsByStockDocumentId(documentId)).thenReturn(false);
        when(documents.saveAndFlush(any(StockDocument.class)))
                .thenAnswer(invocation -> {
                    StockDocument saved = invocation.getArgument(0);
                    if (saved.getId() == null) saved.setId(UUID.randomUUID());
                    return saved;
                });
        when(items.saveAndFlush(any(StockDocumentItem.class)))
                .thenAnswer(invocation -> {
                    StockDocumentItem saved = invocation.getArgument(0);
                    if (saved.getId() == null) saved.setId(UUID.randomUUID());
                    return saved;
                });
        arrangeConfirmationQueries(List.of());

        assertThat(service.confirmFinishedInbound(
                documentId,
                request("0.0000", "整批实物未到仓", "confirm-reject-02"))
                .getId()).isEqualTo(documentId);

        assertThat(document.getStatus()).isEqualTo((short) -1);
        ArgumentCaptor<StockDocument> documentCaptor =
                ArgumentCaptor.forClass(StockDocument.class);
        verify(documents, times(2)).saveAndFlush(documentCaptor.capture());
        StockDocument residualDocument = documentCaptor.getAllValues().stream()
                .filter(saved -> saved != document)
                .findFirst()
                .orElseThrow();
        assertThat(residualDocument.getStatus()).isEqualTo((short) 0);
        assertThat(residualDocument.getDocType()).isEqualTo("FINISHED_IN");
        assertThat(residualDocument.getRemark()).contains("整单拒收待重新交付");

        ArgumentCaptor<StockDocumentItem> itemCaptor =
                ArgumentCaptor.forClass(StockDocumentItem.class);
        verify(items).saveAndFlush(itemCaptor.capture());
        StockDocumentItem residualItem = itemCaptor.getValue();
        assertThat(residualItem.getDocId()).isEqualTo(residualDocument.getId());
        assertThat(residualItem.getQty()).isEqualByComparingTo("10.0000");
        assertThat(residualItem.getSourceDailyReportItemId())
                .isEqualTo(item.getSourceDailyReportItemId());
        // 拒收原因只存确认记录，单据备注保持不可变身份列原值（草稿建单时未写备注）
        assertThat(document.getRemark()).isNull();
        verifyNoInteractions(stock);
        verify(notices).notifyFinishedInboundRejected(
                documentId, "整批实物未到仓", "confirm-reject-02");
        verify(notices).notifyFinishedInboundPending(residualDocument.getId());
    }

    @Test
    void exactIdempotentReplayReturnsExistingDocumentWithoutStockMutation() {
        String key = "confirm-replay-01";
        FinishedInboundConfirmRequest request = request("10.0000", null, key);
        String hash = PlanningPackageFingerprint.sha256(List.of(
                "PRODUCTION-FINISHED-IN-CONFIRM-V1",
                documentId.toString(),
                itemId + "|10",
                ""));
        arrangeConfirmationQueries(
                java.util.Collections.<Object[]>singletonList(
                        new Object[]{key, hash}));
        when(documents.findById(documentId)).thenReturn(Optional.of(document));
        when(balanceAdjustments.existsByStockDocumentId(documentId)).thenReturn(false);

        assertThat(service.confirmFinishedInbound(documentId, request).getId())
                .isEqualTo(documentId);

        verifyNoInteractions(stock);
        verify(documents, never()).save(document);
    }

    @Test
    void sourceContractKeepsFullAndShortAcceptanceOnTheDedicatedLane()
            throws Exception {
        String source = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/stock/StockDocService.java"),
                StandardCharsets.UTF_8);

        assertThat(source)
                .contains("public StockDocDetail confirmFinishedInbound")
                .contains("hasVariance ? \"PARTIAL\" : \"ACCEPTED\"")
                .contains("newFinishedInboundResidual(document)")
                .contains("copyFinishedInboundResidualItem")
                .contains("applyAcceptedFinishedInboundQuantity")
                .contains("proposed.subtract(actual)")
                .contains("'app.production_finished_in_confirm_doc_id'")
                .contains(".setParameter(\"documentId\", id.toString())")
                .contains("return approveInternal(id, true)")
                .contains("\"REJECTED\", varianceReason")
                .contains("confirmationId, document, residualDocument")
                .contains("notifyFinishedInboundPending(residualDocument.getId())")
                .contains("document.setStatus(STATUS_REVERSED)")
                .contains("notifyFinishedInboundRejected")
                .contains("public StockDocDetail reverseFinishedInbound")
                .contains("createFinishedInboundReversalDraft(d, items)")
                .contains("production_finished_in_confirmation_reversals")
                .contains("production_finished_in_confirmation_reversal_items")
                .contains("notifyFinishedInboundReversed")
                .contains("生产成品入库必须使用专用红冲入口")
                .contains("该成品入库单已按另一组实收数量确认")
                .contains("实收数量不能超过报工待入库数量")
                .contains("实收少于报工数量时必须填写差异原因")
                .doesNotContain("不能一部分整行拒收、一部分接收");
    }

    private void arrangeConfirmationQueries(List<Object[]> replayRows) {
        Query warehouse = query();
        when(warehouse.getResultList()).thenReturn(List.of(warehouseId));

        Query productionLinked = query();
        when(productionLinked.getSingleResult()).thenReturn(true);
        Query replay = query();
        when(replay.getResultList()).thenReturn(replayRows);
        Query plan = query();
        when(plan.getResultList()).thenReturn(
                java.util.Collections.<Object[]>singletonList(new Object[]{
                        planId, (short) 1, false, false, false
                }));
        Query sourcePlan = query();
        when(sourcePlan.getResultList()).thenReturn(List.of(planId));
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            String sql = invocation.getArgument(0, String.class);
            if (sql.contains("SELECT warehouse_id")
                    && sql.contains("FROM stock_documents")) {
                return warehouse;
            }
            if (sql.contains("fn_is_production_linked_stock_document")) {
                return productionLinked;
            }
            if (sql.contains("FROM production_finished_in_confirmations")) {
                return replay;
            }
            if (sql.contains("FROM plan_draw_links l")
                    && sql.contains("FOR UPDATE OF p")) {
                return plan;
            }
            if (sql.contains("JOIN production_plans p ON p.id = l.plan_id")) {
                return sourcePlan;
            }
            return query();
        });
    }

    private FinishedInboundConfirmRequest request(
            String acceptedQty, String reason, String key) {
        FinishedInboundConfirmRequest request =
                new FinishedInboundConfirmRequest();
        request.setIdempotencyKey(key);
        request.setVarianceReason(reason);
        request.setLines(List.of(line(itemId, acceptedQty)));
        return request;
    }

    private static FinishedInboundConfirmRequest.Line line(
            UUID id, String acceptedQty) {
        FinishedInboundConfirmRequest.Line line =
                new FinishedInboundConfirmRequest.Line();
        line.setItemId(id);
        line.setAcceptedQty(new BigDecimal(acceptedQty));
        return line;
    }

    private static Query query() {
        Query query = mock(Query.class);
        when(query.setParameter(anyString(), org.mockito.ArgumentMatchers.any()))
                .thenReturn(query);
        return query;
    }
}

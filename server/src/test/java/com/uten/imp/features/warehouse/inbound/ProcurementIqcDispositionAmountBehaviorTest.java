package com.uten.imp.features.warehouse.inbound;

import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.application.port.InventoryMovementCostReference;
import com.uten.imp.application.port.ProcurementInventoryValuePort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.application.port.PreplanAnalysisPegPort;
import com.uten.imp.application.port.ProcurementIqcRejectionPort;
import com.uten.imp.application.port.ProductionSubcontractSupplyTransitionPort;
import com.uten.imp.application.port.ProductionSupplyTransitionPort;
import com.uten.imp.features.stock.StockService;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.when;

class ProcurementIqcDispositionAmountBehaviorTest {

    @Test
    void legacyAmountProjectionSharesOneResolvedCursorWithoutClaimingActualCostAuthority() {
        BigDecimal amount = new BigDecimal("0.0247");
        BigDecimal received = new BigDecimal("3");

        BigDecimal passFirst = ProcurementInspectionService.proratedIncrement(
                amount, received, BigDecimal.ZERO, BigDecimal.ONE);
        BigDecimal failMiddle = ProcurementInspectionService.proratedIncrement(
                amount, received, BigDecimal.ONE, BigDecimal.ONE);
        BigDecimal passLast = ProcurementInspectionService.proratedIncrement(
                amount, received, new BigDecimal("2"), BigDecimal.ONE);

        assertThat(passFirst).isEqualByComparingTo("0.0082");
        assertThat(failMiddle).isEqualByComparingTo("0.0083");
        assertThat(passLast).isEqualByComparingTo("0.0082");
        assertThat(passFirst.add(failMiddle).add(passLast))
                .isEqualByComparingTo(amount);
    }

    @Test
    void receiptReverseUsesEachOriginalStockBatchAsItsCostSource() {
        verifyReceiptReverse(true);
    }

    @Test
    void receiptReverseRejectsMissingStockBatchBeforeAnyMovement() {
        verifyReceiptReverse(false);
    }

    private void verifyReceiptReverse(boolean completeBatchEvidence) {
        UUID inspectionItemId = UUID.randomUUID();
        UUID receiptId = UUID.randomUUID();
        UUID warehouseId = UUID.randomUUID();
        UUID goodsId = UUID.randomUUID();
        UUID colorId = UUID.randomUUID();
        UUID unitId = UUID.randomUUID();
        UUID weightUnitId = UUID.randomUUID();
        UUID firstStockItemId = UUID.randomUUID();
        UUID secondStockItemId = UUID.randomUUID();
        UUID actor = UUID.randomUUID();
        List<UUID> qualityEvents = List.of(UUID.randomUUID(), UUID.randomUUID(), UUID.randomUUID());
        EntityManager em = mock(EntityManager.class);
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            String sql = compact(invocation.getArgument(0));
            Query query = mock(Query.class);
            when(query.setParameter(anyString(), org.mockito.ArgumentMatchers.any()))
                    .thenReturn(query);
            when(query.getResultList()).thenAnswer(ignored -> {
                if (sql.contains("select id, warehouse_id, goods_id")) {
                    return java.util.Collections.singletonList(new Object[]{
                            inspectionItemId, warehouseId, goodsId, colorId,
                            unitId, BigDecimal.ONE, new BigDecimal("2"),
                            new BigDecimal("0.0164"), new BigDecimal("3"),
                            "RESOLVED", null});
                }
                if (sql.contains("from procurement_inspection_events")) {
                    if(sql.startsWith("select id from procurement_inspection_events")){
                        return qualityEvents;
                    }
                    return List.of(
                            new Object[]{"PASS", BigDecimal.ONE},
                            new Object[]{"FAIL", BigDecimal.ONE},
                            new Object[]{"PASS", BigDecimal.ONE});
                }
                if (sql.contains("from procurement_iqc_stock_in_batch_items stocked")) {
                    return completeBatchEvidence ? List.of(
                            new Object[]{firstStockItemId, inspectionItemId, warehouseId, goodsId, colorId,
                                    unitId, BigDecimal.ONE, BigDecimal.ONE, BigDecimal.ONE, weightUnitId},
                            new Object[]{secondStockItemId, inspectionItemId, warehouseId, goodsId, colorId,
                                    unitId, BigDecimal.ONE, BigDecimal.ONE, new BigDecimal("2"), weightUnitId})
                            : List.of();
                }
                return List.of();
            });
            when(query.executeUpdate()).thenReturn(1);
            return query;
        });
        StockService stock = mock(StockService.class);
        SecurityContextCurrentUser currentUser = mock(SecurityContextCurrentUser.class);
        when(currentUser.requireEmployeeId()).thenReturn(UUID.randomUUID());
        when(currentUser.requireId()).thenReturn(actor);
        ProcurementInventoryValuePort procurementValue = mock(ProcurementInventoryValuePort.class);
        ProcurementInspectionService service = new ProcurementInspectionService(
                em,
                stock,
                currentUser,
                mock(TxSessionVars.class),
                mock(ProductionSupplyTransitionPort.class),
                mock(ProductionSubcontractSupplyTransitionPort.class),
                mock(BusinessEventPublisher.class),
                mock(ProcurementIqcRejectionPort.class),
                mock(com.uten.imp.features.notice.ChainNoticeService.class),
                org.mockito.Mockito.mock(com.uten.imp.common.concurrency.ProcurementMutationLocks.class, org.mockito.Mockito.RETURNS_DEEP_STUBS),
                mock(com.uten.imp.common.finance.ProcurementReceiptConsiderationService.class),
                procurementValue);

        if (!completeBatchEvidence) {
            assertThatThrownBy(() -> service.reverseResolvedStock(
                    "PURCHASE", receiptId, OffsetDateTime.parse("2026-08-31T12:00:00Z")))
                    .isInstanceOf(ApiException.class).hasMessageContaining("缺少完整的原批次流水");
            verify(stock, never()).recordMovement(any());
            verify(procurementValue, never()).qualityReversed(any(), any());
            return;
        }

        assertThat(service.reverseResolvedStock(
                "PURCHASE", receiptId, OffsetDateTime.parse("2026-08-31T12:00:00Z")))
                .isTrue();

        ArgumentCaptor<StockService.MovementRequest> movement =
                ArgumentCaptor.forClass(StockService.MovementRequest.class);
        verify(stock, times(2)).recordMovement(movement.capture());
        assertThat(movement.getAllValues()).extracting(StockService.MovementRequest::sourceItemId)
                .containsExactly(firstStockItemId, secondStockItemId);
        assertThat(movement.getAllValues()).allSatisfy(request -> {
            assertThat(request.direction()).isEqualTo(StockService.DIR_OUT);
            assertThat(request.amountLocal()).isNull();
            assertThat(request.costReference()).isEqualTo(
                    new InventoryMovementCostReference.ProcurementStockIn(request.sourceItemId()));
            assertThat(request.warehouseId()).isEqualTo(warehouseId);
            assertThat(request.goodsId()).isEqualTo(goodsId);
            assertThat(request.colorId()).isEqualTo(colorId);
            assertThat(request.weightUnitId()).isEqualTo(weightUnitId);
        });
        assertThat(movement.getAllValues().stream().map(StockService.MovementRequest::qty)
                .reduce(BigDecimal.ZERO, BigDecimal::add)).isEqualByComparingTo("2");
        assertThat(movement.getAllValues().stream().map(StockService.MovementRequest::weight)
                .reduce(BigDecimal.ZERO, BigDecimal::add)).isEqualByComparingTo("3");
        for (UUID event : qualityEvents) verify(procurementValue).qualityReversed(event, actor);
    }

    private static String compact(String sql) {
        return sql.replaceAll("\\s+", " ").trim().toLowerCase();
    }
}

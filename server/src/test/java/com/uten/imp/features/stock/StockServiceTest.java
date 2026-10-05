package com.uten.imp.features.stock;

import com.uten.imp.application.port.SubcontractOutboundWakePort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.stock.weight.CapturedWeight;
import com.uten.imp.features.stock.weight.StockWeightAdjustmentRepository;
import com.uten.imp.features.stock.weight.StockWeightContextReader;
import com.uten.imp.features.stock.weight.StockWeightResolver;
import com.uten.imp.features.stock.weight.WeightSource;
import com.uten.imp.security.TxSessionVars;
import org.springframework.beans.factory.ObjectProvider;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class StockServiceTest {
    private static StockBalanceRepository.PhysicalSnapshot snapshot(StockBalance balance){
        return new StockBalanceRepository.PhysicalSnapshot(){
            public BigDecimal getQty(){return balance.getQty();}
            public BigDecimal getWeight(){return balance.getWeight();}
            public Boolean getWeightEstimated(){return balance.isWeightEstimated();}
        };
    }

    private static com.uten.imp.features.stock.valuation.StockValuationCoordinator quantityTestValuation() {
        return org.mockito.Mockito.mock(com.uten.imp.features.stock.valuation.StockValuationCoordinator.class, invocation -> {
            if (!invocation.getMethod().getName().equals("value")) return org.mockito.Answers.RETURNS_DEFAULTS.answer(invocation);
            return new com.uten.imp.application.port.InventoryValuationPort.MovementValue(
                    UUID.randomUUID(),invocation.getArgument(0),UUID.randomUUID(),UUID.randomUUID(),
                    BigDecimal.ZERO,com.uten.imp.application.port.InventoryValuationPort.State.PENDING,false);
        });
    }

    /** ADR-103: 纯单测没有委外模块, 给库存内核一个「空」端口提供者(走真实 ifAvailable 默认实现)。 */
    private static ObjectProvider<SubcontractOutboundWakePort> noWake() {
        return provider(null);
    }

    private static ObjectProvider<SubcontractOutboundWakePort> wake(SubcontractOutboundWakePort port) {
        return provider(port);
    }

    private static <T> ObjectProvider<T> provider(T value) {
        return new ObjectProvider<>() {
            @Override
            public T getIfAvailable() {
                return value;
            }
        };
    }

    @Mock
    private StockMovementRepository movementRepo;
    @Mock
    private StockBalanceRepository balanceRepo;
    @Mock
    private TxSessionVars tx;
    @Mock
    private InventoryMutationLock inventoryLock;
    @Mock
    private StockWeightAdjustmentRepository weightAdjustments;

    /** ADR-135: 没有重量上下文读取器时只按余额快照定重量(纯单测口径)。 */
    private StockService service(com.uten.imp.features.stock.valuation.StockValuationCoordinator valuation,
                                 ObjectProvider<SubcontractOutboundWakePort> wake) {
        return service(valuation, wake, null);
    }

    private StockService service(com.uten.imp.features.stock.valuation.StockValuationCoordinator valuation,
                                 ObjectProvider<SubcontractOutboundWakePort> wake,
                                 StockWeightContextReader reader) {
        return new StockService(movementRepo, balanceRepo, tx, inventoryLock, valuation,
                org.mockito.Mockito.mock(GoodsOwningWarehouseSyncService.class), wake,
                provider(reader), provider(weightAdjustments));
    }

    private StockService service() {
        return service(quantityTestValuation(), noWake());
    }

    private static StockBalance balance(String qty, String weight) {
        StockBalance balance = new StockBalance();
        balance.setQty(new BigDecimal(qty));
        balance.setWeight(weight == null ? null : new BigDecimal(weight));
        return balance;
    }

    @Test
    void outboundPersistsCanonicalCostInsteadOfCallerSellingAmount() {
        UUID warehouse=UUID.randomUUID(),goods=UUID.randomUUID();
        StockBalance balance=new StockBalance();balance.setQty(new BigDecimal("20"));balance.setAmountLocal(new BigDecimal("600"));
        when(balanceRepo.readPhysicalSnapshot(warehouse,goods,null)).thenReturn(java.util.List.of(snapshot(balance)));
        when(balanceRepo.warehouseAvailableBase(warehouse,goods,null)).thenReturn(new BigDecimal("20"));
        var valuation=org.mockito.Mockito.mock(com.uten.imp.features.stock.valuation.StockValuationCoordinator.class);
        when(valuation.value(org.mockito.ArgumentMatchers.any(),org.mockito.ArgumentMatchers.any(),org.mockito.ArgumentMatchers.any(),org.mockito.ArgumentMatchers.any()))
                .thenAnswer(invocation->new com.uten.imp.application.port.InventoryValuationPort.MovementValue(UUID.randomUUID(),invocation.getArgument(0),
                        UUID.randomUUID(),UUID.randomUUID(),new BigDecimal("600"),com.uten.imp.application.port.InventoryValuationPort.State.FINAL,false));
        var service=service(valuation, noWake());
        service.recordMovement(new StockService.MovementRequest(OffsetDateTime.now(),StockService.TYPE_SALES_OUT,"SALES_SHIPMENT",
                UUID.randomUUID(),UUID.randomUUID(),goods,null,warehouse,StockService.DIR_OUT,new BigDecimal("20"),
                UUID.randomUUID(),BigDecimal.ONE,new BigDecimal("2000"),null,null));
        var movement=org.mockito.ArgumentCaptor.forClass(StockMovement.class);verify(movementRepo).save(movement.capture());
        assertEquals(new BigDecimal("600"),movement.getValue().getAmountLocal());
        // 数量发完: 原重量未知也归零起算(重量账不因此挡出库)。
        verify(balanceRepo).upsertBalance(org.mockito.ArgumentMatchers.eq(warehouse),org.mockito.ArgumentMatchers.eq(goods),org.mockito.ArgumentMatchers.isNull(),
                org.mockito.ArgumentMatchers.eq(new BigDecimal("-20")),org.mockito.ArgumentMatchers.eq(new BigDecimal("-600")),
                org.mockito.ArgumentMatchers.argThat(weight -> weight != null && weight.signum() == 0),
                org.mockito.ArgumentMatchers.eq(false),org.mockito.ArgumentMatchers.any());
    }

    @Test
    void outboundCannotCreateNegativeWarehouseBalance() {
        UUID warehouseId = UUID.randomUUID();
        UUID goodsId = UUID.randomUUID();
        StockBalance balance = new StockBalance();
        balance.setWarehouseId(warehouseId);
        balance.setGoodsId(goodsId);
        balance.setQty(new BigDecimal("4"));
        when(balanceRepo.readPhysicalSnapshot(
                warehouseId, goodsId, null)).thenReturn(java.util.List.of(snapshot(balance)));
        StockService service = service();

        ApiException error = assertThrows(
                ApiException.class,
                () -> service.recordMovement(request(
                        warehouseId, goodsId, StockService.DIR_OUT, "5")));

        assertEquals(ErrorCode.CONFLICT, error.getCode());
        verify(movementRepo, never()).save(org.mockito.ArgumentMatchers.any());
        verifyNoBalanceUpsert();
    }

    @Test
    void inboundDoesNotRequireAnExistingBalance() {
        UUID warehouseId = UUID.randomUUID();
        UUID goodsId = UUID.randomUUID();
        StockService service = service();

        service.recordMovement(request(
                warehouseId, goodsId, StockService.DIR_IN, "5"));

        verify(movementRepo).save(org.mockito.ArgumentMatchers.any());
        verify(balanceRepo).upsertBalance(
                org.mockito.ArgumentMatchers.eq(warehouseId),
                org.mockito.ArgumentMatchers.eq(goodsId),
                org.mockito.ArgumentMatchers.isNull(),
                org.mockito.ArgumentMatchers.eq(new BigDecimal("5")),
                org.mockito.ArgumentMatchers.eq(BigDecimal.ZERO),
                org.mockito.ArgumentMatchers.isNull(),
                org.mockito.ArgumentMatchers.eq(false),
                org.mockito.ArgumentMatchers.any(OffsetDateTime.class));
    }

    @Test
    void actualTotalWeightIsPersistedAndNotMultipliedByUnitRate() {
        UUID warehouseId = UUID.randomUUID();
        UUID goodsId = UUID.randomUUID();
        StockService service = service();
        BigDecimal actualWeight = new BigDecimal("5.0000");

        StockService.PostedMovement posted = service.recordMovement(new StockService.MovementRequest(
                OffsetDateTime.now(), StockService.TYPE_PURCHASE_RECEIPT,
                "TEST", UUID.randomUUID(), UUID.randomUUID(),
                goodsId, null, warehouseId, StockService.DIR_IN,
                new BigDecimal("20"), UUID.randomUUID(), new BigDecimal("10"),
                BigDecimal.ZERO, null, CapturedWeight.measured(actualWeight)));

        var movement = org.mockito.ArgumentCaptor.forClass(StockMovement.class);
        verify(movementRepo).save(movement.capture());
        assertEquals(actualWeight, movement.getValue().getWeight());
        assertEquals("MEASURED", movement.getValue().getWeightSource());
        assertEquals(actualWeight, movement.getValue().getBalanceWeightAfter());
        assertEquals(new StockService.PostedMovement(movement.getValue().getId(), actualWeight,
                WeightSource.MEASURED, false), posted);
        verify(balanceRepo).upsertBalance(
                warehouseId, goodsId, null, new BigDecimal("20"),
                BigDecimal.ZERO, actualWeight, false,
                movement.getValue().getTransactionDate());
    }

    @Test
    void negativeActualWeightIsRejectedBeforeWritingLedger() {
        StockService service = service();

        assertThrows(IllegalArgumentException.class, () -> service.recordMovement(
                new StockService.MovementRequest(
                        OffsetDateTime.now(), StockService.TYPE_PURCHASE_RECEIPT,
                        "TEST", UUID.randomUUID(), UUID.randomUUID(),
                        UUID.randomUUID(), null, UUID.randomUUID(),
                        StockService.DIR_IN, BigDecimal.ONE, UUID.randomUUID(),
                        BigDecimal.ONE, BigDecimal.ZERO, null,
                        new CapturedWeight(new BigDecimal("-0.0001"), WeightSource.MEASURED))));

        verify(movementRepo, never()).save(org.mockito.ArgumentMatchers.any());
        verifyNoBalanceUpsert();
    }

    /** ADR-135: 实称比账面重也照常出库(重量永远不挡数量), 余额用尾差行按本次均重重新估。 */
    @Test
    void outboundHeavierThanBookWeightNeverBlocksAndReEstimatesTheRemainder() {
        UUID warehouseId = UUID.randomUUID();
        UUID goodsId = UUID.randomUUID();
        StockBalance balance = balance("10", "4.5000");
        when(balanceRepo.readPhysicalSnapshot(
                warehouseId, goodsId, null)).thenReturn(java.util.List.of(snapshot(balance)));
        when(balanceRepo.warehouseAvailableBase(warehouseId, goodsId, null)).thenReturn(new BigDecimal("10"));
        StockService service = service();

        StockService.PostedMovement posted = service.recordMovement(new StockService.MovementRequest(
                OffsetDateTime.now(), StockService.TYPE_SALES_OUT,
                "TEST", UUID.randomUUID(), UUID.randomUUID(),
                goodsId, null, warehouseId, StockService.DIR_OUT,
                BigDecimal.ONE, UUID.randomUUID(), BigDecimal.ONE,
                BigDecimal.ZERO, null, CapturedWeight.measured(new BigDecimal("5.0000"))));

        assertEquals(new BigDecimal("5.0000"), posted.weightKg());
        assertEquals(WeightSource.MEASURED, posted.weightSource());
        // 尾差行先写: 账面 4.5 纠正到 50(= 剩 9 个按本次均重 45 + 本次 5), 流水出 5 后正好落在 45。
        var ordered = org.mockito.Mockito.inOrder(weightAdjustments, movementRepo);
        var residual = org.mockito.ArgumentCaptor.forClass(StockWeightAdjustmentRepository.NewAdjustment.class);
        var movement = org.mockito.ArgumentCaptor.forClass(StockMovement.class);
        ordered.verify(weightAdjustments).insert(residual.capture());
        ordered.verify(movementRepo).save(movement.capture());
        assertEquals(new BigDecimal("45.0000"), movement.getValue().getBalanceWeightAfter());
        assertEquals("RESIDUAL", residual.getValue().kind());
        assertEquals(new BigDecimal("4.5000"), residual.getValue().weightBefore());
        assertEquals(new BigDecimal("50.0000"), residual.getValue().weightAfter());
        assertEquals(movement.getValue().getId(), residual.getValue().movementId());
        verify(balanceRepo).upsertBalance(
                org.mockito.ArgumentMatchers.eq(warehouseId),
                org.mockito.ArgumentMatchers.eq(goodsId),
                org.mockito.ArgumentMatchers.isNull(),
                org.mockito.ArgumentMatchers.eq(new BigDecimal("-1")),
                org.mockito.ArgumentMatchers.eq(BigDecimal.ZERO),
                org.mockito.ArgumentMatchers.eq(new BigDecimal("45.0000")),
                org.mockito.ArgumentMatchers.eq(true),
                org.mockito.ArgumentMatchers.any(OffsetDateTime.class));
    }

    @Test
    void unweighedOutboundTakesTheBookAverageWeight() {
        UUID warehouseId = UUID.randomUUID();
        UUID goodsId = UUID.randomUUID();
        when(balanceRepo.readPhysicalSnapshot(warehouseId, goodsId, null))
                .thenReturn(java.util.List.of(snapshot(balance("10", "4.5000"))));
        StockService service = service();

        StockService.PostedMovement posted = service.recordMovement(request(
                warehouseId, goodsId, StockService.DIR_OUT, "4", StockService.TYPE_CHECK_LOSS));

        assertEquals(new BigDecimal("1.8000"), posted.weightKg());
        assertEquals(WeightSource.AVERAGE, posted.weightSource());
        verify(balanceRepo).upsertBalance(
                org.mockito.ArgumentMatchers.eq(warehouseId),
                org.mockito.ArgumentMatchers.eq(goodsId),
                org.mockito.ArgumentMatchers.isNull(),
                org.mockito.ArgumentMatchers.eq(new BigDecimal("-4")),
                org.mockito.ArgumentMatchers.eq(BigDecimal.ZERO),
                org.mockito.ArgumentMatchers.eq(new BigDecimal("2.7000")),
                org.mockito.ArgumentMatchers.eq(false),
                org.mockito.ArgumentMatchers.any(OffsetDateTime.class));
        org.mockito.Mockito.verifyNoInteractions(weightAdjustments);
    }

    @Test
    void emptyDimensionWithStaleWeightIsAnchoredToZeroBeforeTheMovement() {
        UUID warehouseId = UUID.randomUUID();
        UUID goodsId = UUID.randomUUID();
        when(balanceRepo.readPhysicalSnapshot(warehouseId, goodsId, null))
                .thenReturn(java.util.List.of(snapshot(balance("0", null))));
        StockService service = service();

        service.recordMovement(new StockService.MovementRequest(
                OffsetDateTime.now(), StockService.TYPE_PURCHASE_RECEIPT,
                "TEST", UUID.randomUUID(), UUID.randomUUID(),
                goodsId, null, warehouseId, StockService.DIR_IN,
                new BigDecimal("4"), UUID.randomUUID(), BigDecimal.ONE,
                BigDecimal.ZERO, null, CapturedWeight.measured(new BigDecimal("2"))));

        var ordered = org.mockito.Mockito.inOrder(weightAdjustments, movementRepo, balanceRepo);
        var anchor = org.mockito.ArgumentCaptor.forClass(StockWeightAdjustmentRepository.NewAdjustment.class);
        ordered.verify(weightAdjustments).insert(anchor.capture());
        ordered.verify(movementRepo).save(org.mockito.ArgumentMatchers.any());
        ordered.verify(balanceRepo).upsertBalance(
                org.mockito.ArgumentMatchers.eq(warehouseId),
                org.mockito.ArgumentMatchers.eq(goodsId),
                org.mockito.ArgumentMatchers.isNull(),
                org.mockito.ArgumentMatchers.eq(new BigDecimal("4")),
                org.mockito.ArgumentMatchers.eq(BigDecimal.ZERO),
                org.mockito.ArgumentMatchers.eq(new BigDecimal("2.0000")),
                org.mockito.ArgumentMatchers.eq(false),
                org.mockito.ArgumentMatchers.any(OffsetDateTime.class));
        assertEquals("ANCHOR", anchor.getValue().kind());
        assertEquals(null, anchor.getValue().weightBefore());
        assertEquals(0, anchor.getValue().weightAfter().signum());
    }

    @Test
    void massUnitGoodsTakeTheExactWeightFromTheContextReader() {
        UUID warehouseId = UUID.randomUUID();
        UUID goodsId = UUID.randomUUID();
        StockWeightContextReader reader = org.mockito.Mockito.mock(StockWeightContextReader.class);
        when(reader.read(org.mockito.ArgumentMatchers.any(), org.mockito.ArgumentMatchers.any(),
                org.mockito.ArgumentMatchers.any(), org.mockito.ArgumentMatchers.anyBoolean(),
                org.mockito.ArgumentMatchers.anyBoolean()))
                .thenReturn(new StockWeightResolver.WeightContext(BigDecimal.ZERO, null, false, false,
                        new BigDecimal("0.5"), null, null, null, null));
        StockService service = service(quantityTestValuation(), noWake(), reader);

        StockService.PostedMovement posted = service.recordMovement(new StockService.MovementRequest(
                OffsetDateTime.now(), StockService.TYPE_PURCHASE_RECEIPT,
                "TEST", UUID.randomUUID(), UUID.randomUUID(),
                goodsId, null, warehouseId, StockService.DIR_IN,
                new BigDecimal("3"), UUID.randomUUID(), BigDecimal.ONE,
                BigDecimal.ZERO, null, CapturedWeight.measured(new BigDecimal("9"))));

        // 斤计量的货品: 3 斤 = 1.5 千克, 客户端带的实称不参与(精确优先)。
        assertEquals(new BigDecimal("1.5000"), posted.weightKg());
        assertEquals(WeightSource.EXACT, posted.weightSource());
        verify(balanceRepo).upsertBalance(
                org.mockito.ArgumentMatchers.eq(warehouseId),
                org.mockito.ArgumentMatchers.eq(goodsId),
                org.mockito.ArgumentMatchers.isNull(),
                org.mockito.ArgumentMatchers.eq(new BigDecimal("3")),
                org.mockito.ArgumentMatchers.eq(BigDecimal.ZERO),
                org.mockito.ArgumentMatchers.eq(new BigDecimal("1.5000")),
                org.mockito.ArgumentMatchers.eq(false),
                org.mockito.ArgumentMatchers.any(OffsetDateTime.class));
    }

    @Test
    void normalOutboundCannotConsumeReservedOrSafetyStock() {
        UUID warehouseId = UUID.randomUUID();
        UUID goodsId = UUID.randomUUID();
        StockBalance balance = new StockBalance();
        balance.setWarehouseId(warehouseId);
        balance.setGoodsId(goodsId);
        balance.setQty(new BigDecimal("10"));
        when(balanceRepo.readPhysicalSnapshot(
                warehouseId, goodsId, null)).thenReturn(java.util.List.of(snapshot(balance)));
        when(balanceRepo.warehouseAvailableBase(warehouseId, goodsId, null))
                .thenReturn(new BigDecimal("2"));
        StockService service = service();

        ApiException error = assertThrows(
                ApiException.class,
                () -> service.recordMovement(request(
                        warehouseId, goodsId, StockService.DIR_OUT, "3",
                        StockService.TYPE_SALES_OUT)));

        assertEquals(ErrorCode.CONFLICT, error.getCode());
        verify(movementRepo, never()).save(org.mockito.ArgumentMatchers.any());
    }

    @Test
    void reversalReturnTypeBypassesMovableButRespectsNonNegativeFloor() {
        // KS-P1-1：红冲/退货类 DIR_OUT（如 PURCHASE_RECEIPT 反向）只守"非负底线"（在手 ≥ 本次），
        // 不守 movable（已扣预留/安全）——撤销入库/退货不应被他人预留卡死。
        UUID warehouseId = UUID.randomUUID();
        UUID goodsId = UUID.randomUUID();
        StockBalance balance = new StockBalance();
        balance.setWarehouseId(warehouseId);
        balance.setGoodsId(goodsId);
        balance.setQty(new BigDecimal("10")); // 在手 10，但 movable 被预留/安全压到 2
        when(balanceRepo.readPhysicalSnapshot(
                warehouseId, goodsId, null)).thenReturn(java.util.List.of(snapshot(balance)));
        StockService service = service();

        // qty 3 ≤ 在手 10 → 过非负底线；PURCHASE_RECEIPT 在 REVERSAL_RETURN_TYPES → 跳过 movable
        service.recordMovement(request(
                warehouseId, goodsId, StockService.DIR_OUT, "3",
                StockService.TYPE_PURCHASE_RECEIPT));

        verify(balanceRepo, never()).warehouseAvailableBase(warehouseId, goodsId, null);
        verify(movementRepo).save(org.mockito.ArgumentMatchers.any());
    }

    @Test
    void provenProductionIssueUsesItsAllocatedLeafWithoutSubtractingSafetyAgain() {
        var req = productionIssueRequest();
        stockAt(req, "30");
        when(balanceRepo.unboundProductionIssueQuantity(org.mockito.ArgumentMatchers.any(),
                org.mockito.ArgumentMatchers.eq(req.sourceDocId()), org.mockito.ArgumentMatchers.eq(req.sourceItemId()),
                org.mockito.ArgumentMatchers.eq(req.warehouseId()), org.mockito.ArgumentMatchers.eq(req.goodsId()),
                org.mockito.ArgumentMatchers.isNull(), org.mockito.ArgumentMatchers.eq(req.unitId()),
                org.mockito.ArgumentMatchers.eq(BigDecimal.ONE))).thenReturn(new BigDecimal("30"));
        when(balanceRepo.warehouseUnreservedBase(req.warehouseId(), req.goodsId(), null)).thenReturn(new BigDecimal("30"));

        service().recordMovement(req);

        verify(balanceRepo, never()).warehouseAvailableBase(req.warehouseId(), req.goodsId(), null);
        verify(movementRepo).save(org.mockito.ArgumentMatchers.any());
    }

    @Test
    void productionEventWithoutExactUnboundPostingCannotBypassStockRules() {
        var req = productionIssueRequest();
        stockAt(req, "30");
        StockService service = service();
        assertThrows(ApiException.class, () -> service.recordMovement(req));
        verify(balanceRepo, never()).warehouseUnreservedBase(org.mockito.ArgumentMatchers.any(),
                org.mockito.ArgumentMatchers.any(), org.mockito.ArgumentMatchers.any());
        verify(movementRepo, never()).save(org.mockito.ArgumentMatchers.any());
    }

    @Test
    void provenProductionIssueStillCannotTakeAnotherOrdersHardReservation() {
        var req = productionIssueRequest();
        stockAt(req, "30");
        when(balanceRepo.unboundProductionIssueQuantity(org.mockito.ArgumentMatchers.any(),
                org.mockito.ArgumentMatchers.eq(req.sourceDocId()), org.mockito.ArgumentMatchers.eq(req.sourceItemId()),
                org.mockito.ArgumentMatchers.eq(req.warehouseId()), org.mockito.ArgumentMatchers.eq(req.goodsId()),
                org.mockito.ArgumentMatchers.isNull(), org.mockito.ArgumentMatchers.eq(req.unitId()),
                org.mockito.ArgumentMatchers.eq(BigDecimal.ONE))).thenReturn(new BigDecimal("30"));
        when(balanceRepo.warehouseUnreservedBase(req.warehouseId(), req.goodsId(), null)).thenReturn(new BigDecimal("29"));
        StockService service = service();
        assertThrows(ApiException.class, () -> service.recordMovement(req));
        verify(movementRepo, never()).save(org.mockito.ArgumentMatchers.any());
    }

    private void stockAt(StockService.MovementRequest req, String qty) {
        StockBalance balance = new StockBalance();
        balance.setQty(new BigDecimal(qty));
        when(balanceRepo.readPhysicalSnapshot(req.warehouseId(), req.goodsId(), null))
                .thenReturn(java.util.List.of(snapshot(balance)));
    }

    private StockService.MovementRequest productionIssueRequest() {
        return new StockService.MovementRequest(OffsetDateTime.now(), (short) 5, "STOCK_DOC",
                UUID.randomUUID(), UUID.randomUUID(), UUID.randomUUID(), null, UUID.randomUUID(),
                StockService.DIR_OUT, new BigDecimal("30"), UUID.randomUUID(), BigDecimal.ONE,
                null, null, null,
                new com.uten.imp.application.port.InventoryMovementCostReference.ProductionMaterialEvent(UUID.randomUUID()));
    }

    @Test
    void countLossCanRecordPhysicalRealityBelowProtectedQuantity() {
        UUID warehouseId = UUID.randomUUID();
        UUID goodsId = UUID.randomUUID();
        StockBalance balance = new StockBalance();
        balance.setWarehouseId(warehouseId);
        balance.setGoodsId(goodsId);
        balance.setQty(new BigDecimal("10"));
        when(balanceRepo.readPhysicalSnapshot(
                warehouseId, goodsId, null)).thenReturn(java.util.List.of(snapshot(balance)));
        StockService service = service();

        service.recordMovement(request(
                warehouseId, goodsId, StockService.DIR_OUT, "3",
                StockService.TYPE_CHECK_LOSS));

        verify(balanceRepo, never()).warehouseAvailableBase(
                warehouseId, goodsId, null);
        verify(movementRepo).save(org.mockito.ArgumentMatchers.any());
        verify(balanceRepo).upsertBalance(
                org.mockito.ArgumentMatchers.eq(warehouseId),
                org.mockito.ArgumentMatchers.eq(goodsId),
                org.mockito.ArgumentMatchers.isNull(),
                org.mockito.ArgumentMatchers.eq(new BigDecimal("-3")),
                org.mockito.ArgumentMatchers.eq(BigDecimal.ZERO),
                org.mockito.ArgumentMatchers.isNull(),
                org.mockito.ArgumentMatchers.eq(false),
                org.mockito.ArgumentMatchers.any(OffsetDateTime.class));
    }

    @Test
    void inboundWakesSubcontractOutboundOnceWithTheStockedDimension() {
        UUID warehouseId = UUID.randomUUID();
        UUID goodsId = UUID.randomUUID();
        UUID colorId = UUID.randomUUID();
        SubcontractOutboundWakePort port = org.mockito.Mockito.mock(SubcontractOutboundWakePort.class);
        StockService service = service(quantityTestValuation(), wake(port));
        StockService.MovementRequest req = new StockService.MovementRequest(
                OffsetDateTime.now(), StockService.TYPE_PURCHASE_RECEIPT, "TEST",
                UUID.randomUUID(), UUID.randomUUID(), goodsId, colorId, warehouseId,
                StockService.DIR_IN, new BigDecimal("5"), UUID.randomUUID(), BigDecimal.ONE,
                BigDecimal.ZERO, null, null);

        service.recordMovement(req);

        // ADR-143: 库存内核每笔入库登记一次领料重算, 维度就是这笔入库的货品/颜色/实收仓。
        verify(port, org.mockito.Mockito.times(1)).enqueueDrawRecheck(java.util.List.of(
                new SubcontractOutboundWakePort.StockedDimension(goodsId, colorId, warehouseId)));
    }

    @Test
    void inboundWaitsForSourceAttributionAndDeduplicatesBeforeCommit() {
        UUID warehouseId = UUID.randomUUID();
        UUID goodsId = UUID.randomUUID();
        SubcontractOutboundWakePort port = org.mockito.Mockito.mock(SubcontractOutboundWakePort.class);
        StockService service = service(quantityTestValuation(), wake(port));
        org.springframework.transaction.support.TransactionSynchronizationManager.initSynchronization();
        try {
            service.recordMovement(request(warehouseId, goodsId, StockService.DIR_IN, "5"));
            service.recordMovement(request(warehouseId, goodsId, StockService.DIR_IN, "3"));
            org.mockito.Mockito.verifyNoInteractions(port);
            var synchronizations = org.springframework.transaction.support.TransactionSynchronizationManager.getSynchronizations();
            org.junit.jupiter.api.Assertions.assertEquals(1, synchronizations.size());
            synchronizations.forEach(sync -> sync.beforeCommit(false));
            verify(port).enqueueDrawRecheck(List.of(
                    new SubcontractOutboundWakePort.StockedDimension(goodsId, null, warehouseId)));
        } finally {
            org.springframework.transaction.support.TransactionSynchronizationManager.clearSynchronization();
        }
    }

    @Test
    void rollbackNeverWakesAndBeforeCommitFailurePropagates() {
        UUID warehouseId = UUID.randomUUID();
        UUID goodsId = UUID.randomUUID();
        SubcontractOutboundWakePort port = org.mockito.Mockito.mock(SubcontractOutboundWakePort.class);
        StockService service = service(quantityTestValuation(), wake(port));
        org.springframework.transaction.support.TransactionSynchronizationManager.initSynchronization();
        try {
            service.recordMovement(request(warehouseId, goodsId, StockService.DIR_IN, "5"));
            var synchronization = org.springframework.transaction.support.TransactionSynchronizationManager.getSynchronizations().getFirst();
            synchronization.afterCompletion(org.springframework.transaction.support.TransactionSynchronization.STATUS_ROLLED_BACK);
            org.mockito.Mockito.verifyNoInteractions(port);
            org.mockito.Mockito.doThrow(new IllegalStateException("wake failed"))
                    .when(port).enqueueDrawRecheck(org.mockito.ArgumentMatchers.any());
            assertThrows(IllegalStateException.class, () -> synchronization.beforeCommit(false));
        } finally {
            org.springframework.transaction.support.TransactionSynchronizationManager.clearSynchronization();
        }
    }

    @Test
    void outboundDoesNotWakeSubcontractOutbound() {
        UUID warehouseId = UUID.randomUUID();
        UUID goodsId = UUID.randomUUID();
        stockAt(request(warehouseId, goodsId, StockService.DIR_OUT, "3"), "10");
        SubcontractOutboundWakePort port = org.mockito.Mockito.mock(SubcontractOutboundWakePort.class);
        StockService service = service(quantityTestValuation(), wake(port));

        // 盘亏出库不守可动用量, 只需库存快照, 避免多余 stub 被严格模式判为未使用。
        service.recordMovement(request(
                warehouseId, goodsId, StockService.DIR_OUT, "3", StockService.TYPE_CHECK_LOSS));

        verify(port, never()).enqueueDrawRecheck(org.mockito.ArgumentMatchers.any());
        verify(movementRepo).save(org.mockito.ArgumentMatchers.any());
    }

    @Test
    void inboundWithoutSubcontractModuleStillRecordsStock() {
        UUID warehouseId = UUID.randomUUID();
        UUID goodsId = UUID.randomUUID();
        StockService service = service();

        assertDoesNotThrow(() -> service.recordMovement(
                request(warehouseId, goodsId, StockService.DIR_IN, "5")));

        verify(movementRepo).save(org.mockito.ArgumentMatchers.any());
        verify(balanceRepo).upsertBalance(
                org.mockito.ArgumentMatchers.eq(warehouseId),
                org.mockito.ArgumentMatchers.eq(goodsId),
                org.mockito.ArgumentMatchers.isNull(),
                org.mockito.ArgumentMatchers.eq(new BigDecimal("5")),
                org.mockito.ArgumentMatchers.eq(BigDecimal.ZERO),
                org.mockito.ArgumentMatchers.isNull(),
                org.mockito.ArgumentMatchers.eq(false),
                org.mockito.ArgumentMatchers.any(OffsetDateTime.class));
    }

    @Test
    void wakeFailureFailsTheInboundMovementClosed() {
        UUID warehouseId = UUID.randomUUID();
        UUID goodsId = UUID.randomUUID();
        SubcontractOutboundWakePort port = org.mockito.Mockito.mock(SubcontractOutboundWakePort.class);
        org.mockito.Mockito.doThrow(new IllegalStateException("wake failed"))
                .when(port).enqueueDrawRecheck(org.mockito.ArgumentMatchers.any());
        StockService service = service(quantityTestValuation(), wake(port));

        // ADR-143 fail-closed: 追加重算事件失败就整笔入库抛出(同事务回滚), 不吞错。
        assertThrows(IllegalStateException.class, () -> service.recordMovement(
                request(warehouseId, goodsId, StockService.DIR_IN, "5")));
    }

    private void verifyNoBalanceUpsert() {
        verify(balanceRepo, never()).upsertBalance(
                org.mockito.ArgumentMatchers.any(),
                org.mockito.ArgumentMatchers.any(),
                org.mockito.ArgumentMatchers.any(),
                org.mockito.ArgumentMatchers.any(),
                org.mockito.ArgumentMatchers.any(),
                org.mockito.ArgumentMatchers.any(),
                org.mockito.ArgumentMatchers.anyBoolean(),
                org.mockito.ArgumentMatchers.any());
    }

    private static StockService.MovementRequest request(
            UUID warehouseId, UUID goodsId, short direction, String qty) {
        return request(
                warehouseId, goodsId, direction, qty,
                StockService.TYPE_PURCHASE_RECEIPT);
    }

    private static StockService.MovementRequest request(
            UUID warehouseId, UUID goodsId, short direction, String qty,
            short movementType) {
        return new StockService.MovementRequest(
                OffsetDateTime.now(),
                movementType,
                "TEST",
                UUID.randomUUID(),
                UUID.randomUUID(),
                goodsId,
                null,
                warehouseId,
                direction,
                new BigDecimal(qty),
                UUID.randomUUID(),
                BigDecimal.ONE,
                BigDecimal.ZERO,
                null,
                null);
    }
}

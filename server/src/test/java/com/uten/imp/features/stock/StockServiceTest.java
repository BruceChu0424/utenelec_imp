package com.uten.imp.features.stock;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.TxSessionVars;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.Optional;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class StockServiceTest {
    private static StockBalanceRepository.PhysicalSnapshot snapshot(StockBalance balance){
        return new StockBalanceRepository.PhysicalSnapshot(){
            public BigDecimal getQty(){return balance.getQty();}
            public BigDecimal getWeight(){return balance.getWeight();}
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

    @Mock
    private StockMovementRepository movementRepo;
    @Mock
    private StockBalanceRepository balanceRepo;
    @Mock
    private TxSessionVars tx;
    @Mock
    private InventoryMutationLock inventoryLock;

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
        var service=new StockService(movementRepo,balanceRepo,tx,inventoryLock,valuation);
        service.recordMovement(new StockService.MovementRequest(OffsetDateTime.now(),StockService.TYPE_SALES_OUT,"SALES_SHIPMENT",
                UUID.randomUUID(),UUID.randomUUID(),goods,null,warehouse,StockService.DIR_OUT,new BigDecimal("20"),
                UUID.randomUUID(),BigDecimal.ONE,new BigDecimal("2000"),null));
        var movement=org.mockito.ArgumentCaptor.forClass(StockMovement.class);verify(movementRepo).save(movement.capture());
        assertEquals(new BigDecimal("600"),movement.getValue().getAmountLocal());
        verify(balanceRepo).upsertBalance(org.mockito.ArgumentMatchers.eq(warehouse),org.mockito.ArgumentMatchers.eq(goods),org.mockito.ArgumentMatchers.isNull(),
                org.mockito.ArgumentMatchers.eq(new BigDecimal("-20")),org.mockito.ArgumentMatchers.eq(new BigDecimal("-600")),
                org.mockito.ArgumentMatchers.isNull(),org.mockito.ArgumentMatchers.any());
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
        StockService service =
                new StockService(movementRepo, balanceRepo, tx, inventoryLock, quantityTestValuation());

        ApiException error = assertThrows(
                ApiException.class,
                () -> service.recordMovement(request(
                        warehouseId, goodsId, StockService.DIR_OUT, "5")));

        assertEquals(ErrorCode.CONFLICT, error.getCode());
        verify(movementRepo, never()).save(org.mockito.ArgumentMatchers.any());
        verify(balanceRepo, never()).upsertBalance(
                org.mockito.ArgumentMatchers.any(),
                org.mockito.ArgumentMatchers.any(),
                org.mockito.ArgumentMatchers.any(),
                org.mockito.ArgumentMatchers.any(),
                org.mockito.ArgumentMatchers.any(),
                org.mockito.ArgumentMatchers.any(),
                org.mockito.ArgumentMatchers.any());
    }

    @Test
    void inboundDoesNotRequireAnExistingBalance() {
        UUID warehouseId = UUID.randomUUID();
        UUID goodsId = UUID.randomUUID();
        StockService service =
                new StockService(movementRepo, balanceRepo, tx, inventoryLock, quantityTestValuation());

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
                org.mockito.ArgumentMatchers.any(OffsetDateTime.class));
    }

    @Test
    void actualTotalWeightIsPersistedAndNotMultipliedByUnitRate() {
        UUID warehouseId = UUID.randomUUID();
        UUID goodsId = UUID.randomUUID();
        StockService service =
                new StockService(movementRepo, balanceRepo, tx, inventoryLock, quantityTestValuation());
        BigDecimal actualWeight = new BigDecimal("5.0000");

        service.recordMovement(new StockService.MovementRequest(
                OffsetDateTime.now(), StockService.TYPE_PURCHASE_RECEIPT,
                "TEST", UUID.randomUUID(), UUID.randomUUID(),
                goodsId, null, warehouseId, StockService.DIR_IN,
                new BigDecimal("20"), UUID.randomUUID(), new BigDecimal("10"),
                BigDecimal.ZERO, null, actualWeight));

        var movement = org.mockito.ArgumentCaptor.forClass(StockMovement.class);
        verify(movementRepo).save(movement.capture());
        assertEquals(actualWeight, movement.getValue().getWeight());
        verify(balanceRepo).upsertBalance(
                warehouseId, goodsId, null, new BigDecimal("20"),
                BigDecimal.ZERO, actualWeight,
                movement.getValue().getTransactionDate());
    }

    @Test
    void negativeActualWeightIsRejectedBeforeWritingLedger() {
        StockService service =
                new StockService(movementRepo, balanceRepo, tx, inventoryLock, quantityTestValuation());

        assertThrows(IllegalArgumentException.class, () -> service.recordMovement(
                new StockService.MovementRequest(
                        OffsetDateTime.now(), StockService.TYPE_PURCHASE_RECEIPT,
                        "TEST", UUID.randomUUID(), UUID.randomUUID(),
                        UUID.randomUUID(), null, UUID.randomUUID(),
                        StockService.DIR_IN, BigDecimal.ONE, UUID.randomUUID(),
                        BigDecimal.ONE, BigDecimal.ZERO, null,
                        new BigDecimal("-0.0001"))));

        verify(movementRepo, never()).save(org.mockito.ArgumentMatchers.any());
        verify(balanceRepo, never()).upsertBalance(
                org.mockito.ArgumentMatchers.any(),
                org.mockito.ArgumentMatchers.any(),
                org.mockito.ArgumentMatchers.any(),
                org.mockito.ArgumentMatchers.any(),
                org.mockito.ArgumentMatchers.any(),
                org.mockito.ArgumentMatchers.any(),
                org.mockito.ArgumentMatchers.any());
    }

    @Test
    void outboundCannotMakeKnownWeightBalanceNegative() {
        UUID warehouseId = UUID.randomUUID();
        UUID goodsId = UUID.randomUUID();
        StockBalance balance = new StockBalance();
        balance.setWarehouseId(warehouseId);
        balance.setGoodsId(goodsId);
        balance.setQty(new BigDecimal("10"));
        balance.setWeight(new BigDecimal("4.5000"));
        when(balanceRepo.readPhysicalSnapshot(
                warehouseId, goodsId, null)).thenReturn(java.util.List.of(snapshot(balance)));
        StockService service =
                new StockService(movementRepo, balanceRepo, tx, inventoryLock, quantityTestValuation());

        ApiException error = assertThrows(
                ApiException.class,
                () -> service.recordMovement(new StockService.MovementRequest(
                        OffsetDateTime.now(), StockService.TYPE_SALES_OUT,
                        "TEST", UUID.randomUUID(), UUID.randomUUID(),
                        goodsId, null, warehouseId, StockService.DIR_OUT,
                        BigDecimal.ONE, UUID.randomUUID(), BigDecimal.ONE,
                        BigDecimal.ZERO, null, new BigDecimal("5.0000"))));

        assertEquals(ErrorCode.CONFLICT, error.getCode());
        verify(movementRepo, never()).save(org.mockito.ArgumentMatchers.any());
        verify(balanceRepo, never()).upsertBalance(
                org.mockito.ArgumentMatchers.any(),
                org.mockito.ArgumentMatchers.any(),
                org.mockito.ArgumentMatchers.any(),
                org.mockito.ArgumentMatchers.any(),
                org.mockito.ArgumentMatchers.any(),
                org.mockito.ArgumentMatchers.any(),
                org.mockito.ArgumentMatchers.any());
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
        StockService service =
                new StockService(movementRepo, balanceRepo, tx, inventoryLock, quantityTestValuation());

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
        StockService service =
                new StockService(movementRepo, balanceRepo, tx, inventoryLock, quantityTestValuation());

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

        new StockService(movementRepo, balanceRepo, tx, inventoryLock, quantityTestValuation()).recordMovement(req);

        verify(balanceRepo, never()).warehouseAvailableBase(req.warehouseId(), req.goodsId(), null);
        verify(movementRepo).save(org.mockito.ArgumentMatchers.any());
    }

    @Test
    void productionEventWithoutExactUnboundPostingCannotBypassStockRules() {
        var req = productionIssueRequest();
        stockAt(req, "30");
        assertThrows(ApiException.class, () -> new StockService(movementRepo, balanceRepo, tx,
                inventoryLock, quantityTestValuation()).recordMovement(req));
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
        assertThrows(ApiException.class, () -> new StockService(movementRepo, balanceRepo, tx,
                inventoryLock, quantityTestValuation()).recordMovement(req));
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
                null, null, null, null,
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
        StockService service =
                new StockService(movementRepo, balanceRepo, tx, inventoryLock, quantityTestValuation());

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
                org.mockito.ArgumentMatchers.any(OffsetDateTime.class));
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

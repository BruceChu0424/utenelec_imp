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

    @Mock
    private StockMovementRepository movementRepo;
    @Mock
    private StockBalanceRepository balanceRepo;
    @Mock
    private TxSessionVars tx;
    @Mock
    private InventoryMutationLock inventoryLock;

    @Test
    void outboundCannotCreateNegativeWarehouseBalance() {
        UUID warehouseId = UUID.randomUUID();
        UUID goodsId = UUID.randomUUID();
        StockBalance balance = new StockBalance();
        balance.setWarehouseId(warehouseId);
        balance.setGoodsId(goodsId);
        balance.setQty(new BigDecimal("4"));
        when(balanceRepo.findByWarehouseIdAndGoodsIdAndColorId(
                warehouseId, goodsId, null)).thenReturn(Optional.of(balance));
        StockService service =
                new StockService(movementRepo, balanceRepo, tx, inventoryLock);

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
                new StockService(movementRepo, balanceRepo, tx, inventoryLock);

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

    private static StockService.MovementRequest request(
            UUID warehouseId, UUID goodsId, short direction, String qty) {
        return new StockService.MovementRequest(
                OffsetDateTime.now(),
                StockService.TYPE_PURCHASE_RECEIPT,
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

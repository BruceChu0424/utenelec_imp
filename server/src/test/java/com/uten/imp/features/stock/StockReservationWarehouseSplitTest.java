package com.uten.imp.features.stock;

import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.ArgumentCaptor;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import java.math.BigDecimal;
import java.util.Collections;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class StockReservationWarehouseSplitTest {

    @Mock private StockReservationRepository repository;
    @Mock private TxSessionVars tx;
    @Mock private EntityManager entityManager;
    @Mock private InventoryMutationLock inventoryLock;

    @Test
    void partialConsumptionKeepsTheRemainderGloballyAvailable() {
        UUID orderItemId = UUID.randomUUID();
        UUID goodsId = UUID.randomUUID();
        UUID warehouseId = UUID.randomUUID();

        Query sourceKeyQuery = org.mockito.Mockito.mock(Query.class);
        when(sourceKeyQuery.setParameter(anyString(), any()))
                .thenReturn(sourceKeyQuery);
        when(sourceKeyQuery.getResultList())
                .thenReturn(Collections.singletonList(
                        new Object[]{goodsId, null}));

        StockReservation source = new StockReservation();
        source.setOrderItemId(orderItemId);
        source.setGoodsId(goodsId);
        source.setQty(new BigDecimal("10"));
        source.setConsumedQty(BigDecimal.ZERO);
        source.setReleasedQty(BigDecimal.ZERO);
        source.setSource(StockReservation.SOURCE_ORDER);
        source.setSourceDocType("SALES_ORDER");
        source.setSourceDocId(UUID.randomUUID());

        Query reservationQuery = org.mockito.Mockito.mock(Query.class);
        when(reservationQuery.setParameter(anyString(), any()))
                .thenReturn(reservationQuery);
        when(reservationQuery.getResultList()).thenReturn(List.of(source));
        when(entityManager.createNativeQuery(anyString()))
                .thenReturn(sourceKeyQuery);
        when(entityManager.createNativeQuery(
                anyString(), eq(StockReservation.class)))
                .thenReturn(reservationQuery);

        StockReservationService service = new StockReservationService(
                repository, tx, entityManager, inventoryLock);

        BigDecimal consumed = service.consumeForOrderItem(
                orderItemId, warehouseId, new BigDecimal("4"));

        assertThat(consumed).isEqualByComparingTo("4");
        ArgumentCaptor<StockReservation> saved =
                ArgumentCaptor.forClass(StockReservation.class);
        verify(repository, org.mockito.Mockito.times(2))
                .save(saved.capture());
        StockReservation consumedRow = saved.getAllValues().get(0);
        StockReservation remainder = saved.getAllValues().get(1);
        assertThat(consumedRow.getWarehouseId()).isEqualTo(warehouseId);
        assertThat(consumedRow.getQty()).isEqualByComparingTo("4");
        assertThat(consumedRow.getConsumedQty())
                .isEqualByComparingTo("4");
        assertThat(consumedRow.getStatus())
                .isEqualTo(StockReservation.STATUS_DONE);
        assertThat(remainder.getWarehouseId()).isNull();
        assertThat(remainder.getQty()).isEqualByComparingTo("6");
        assertThat(remainder.effectiveQty()).isEqualByComparingTo("6");
    }
}

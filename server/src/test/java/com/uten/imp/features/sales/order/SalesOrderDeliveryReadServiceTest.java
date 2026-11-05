package com.uten.imp.features.sales.order;

import com.uten.imp.common.delivery.DeliveryBom;
import com.uten.imp.common.web.ApiException;
import org.junit.jupiter.api.Test;
import java.util.Optional;
import java.util.UUID;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

class SalesOrderDeliveryReadServiceTest {
    @Test void eachReadContextUsesItsExistingDocumentAdmissionAndKeepsTheFrozenHistoricalTree() {
        var orders=mock(SalesOrderService.class);var reviews=mock(SalesOrderFinanceConfirmService.class);
        var items=mock(SalesOrderItemRepository.class);var reader=new SalesOrderDeliveryReadService(orders,reviews,items);
        UUID orderId=UUID.randomUUID(),itemId=UUID.randomUUID();var item=new SalesOrderItem();
        item.setId(itemId);item.setOrderId(orderId);item.setGoodsId(UUID.randomUUID());item.setDeleted(true);
        item.setDeliveryBomSnapshot(new DeliveryBom.Snapshot(1,item.getGoodsId(),"old-reviewed-proof",null));
        when(items.findById(itemId)).thenReturn(Optional.of(item));
        for(var context:SalesOrderDeliveryReadService.Context.values()) {
            var snapshot=reader.read(orderId,itemId,context);
            assertThat(snapshot.missing()).isFalse();assertThat(snapshot.bomFingerprint()).isEqualTo("old-reviewed-proof");
        }
        verify(orders).detail(orderId);verify(reviews).managerReview(orderId);verify(reviews).review(orderId);
    }
    @Test void foreignItemIsRejectedAndMissingLegacyEvidenceNeverReadsCurrentBom() {
        var orders=mock(SalesOrderService.class);var reviews=mock(SalesOrderFinanceConfirmService.class);
        var items=mock(SalesOrderItemRepository.class);var reader=new SalesOrderDeliveryReadService(orders,reviews,items);
        UUID orderId=UUID.randomUUID(),itemId=UUID.randomUUID();var item=new SalesOrderItem();
        item.setOrderId(UUID.randomUUID());when(items.findById(itemId)).thenReturn(Optional.of(item));
        assertThatThrownBy(()->reader.read(orderId,itemId,SalesOrderDeliveryReadService.Context.SALES)).isInstanceOf(ApiException.class);
        item.setOrderId(orderId);var result=reader.read(orderId,itemId,SalesOrderDeliveryReadService.Context.SALES);
        assertThat(result.missing()).isTrue();assertThat(result.root()).isNull();assertThat(result.missingReason()).contains("不能用今天");
    }
}

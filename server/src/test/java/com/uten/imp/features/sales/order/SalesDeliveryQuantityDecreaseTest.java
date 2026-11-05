package com.uten.imp.features.sales.order;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.delivery.BomDeliveryService;
import com.uten.imp.common.delivery.DeliveryPlan;
import com.uten.imp.common.web.ApiException;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import java.math.BigDecimal;
import java.util.List;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.*;

class SalesDeliveryQuantityDecreaseTest {
    @Test void unplannedPhysicalTailCanDecreaseButAnAnalysisOrProcessingSnapshotBlocksIt() {
        var item=new SalesOrderItem();item.setQty(new BigDecimal("100"));item.setShippedQty(new BigDecimal("10"));
        item.setDeliveryPlan(new DeliveryPlan(1,DeliveryPlan.Mode.BOM,DeliveryPlan.Packaging.ORIGINAL,List.of(),List.of(),"snapshot"));
        var em=mock(EntityManager.class);var query=mock(Query.class,RETURNS_SELF);
        when(em.createNativeQuery(anyString())).thenReturn(query);when(query.getSingleResult()).thenReturn(0L,1L);
        var service=new SalesOrderDeliveryService(mock(BomDeliveryService.class),mock(SalesOrderItemRepository.class),em,new ObjectMapper());
        service.requireUncommittedDecrease(item.getId());
        assertThat(SalesOrderService.remainingReductionAfterUncommitted(item,new BigDecimal("30"))).isZero();
        assertThatThrownBy(()->service.requireUncommittedDecrease(item.getId())).isInstanceOf(ApiException.class).hasMessageContaining("分析快照或加工");
        item.setDeliveryPlan(DeliveryPlan.assembled());
        assertThat(SalesOrderService.remainingReductionAfterUncommitted(item,new BigDecimal("30"))).isEqualByComparingTo("30");
        verify(query,times(2)).getSingleResult();
    }
}

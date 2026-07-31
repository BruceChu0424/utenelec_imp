package com.uten.imp.common.integrity;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;

import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class ProductionSupplySourceGuardTest {

    @Test
    void genericCrudFailsClosedWithActionablePurchaseMessage() {
        EntityManager em = mock(EntityManager.class);
        Query query = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.setParameter("headerId", UUID_ZERO)).thenReturn(query);
        when(query.getSingleResult()).thenReturn(1L);

        ProductionSupplySourceGuard guard =
                new ProductionSupplySourceGuard(em);

        assertThatThrownBy(
                () -> guard.requirePurchaseRequestMutable(UUID_ZERO))
                .isInstanceOf(ApiException.class)
                .extracting(error -> ((ApiException) error).getCode())
                .isEqualTo(ErrorCode.CONFLICT);
        assertThatThrownBy(
                () -> guard.requirePurchaseRequestMutable(UUID_ZERO))
                .hasMessageContaining("生产物料需求")
                .hasMessageContaining("生产计划包");
    }

    @Test
    void genericCrudFailsClosedWithActionableSubcontractMessage() {
        EntityManager em = mock(EntityManager.class);
        Query query = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.setParameter("headerId", UUID_ZERO)).thenReturn(query);
        when(query.getSingleResult()).thenReturn(1L);

        ProductionSupplySourceGuard guard =
                new ProductionSupplySourceGuard(em);

        assertThatThrownBy(
                () -> guard.requireSubcontractApplicationMutable(UUID_ZERO))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("委外申请")
                .hasMessageContaining("生产计划包");
    }

    @Test
    void exposesAuthoritativeCapabilitiesForEveryProductionSupplySource() {
        EntityManager em = mock(EntityManager.class);
        Query query = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.setParameter("headerId", UUID_ZERO)).thenReturn(query);
        when(query.getSingleResult()).thenReturn(1L);

        ProductionSupplySourceGuard guard =
                new ProductionSupplySourceGuard(em);

        assertThat(guard.isPurchaseRequestLinked(UUID_ZERO)).isTrue();
        assertThat(guard.isPurchaseOrderLinked(UUID_ZERO)).isTrue();
        assertThat(guard.isSubcontractApplicationLinked(UUID_ZERO)).isTrue();
        assertThat(guard.isSubcontractOrderLinked(UUID_ZERO)).isTrue();

        assertThatThrownBy(() -> guard.requirePurchaseOrderMutable(UUID_ZERO))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("采购订单")
                .hasMessageContaining("生产计划");
        assertThatThrownBy(() -> guard.requireSubcontractOrderMutable(UUID_ZERO))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("委外订单")
                .hasMessageContaining("生产计划");

        when(query.getSingleResult()).thenReturn(0L);
        assertThat(guard.isPurchaseRequestLinked(UUID_ZERO)).isFalse();
    }

    private static final UUID UUID_ZERO = new UUID(0L, 0L);
}

package com.uten.imp.common.integrity;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
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
                .hasMessageContaining("物料分析")
                .hasMessageContaining("生产计划专用流程");
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
                .hasMessageContaining("物料分析")
                .hasMessageContaining("生产计划专用流程");
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

    @Test
    void capabilitiesCoverPreplanDocumentHistoryAndUpstreamOrderSources() {
        EntityManager em = mock(EntityManager.class);
        Query query = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.setParameter("headerId", UUID_ZERO)).thenReturn(query);
        when(query.getSingleResult()).thenReturn(0L);

        ProductionSupplySourceGuard guard =
                new ProductionSupplySourceGuard(em);

        assertThat(guard.isPurchaseRequestLinked(UUID_ZERO)).isFalse();
        assertThat(guard.isPurchaseOrderLinked(UUID_ZERO)).isFalse();
        assertThat(guard.isSubcontractApplicationLinked(UUID_ZERO)).isFalse();
        assertThat(guard.isSubcontractOrderLinked(UUID_ZERO)).isFalse();

        ArgumentCaptor<String> sqlCaptor = ArgumentCaptor.forClass(String.class);
        verify(em, times(4)).createNativeQuery(sqlCaptor.capture());
        List<String> sql = sqlCaptor.getAllValues().stream()
                .map(ProductionSupplySourceGuardTest::normalizedSql)
                .toList();

        assertThat(sql.get(0))
                .contains("production_material_supply_pegs")
                .contains("peg.supply_type = 'purchase_request_item'")
                .contains("from preplan_supply_actions action")
                .contains("action.external_document_type = 'purchase_request'")
                .contains("action.external_document_id = :headerid")
                .doesNotContain("action.status")
                .doesNotContain("action.is_deleted");

        assertThat(sql.get(1))
                .contains("production_material_supply_pegs")
                .contains("peg.supply_type = 'purchase_order_item'")
                .contains("order_item.request_item_id")
                .contains("action.external_document_id = request_item.request_id")
                .doesNotContain("action.status")
                .doesNotContain("action.is_deleted");

        assertThat(sql.get(2))
                .contains("production_material_supply_pegs")
                .contains("peg.supply_type = 'subcontract_application_item'")
                .contains("from preplan_supply_actions action")
                .contains("action.external_document_type = 'subcontract_application'")
                .contains("action.external_document_id = :headerid")
                .doesNotContain("action.status")
                .doesNotContain("action.is_deleted");

        assertThat(sql.get(3))
                .contains("production_material_supply_pegs")
                .contains("peg.supply_type = 'subcontract_order_item'")
                .contains("order_item.application_item_id")
                .contains("action.external_document_id = application_item.application_id")
                .doesNotContain("action.status")
                .doesNotContain("action.is_deleted");
    }

    private static String normalizedSql(String sql) {
        return sql.replaceAll("\\s+", " ").strip().toLowerCase();
    }

    private static final UUID UUID_ZERO = new UUID(0L, 0L);
}

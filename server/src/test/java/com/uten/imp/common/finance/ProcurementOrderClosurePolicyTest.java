package com.uten.imp.common.finance;

import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;

import java.util.UUID;
import java.util.concurrent.atomic.AtomicReference;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class ProcurementOrderClosurePolicyTest {

    @Test
    void newOrdersCloseOnlyFromWarehouseStockedNetQuantity() {
        AtomicReference<String> sql = new AtomicReference<>();
        EntityManager em = mock(EntityManager.class);
        Query query = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            sql.set(invocation.getArgument(0));
            return query;
        });
        when(query.setParameter(anyString(), org.mockito.ArgumentMatchers.any()))
                .thenReturn(query);
        when(query.executeUpdate()).thenReturn(1);

        ProcurementOrderClosurePolicy.recalculate(
                em, ProcurementOrderClosurePolicy.SUBCONTRACT, UUID.randomUUID());

        assertThat(sql.get())
                .contains("UPDATE subcontract_orders")
                .contains("procurement_inspection_items")
                .contains("WHEN inspection.id IS NULL")
                .contains("receipt_item.qty*COALESCE(receipt_item.unit_rate,1)")
                .contains("ELSE inspection.warehouse_stocked_base_qty")
                .doesNotContain("ELSE inspection.passed_base_qty")
                .contains("receipt_doc.status=1")
                .contains("order_item.returned_qty")
                .contains("WHEN inspection.status='REVERSED' THEN 0")
                .contains("COALESCE(order_item.received_qty,0)");
    }

    @Test
    void unknownOrderTypeCannotSelectAnArbitraryTable() {
        assertThatThrownBy(() -> ProcurementOrderClosurePolicy.recalculate(
                mock(EntityManager.class), "DROP_TABLE", UUID.randomUUID()))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("unsupported procurement order type");
    }
}

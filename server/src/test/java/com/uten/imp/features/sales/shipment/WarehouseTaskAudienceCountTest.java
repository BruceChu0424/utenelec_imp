package com.uten.imp.features.sales.shipment;

import com.uten.imp.features.sales.SalesDocumentAccessPolicy;
import jakarta.persistence.EntityManager;
import org.junit.jupiter.api.Test;
import org.springframework.test.util.ReflectionTestUtils;
import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.*;

class WarehouseTaskAudienceCountTest {
    @Test void warehouseReadersDoNotReceivePickingTasksWithoutExecute() {
        var em = mock(EntityManager.class);
        var access = mock(SalesDocumentAccessPolicy.class);
        when(access.hasAuthority("warehouse_sales_outbound:view")).thenReturn(true);
        var service = mock(SalesShipmentService.class, CALLS_REAL_METHODS);
        ReflectionTestUtils.setField(service, "em", em);
        ReflectionTestUtils.setField(service, "accessPolicy", access);
        assertThat(service.countPendingWarehouseWork()).isZero();
        assertThat(service.countWarehouseWorkByStatus()).isEmpty();
        verifyNoInteractions(em);
    }
}

package com.uten.imp.features.warehouse.taskcenter;

import com.uten.imp.application.port.WarehouseTaskRowCountPort;
import com.uten.imp.application.port.WarehouseTaskScopePort;
import com.uten.imp.application.port.WarehouseTaskScopePort.WarehouseTaskScope;
import com.uten.imp.features.operations.workbench.FulfillmentWorkbenchController;
import com.uten.imp.features.sales.shipment.warehouse.WarehouseSalesOutboundController;
import com.uten.imp.features.stock.allocation.ProductionMaterialReturnRequestController;
import com.uten.imp.features.warehouse.finishedin.ProductionFinishedInboundTaskController;
import com.uten.imp.features.warehouse.inbound.WarehouseInboundController;
import com.uten.imp.features.warehouse.outbound.WarehouseSubcontractOutboundController;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class WarehouseTaskRowCountControllerTest {
    @Test void warehouseBadgeEndpointsForwardScopedPhysicalFactsWithoutDocumentDeduplication() {
        UUID warehouse=UUID.randomUUID();
        var scope=new WarehouseTaskScope(true,List.of(warehouse),false);
        var scopes=mock(WarehouseTaskScopePort.class);
        when(scopes.current(warehouse)).thenReturn(scope);
        var rows=mock(WarehouseTaskRowCountPort.class);
        when(rows.inboundExpectations(scope)).thenReturn(Map.of("PURCHASE",2L,"SUBCONTRACT",3L));
        when(rows.finishedInbound(scope)).thenReturn(2L);
        when(rows.subcontractOutbound(scope)).thenReturn(2L);
        when(rows.productionReturn(scope)).thenReturn(2L);
        when(rows.salesOutbound(scope)).thenReturn(Map.of("PENDING_PICK",2L,"LEGACY_PENDING",3L));
        when(rows.productionDraw(scope)).thenReturn(Map.of("OPEN_ANY",5L,"READY_TO_PICK",2L,"PARTIAL",1L,"MATERIALS_TO_DEFINE",2L));

        assertThat(new WarehouseInboundController(null,null,null,null,null,scopes,rows).expectationCount(warehouse))
                .containsEntry("count",5L).containsEntry("PURCHASE",2L).containsEntry("SUBCONTRACT",3L);
        assertThat(new ProductionFinishedInboundTaskController(null,null,scopes,rows).count(warehouse)).containsEntry("count",2L);
        assertThat(new WarehouseSubcontractOutboundController(null,null,scopes,rows).taskCount(warehouse)).containsEntry("count",2L);
        assertThat(new ProductionMaterialReturnRequestController(null,scopes,rows).count(warehouse)).containsEntry("count",2L);
        var sales=new WarehouseSalesOutboundController(null,null,scopes,rows);
        assertThat(sales.pendingCount(warehouse)).containsEntry("count",2L);
        assertThat(sales.counts(warehouse)).containsEntry("PENDING_PICK",2L).containsEntry("LEGACY_PENDING",3L);
        var draw=new FulfillmentWorkbenchController(null,scopes,rows);
        assertThat(draw.warehouseCount(warehouse)).containsEntry("count",5L).containsEntry("pending",5L)
                .containsEntry("READY_TO_PICK",2L).containsEntry("PARTIAL",1L).containsEntry("MATERIALS_TO_DEFINE",2L);
        assertThat(draw.warehouseStatusBreakdown(warehouse)).containsEntry("OPEN_ANY",5L);
    }
}

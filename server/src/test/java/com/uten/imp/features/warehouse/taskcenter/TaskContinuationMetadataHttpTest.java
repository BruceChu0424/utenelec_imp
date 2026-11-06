package com.uten.imp.features.warehouse.taskcenter;

import com.uten.imp.application.port.WarehouseTaskScopePort;
import com.uten.imp.features.operations.workbench.*;
import org.junit.jupiter.api.Test;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;
import java.math.BigDecimal;
import java.util.*;
import static org.mockito.Mockito.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

/** HTTP dispatch/shape regression; existing full security/PG tests retain the authorization proof. */
class TaskContinuationMetadataHttpTest {
    @Test void allFiveExistingListRoutesDefaultToFullMetadataAndOptInToExplicitContinuationShape() throws Exception {
        var fullOps=new FulfillmentWorkbenchPage(List.of(),1,100,0,0,
                new FulfillmentWorkbenchPage.Summary(0,0,0,BigDecimal.ZERO,Map.of(),Map.of(),0),
                new FulfillmentWorkbenchPage.Capabilities(false,false),Map.of(),Map.of());
        var rowsOps=new FulfillmentWorkbenchPage(List.of(),1,100,0,0,null,fullOps.capabilities(),null,null,false);
        var operations=mock(FulfillmentWorkbenchQueryService.class,call->
                call.getMethod().getName().equals("query")?call.getArguments().length==11?rowsOps:fullOps:RETURNS_DEFAULTS.answer(call));
        var scopes=mock(WarehouseTaskScopePort.class);
        when(scopes.currentForRead(org.mockito.ArgumentMatchers.any())).thenReturn(WarehouseTaskScopePort.WarehouseTaskScope.ALL);
        var fullWarehouse=new WarehouseTaskCenterContracts.Page(List.of(),1,100,0,0,Map.of());
        var rowsWarehouse=new WarehouseTaskCenterContracts.Page(List.of(),1,100,0,0,null,false);
        var inbound=mock(WarehouseInboundTaskCenterQueryService.class,call->
                call.getMethod().getName().equals("list")?call.getArguments().length==2?rowsWarehouse:fullWarehouse:RETURNS_DEFAULTS.answer(call));
        var outbound=mock(WarehouseOutboundTaskCenterQueryService.class,call->
                call.getMethod().getName().equals("list")?call.getArguments().length==2?rowsWarehouse:fullWarehouse:RETURNS_DEFAULTS.answer(call));
        var mvc=MockMvcBuilders.standaloneSetup(
                new FulfillmentWorkbenchController(operations,scopes,mock(com.uten.imp.application.port.WarehouseTaskRowCountPort.class)),
                new WarehouseInboundTaskCenterController(inbound,null,null,null,null,null,null),
                new WarehouseOutboundTaskCenterController(outbound,null,null,null,null,null)).build();
        for(String route:List.of("/api/operations/workbench/purchase","/api/operations/workbench/subcontract",
                "/api/operations/workbench/warehouse","/api/warehouse/task-center/inbound","/api/warehouse/task-center/outbound")) {
            mvc.perform(get(route)).andExpect(status().isOk()).andExpect(jsonPath("$.metadataIncluded").value(true));
            mvc.perform(get(route).param("includeMetadata","false")).andExpect(status().isOk())
                    .andExpect(jsonPath("$.metadataIncluded").value(false)).andExpect(jsonPath("$.facets").value(org.hamcrest.Matchers.nullValue()));
        }
    }
}

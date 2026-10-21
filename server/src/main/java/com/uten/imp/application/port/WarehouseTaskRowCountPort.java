package com.uten.imp.application.port;

import com.uten.imp.application.port.WarehouseTaskScopePort.WarehouseTaskScope;
import java.util.Map;

/** Warehouse task badges count the same physical rows as their task-center lists. */
public interface WarehouseTaskRowCountPort {
    Map<String, Long> inboundExpectations(WarehouseTaskScope scope);
    long finishedInbound(WarehouseTaskScope scope);
    long subcontractOutbound(WarehouseTaskScope scope);
    Map<String, Long> salesOutbound(WarehouseTaskScope scope);
    Map<String, Long> productionDraw(WarehouseTaskScope scope);
    long productionReturn(WarehouseTaskScope scope);
}

package com.uten.imp.features.sales.shipment.warehouse;

import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/** Commercial-free sales outbound task row for warehouse staff. */
public record WarehouseSalesOutboundListItem(
        UUID id,
        String billNo,
        LocalDate billDate,
        UUID clientId,
        String clientName,
        UUID warehouseId,
        String warehouseName,
        String warehouseWorkStatus,
        List<String> allowedWarehouseTargets) {

    public WarehouseSalesOutboundListItem {
        allowedWarehouseTargets = allowedWarehouseTargets == null
                ? List.of() : List.copyOf(allowedWarehouseTargets);
    }
}

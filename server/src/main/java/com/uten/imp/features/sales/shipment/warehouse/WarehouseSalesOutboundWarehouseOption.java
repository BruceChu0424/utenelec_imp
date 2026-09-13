package com.uten.imp.features.sales.shipment.warehouse;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

/** Read-only physical stock and exact order-reservation eligibility in each actual warehouse. */
public record WarehouseSalesOutboundWarehouseOption(UUID warehouseId,String warehouseName,boolean canFulfill,
                                                    List<Line> lines) {
    public record Line(UUID shipmentItemId,BigDecimal availableQty,BigDecimal requiredQty) {}
}

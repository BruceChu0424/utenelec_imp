package com.uten.imp.features.sales.shipment.warehouse;

import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;

/** Commercial-free warehouse sales outbound detail. */
public record WarehouseSalesOutboundDetail(
        UUID id,
        String billNo,
        LocalDate billDate,
        UUID clientId,
        String clientName,
        UUID warehouseId,
        String warehouseName,
        String shipAddress,
        String contactPhone,
        String logisticsNo,
        Integer parcelCount,
        String warehouseWorkStatus,
        OffsetDateTime warehouseWorkUpdatedAt,
        OffsetDateTime pickingStartedAt,
        OffsetDateTime pickedAt,
        OffsetDateTime handedOverAt,
        String warehouseExceptionReason,
        List<String> allowedWarehouseTargets,
        List<WarehouseSalesOutboundLine> lines) {

    public WarehouseSalesOutboundDetail {
        allowedWarehouseTargets = allowedWarehouseTargets == null
                ? List.of() : List.copyOf(allowedWarehouseTargets);
        lines = lines == null ? List.of() : List.copyOf(lines);
    }
}

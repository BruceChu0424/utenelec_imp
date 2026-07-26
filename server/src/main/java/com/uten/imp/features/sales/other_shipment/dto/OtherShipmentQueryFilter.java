package com.uten.imp.features.sales.other_shipment.dto;

import java.time.LocalDate;
import java.util.UUID;

/** 其它出货列表查询条件。 */
public record OtherShipmentQueryFilter(
        String keyword,
        UUID clientId,
        UUID warehouseId,
        String outType,
        Short status,
        LocalDate dateFrom,
        LocalDate dateTo) {
}

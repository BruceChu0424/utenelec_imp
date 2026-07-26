package com.uten.imp.features.sales.shipment.dto;

import java.time.LocalDate;
import java.util.UUID;

/** 销售出货列表查询条件。 */
public record ShipmentQueryFilter(
        String keyword,
        UUID clientId,
        UUID warehouseId,
        Short status,
        Boolean arPosted,
        LocalDate dateFrom,
        LocalDate dateTo) {
}

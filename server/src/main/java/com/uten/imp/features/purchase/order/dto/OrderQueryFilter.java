package com.uten.imp.features.purchase.order.dto;

import java.time.LocalDate;
import java.util.UUID;

public record OrderQueryFilter(
        String keyword,
        UUID supplierId,
        UUID warehouseId,
        Short status,
        LocalDate dateFrom,
        LocalDate dateTo) {
}

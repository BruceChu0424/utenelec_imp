package com.uten.imp.features.purchase.request.dto;

import java.time.LocalDate;
import java.util.UUID;

public record RequestQueryFilter(
        String keyword, UUID warehouseId, Short status, LocalDate dateFrom, LocalDate dateTo) {
}

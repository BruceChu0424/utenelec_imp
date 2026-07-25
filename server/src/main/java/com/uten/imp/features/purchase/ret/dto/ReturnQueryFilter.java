package com.uten.imp.features.purchase.ret.dto;

import java.time.LocalDate;
import java.util.UUID;

public record ReturnQueryFilter(
        String keyword, UUID supplierId, UUID warehouseId, Short status, LocalDate dateFrom, LocalDate dateTo) {
}

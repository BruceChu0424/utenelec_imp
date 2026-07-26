package com.uten.imp.features.sales.order.dto;

import java.time.LocalDate;
import java.util.UUID;

/** 销售订货列表查询条件。 */
public record OrderQueryFilter(
        String keyword,
        UUID clientId,
        Short status,
        Boolean closed,
        LocalDate dateFrom,
        LocalDate dateTo) {
}

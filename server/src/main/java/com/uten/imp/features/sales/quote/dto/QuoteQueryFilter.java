package com.uten.imp.features.sales.quote.dto;

import java.time.LocalDate;
import java.util.UUID;

/** 销售报价列表查询条件。 */
public record QuoteQueryFilter(
        String keyword,
        UUID clientId,
        Short status,
        LocalDate dateFrom,
        LocalDate dateTo) {
}

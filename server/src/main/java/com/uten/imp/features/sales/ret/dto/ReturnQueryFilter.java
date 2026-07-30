package com.uten.imp.features.sales.ret.dto;

import java.time.LocalDate;
import java.util.UUID;

/** 销售退货列表查询条件。 */
public record ReturnQueryFilter(
        String keyword,
        UUID clientId,
        UUID warehouseId,
        Short status,
        Boolean arPosted,
        LocalDate dateFrom,
        LocalDate dateTo) {
}

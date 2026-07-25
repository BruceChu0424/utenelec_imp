package com.uten.imp.features.stock.dto;

import java.time.LocalDate;
import java.util.UUID;

/**
 * 仓库单据列表查询条件（统一）：docType 必填（按单据类型分页）+ keyword + 仓库/状态 + 日期范围。
 */
public record StockDocQueryFilter(
        String docType,
        String keyword,
        UUID warehouseId,
        Short status,
        LocalDate dateFrom,
        LocalDate dateTo) {
}

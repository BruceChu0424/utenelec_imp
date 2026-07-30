package com.uten.imp.features.purchase.receipt.dto;

import java.time.LocalDate;
import java.util.UUID;

/** 收货单列表查询条件（keyword + 供应商/仓库/状态精确 + 日期范围）。 */
public record ReceiptQueryFilter(
        String keyword,
        UUID supplierId,
        UUID warehouseId,
        Short status,
        LocalDate dateFrom,
        LocalDate dateTo) {
}

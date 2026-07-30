package com.uten.imp.features.subcontract.application.dto;

import java.time.LocalDate;
import java.util.UUID;

/** 委外申请单列表查询条件（keyword + 供应商/仓库/状态精确 + 日期范围）。 */
public record ApplicationQueryFilter(
        String keyword,
        UUID supplierId,
        UUID warehouseId,
        Short status,
        LocalDate dateFrom,
        LocalDate dateTo) {
}

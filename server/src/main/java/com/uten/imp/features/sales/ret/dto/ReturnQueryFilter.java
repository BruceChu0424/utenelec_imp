package com.uten.imp.features.sales.ret.dto;

import java.time.LocalDate;
import java.util.UUID;

/** 销售退货列表查询条件。billNo=单据号表头值筛选（2026-09-25 单号列统一，精确匹配）。 */
public record ReturnQueryFilter(
        String keyword,
        UUID clientId,
        UUID warehouseId,
        Short status,
        Boolean arPosted,
        LocalDate dateFrom,
        LocalDate dateTo,
        String billNo) {

    /** 兼容旧签名（无单号筛选）。 */
    public ReturnQueryFilter(
            String keyword, UUID clientId, UUID warehouseId, Short status, Boolean arPosted,
            LocalDate dateFrom, LocalDate dateTo) {
        this(keyword, clientId, warehouseId, status, arPosted, dateFrom, dateTo, null);
    }
}

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
        String billNo,
        boolean includeDeleted, boolean onlyDeleted,
        java.util.UUID currencyId,
        com.uten.imp.common.web.HeaderColumnFilter headerFilters) {
    public ReturnQueryFilter {
        headerFilters = headerFilters == null ? com.uten.imp.common.web.HeaderColumnFilter.EMPTY : headerFilters;
    }
    public ReturnQueryFilter(String keyword,
        UUID clientId,
        UUID warehouseId,
        Short status,
        Boolean arPosted,
        LocalDate dateFrom,
        LocalDate dateTo,
        String billNo,
        boolean includeDeleted, boolean onlyDeleted) {
        this(keyword, clientId, warehouseId, status, arPosted, dateFrom, dateTo, billNo, includeDeleted, onlyDeleted, null, com.uten.imp.common.web.HeaderColumnFilter.EMPTY);
    }
    public ReturnQueryFilter withHeaders(com.uten.imp.common.web.HeaderColumnFilter headers) {
        return new ReturnQueryFilter(keyword, clientId, warehouseId, status, arPosted, dateFrom, dateTo, billNo, includeDeleted, onlyDeleted, currencyId, headers);
    }
    public ReturnQueryFilter withCurrency(java.util.UUID value) {
        return new ReturnQueryFilter(keyword, clientId, warehouseId, status, arPosted, dateFrom, dateTo, billNo, includeDeleted, onlyDeleted, value, headerFilters);
    }

    public ReturnQueryFilter(
        String keyword,
        UUID clientId,
        UUID warehouseId,
        Short status,
        Boolean arPosted,
        LocalDate dateFrom,
        LocalDate dateTo,
        String billNo) { this(keyword, clientId, warehouseId, status, arPosted, dateFrom, dateTo, billNo, false, false); }
    public ReturnQueryFilter withHistory(boolean includeDeleted, boolean onlyDeleted) {
        return new ReturnQueryFilter(keyword, clientId, warehouseId, status, arPosted, dateFrom, dateTo, billNo, includeDeleted || onlyDeleted, onlyDeleted, currencyId, headerFilters);
    }


    /** 兼容旧签名（无单号筛选）。 */
    public ReturnQueryFilter(
            String keyword, UUID clientId, UUID warehouseId, Short status, Boolean arPosted,
            LocalDate dateFrom, LocalDate dateTo) {
        this(keyword, clientId, warehouseId, status, arPosted, dateFrom, dateTo, null);
    }
}

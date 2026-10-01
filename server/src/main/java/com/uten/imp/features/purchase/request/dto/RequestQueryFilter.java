package com.uten.imp.features.purchase.request.dto;

import java.time.LocalDate;
import java.util.UUID;

public record RequestQueryFilter(
        String keyword, UUID warehouseId, Short status, LocalDate dateFrom, LocalDate dateTo,
        /** 单据号表头值筛选（2026-09-25 单号列统一）：精确匹配，分页前服务端生效。 */
        String billNo,
        boolean includeDeleted, boolean onlyDeleted,
        com.uten.imp.common.web.HeaderColumnFilter headerFilters) {
    public RequestQueryFilter {
        headerFilters = headerFilters == null ? com.uten.imp.common.web.HeaderColumnFilter.EMPTY : headerFilters;
    }
    public RequestQueryFilter(String keyword, UUID warehouseId, Short status, LocalDate dateFrom, LocalDate dateTo,
        /** 单据号表头值筛选（2026-09-25 单号列统一）：精确匹配，分页前服务端生效。 */
        String billNo,
        boolean includeDeleted, boolean onlyDeleted) {
        this(keyword, warehouseId, status, dateFrom, dateTo, billNo, includeDeleted, onlyDeleted, com.uten.imp.common.web.HeaderColumnFilter.EMPTY);
    }
    public RequestQueryFilter withHeaders(com.uten.imp.common.web.HeaderColumnFilter headers) {
        return new RequestQueryFilter(keyword, warehouseId, status, dateFrom, dateTo, billNo, includeDeleted, onlyDeleted, headers);
    }

    public RequestQueryFilter(
        String keyword, UUID warehouseId, Short status, LocalDate dateFrom, LocalDate dateTo,
        /** 单据号表头值筛选（2026-09-25 单号列统一）：精确匹配，分页前服务端生效。 */
        String billNo) { this(keyword, warehouseId, status, dateFrom, dateTo, billNo, false, false); }
    public RequestQueryFilter withHistory(boolean includeDeleted, boolean onlyDeleted) {
        return new RequestQueryFilter(keyword, warehouseId, status, dateFrom, dateTo, billNo, includeDeleted || onlyDeleted, onlyDeleted, headerFilters);
    }


    /** 兼容旧签名（无单号筛选）。 */
    public RequestQueryFilter(
            String keyword, UUID warehouseId, Short status, LocalDate dateFrom, LocalDate dateTo) {
        this(keyword, warehouseId, status, dateFrom, dateTo, null);
    }
}

package com.uten.imp.features.subcontract.receipt.dto;

import java.time.LocalDate;
import java.util.UUID;

/** 委外进仓单列表查询条件（keyword + 供应商/仓库/状态精确 + 日期范围）。 */
public record ReceiptQueryFilter(
        String keyword,
        UUID supplierId,
        UUID warehouseId,
        Short status,
        LocalDate dateFrom,
        LocalDate dateTo,
        /** 单据号表头值筛选（2026-09-25 单号列统一）：精确匹配，分页前服务端生效。 */
        String billNo,
        boolean includeDeleted, boolean onlyDeleted,
        com.uten.imp.common.web.HeaderColumnFilter headerFilters) {
    public ReceiptQueryFilter {
        headerFilters = headerFilters == null ? com.uten.imp.common.web.HeaderColumnFilter.EMPTY : headerFilters;
    }
    public ReceiptQueryFilter(String keyword,
        UUID supplierId,
        UUID warehouseId,
        Short status,
        LocalDate dateFrom,
        LocalDate dateTo,
        /** 单据号表头值筛选（2026-09-25 单号列统一）：精确匹配，分页前服务端生效。 */
        String billNo,
        boolean includeDeleted, boolean onlyDeleted) {
        this(keyword, supplierId, warehouseId, status, dateFrom, dateTo, billNo, includeDeleted, onlyDeleted, com.uten.imp.common.web.HeaderColumnFilter.EMPTY);
    }
    public ReceiptQueryFilter withHeaders(com.uten.imp.common.web.HeaderColumnFilter headers) {
        return new ReceiptQueryFilter(keyword, supplierId, warehouseId, status, dateFrom, dateTo, billNo, includeDeleted, onlyDeleted, headers);
    }

    public ReceiptQueryFilter(
        String keyword,
        UUID supplierId,
        UUID warehouseId,
        Short status,
        LocalDate dateFrom,
        LocalDate dateTo,
        /** 单据号表头值筛选（2026-09-25 单号列统一）：精确匹配，分页前服务端生效。 */
        String billNo) { this(keyword, supplierId, warehouseId, status, dateFrom, dateTo, billNo, false, false); }
    public ReceiptQueryFilter withHistory(boolean includeDeleted, boolean onlyDeleted) {
        return new ReceiptQueryFilter(keyword, supplierId, warehouseId, status, dateFrom, dateTo, billNo, includeDeleted || onlyDeleted, onlyDeleted, headerFilters);
    }


    /** 兼容旧签名（无单号筛选）。 */
    public ReceiptQueryFilter(
            String keyword, UUID supplierId, UUID warehouseId, Short status,
            LocalDate dateFrom, LocalDate dateTo) {
        this(keyword, supplierId, warehouseId, status, dateFrom, dateTo, null);
    }
}

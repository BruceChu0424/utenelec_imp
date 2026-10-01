package com.uten.imp.features.purchase.ret.dto;

import java.time.LocalDate;
import java.util.UUID;

public record ReturnQueryFilter(
        String keyword, UUID supplierId, UUID warehouseId, Short status, LocalDate dateFrom, LocalDate dateTo,
        /** 单据号表头值筛选（2026-09-25 单号列统一）：精确匹配，分页前服务端生效。 */
        String billNo,
        boolean includeDeleted, boolean onlyDeleted) {
    public ReturnQueryFilter(
        String keyword, UUID supplierId, UUID warehouseId, Short status, LocalDate dateFrom, LocalDate dateTo,
        /** 单据号表头值筛选（2026-09-25 单号列统一）：精确匹配，分页前服务端生效。 */
        String billNo) { this(keyword, supplierId, warehouseId, status, dateFrom, dateTo, billNo, false, false); }
    public ReturnQueryFilter withHistory(boolean includeDeleted, boolean onlyDeleted) {
        return new ReturnQueryFilter(keyword, supplierId, warehouseId, status, dateFrom, dateTo, billNo, includeDeleted || onlyDeleted, onlyDeleted);
    }


    /** 兼容旧签名（无单号筛选）。 */
    public ReturnQueryFilter(
            String keyword, UUID supplierId, UUID warehouseId, Short status, LocalDate dateFrom, LocalDate dateTo) {
        this(keyword, supplierId, warehouseId, status, dateFrom, dateTo, null);
    }
}

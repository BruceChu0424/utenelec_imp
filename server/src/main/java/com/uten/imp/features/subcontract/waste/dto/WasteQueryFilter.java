package com.uten.imp.features.subcontract.waste.dto;

import java.time.LocalDate;
import java.util.UUID;

/** 委外损耗单列表查询条件（keyword + 供应商/仓库/状态精确 + 日期范围 + 单据号值筛选）。 */
public record WasteQueryFilter(
        String keyword,
        UUID supplierId,
        UUID warehouseId,
        Short status,
        LocalDate dateFrom,
        LocalDate dateTo,
        /** 单据号表头值筛选（2026-09-25 单号列统一）：精确匹配。 */
        String billNo,
        boolean includeDeleted, boolean onlyDeleted) {
    public WasteQueryFilter(
        String keyword,
        UUID supplierId,
        UUID warehouseId,
        Short status,
        LocalDate dateFrom,
        LocalDate dateTo,
        /** 单据号表头值筛选（2026-09-25 单号列统一）：精确匹配。 */
        String billNo) { this(keyword, supplierId, warehouseId, status, dateFrom, dateTo, billNo, false, false); }
    public WasteQueryFilter withHistory(boolean includeDeleted, boolean onlyDeleted) {
        return new WasteQueryFilter(keyword, supplierId, warehouseId, status, dateFrom, dateTo, billNo, includeDeleted || onlyDeleted, onlyDeleted);
    }


    /** 兼容旧签名（无单号筛选）。 */
    public WasteQueryFilter(
            String keyword, UUID supplierId, UUID warehouseId, Short status,
            LocalDate dateFrom, LocalDate dateTo) {
        this(keyword, supplierId, warehouseId, status, dateFrom, dateTo, null);
    }
}

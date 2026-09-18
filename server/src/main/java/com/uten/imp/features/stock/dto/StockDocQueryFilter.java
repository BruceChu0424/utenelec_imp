package com.uten.imp.features.stock.dto;

import java.time.LocalDate;
import java.util.UUID;

/**
 * 仓库单据列表查询条件（统一）：docType 必填（按单据类型分页）+ keyword + 仓库/状态 + 日期范围。
 * departmentId/issueStatus 仅 DRAW 有意义（各车间领料统计 / 未完成领料单筛选）；
 * toWarehouseId 仅转仓类单据有意义（调入仓表头筛选，2026-09-16）。
 */
public record StockDocQueryFilter(
        String docType,
        String keyword,
        UUID warehouseId,
        Short status,
        LocalDate dateFrom,
        LocalDate dateTo,
        UUID departmentId,
        Short issueStatus,
        Boolean productionReturnRequests,
        UUID toWarehouseId) {
    public StockDocQueryFilter(String docType, String keyword, UUID warehouseId, Short status,
                              LocalDate dateFrom, LocalDate dateTo, UUID departmentId, Short issueStatus) {
        this(docType,keyword,warehouseId,status,dateFrom,dateTo,departmentId,issueStatus,null,null);
    }

    /** 兼容旧调用：无 toWarehouseId。 */
    public StockDocQueryFilter(String docType, String keyword, UUID warehouseId, Short status,
                              LocalDate dateFrom, LocalDate dateTo, UUID departmentId, Short issueStatus,
                              Boolean productionReturnRequests) {
        this(docType,keyword,warehouseId,status,dateFrom,dateTo,departmentId,issueStatus,productionReturnRequests,null);
    }
}

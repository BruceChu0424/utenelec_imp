package com.uten.imp.features.stock.dto;

import com.uten.imp.application.port.WarehouseTaskScopePort.WarehouseTaskScope;

import java.time.LocalDate;
import java.util.UUID;

/**
 * 仓库单据列表查询条件（统一）：docType 必填（按单据类型分页）+ keyword + 仓库/状态 + 日期范围。
 * departmentId/issueStatus 仅 DRAW 有意义（各车间领料统计 / 未完成领料单筛选）；
 * toWarehouseId 仅转仓类单据有意义（调入仓表头筛选，2026-09-16）。
 * warehouseScope 为仓库数据范围(ADR-149，服务端按本人范围强制)，发出仓或调入仓落在范围内即算；
 * ownDraftsInScope 为真(本人默认范围, 页面没挑仓)时，当前账号自己还没提交的草稿不论仓都算在范围内
 * (建单不限仓, 草稿不能从制单人自己的列表里消失)。
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
        UUID toWarehouseId,
        WarehouseTaskScope warehouseScope,
        /** 单据号表头值筛选（2026-09-25 单号列统一）：精确匹配，分页前服务端生效。 */
        String billNo,
        boolean ownDraftsInScope) {
    public StockDocQueryFilter {
        warehouseScope = warehouseScope == null ? WarehouseTaskScope.ALL : warehouseScope;
    }

    /** 不带「本人草稿」例外(内部调用与旧测试)。 */
    public StockDocQueryFilter(String docType, String keyword, UUID warehouseId, Short status,
                              LocalDate dateFrom, LocalDate dateTo, UUID departmentId, Short issueStatus,
                              Boolean productionReturnRequests, UUID toWarehouseId,
                              WarehouseTaskScope warehouseScope, String billNo) {
        this(docType, keyword, warehouseId, status, dateFrom, dateTo, departmentId, issueStatus,
                productionReturnRequests, toWarehouseId, warehouseScope, billNo, false);
    }

    /** 兼容旧签名（无单号筛选）。 */
    public StockDocQueryFilter(String docType, String keyword, UUID warehouseId, Short status,
                              LocalDate dateFrom, LocalDate dateTo, UUID departmentId, Short issueStatus,
                              Boolean productionReturnRequests, UUID toWarehouseId,
                              WarehouseTaskScope warehouseScope) {
        this(docType, keyword, warehouseId, status, dateFrom, dateTo, departmentId, issueStatus,
                productionReturnRequests, toWarehouseId, warehouseScope, null);
    }

    /** 兼容旧调用：不按仓库范围过滤。 */
    public StockDocQueryFilter(String docType, String keyword, UUID warehouseId, Short status,
                              LocalDate dateFrom, LocalDate dateTo, UUID departmentId, Short issueStatus,
                              Boolean productionReturnRequests, UUID toWarehouseId) {
        this(docType, keyword, warehouseId, status, dateFrom, dateTo, departmentId, issueStatus,
                productionReturnRequests, toWarehouseId, WarehouseTaskScope.ALL, null);
    }

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

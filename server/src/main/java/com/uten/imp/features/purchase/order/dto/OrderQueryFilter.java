package com.uten.imp.features.purchase.order.dto;

import java.time.LocalDate;
import java.util.UUID;

/**
 * 采购订货单列表查询条件（keyword + 供应商/仓库/状态精确 + 日期范围）。
 *
 * <p>{@code financeApproval} 为财务审批态切片（可空）：财务通过前单据 status 保持 0，
 * 「草稿」段与「等待财务审核」段同为 status=0，靠本参数区分——
 * {@code NONE} = 未提交（真草稿）；{@code PENDING} = 已提交在审。
 */
public record OrderQueryFilter(
        String keyword,
        UUID supplierId,
        UUID warehouseId,
        Short status,
        LocalDate dateFrom,
        LocalDate dateTo,
        String financeApproval,
        /** 单据号表头值筛选（2026-09-25 单号列统一）：精确匹配，分页前服务端生效。 */
        String billNo,
        boolean includeDeleted, boolean onlyDeleted,
        com.uten.imp.common.web.HeaderColumnFilter headerFilters) {
    public OrderQueryFilter {
        headerFilters = headerFilters == null ? com.uten.imp.common.web.HeaderColumnFilter.EMPTY : headerFilters;
    }
    public OrderQueryFilter(String keyword,
        UUID supplierId,
        UUID warehouseId,
        Short status,
        LocalDate dateFrom,
        LocalDate dateTo,
        String financeApproval,
        /** 单据号表头值筛选（2026-09-25 单号列统一）：精确匹配，分页前服务端生效。 */
        String billNo,
        boolean includeDeleted, boolean onlyDeleted) {
        this(keyword, supplierId, warehouseId, status, dateFrom, dateTo, financeApproval, billNo, includeDeleted, onlyDeleted, com.uten.imp.common.web.HeaderColumnFilter.EMPTY);
    }
    public OrderQueryFilter withHeaders(com.uten.imp.common.web.HeaderColumnFilter headers) {
        return new OrderQueryFilter(keyword, supplierId, warehouseId, status, dateFrom, dateTo, financeApproval, billNo, includeDeleted, onlyDeleted, headers);
    }

    public OrderQueryFilter(
        String keyword,
        UUID supplierId,
        UUID warehouseId,
        Short status,
        LocalDate dateFrom,
        LocalDate dateTo,
        String financeApproval,
        /** 单据号表头值筛选（2026-09-25 单号列统一）：精确匹配，分页前服务端生效。 */
        String billNo) { this(keyword, supplierId, warehouseId, status, dateFrom, dateTo, financeApproval, billNo, false, false); }
    public OrderQueryFilter withHistory(boolean includeDeleted, boolean onlyDeleted) {
        return new OrderQueryFilter(keyword, supplierId, warehouseId, status, dateFrom, dateTo, financeApproval, billNo, includeDeleted || onlyDeleted, onlyDeleted, headerFilters);
    }


    /** 兼容旧签名（无单号筛选）。 */
    public OrderQueryFilter(
            String keyword, UUID supplierId, UUID warehouseId, Short status,
            LocalDate dateFrom, LocalDate dateTo, String financeApproval) {
        this(keyword, supplierId, warehouseId, status, dateFrom, dateTo, financeApproval, null);
    }
}

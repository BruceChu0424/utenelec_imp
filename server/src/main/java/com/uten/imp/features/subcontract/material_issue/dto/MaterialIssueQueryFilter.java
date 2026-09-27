package com.uten.imp.features.subcontract.material_issue.dto;

import java.time.LocalDate;
import java.util.UUID;

/** 委外材料出仓单列表查询条件（keyword + 供应商/仓库/状态精确 + 日期范围）。 */
public record MaterialIssueQueryFilter(
        String keyword,
        UUID supplierId,
        UUID warehouseId,
        Short status,
        LocalDate dateFrom,
        LocalDate dateTo,
        /** 单据号表头值筛选（2026-09-25 单号列统一）：精确匹配，分页前服务端生效。 */
        String billNo) {

    /** 兼容旧签名（无单号筛选）。 */
    public MaterialIssueQueryFilter(
            String keyword, UUID supplierId, UUID warehouseId, Short status,
            LocalDate dateFrom, LocalDate dateTo) {
        this(keyword, supplierId, warehouseId, status, dateFrom, dateTo, null);
    }
}

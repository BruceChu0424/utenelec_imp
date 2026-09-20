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
        String financeApproval) {
}

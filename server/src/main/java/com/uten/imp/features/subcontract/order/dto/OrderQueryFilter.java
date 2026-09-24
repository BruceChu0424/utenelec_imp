package com.uten.imp.features.subcontract.order.dto;

import java.time.LocalDate;
import java.util.UUID;

/**
 * 委外订货单列表查询条件（keyword + 供应商/仓库/状态精确 + 日期范围）。
 *
 * <p>{@code financeApproval} 为财务审批态切片（可空）：财务通过前单据 status 保持 0，
 * 「草稿」段与「等待财务审核」段同为 status=0，靠本参数区分——
 * {@code NONE} = 未提交（真草稿）；{@code PENDING} = 已提交在审；{@code REJECTED} = 财务退回；
 * {@code IN_PROGRESS} = 在审/退回待修改，或财务已通过且未结案（不附加 status/closed 时为聚合视图）。
 */
public record OrderQueryFilter(
        String keyword,
        UUID supplierId,
        UUID warehouseId,
        Short status,
        LocalDate dateFrom,
        LocalDate dateTo,
        /** 结案筛选（追加）：null=全部 / true=已结案 / false=未完成（部分入库的委外单）。 */
        Boolean closed,
        String financeApproval) {
}

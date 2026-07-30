package com.uten.imp.features.subcontract.order.dto;

import java.time.LocalDate;
import java.util.UUID;

/** 委外订货单列表查询条件（keyword + 供应商/仓库/状态精确 + 日期范围）。 */
public record OrderQueryFilter(
        String keyword,
        UUID supplierId,
        UUID warehouseId,
        Short status,
        LocalDate dateFrom,
        LocalDate dateTo,
        /** 结案筛选（V99 追加）：null=全部 / true=已结案 / false=未完成（部分入库的委外单）。 */
        Boolean closed) {
}

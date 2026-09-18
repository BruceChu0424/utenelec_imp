package com.uten.imp.features.expenseclaim.dto;

import java.util.List;

/**
 * 报销审批列表表头筛选桶（2026-09-10）：部门（value=部门 id，label=部门名）与
 * 年月（value=label=yyyy-MM，业务时区）。count 为该队列状态集下的命中单数。
 * 2026-09-16 增类别桶（value=label=类别码 TRANSPORT/TRAVEL/...，挂在明细项上，
 * count=该队列状态集下含该类别明细的单数）。
 */
public record ExpenseClaimFacetsDto(
        List<Bucket> departments,
        List<Bucket> months,
        List<Bucket> categories
) {
    public record Bucket(String value, String label, long count) {
    }
}

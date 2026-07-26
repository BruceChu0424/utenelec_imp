package com.uten.imp.features.production.plan.dto;

import java.time.LocalDate;
import java.util.UUID;

/**
 * 生产计划查询过滤。
 *
 * @param keyword      模糊搜索 bill_no
 * @param departmentId 车间所属部门（departments.id）
 * @param status       0 草稿 / 1 已审 / -1 红冲
 * @param closed       是否结案（CheckFulfill4 派生）
 * @param dateFrom     bill_date 起
 * @param dateTo       bill_date 止
 */
public record PlanQueryFilter(
        String keyword,
        UUID departmentId,
        Short status,
        Boolean closed,
        LocalDate dateFrom,
        LocalDate dateTo) {
}

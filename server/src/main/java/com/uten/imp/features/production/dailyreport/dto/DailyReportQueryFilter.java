package com.uten.imp.features.production.dailyreport.dto;

import java.time.LocalDate;
import java.util.UUID;

/**
 * 生产日报查询过滤。
 *
 * @param keyword      模糊搜索 bill_no
 * @param warehouseId  仓库（StockID）
 * @param departmentId 车间所属部门
 * @param workerId     报工人
 * @param status       0 草稿 / 1 已审 / -1 红冲
 * @param dateFrom     bill_date 起
 * @param dateTo       bill_date 止
 */
public record DailyReportQueryFilter(
        String keyword,
        UUID warehouseId,
        UUID departmentId,
        UUID workerId,
        Short status,
        LocalDate dateFrom,
        LocalDate dateTo) {
}

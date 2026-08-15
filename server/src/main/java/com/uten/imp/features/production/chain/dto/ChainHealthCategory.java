package com.uten.imp.features.production.chain.dto;

import java.util.List;

/**
 * 全链路断链检查（生产计划单一键生成与全链路溯源设计 §五）单类结果。
 *
 * @param category    类别 key（SALES_GAP_NO_ANALYSIS / ANALYSIS_UNPLANNED /
 *                    PLAN_NO_DRAW / DRAW_NO_PLAN）
 * @param label       类别中文名
 * @param description 类别说明（含修复指引）
 * @param count       全量命中数（不受返回条数限制）
 * @param issues      明细（按 limit 截断，前端分页到权威列表页处理）
 */
public record ChainHealthCategory(
        String category,
        String label,
        String description,
        long count,
        List<ChainHealthIssue> issues) {
}

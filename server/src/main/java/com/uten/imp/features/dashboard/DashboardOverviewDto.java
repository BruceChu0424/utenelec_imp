package com.uten.imp.features.dashboard;

import java.time.Instant;
import java.util.List;

/**
 * 工作台首屏的权限化读模型。
 *
 * <p>敏感指标没有权限时不会出现在响应中，前端不承担数据隔离职责。
 */
public record DashboardOverviewDto(
        String departmentCode,
        String departmentName,
        Instant generatedAt,
        List<MetricCard> metrics,
        List<TodoCard> todos) {

    public record MetricCard(
            String id,
            String title,
            String value,
            String subtitle,
            String tone,
            String route,
            boolean sensitive) {
    }

    public record TodoCard(
            String id,
            String title,
            String summary,
            long count,
            long urgentCount,
            String tone,
            String route,
            String sourceType,
            String sourceId,
            Instant dueAt,
            boolean completable) {
    }
}

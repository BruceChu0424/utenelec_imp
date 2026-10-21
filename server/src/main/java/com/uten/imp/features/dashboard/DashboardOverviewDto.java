package com.uten.imp.features.dashboard;

import com.fasterxml.jackson.annotation.JsonCreator;
import com.fasterxml.jackson.annotation.JsonProperty;
import com.fasterxml.jackson.annotation.JsonPropertyOrder;
import java.time.Instant;
import java.util.Collections;
import java.util.List;
import java.util.Objects;

/**
 * 工作台首屏的权限化读模型。
 *
 * <p>敏感指标没有权限时不会出现在响应中，前端不承担数据隔离职责。
 */
@JsonPropertyOrder({"departmentCode", "departmentName", "generatedAt", "metrics", "todos"})
public final class DashboardOverviewDto {
    private final String departmentCode;
    private final String departmentName;
    private final Instant generatedAt;
    private final List<MetricCard> metrics;
    private final List<TodoCard> todos;

    @JsonCreator
    public DashboardOverviewDto(@JsonProperty("departmentCode") String departmentCode,
                                @JsonProperty("departmentName") String departmentName,
                                @JsonProperty("generatedAt") Instant generatedAt,
                                @JsonProperty("metrics") List<MetricCard> metrics,
                                @JsonProperty("todos") List<TodoCard> todos) {
        this.departmentCode = departmentCode;
        this.departmentName = departmentName;
        this.generatedAt = generatedAt;
        this.metrics = metrics == null ? null : List.copyOf(metrics);
        this.todos = todos == null ? null : List.copyOf(todos);
    }

    @JsonProperty("departmentCode")
    public String departmentCode() { return departmentCode; }

    @JsonProperty("departmentName")
    public String departmentName() { return departmentName; }

    @JsonProperty("generatedAt")
    public Instant generatedAt() { return generatedAt; }

    @JsonProperty("metrics")
    public List<MetricCard> metrics() {
        return metrics == null ? null : Collections.unmodifiableList(metrics);
    }

    @JsonProperty("todos")
    public List<TodoCard> todos() {
        return todos == null ? null : Collections.unmodifiableList(todos);
    }

    @Override
    public boolean equals(Object other) {
        if (this == other) return true;
        if (!(other instanceof DashboardOverviewDto that)) return false;
        return Objects.equals(departmentCode, that.departmentCode)
                && Objects.equals(departmentName, that.departmentName)
                && Objects.equals(generatedAt, that.generatedAt)
                && Objects.equals(metrics, that.metrics)
                && Objects.equals(todos, that.todos);
    }

    @Override
    public int hashCode() {
        int result = Objects.hashCode(departmentCode);
        result = 31 * result + Objects.hashCode(departmentName);
        result = 31 * result + Objects.hashCode(generatedAt);
        result = 31 * result + Objects.hashCode(metrics);
        return 31 * result + Objects.hashCode(todos);
    }

    @Override
    public String toString() {
        return "DashboardOverviewDto[departmentCode=" + departmentCode + ", departmentName=" + departmentName
                + ", generatedAt=" + generatedAt + ", metrics=" + metrics + ", todos=" + todos + "]";
    }

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

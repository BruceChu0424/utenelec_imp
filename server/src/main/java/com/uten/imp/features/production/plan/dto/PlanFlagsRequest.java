package com.uten.imp.features.production.plan.dto;

/**
 * 看板标记更新请求（V127）：置顶 / 重要。null 字段保持不变。
 */
public record PlanFlagsRequest(Boolean pinned, Boolean important) {
}

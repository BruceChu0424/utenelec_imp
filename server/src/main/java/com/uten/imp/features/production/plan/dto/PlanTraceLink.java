package com.uten.imp.features.production.plan.dto;

import java.util.UUID;

/**
 * 计划详情中的部分溯源投影节点。
 *
 * @param id     目标单据 id（前端跳转用）
 * @param billNo 目标单据号（展示用）
 * @param kind   SALES_ORDER / STOCK_DRAW / FINISHED_IN / PURCHASE_REQUEST
 */
public record PlanTraceLink(UUID id, String billNo, String kind) {
}

package com.uten.imp.features.production.plan.dto;

import java.util.UUID;

/**
 * 计划详情中的部分溯源投影节点。
 *
 * @param id         目标单据 id（前端跳转用）
 * @param billNo     目标单据号（展示用）
 * @param kind       SALES_ORDER / STOCK_DRAW / FINISHED_IN / PURCHASE_REQUEST /
 *                   SUBCONTRACT_APPLICATION / DAILY_REPORT
 * @param clientName 来源销售订单的客户名（仅 SALES_ORDER 有值；其余 kind 为 null）
 * @param sellerName 来源销售订单的业务员名（仅 SALES_ORDER 有值；其余 kind 为 null）
 */
public record PlanTraceLink(UUID id, String billNo, String kind, String clientName, String sellerName) {
}

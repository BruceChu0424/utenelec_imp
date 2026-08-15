package com.uten.imp.features.production.chain.dto;

/**
 * 全链路断链检查单条命中。
 *
 * @param refId     权威单据/行 id（前端跳转用：订单行→订单、分析、计划、领料单）
 * @param targetId  跳转目标单据 id（如订单行所属订单 id；与 refId 相同则可忽略）
 * @param billNo    展示单号
 * @param label     主文案（货品名 / 分析号 / 计划号）
 * @param detail    补充说明（缺口量 / 未排量 / 车间等）
 * @param route     前端修复入口路由提示（SALES_ORDER / MATERIAL_ANALYSIS /
 *                  PRODUCTION_PLAN / STOCK_DRAW）
 */
public record ChainHealthIssue(
        String refId,
        String targetId,
        String billNo,
        String label,
        String detail,
        String route) {
}

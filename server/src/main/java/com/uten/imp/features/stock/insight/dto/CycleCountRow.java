package com.uten.imp.features.stock.insight.dto;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/**
 * 盘点建议一行 (仓库 × 货品 × 颜色; GET /api/stock/insights/cycle-count)。
 *
 * <p>按颜色分行: 盘点单明细是货品 + 颜色, 「生成盘点单」把这一行原样预填成一条盘点明细 (无颜色货品
 * colorId 为 null)。上次盘点 = 该仓该货品该颜色最近一张已审盘点单的单据日期 (盘点无差异不产生流水,
 * 所以不看流水); 从未盘过时按第一笔流水日期起算。周期按货品 ABC: A 30 天 / B 90 天 / C、N 180 天。
 *
 * @param warehouseId     仓库
 * @param warehouseName   仓库名
 * @param goodsId         货品
 * @param code            货品编号
 * @param name            货品名称
 * @param colorId         颜色 (无颜色为 null)
 * @param colorName       颜色名
 * @param unitName        基本单位
 * @param abc             A / B / C / N
 * @param lastCountedOn   上次盘点日期 (从未盘过为 null)
 * @param daysSince       距上次盘点 (或起算日) 天数
 * @param reasons         原因: DUE 到期 / RESIDUAL 近期重量尾差 / ESTIMATED_WEIGHT 重量为估算 /
 *                        UNKNOWN_WEIGHT 重量未知 / RED_TIER 单重未学准
 * @param score           优先级分 (到期比例 + 各原因加分, 越大越先盘)
 * @param qty             库存数量
 * @param weightKg        库存重量 (千克; null = 未知)
 * @param weightEstimated 重量含估算
 */
public record CycleCountRow(
        UUID warehouseId,
        String warehouseName,
        UUID goodsId,
        String code,
        String name,
        UUID colorId,
        String colorName,
        String unitName,
        String abc,
        LocalDate lastCountedOn,
        long daysSince,
        List<String> reasons,
        BigDecimal score,
        BigDecimal qty,
        BigDecimal weightKg,
        boolean weightEstimated) {
}

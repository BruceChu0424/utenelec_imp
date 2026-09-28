package com.uten.imp.features.stock.insight.dto;

import com.fasterxml.jackson.annotation.JsonProperty;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.UUID;

/**
 * 单个货品的库存分析指标条 (GET /api/stock/insights/goods/{goodsId}, stock:view; 核算仓、不含线边仓,
 * 各颜色合计)。不含供应商层面的数字。
 *
 * @param goodsId         货品
 * @param unitName        基本单位
 * @param qty             库存数量
 * @param weightKg        库存重量 (千克; null = 未知)
 * @param weightEstimated 重量含估算
 * @param unitWeightKg    当前单重 (千克/基本单位)
 * @param basis           单重依据 EXACT / MANUAL / LEARNED / MASTER_PRIOR / NONE
 * @param tier            可靠度 GREEN / YELLOW / RED
 * @param relHalfWidth    相对半宽
 * @param lastInAt        最后入库
 * @param lastOutAt       最后消耗 (近 365 天)
 * @param idleDays        距最后变动天数
 * @param out90           近 90 天消耗
 * @param avgDailyOut90   近 90 天日均消耗
 * @param daysOfCover     约可用天数
 * @param abc             A / B / C / N
 * @param agePct0_30      库龄 30 天内的数量占比 (%)
 * @param age0_30         库龄 0-30 天
 * @param age31_90        31-90 天
 * @param age91_180       91-180 天
 * @param age181_365      181-365 天
 * @param ageOver365      超过 365 天
 * @param ageUnknown      期初 (无入库记录)
 */
public record GoodsInsight(
        UUID goodsId,
        String unitName,
        BigDecimal qty,
        BigDecimal weightKg,
        boolean weightEstimated,
        BigDecimal unitWeightKg,
        String basis,
        String tier,
        Double relHalfWidth,
        OffsetDateTime lastInAt,
        OffsetDateTime lastOutAt,
        Integer idleDays,
        BigDecimal out90,
        BigDecimal avgDailyOut90,
        BigDecimal daysOfCover,
        String abc,
        @JsonProperty("agePct0_30") BigDecimal agePct0_30,
        @JsonProperty("age0_30") BigDecimal age0_30,
        @JsonProperty("age31_90") BigDecimal age31_90,
        @JsonProperty("age91_180") BigDecimal age91_180,
        @JsonProperty("age181_365") BigDecimal age181_365,
        BigDecimal ageOver365,
        BigDecimal ageUnknown) {
}

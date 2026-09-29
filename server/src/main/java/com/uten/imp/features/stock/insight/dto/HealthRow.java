package com.uten.imp.features.stock.insight.dto;

import com.fasterxml.jackson.annotation.JsonProperty;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.UUID;

/**
 * 呆滞与库龄一行 (货品 × 颜色, 所选仓库范围内合计; GET /api/stock/insights/health)。
 *
 * <p>库龄按先进先出把现存量分给最新的入库批次 (外部来货 + 盘盈; 范围外调入也算; 退料不重置库龄;
 * 同一来源行的红冲已冲减); 分不到批次的量记入 ageUnknown (期初, 无入库记录)。
 * 消耗 = 销售/领料/其它出/产成品出/委外发料/销售其它出 (+ 调往范围外的调拨), 红冲已冲减。
 *
 * @param goodsId         货品
 * @param code            货品编号
 * @param name            货品名称
 * @param colorId         颜色
 * @param colorName       颜色名
 * @param unitName        基本单位
 * @param qty             库存数量
 * @param weightKg        库存重量 (千克; null = 未知)
 * @param weightEstimated 重量含估算
 * @param lastInAt        最后入库 (仍有存量的最新入库批次)
 * @param lastOutAt       最后消耗 (近 365 天内; 更早为 null)
 * @param idleDays        距最后变动天数
 * @param age0_30         库龄 0-30 天的数量
 * @param age31_90        库龄 31-90 天
 * @param age91_180       库龄 91-180 天
 * @param age181_365      库龄 181-365 天
 * @param ageOver365      库龄超过 365 天
 * @param ageUnknown      期初 (无入库记录)
 * @param out30           近 30 天消耗
 * @param out90           近 90 天消耗
 * @param out365          近 365 天消耗
 * @param avgDailyOut90   近 90 天日均消耗
 * @param daysOfCover     约可用天数 (近 90 天没有消耗时为 null)
 * @param picks90         近 90 天出库次数 (红冲已冲减)
 * @param abc             A / B / C / N (按近 90 天出库次数的全范围排名; N = 没有出库)
 * @param dead            呆滞: 有库存、近 90 天没有消耗、最新批次也早于 90 天
 * @param amountLocal     库存台账金额 (没有 goods:cost:view 时为 null)
 * @param costMasked      金额已按成本权限遮住
 */
public record HealthRow(
        UUID goodsId,
        String code,
        String name,
        UUID colorId,
        String colorName,
        String unitName,
        BigDecimal qty,
        BigDecimal weightKg,
        boolean weightEstimated,
        OffsetDateTime lastInAt,
        OffsetDateTime lastOutAt,
        Integer idleDays,
        @JsonProperty("age0_30") BigDecimal age0_30,
        @JsonProperty("age31_90") BigDecimal age31_90,
        @JsonProperty("age91_180") BigDecimal age91_180,
        @JsonProperty("age181_365") BigDecimal age181_365,
        BigDecimal ageOver365,
        BigDecimal ageUnknown,
        BigDecimal out30,
        BigDecimal out90,
        BigDecimal out365,
        BigDecimal avgDailyOut90,
        BigDecimal daysOfCover,
        long picks90,
        String abc,
        boolean dead,
        BigDecimal amountLocal,
        boolean costMasked) {
}

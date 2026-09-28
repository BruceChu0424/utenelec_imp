package com.uten.imp.features.stock.insight.dto;

import com.fasterxml.jackson.annotation.JsonProperty;

import java.math.BigDecimal;

/**
 * 库存分析顶部指标 (所选仓库范围, 不受表格筛选影响)。
 *
 * @param skuWithStock      有库存的货品×颜色行数
 * @param knownWeightKg     已知库存重量合计 (千克)
 * @param weightUnknownRows 重量未知的行数
 * @param weighedCoveragePct 称重覆盖率 (%): 有库存的余额行里重量已知且不是估算的占比
 * @param deadSku           呆滞行数
 * @param aged180QtyPct     库龄超过 180 天 (含期初无入库记录) 的数量占比 (%)
 * @param movements30d      近 30 天出入库笔数
 * @param alerts30d         近 30 天称重异常条数
 * @param receiptShort30d   其中来料少数 (到货称重偏轻) 的条数
 * @param drawOver30d       其中领料超发 (领料称重偏重) 的条数
 * @param needsSample       待称样货品数 (近 90 天有动态、还没学准: 没有学习结果或可靠度 RED/结论矛盾;
 *                          不含按重量计、人工设定单重、停止学习的货品)
 * @param deadAmountLocal   呆滞金额 (没有 goods:cost:view 时为 null)
 */
public record HealthOverview(
        long skuWithStock,
        BigDecimal knownWeightKg,
        long weightUnknownRows,
        BigDecimal weighedCoveragePct,
        long deadSku,
        @JsonProperty("aged180QtyPct") BigDecimal aged180QtyPct,
        @JsonProperty("movements30d") long movements30d,
        @JsonProperty("alerts30d") long alerts30d,
        @JsonProperty("receiptShort30d") long receiptShort30d,
        @JsonProperty("drawOver30d") long drawOver30d,
        long needsSample,
        BigDecimal deadAmountLocal) {
}

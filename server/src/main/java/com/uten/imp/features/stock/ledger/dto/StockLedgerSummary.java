package com.uten.imp.features.stock.ledger.dto;

import java.math.BigDecimal;

/**
 * 流水汇总 (存货明细账的「期初结存 · 本期收入 · 本期发出 · 期末结存」, 数量与重量两套)。
 *
 * <p>期初/期末只受仓库 (含下级) 与颜色范围影响, 不受类型/方向筛选影响; 本期收入/发出按类型/方向筛选,
 * 按类型的自然方向归类 (红冲为负数冲减本期收入或发出), 不含范围内部的调拨 (两腿都在范围内时
 * 单列 internalTransferQty)。重量恒为千克, null = 不知道; 收入/发出重量只加已知重量, 未知的行数另给。
 *
 * @param openingQty           期初结存数量 (dateFrom 之前; 不给 dateFrom 时为最早一笔之前)
 * @param closingQty           期末结存数量 (dateTo 当天结束; 不给 dateTo 时为当前余额)
 * @param inQty                本期收入数量
 * @param outQty               本期发出数量
 * @param internalTransferQty  本期范围内部调拨 (调入腿) 数量
 * @param openingWeightKg      期初结存重量
 * @param closingWeightKg      期末结存重量
 * @param inWeightKg           本期收入已知重量合计
 * @param outWeightKg          本期发出已知重量合计
 * @param inWeightUnknownRows  本期收入里重量未知的行数
 * @param outWeightUnknownRows 本期发出里重量未知的行数
 * @param residualKg           本期重量尾差调整合计 (带符号)
 */
public record StockLedgerSummary(
        BigDecimal openingQty,
        BigDecimal closingQty,
        BigDecimal inQty,
        BigDecimal outQty,
        BigDecimal internalTransferQty,
        BigDecimal openingWeightKg,
        BigDecimal closingWeightKg,
        BigDecimal inWeightKg,
        BigDecimal outWeightKg,
        long inWeightUnknownRows,
        long outWeightUnknownRows,
        BigDecimal residualKg) {
}

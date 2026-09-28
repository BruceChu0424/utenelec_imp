package com.uten.imp.features.stock.insight.dto;

import java.math.BigDecimal;
import java.util.UUID;

/**
 * 称重异常按往来方汇总 (窗口内, 只看有效且未排除的称重记录)。
 *
 * <p>供应商 (来料, RECEIPT): events = 到货称重次数, flagged = 告警且偏轻 (少数) 的次数,
 * avgPct = 这些次数的平均偏差 %, kg = 少了多少千克 (应有 − 实称)。
 * 车间 (领料, DRAW): events = 领料称重次数, flagged = 告警且偏重 (超发) 的次数,
 * avgPct = 平均偏差 %, kg = 多发了多少千克 (实称 − 应有)。
 *
 * @param partyId   供应商 id / 车间 (部门) id
 * @param partyName 名称
 * @param events    称重次数
 * @param flagged   异常次数
 * @param avgPct    异常次数的平均偏差 %
 * @param kg        异常累计千克
 */
public record WeightPartySummary(
        UUID partyId,
        String partyName,
        long events,
        long flagged,
        BigDecimal avgPct,
        BigDecimal kg) {
}

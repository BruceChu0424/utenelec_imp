package com.uten.imp.features.subcontract.short_delivery;

import java.math.BigDecimal;
import com.uten.imp.common.finance.BusinessPrecisionContext;

/**
 * 成品履约短交的唯一纯计算口径。供料最大损耗预算不能降低成品目标。
 *
 * <ul>
 *   <li>履约下限 F = Q；1000 目标、10% 供料预算的正常成品范围是 1000..1100。</li>
 *   <li>短交率 = (Q − D) / Q × 100, 除不尽时由本次用户明确选择精度。</li>
 *   <li>D ≥ Q 不短交；任何 D &lt; Q 都须分批等待或负责人明确处理，短交率 ≥20%为严重。</li>
 * </ul>
 */
public final class SubcontractShortDeliveryPolicy {

    public static final String SEVERE = "SEVERE";
    public static final String BELOW_FLOOR = "BELOW_FLOOR";
    public static final String WITHIN_TOLERANCE = "WITHIN_TOLERANCE";
    public static final String UNSET_TOLERANCE = "UNSET_TOLERANCE";

    public static final String PERCENT_PURPOSE = "subcontract.shortfall.percent";
    private static final BigDecimal HUNDRED = BigDecimal.valueOf(100);
    private static final BigDecimal SEVERE_MIN_SHORTFALL_PCT = BigDecimal.valueOf(20);

    private SubcontractShortDeliveryPolicy() {
    }

    /** 成品履约下限；供料损耗百分比只影响材料预算。 */
    public static BigDecimal floorQty(BigDecimal orderedQty, BigDecimal allowedLossPct) {
        return orderedQty;
    }

    /** 短交量 = max(Q − D, 0)。 */
    public static BigDecimal shortfallQty(BigDecimal orderedQty, BigDecimal deliveredQty) {
        BigDecimal delivered = deliveredQty == null ? BigDecimal.ZERO : deliveredQty;
        return orderedQty.subtract(delivered).max(BigDecimal.ZERO);
    }

    /** 短交率(%) = 短交量 / Q × 100; Q 为 0 时 0。 */
    public static BigDecimal shortfallPct(BigDecimal orderedQty, BigDecimal deliveredQty) {
        if (orderedQty == null || orderedQty.signum() <= 0) return BigDecimal.ZERO;
        return BusinessPrecisionContext.divide(shortfallQty(orderedQty, deliveredQty).multiply(HUNDRED),
                orderedQty,PERCENT_PURPOSE,"本次委外短交比例",24);
    }

    /** 严重程度按成品短交比例，独立于供料预算。 */
    public static BigDecimal severeThresholdPct(BigDecimal allowedLossPct) {
        return SEVERE_MIN_SHORTFALL_PCT;
    }

    /** 程度; 不短交(D ≥ Q)返回 null。 */
    public static String severity(BigDecimal orderedQty, BigDecimal allowedLossPct, BigDecimal deliveredQty) {
        BigDecimal delivered = deliveredQty == null ? BigDecimal.ZERO : deliveredQty;
        if (orderedQty == null || delivered.compareTo(orderedQty) >= 0) return null;
        // Business severity uses the original ratio, never a chosen display rounding.
        return shortfallQty(orderedQty,delivered).multiply(HUNDRED)
                .compareTo(orderedQty.multiply(severeThresholdPct(allowedLossPct)))>=0 ? SEVERE : BELOW_FLOOR;
    }

    /** 低于允许下限的两档(要弹窗、要紧急通知)。 */
    public static boolean isBelowFloor(String severity) {
        return SEVERE.equals(severity) || BELOW_FLOOR.equals(severity);
    }

    /** 成品短交没有由材料预算自动授予的正常损耗份额；负责人仍可明确受控认损。 */
    public static BigDecimal allowedLossQty(BigDecimal orderedQty, BigDecimal allowedLossPct) {
        return BigDecimal.ZERO;
    }
}

package com.uten.imp.features.subcontract.short_delivery;

import java.math.BigDecimal;
import java.math.RoundingMode;

/**
 * ADR-098 短交判定的纯口径(无 IO)：允许下限、短交率、程度。数量全部按订货单位。
 *
 * <ul>
 *   <li>允许下限 F = Q × (1 − p/100), 4 位小数; p 为空则无下限。</li>
 *   <li>短交率 = (Q − D) / Q × 100, 2 位小数。</li>
 *   <li>程度: D ≥ Q 不短交(返回 null); p 为空 → UNSET_TOLERANCE; D ≥ F → WITHIN_TOLERANCE;
 *       短交率 ≥ max(2p, 20)% → SEVERE; 其余 BELOW_FLOOR。</li>
 * </ul>
 */
public final class SubcontractShortDeliveryPolicy {

    public static final String SEVERE = "SEVERE";
    public static final String BELOW_FLOOR = "BELOW_FLOOR";
    public static final String WITHIN_TOLERANCE = "WITHIN_TOLERANCE";
    public static final String UNSET_TOLERANCE = "UNSET_TOLERANCE";

    static final int QTY_SCALE = 4;
    static final int PCT_SCALE = 2;
    private static final BigDecimal HUNDRED = BigDecimal.valueOf(100);
    private static final BigDecimal SEVERE_MIN_SHORTFALL_PCT = BigDecimal.valueOf(20);
    private static final BigDecimal SEVERE_TOLERANCE_MULTIPLIER = BigDecimal.valueOf(2);

    private SubcontractShortDeliveryPolicy() {
    }

    /** 允许下限; 允许损耗为空返回 null。 */
    public static BigDecimal floorQty(BigDecimal orderedQty, BigDecimal allowedLossPct) {
        if (orderedQty == null || allowedLossPct == null) return null;
        BigDecimal keep = HUNDRED.subtract(allowedLossPct).max(BigDecimal.ZERO);
        return orderedQty.multiply(keep).divide(HUNDRED, QTY_SCALE, RoundingMode.HALF_UP);
    }

    /** 短交量 = max(Q − D, 0)。 */
    public static BigDecimal shortfallQty(BigDecimal orderedQty, BigDecimal deliveredQty) {
        BigDecimal delivered = deliveredQty == null ? BigDecimal.ZERO : deliveredQty;
        return orderedQty.subtract(delivered).max(BigDecimal.ZERO).setScale(QTY_SCALE, RoundingMode.HALF_UP);
    }

    /** 短交率(%) = 短交量 / Q × 100; Q 为 0 时 0。 */
    public static BigDecimal shortfallPct(BigDecimal orderedQty, BigDecimal deliveredQty) {
        if (orderedQty == null || orderedQty.signum() <= 0) return BigDecimal.ZERO.setScale(PCT_SCALE);
        return shortfallQty(orderedQty, deliveredQty).multiply(HUNDRED)
                .divide(orderedQty, PCT_SCALE, RoundingMode.HALF_UP);
    }

    /** 严重短交阈值(%) = max(2 × 允许损耗, 20)。 */
    public static BigDecimal severeThresholdPct(BigDecimal allowedLossPct) {
        if (allowedLossPct == null) return SEVERE_MIN_SHORTFALL_PCT;
        return allowedLossPct.multiply(SEVERE_TOLERANCE_MULTIPLIER).max(SEVERE_MIN_SHORTFALL_PCT);
    }

    /** 程度; 不短交(D ≥ Q)返回 null。 */
    public static String severity(BigDecimal orderedQty, BigDecimal allowedLossPct, BigDecimal deliveredQty) {
        BigDecimal delivered = deliveredQty == null ? BigDecimal.ZERO : deliveredQty;
        if (orderedQty == null || delivered.compareTo(orderedQty) >= 0) return null;
        if (allowedLossPct == null) return UNSET_TOLERANCE;
        BigDecimal floor = floorQty(orderedQty, allowedLossPct);
        if (delivered.compareTo(floor) >= 0) return WITHIN_TOLERANCE;
        BigDecimal pct = shortfallPct(orderedQty, delivered);
        return pct.compareTo(severeThresholdPct(allowedLossPct)) >= 0 ? SEVERE : BELOW_FLOOR;
    }

    /** 低于允许下限的两档(要弹窗、要紧急通知)。 */
    public static boolean isBelowFloor(String severity) {
        return SEVERE.equals(severity) || BELOW_FLOOR.equals(severity);
    }

    /** 允许损耗对应的数量份额 = Q × p / 100(损耗单允许量的基数); p 为空按 0。 */
    public static BigDecimal allowedLossQty(BigDecimal orderedQty, BigDecimal allowedLossPct) {
        if (orderedQty == null || allowedLossPct == null) return BigDecimal.ZERO.setScale(QTY_SCALE);
        return orderedQty.multiply(allowedLossPct).divide(HUNDRED, QTY_SCALE, RoundingMode.HALF_UP);
    }
}

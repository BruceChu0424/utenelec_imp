package com.uten.imp.features.stock.weight;

import java.math.BigDecimal;
import java.math.MathContext;
import java.math.RoundingMode;

/**
 * 仓库重量账的取位口径(ADR-135): 流水、余额、调整行的重量都是千克, 统一四舍五入到 4 位(0.1 克)。
 *
 * <p>重量是数量口径, 不是金额(ArchitectureBoundaryTest 对 features/stock/weight/ 豁免 HALF_UP)。
 * 比例先按 34 位有效数字算完再取 4 位, 避免中间步骤先舍入造成的尾差。
 */
public final class WeightMath {

    public static final int SCALE = 4;
    private static final MathContext PRECISE = MathContext.DECIMAL128;

    private WeightMath() {
    }

    /** 4 位四舍五入; 空值原样返回。 */
    public static BigDecimal round4(BigDecimal kg) {
        return kg == null ? null : kg.setScale(SCALE, RoundingMode.HALF_UP);
    }

    /** qty x 每单位千克数, 取 4 位。 */
    public static BigDecimal times(BigDecimal qty, BigDecimal kgPerUnit) {
        return round4(qty.multiply(kgPerUnit, PRECISE));
    }

    /** total x part / whole, 取 4 位; whole 必须大于 0。 */
    public static BigDecimal prorate(BigDecimal total, BigDecimal part, BigDecimal whole) {
        if (whole == null || whole.signum() <= 0) {
            throw new IllegalArgumentException("weight proration needs a positive whole");
        }
        return round4(total.multiply(part, PRECISE).divide(whole, PRECISE));
    }

    /** 行单位本身是重量单位: 基本数量 / 换算率 = 行数量, 再乘该重量单位的千克数, 取 4 位。 */
    public static BigDecimal lineUnitWeight(BigDecimal baseQty, BigDecimal unitRate, BigDecimal kgPerLineUnit) {
        BigDecimal rate = unitRate == null || unitRate.signum() <= 0 ? BigDecimal.ONE : unitRate;
        return round4(baseQty.divide(rate, PRECISE).multiply(kgPerLineUnit, PRECISE));
    }

    /** 小数位超过 4 位的输入先去掉尾零, 仍超过则四舍五入到 4 位(重量永远不挡数量过账)。 */
    public static BigDecimal normalizeInput(BigDecimal kg) {
        if (kg == null || kg.scale() <= SCALE) return kg;
        BigDecimal stripped = kg.stripTrailingZeros();
        return stripped.scale() <= SCALE ? stripped : round4(kg);
    }

    public static boolean positive(BigDecimal value) {
        return value != null && value.signum() > 0;
    }

    public static boolean isZero(BigDecimal value) {
        return value != null && value.signum() == 0;
    }

    /** 两个可空重量是否相同(都未知也算相同; 数值按大小比较, 忽略小数位差异)。 */
    public static boolean sameKg(BigDecimal a, BigDecimal b) {
        if (a == null || b == null) return a == null && b == null;
        return a.compareTo(b) == 0;
    }

    /** after - before; 任一未知返回 null。 */
    public static BigDecimal delta(BigDecimal before, BigDecimal after) {
        return before == null || after == null ? null : after.subtract(before);
    }
}

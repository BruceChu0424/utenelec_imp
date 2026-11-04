package com.uten.imp.features.stock.weight;

import java.math.BigDecimal;

/** Exact kilogram facts and proration. Non-terminating or stored-field precision
 * limits require this operation's explicit BusinessPrecisionContext choice. */
public final class WeightMath {

    public static final int SCALE = 24;

    private WeightMath() {
    }

    /** Legacy method name: exact kilogram field boundary; null remains unknown. */
    public static BigDecimal round4(BigDecimal kg) {
        return kg==null?null:com.uten.imp.common.util.FinancialExactAmount.quantity(
            com.uten.imp.common.finance.BusinessPrecisionContext.divide(kg,BigDecimal.ONE,
                "weight.kg-field","本次千克重量记录",SCALE),"千克重量");
    }

    /** qty x 每单位千克数, 保留有限原值或明确选择24位边界。 */
    public static BigDecimal times(BigDecimal qty, BigDecimal kgPerUnit) {
        return round4(qty.multiply(kgPerUnit));
    }

    /** total x part / whole, 保留有限原值或明确选择24位边界; whole 必须大于 0。 */
    public static BigDecimal prorate(BigDecimal total, BigDecimal part, BigDecimal whole) {
        if (whole == null || whole.signum() <= 0) {
            throw new IllegalArgumentException("weight proration needs a positive whole");
        }
        BigDecimal result=com.uten.imp.common.util.FinancialExactAmount.quantity(
            com.uten.imp.common.finance.BusinessPrecisionContext.divide(total.multiply(part),whole,
                "weight.prorate","本次重量分摊",SCALE),"分摊重量");
        if(total.signum()>=0&&part.signum()>=0&&part.compareTo(whole)<=0&&result.compareTo(total)>0)
            throw new com.uten.imp.common.finance.BusinessPrecisionRequiredException("weight.prorate","本次重量分摊：上次精度超出原来源，请明确重新选择",SCALE,"PRECISION_LIMIT",true);
        return result;
    }

    /** 行单位本身是重量单位: 基本数量 / 换算率 = 行数量, 再乘该重量单位的千克数, 保留有限原值或明确选择24位边界。 */
    public static BigDecimal lineUnitWeight(BigDecimal baseQty, BigDecimal unitRate, BigDecimal kgPerLineUnit) {
        BigDecimal rate = unitRate == null || unitRate.signum() <= 0 ? BigDecimal.ONE : unitRate;
        return com.uten.imp.common.util.FinancialExactAmount.quantity(
            com.uten.imp.common.finance.BusinessPrecisionContext.divide(baseQty.multiply(kgPerLineUnit),rate,
                "weight.line-unit","本次行单位重量换算",SCALE),"行单位重量");
    }

    /** 有限输入完整保留；超过支持范围由本次明确选择处理，不默认取舍。 */
    public static BigDecimal normalizeInput(BigDecimal kg) { return round4(kg); }

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

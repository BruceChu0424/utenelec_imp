package com.uten.imp.features.stock.weight;

/**
 * Student-t 97.5% 分位数的近似 (Cornish-Fisher 三项展开, 与参考实现 apw_proto.py 同式)。
 *
 * <p>df 小时 (只有一两次称重) 区间自然变宽, 避免两次恰好一致的称重就被当成「可靠」。
 */
public final class StudentT {

    /** 标准正态 97.5% 分位数。 */
    public static final double Z975 = 1.959963985;

    private StudentT() {
    }

    /** t_{0.975}(df) ≈ z + 2.37228/df + 2.82202/df² + 2.55605/df³ (df > 0)。 */
    public static double t975(double df) {
        if (!(df > 0)) {
            throw new IllegalArgumentException("df must be > 0");
        }
        return Z975 + 2.37228 / df + 2.82202 / (df * df) + 2.55605 / StrictMath.pow(df, 3);
    }
}

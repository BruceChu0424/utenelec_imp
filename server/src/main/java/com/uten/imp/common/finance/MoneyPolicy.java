package com.uten.imp.common.finance;

import com.uten.imp.common.util.FinancialExactAmount;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.util.Collection;

/**
 * 全平台唯一的金额口径(ADR-112, 用户 2026-09-07 确认「财务不四舍五入, 分摊不丢余额」)。
 *
 * <ul>
 *   <li>乘积(数量 × 单价 × 折扣, 原币 × 汇率)保留完整位数, 只按 {@link FinancialExactAmount}
 *       的可无损保存上限校验, 从不舍入。</li>
 *   <li>按量分摊一律「累计量对应金额 − 已分摊金额」: 末批(累计量 = 来源量)直接取来源总额 − 已分摊,
 *       余数只在同一来源内继续核对, 不会丢也不会被造出来。</li>
 *   <li>累计份额能整除(有限小数, 不超过 24 位)取精确值; 除不尽时取到来源金额自身的小数位(至少 4 位)的
 *       最近值(四舍五入), 取舍差不单独记账, 留在来源余额里由后续批次(最终是末批)收回。
 *       只有除不尽的累计份额取位, 单据金额、乘积与末批都不取位。</li>
 *   <li>4 位库存价值列(IQC 放行、分批入库, V446/V449 库级守卫)用 {@link #projectedSlice}:
 *       ROUND(来源 × 累计量 / 来源量, 4)。来源是 4 位金额且除不尽时与 {@link #cumulativeShare} 逐位一致,
 *       所以同一张收货的仓库放行价值与财务不合格金额、退货可退额度相加恰好等于收货金额。</li>
 * </ul>
 *
 * <p>sales/purchase/subcontract/finance 与 common.finance 里, 除本类外禁止出现
 * {@code setScale(.., HALF_UP)} / {@code divide(.., n, HALF_UP)}(ArchitectureBoundaryTest 锁边)。
 * 数量列(NUMERIC(18,4))的存储取整也在这里, 与金额分开命名。
 */
public final class MoneyPolicy {
    /** 数量列存储位数(库存/单据数量 NUMERIC(18,4))。只用于数量, 金额从不经过它。 */
    public static final int QUANTITY_SCALE = 4;
    /** 除不尽的分摊份额至少保留的小数位(旧金额列与界面显示的最小位数)。 */
    private static final int MIN_SHARE_SCALE = 4;

    private MoneyPolicy() {
    }

    /** 数量 × 单价 的完整乘积。 */
    public static BigDecimal exactProduct(BigDecimal quantity, BigDecimal price) {
        return exactProduct(quantity, price, null);
    }

    /**
     * 数量 × 单价 × 折扣倍率 的完整乘积。折扣为空或 0 视为不打折(倍率 1): 历史订单行
     * discount 默认 0, 金额仍 = 数量 × 单价, 不能被重新解释成免费。
     * 数量与折扣列只存 4 位小数: 超出的输入先明确拒绝, 不让数据库悄悄舍入后「金额 ≠ 数量 × 单价」。
     */
    public static BigDecimal exactProduct(BigDecimal quantity, BigDecimal price, BigDecimal discount) {
        if (quantity == null || price == null) {
            throw invalid("数量和单价不能为空");
        }
        FinancialExactAmount.quantity(quantity, "数量");
        if (discount != null) FinancialExactAmount.quantity(discount, "折扣");
        BigDecimal product = quantity.multiply(price).multiply(discountMultiplier(discount));
        return canonical(FinancialExactAmount.book(product, "金额"));
    }

    /** 折扣倍率: 空或 0 表示未打折。负数由调用方的业务校验拒绝, 这里不替它改值。 */
    public static BigDecimal discountMultiplier(BigDecimal discount) {
        return discount == null || discount.signum() == 0 ? BigDecimal.ONE : discount;
    }

    /** 原币 × 汇率 = 本币账面值, 完整乘积(账面值最多 30 位小数)。 */
    public static BigDecimal local(BigDecimal original, BigDecimal rate) {
        if (original == null || rate == null) {
            throw invalid("原币金额和汇率不能为空");
        }
        return canonical(FinancialExactAmount.book(original.multiply(rate), "本币金额"));
    }

    /**
     * 单据行金额: 单价空则金额空(不采信也不猜); 汇率空则本币空。
     * 没有币种的单据(申请、报价、发料等)由调用方传汇率 1。
     */
    public static LineAmounts line(BigDecimal quantity, BigDecimal price, BigDecimal discount, BigDecimal rate) {
        if (quantity == null || price == null) {
            return new LineAmounts(null, null);
        }
        BigDecimal original = exactProduct(quantity, price, discount);
        return new LineAmounts(original, rate == null ? null : local(original, rate));
    }

    /** 表头合计 = 行金额相加; 空行金额不计入。全部为空时返回 0(与旧表头口径一致)。 */
    public static BigDecimal sum(Collection<BigDecimal> amounts) {
        BigDecimal total = BigDecimal.ZERO;
        if (amounts == null) return total;
        for (BigDecimal amount : amounts) {
            if (amount != null) total = total.add(amount);
        }
        return total;
    }

    /**
     * 来源总额中累计量 cumulativeQty 对应的份额。
     * 末批(累计量 = 来源量)返回来源总额本身; 能整除取精确值(部分出货/退货就是本批数量的精确乘积);
     * 除不尽取到来源金额自身小数位(至少 4 位)的最近值——取舍差留在来源余额里, 末批收回。
     */
    public static BigDecimal cumulativeShare(BigDecimal total, BigDecimal cumulativeQty, BigDecimal sourceQty) {
        requireShareBasis(total, cumulativeQty, sourceQty);
        if (cumulativeQty.compareTo(sourceQty) == 0) return total;
        if (cumulativeQty.signum() == 0) return BigDecimal.ZERO;
        BigDecimal numerator = total.multiply(cumulativeQty);
        try {
            BigDecimal exact = numerator.divide(sourceQty).stripTrailingZeros();
            if (exact.scale() <= FinancialExactAmount.MAX_FRACTION_DIGITS) return canonical(exact);
        } catch (ArithmeticException nonTerminating) {
            // 除不尽: 落到下面按来源位数取最近值。
        }
        return canonical(numerator.divide(sourceQty, shareScale(total), RoundingMode.HALF_UP));
    }

    /**
     * 4 位库存价值列(IQC 放行价值、分批入库价值, 列为 NUMERIC(18,4))的切片:
     * 本片 = ROUND(来源 × (before + slice) / 来源量, 4) − ROUND(来源 × before / 来源量, 4),
     * 切到来源量时取全部剩余。与 V446/V449 库级守卫同一公式; 来源是 4 位金额且除不尽时与
     * {@link #cumulativeShare} 逐位一致。库存估值整体精确化前, 这是 4 位价值列唯一的切法。
     */
    public static BigDecimal projectedSlice(BigDecimal total, BigDecimal whole, BigDecimal before, BigDecimal slice) {
        if (before == null || slice == null || slice.signum() < 0) {
            throw conflict("金额切片的来源无效");
        }
        return projectedShare(total, before.add(slice), whole).subtract(projectedShare(total, before, whole));
    }

    private static BigDecimal projectedShare(BigDecimal total, BigDecimal cumulativeQty, BigDecimal sourceQty) {
        requireShareBasis(total, cumulativeQty, sourceQty);
        if (cumulativeQty.compareTo(sourceQty) == 0) return total;
        return total.multiply(cumulativeQty).divide(sourceQty, MIN_SHARE_SCALE, RoundingMode.HALF_UP);
    }

    private static void requireShareBasis(BigDecimal total, BigDecimal cumulativeQty, BigDecimal sourceQty) {
        if (total == null || cumulativeQty == null || sourceQty == null
                || sourceQty.signum() <= 0 || cumulativeQty.signum() < 0
                || cumulativeQty.compareTo(sourceQty) > 0) {
            throw conflict("分摊数量超过来源数量或来源数量无效");
        }
    }

    /**
     * 同一来源按事件先后切片的本片金额 = 累计份额(before + slice) − 累计份额(before)。
     * 切到来源量时取全部剩余, 所以各片之和恰好等于来源总额(财务侧 IQC 不合格金额用它)。
     */
    public static BigDecimal amountSlice(BigDecimal total, BigDecimal whole, BigDecimal before, BigDecimal slice) {
        if (before == null || slice == null || slice.signum() < 0) {
            throw conflict("金额切片的来源无效");
        }
        return canonical(cumulativeShare(total, before.add(slice), whole)
                .subtract(cumulativeShare(total, before, whole)));
    }

    /**
     * 本批分摊额 = 累计份额(prior + 本批) − 已分摊金额; 末批 = 来源总额 − 已分摊金额。
     * 已分摊金额超过累计份额(例如中间批次被红冲)时本批记 0, 差额继续留在来源余额里由末批收回。
     */
    public static BigDecimal prorate(
            BigDecimal total, BigDecimal cumulativeQty, BigDecimal sourceQty, BigDecimal priorAllocated) {
        if (priorAllocated == null) {
            throw conflict("来源已分摊金额缺失");
        }
        BigDecimal share = cumulativeShare(total, cumulativeQty, sourceQty);
        BigDecimal amount = share.subtract(priorAllocated);
        if (cumulativeQty.compareTo(sourceQty) == 0) {
            if (amount.signum() < 0) {
                throw conflict("来源已分摊金额超过来源总额, 请先核对历史批次");
            }
            return canonical(amount);
        }
        return canonical(amount.max(BigDecimal.ZERO));
    }

    /** 同一来源一批的原币与本币: 两个都按累计差额分摊, 末批取全部剩余。 */
    public static LineAmounts prorateBatch(
            BigDecimal batchQty, BigDecimal priorQty, BigDecimal sourceQty,
            BigDecimal sourceOriginal, BigDecimal sourceLocal,
            BigDecimal priorOriginal, BigDecimal priorLocal) {
        if (batchQty == null || batchQty.signum() <= 0 || priorQty == null || priorQty.signum() < 0) {
            throw conflict("分摊批次数量无效");
        }
        BigDecimal cumulative = priorQty.add(batchQty);
        return new LineAmounts(
                prorate(sourceOriginal, cumulative, sourceQty, priorOriginal),
                prorate(sourceLocal, cumulative, sourceQty, priorLocal));
    }

    /**
     * 除不尽的累计份额一次取位可能产生的最大偏差上界(来源金额最末一位的 1 个单位)。
     * 用于核对历史批次累计是否仍落在「累计份额」附近: 每红冲一批最多多出一个单位。
     */
    public static BigDecimal shareGranularity(BigDecimal total) {
        return BigDecimal.ONE.movePointLeft(shareScale(total));
    }

    /** 份额位数 = 来源金额自身的小数位, 至少 4 位。 */
    private static int shareScale(BigDecimal total) {
        return Math.max(MIN_SHARE_SCALE, Math.max(0, total.stripTrailingZeros().scale()));
    }

    /** 数量按比例拆分(基本单位 ↔ 单据单位): 整除取精确值, 否则按数量列 4 位四舍五入。只用于数量。 */
    public static BigDecimal quantityShare(BigDecimal quantity, BigDecimal part, BigDecimal whole) {
        if (quantity == null || part == null || whole == null || whole.signum() <= 0) {
            throw conflict("数量拆分的来源无效");
        }
        if (part.compareTo(whole) == 0) return quantity;
        return quantity(quantity.multiply(part).divide(whole, QUANTITY_SCALE + 8, RoundingMode.HALF_UP));
    }

    /** 基本单位量 → 单据单位量(除以换算率), 按数量列 4 位四舍五入。只用于数量。 */
    public static BigDecimal quantityFromBase(BigDecimal baseQuantity, BigDecimal unitRate) {
        if (baseQuantity == null || unitRate == null || unitRate.signum() <= 0) {
            throw conflict("单位换算率无效");
        }
        return baseQuantity.divide(unitRate, QUANTITY_SCALE, RoundingMode.HALF_UP);
    }

    /**
     * 数量/重量按累计切片(4 位存储): 本片 = 累计量对应份额 − 之前累计份额, 两端各按 4 位四舍五入,
     * 切完时各片之和恰好等于来源总量。只用于数量与重量。
     */
    public static BigDecimal quantitySlice(
            BigDecimal total, BigDecimal whole, BigDecimal before, BigDecimal slice) {
        if (total == null || whole == null || whole.signum() <= 0 || before == null || slice == null) {
            throw conflict("数量切片的来源无效");
        }
        BigDecimal previous = total.multiply(before).divide(whole, QUANTITY_SCALE, RoundingMode.HALF_UP);
        BigDecimal next = total.multiply(before.add(slice)).divide(whole, QUANTITY_SCALE, RoundingMode.HALF_UP);
        return next.subtract(previous);
    }

    /** 数量列存储口径: 4 位四舍五入。只用于数量(含基本单位换算量), 金额从不经过它。 */
    public static BigDecimal quantity(BigDecimal value) {
        return value == null ? null : value.setScale(QUANTITY_SCALE, RoundingMode.HALF_UP);
    }

    /**
     * 金额的统一表示: 数值不变, 只把小数位补到至少 4 位(与旧金额列、界面显示对齐),
     * 更多位数原样保留。这是格式, 不是舍入。
     */
    public static BigDecimal canonical(BigDecimal value) {
        if (value == null) return null;
        BigDecimal exact = value.stripTrailingZeros();
        return exact.setScale(Math.max(MIN_SHARE_SCALE, exact.scale()), RoundingMode.UNNECESSARY);
    }

    /** 报表占比(%): 展示用比例, 两位小数四舍五入; 不是金额, 不参与任何合计或回写。 */
    public static BigDecimal percentOf(BigDecimal part, BigDecimal whole) {
        if (part == null || whole == null || whole.signum() == 0) return null;
        return part.multiply(BigDecimal.valueOf(100)).divide(whole, 2, RoundingMode.HALF_UP);
    }

    /** 汇率的统一表示: 数值不变, 小数位补到至少 6 位(汇率输入上限), 不舍入。 */
    public static BigDecimal canonicalRate(BigDecimal rate) {
        if (rate == null) return null;
        BigDecimal exact = rate.stripTrailingZeros();
        return exact.setScale(Math.max(6, exact.scale()), RoundingMode.UNNECESSARY);
    }

    /**
     * 单位价值(总额 ÷ 数量)只作展示投影: 整除取精确值, 除不尽按账面上限 30 位向下截取;
     * 业务金额始终取来源总额, 不用它回乘。
     */
    public static BigDecimal unitValue(BigDecimal total, BigDecimal quantity) {
        if (total == null || quantity == null || quantity.signum() <= 0) {
            throw conflict("单位价值的来源无效");
        }
        try {
            BigDecimal exact = total.divide(quantity).stripTrailingZeros();
            if (exact.scale() <= FinancialExactAmount.MAX_BOOK_FRACTION_DIGITS) return canonical(exact);
        } catch (ArithmeticException nonTerminating) {
            // 除不尽: 向下截取到账面位数上限。
        }
        return total.divide(quantity, FinancialExactAmount.MAX_BOOK_FRACTION_DIGITS, RoundingMode.DOWN);
    }

    /** 行金额(原币/本币)。 */
    public record LineAmounts(BigDecimal original, BigDecimal local) {
    }

    private static ApiException invalid(String message) {
        return new ApiException(ErrorCode.VALIDATION_FAILED, message);
    }

    private static ApiException conflict(String message) {
        return new ApiException(ErrorCode.CONFLICT, message);
    }
}

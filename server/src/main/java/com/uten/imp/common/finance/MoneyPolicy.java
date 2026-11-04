package com.uten.imp.common.finance;

import com.uten.imp.common.util.FinancialExactAmount;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.util.Collection;

/**
 * Shared business money/quantity arithmetic. Finite decimal values are retained;
 * a repeating or storage-limited result requires the current user's explicit
 * BusinessPrecisionContext choice. There is no automatic rounding default.
 *
 * Source allocations remain cumulative and the final slice takes the actual
 * remainder. An explicit precision choice never creates a second cost/fee.
 * QUANTITY_SCALE is retained only as legacy formatting metadata, not a coercion.
 */
public final class MoneyPolicy {
    /** 旧数量格式的位数；新业务值不按此常量改变精度。 */
    public static final int QUANTITY_SCALE = 4;
    /** 只用于旧来源证明的粒度校验与补尾零格式，不是新计算的舍入策略。 */
    private static final int LEGACY_FORMAT_SCALE = 4;

    private MoneyPolicy() {
    }

    /** 数量 × 单价 的完整乘积。 */
    public static BigDecimal exactProduct(BigDecimal quantity, BigDecimal price) {
        return exactProduct(quantity, price, null);
    }

    /**
     * 数量 × 单价 × 折扣倍率 的完整乘积。折扣为空或 0 视为不打折(倍率 1): 历史订单行
     * discount 默认 0, 金额仍 = 数量 × 单价, 不能被重新解释成免费。
     * 输入先校验当前支持范围；完整乘积超出账面存储范围时，须本次用户明确选择处理精度。
     */
    public static BigDecimal exactProduct(BigDecimal quantity, BigDecimal price, BigDecimal discount) {
        if (quantity == null || price == null) {
            throw invalid("数量和单价不能为空");
        }
        FinancialExactAmount.quantity(quantity, "数量");
        if (discount != null) FinancialExactAmount.quantity(discount, "折扣");
        BigDecimal product = quantity.multiply(price).multiply(discountMultiplier(discount));
        return canonical(FinancialExactAmount.book(BusinessPrecisionContext.limit(product,"money.product","本次数量、单价和折扣乘积",FinancialExactAmount.MAX_BOOK_FRACTION_DIGITS), "金额"));
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
        return canonical(FinancialExactAmount.book(BusinessPrecisionContext.limit(original.multiply(rate),"money.local-product","本次原币和汇率乘积",FinancialExactAmount.MAX_BOOK_FRACTION_DIGITS), "本币金额"));
    }

    /**
     * 单据行金额: 单价空则金额空(不采信也不猜); 汇率空则本币空。
     * 没有币种的单据(申请、报价、发料等)由调用方传汇率 1。
     */
    public static LineAmounts line(BigDecimal quantity, BigDecimal price, BigDecimal discount, BigDecimal rate) {
        if (quantity != null) FinancialExactAmount.quantity(quantity, "数量");
        if (quantity == null || price == null) {
            return new LineAmounts(null, null);
        }
        BigDecimal original = exactProduct(quantity, price, discount);
        return new LineAmounts(original, rate == null ? null : local(original, rate));
    }

    /** User-entered line consideration is a fact; its displayed unit price is only a reference. */
    public static BigDecimal totalAmountInput(BigDecimal total) {
        if (total == null) return null;
        BigDecimal exact = FinancialExactAmount.require(total, "总金额");
        if (exact.signum() < 0) throw invalid("总金额不能为负数");
        return exact;
    }

    /** Never multiply a projected display/reference price back into the agreed total. */
    public static BigDecimal referenceUnitPrice(BigDecimal total, BigDecimal quantity) {
        BigDecimal exact = totalAmountInput(total);
        if (exact == null || quantity == null || quantity.signum() <= 0) {
            throw invalid("按总金额计价时数量必须大于 0");
        }
        FinancialExactAmount.quantity(quantity, "数量");
        return FinancialExactAmount.unitPrice(BusinessPrecisionContext.divide(exact,quantity,"money.reference-unit-price","本次参考单价",FinancialExactAmount.MAX_FRACTION_DIGITS), "参考单价");
    }

    /** The input total precedes any separately declared extra-column adjustments. */
    public static BigDecimal orderBaseAmount(BigDecimal quantity, BigDecimal price, BigDecimal totalInput) {
        if (totalInput != null) {
            referenceUnitPrice(totalInput, quantity);
            return canonical(totalAmountInput(totalInput));
        }
        return price == null ? null : exactProduct(quantity, price);
    }

    /** Approved quantity revisions retain the original exact ratio, never the reference price. */
    public static BigDecimal revisedTotalAmountInput(BigDecimal total, BigDecimal oldQty, BigDecimal newQty) {
        if (total == null) return null;
        if (oldQty == null || oldQty.signum() <= 0 || newQty == null || newQty.signum() <= 0) {
            throw invalid("按总金额计价的改量数量必须大于 0");
        }
        FinancialExactAmount.quantity(newQty, "数量");
        return totalAmountInput(BusinessPrecisionContext.divide(totalAmountInput(total).multiply(newQty),oldQty,"money.revised-total","本次按原总额比例改量",FinancialExactAmount.MAX_FRACTION_DIGITS));
    }

    /** Extra deliveries require the same exact commercial ratio as a quantity revision. */
    public static BigDecimal orderOverageAmount(BigDecimal qty, BigDecimal price,
            BigDecimal totalInput, BigDecimal sourceQty) {
        if (qty.signum() == 0) return BigDecimal.ZERO;
        return totalInput == null ? exactProduct(qty, price)
                : revisedTotalAmountInput(totalInput, sourceQty, qty);
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
     * 除不尽由本次用户选择保留位数和取舍方式；差额留在同一来源余额，末批收回。
     */
    public static BigDecimal cumulativeShare(BigDecimal total, BigDecimal cumulativeQty, BigDecimal sourceQty) {
        return cumulativeShare(total,cumulativeQty,sourceQty,"money.cumulative-share","本次金额分摊",FinancialExactAmount.MAX_FRACTION_DIGITS);
    }

    private static BigDecimal cumulativeShare(BigDecimal total, BigDecimal cumulativeQty, BigDecimal sourceQty,
            String purpose,String label,int maximumScale) {
        requireShareBasis(total, cumulativeQty, sourceQty);
        if (cumulativeQty.compareTo(sourceQty) == 0) return total;
        if (cumulativeQty.signum() == 0) return BigDecimal.ZERO;
        return canonical(BusinessPrecisionContext.divide(total.multiply(cumulativeQty),sourceQty,purpose,label,maximumScale));
    }

    /**
     * 库存价值切片复用累计份额：本片=累计到本片之后−累计到本片之前。
     * 两端均按完整来源或本次显式精度处理，最后一片保留同一来源真实余数。
     */
    public static BigDecimal projectedSlice(BigDecimal total, BigDecimal whole, BigDecimal before, BigDecimal slice) {
        if (before == null || slice == null || slice.signum() < 0) {
            throw conflict("金额切片的来源无效");
        }
        return projectedShare(total, before.add(slice), whole).subtract(projectedShare(total, before, whole));
    }

    /** Same cumulative allocation, with the book-value field's 30-place storage boundary. */
    public static BigDecimal bookValueSlice(BigDecimal total,BigDecimal whole,BigDecimal before,BigDecimal slice) {
        if(before==null||slice==null||slice.signum()<0)throw conflict("库存价值切片的来源无效");
        requireShareBasis(total,before.add(slice),whole);
        if(slice.signum()==0)return BigDecimal.ZERO;
        BigDecimal amount=FinancialExactAmount.book(cumulativeShare(total,before.add(slice),whole,
                "stock.value.interval","本次库存价值累计切片",FinancialExactAmount.MAX_BOOK_FRACTION_DIGITS)
            .subtract(cumulativeShare(total,before,whole,
                "stock.value.interval","本次库存价值累计切片",FinancialExactAmount.MAX_BOOK_FRACTION_DIGITS)),"库存价值切片");
        if(amount.abs().compareTo(total.abs())>0||amount.signum()!=0&&amount.signum()!=total.signum())
            throw new BusinessPrecisionRequiredException("stock.value.interval","本次库存价值切片：上次精度超出原来源，请明确重新选择",
                FinancialExactAmount.MAX_BOOK_FRACTION_DIGITS,"PRECISION_LIMIT",true);
        return amount;
    }

    private static BigDecimal projectedShare(BigDecimal total, BigDecimal cumulativeQty, BigDecimal sourceQty) {
        requireShareBasis(total, cumulativeQty, sourceQty);
        if (cumulativeQty.compareTo(sourceQty) == 0) return total;
        return cumulativeShare(total,cumulativeQty,sourceQty);
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
        return Math.max(LEGACY_FORMAT_SCALE, Math.max(0, total.stripTrailingZeros().scale()));
    }

    /** 数量按比例拆分：有限结果精确保留，除不尽使用本次用户明确选择。 */
    public static BigDecimal quantityShare(BigDecimal quantity, BigDecimal part, BigDecimal whole) {
        if (quantity == null || part == null || whole == null || whole.signum() <= 0) {
            throw conflict("数量拆分的来源无效");
        }
        if (part.compareTo(whole) == 0) return quantity;
        return quantity(BusinessPrecisionContext.divide(quantity.multiply(part),whole,"quantity.share","本次数量分配",FinancialExactAmount.MAX_FRACTION_DIGITS));
    }

    /** 基本单位量换算：不按旧四位默认舍入。 */
    public static BigDecimal quantityFromBase(BigDecimal baseQuantity, BigDecimal unitRate) {
        if (baseQuantity == null || unitRate == null || unitRate.signum() <= 0) {
            throw conflict("单位换算率无效");
        }
        return BusinessPrecisionContext.divide(baseQuantity,unitRate,"quantity.from-base","本次基本单位换算",FinancialExactAmount.MAX_FRACTION_DIGITS);
    }

    /** Original line quantity/rate remain independent operands. Only the
     * derived native basic quantity consumes an explicit storage choice. */
    public static BigDecimal quantityToBase(BigDecimal lineQuantity,BigDecimal unitRate){
        if(lineQuantity==null||unitRate==null||unitRate.signum()<=0)throw conflict("单位换算率或原数量尚未核对，不能默认按1换算");
        BigDecimal qty=FinancialExactAmount.quantity(lineQuantity,"原数量"),rate=FinancialExactAmount.rate(unitRate,"原单位换算率");
        BigDecimal result=quantity(BusinessPrecisionContext.divide(qty.multiply(rate),BigDecimal.ONE,"quantity.to-base","本次基本单位数量换算",FinancialExactAmount.MAX_FRACTION_DIGITS));
        if(qty.signum()!=0&&result.signum()==0)throw new BusinessPrecisionRequiredException("quantity.to-base","本次基本单位数量换算：所选精度会丢失非零实物，请明确重新选择",FinancialExactAmount.MAX_FRACTION_DIGITS,"PRECISION_LIMIT",true);
        return result;
    }

    /**
     * 数量/重量按累计切片，有限值完整保留，除不尽复用本次用户明确的选择。
     * 切完时各片之和等于同一来源总量。
     */
    public static BigDecimal quantitySlice(
            BigDecimal total, BigDecimal whole, BigDecimal before, BigDecimal slice) {
        if (total == null || whole == null || whole.signum() <= 0 || before == null || slice == null) {
            throw conflict("数量切片的来源无效");
        }
        BigDecimal previous = before.signum()==0?BigDecimal.ZERO:BusinessPrecisionContext.divide(total.multiply(before),whole,"quantity.slice","本次数量或重量切片",FinancialExactAmount.MAX_FRACTION_DIGITS);
        BigDecimal next = before.add(slice).compareTo(whole)==0?total:BusinessPrecisionContext.divide(total.multiply(before.add(slice)),whole,"quantity.slice","本次数量或重量切片",FinancialExactAmount.MAX_FRACTION_DIGITS);
        return next.subtract(previous);
    }

    /** 数量存储校验：不改变有限原值。 */
    public static BigDecimal quantity(BigDecimal value) {
        return value == null ? null : FinancialExactAmount.quantity(value,"数量");
    }

    /** 兼容旧展示调用；现在完整保留原值，不再按传入的展示位数取舍。 */
    public static BigDecimal quantityDisplay(BigDecimal value, int scale) {
        return value;
    }

    /**
     * 金额的统一表示: 数值不变, 只把小数位补到至少 4 位(与旧金额列、界面显示对齐),
     * 更多位数原样保留。这是格式, 不是舍入。
     */
    public static BigDecimal canonical(BigDecimal value) {
        if (value == null) return null;
        BigDecimal exact = value.stripTrailingZeros();
        return exact.setScale(Math.max(LEGACY_FORMAT_SCALE, exact.scale()), RoundingMode.UNNECESSARY);
    }

    /** 报表比例：保留有限精度；非有限时必须由用户选择。 */
    public static BigDecimal percentOf(BigDecimal part, BigDecimal whole) {
        if (part == null || whole == null || whole.signum() == 0) return null;
        return BusinessPrecisionContext.divide(part.multiply(BigDecimal.valueOf(100)),whole,"report.percentage","本次报表比例",FinancialExactAmount.MAX_BOOK_FRACTION_DIGITS);
    }

    /** 汇率的统一表示: 数值不变, 小数位补到至少 6 位(汇率输入上限), 不舍入。 */
    public static BigDecimal canonicalRate(BigDecimal rate) {
        if (rate == null) return null;
        BigDecimal exact = rate.stripTrailingZeros();
        return exact.setScale(Math.max(6, exact.scale()), RoundingMode.UNNECESSARY);
    }

    /**
     * 单位价值(总额 ÷ 数量)只作展示投影: 有限值精确保留，除不尽由本次用户选择;
     * 业务金额始终取来源总额, 不用它回乘。
     */
    public static BigDecimal unitValue(BigDecimal total, BigDecimal quantity) {
        if (total == null || quantity == null || quantity.signum() <= 0) {
            throw conflict("单位价值的来源无效");
        }
        return BusinessPrecisionContext.divide(total,quantity,"money.unit-value","本次单位价值",FinancialExactAmount.MAX_BOOK_FRACTION_DIGITS);
    }

    /**
     * 由「对方写的单价」反推销售折扣倍率(ADR-134): 折扣 = 对方单价 × 汇率 ÷ 标价, 按折扣列 4 位四舍五入。
     * 只算折扣, 从不改写任何单价; 标价仍是货品资料的售价(销售无权改价)。
     * 也用于财务按「成交单价」反推折扣(汇率传 1)。
     *
     * <ul>
     *   <li>标价为空或不大于 0: {@link DiscountFlag#NO_LIST_PRICE}, 折扣为空(需财务先定价)。</li>
     *   <li>对方单价或汇率为空/不大于 0: {@link DiscountFlag#INVALID}, 折扣为空。</li>
     *   <li>取位后大于 1(对方单价高于标价): {@link DiscountFlag#ABOVE_LIST}, 折扣为空, 绝不截成 1。</li>
     *   <li>取位后等于换算单价: {@link DiscountFlag#OK}; 有取位差: {@link DiscountFlag#ROUNDED},
     *       unitGap = |对方单价 × 汇率 − 标价 × 折扣|(单件差额, 调用方乘数量展示)。</li>
     * </ul>
     * 合理区间(例如 0.3 以上)属于业务判断, 由调用方比较, 不在这里取舍。
     */
    public static DiscountQuote discountFromUnitPrice(BigDecimal counterpartUnitPrice, BigDecimal rate, BigDecimal listPrice) {
        if (listPrice == null || listPrice.signum() <= 0) {
            return new DiscountQuote(null, DiscountFlag.NO_LIST_PRICE, null);
        }
        if (counterpartUnitPrice == null || counterpartUnitPrice.signum() <= 0 || rate == null || rate.signum() <= 0) {
            return new DiscountQuote(null, DiscountFlag.INVALID, null);
        }
        BigDecimal converted = counterpartUnitPrice.multiply(rate);
        BigDecimal discount = BusinessPrecisionContext.divide(converted,listPrice,"money.discount","本次成交折扣",FinancialExactAmount.MAX_FRACTION_DIGITS);
        if (discount.signum() <= 0) {
            return new DiscountQuote(null, DiscountFlag.INVALID, null);
        }
        if (discount.compareTo(BigDecimal.ONE) > 0) {
            return new DiscountQuote(null, DiscountFlag.ABOVE_LIST, null);
        }
        BigDecimal gap = converted.subtract(listPrice.multiply(discount)).abs();
        return new DiscountQuote(discount, gap.signum() == 0 ? DiscountFlag.OK : DiscountFlag.ROUNDED,
                canonical(gap));
    }

    /** {@link #discountFromUnitPrice} 的结果: discount 为 4 位倍率或空; unitGap 仅在算出折扣时给出。 */
    public record DiscountQuote(BigDecimal discount, DiscountFlag flag, BigDecimal unitGap) {
    }

    /** 反推折扣的结论。 */
    public enum DiscountFlag { OK, ROUNDED, ABOVE_LIST, NO_LIST_PRICE, INVALID }

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

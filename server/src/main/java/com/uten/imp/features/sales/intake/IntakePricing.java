package com.uten.imp.features.sales.intake;

import com.uten.imp.common.finance.MoneyPolicy;
import com.uten.imp.common.finance.MoneyPolicy.DiscountFlag;
import com.uten.imp.common.finance.MoneyPolicy.DiscountQuote;
import com.uten.imp.features.sales.SalesPriceAuthority;

import java.math.BigDecimal;
import java.util.UUID;

/**
 * 按文件单价反推折扣(SPEC §5.7)。<b>从不写任何价格</b>: 单价永远是货品资料的标价, 这里只算「文件单价 ÷ 标价」的折扣,
 * 舍入只经 {@link MoneyPolicy#discountFromUnitPrice}(4 位, 这里不做任何舍入)。
 *
 * <p>单据币种一律是本位币。文件是外币时, 汇率只用财务在币种资料里维护的参考汇率(销售不能填)。
 * 外币文件同时试「按 1 折算」(客户直接写的人民币价)与「按汇率折算」: 只有一种落在 (0.3, 1] 才采用;
 * 两种都在范围内(AMBIGUOUS_CURRENCY)或都不在(OUT_OF_RANGE / ABOVE_LIST)时不给折扣, 交给人核对。
 * 「落在 (0.3, 1]」判的是 MoneyPolicy 取 4 位后的折扣, 用 {@link SalesPriceAuthority#plausibleDiscount} ——
 * 与看不到价格的人保存时服务端反推折扣是同一个判断, 同一行文件不会因为谁在看而得到不同的折扣。
 */
final class IntakePricing {

    static final String OK = "OK";
    static final String ROUNDED = "ROUNDED";
    static final String NO_LIST_PRICE = "NO_LIST_PRICE";
    static final String ABOVE_LIST = "ABOVE_LIST";
    static final String OUT_OF_RANGE = "OUT_OF_RANGE";
    static final String AMBIGUOUS_CURRENCY = "AMBIGUOUS_CURRENCY";
    static final String RATE_MISSING = "RATE_MISSING";

    private IntakePricing() {
    }

    /**
     * 文件币种与本位币信息。
     *
     * @param fileCurrency     文件上写明的币种(CNY/USD/EUR/HKD); 不知道为 null
     * @param baseCurrencyId   本位币 id
     * @param baseCurrencyName 本位币名称(如「人民币」)
     * @param foreign          文件币种明确是外币(与本位币不同)
     * @param financeRate      该外币的财务参考汇率(大于 0 才有值)
     * @param fileCurrencyName 文件币种中文名(提示用, 如「美元」)
     */
    record CurrencyInfo(String fileCurrency, UUID baseCurrencyId, String baseCurrencyName, boolean foreign,
                        BigDecimal financeRate, String fileCurrencyName) {

        boolean rateMissing() {
            return foreign && (financeRate == null || financeRate.signum() <= 0);
        }

        GoodsMatcher.PriceContext priceContext() {
            return new GoodsMatcher.PriceContext(foreign, financeRate == null ? 0 : financeRate.doubleValue());
        }
    }

    /**
     * 一个候选货品的定价结论。
     *
     * @param discount 折扣(4 位小数); 不能确定为 null
     * @param rateUsed 采用的折算率(1 或参考汇率); 没有采用为 null
     * @param flag     OK / ROUNDED / NO_LIST_PRICE / ABOVE_LIST / OUT_OF_RANGE / AMBIGUOUS_CURRENCY / RATE_MISSING;
     *                 文件没写单价为 null
     * @param note     给人看的一句话说明; 可为 null
     */
    record CandidatePricing(BigDecimal listPrice, BigDecimal discount, BigDecimal rateUsed, String flag, String note) {

        /** 阻断性状态: 没有标价或客户价高于标价(订货单不能直接导入)。 */
        boolean blocking() {
            return NO_LIST_PRICE.equals(flag) || ABOVE_LIST.equals(flag);
        }
    }

    static CandidatePricing price(BigDecimal customerPrice, BigDecimal listPrice, CurrencyInfo currency) {
        if (listPrice == null || listPrice.signum() <= 0) {
            return new CandidatePricing(listPrice, null, null, NO_LIST_PRICE, "这个货品还没有标价, 需要财务定价");
        }
        if (customerPrice == null || customerPrice.signum() <= 0) {
            return new CandidatePricing(listPrice, null, null, null, null);
        }
        DiscountQuote plain = MoneyPolicy.discountFromUnitPrice(customerPrice, BigDecimal.ONE, listPrice);
        boolean in1 = plausible(plain);
        if (currency.foreign() && !currency.rateMissing()) {
            BigDecimal rate = currency.financeRate();
            DiscountQuote converted = MoneyPolicy.discountFromUnitPrice(customerPrice, rate, listPrice);
            boolean inR = plausible(converted);
            if (in1 && inR) {
                return new CandidatePricing(listPrice, null, null, AMBIGUOUS_CURRENCY,
                        "按" + label(currency) + "和按人民币算都说得通, 请核对后再填折扣");
            }
            if (in1) {
                return adopt(plain, BigDecimal.ONE, listPrice,
                        "客户单价按" + currency.baseCurrencyName() + "标价计算(没有按汇率换算)");
            }
            if (inR) {
                return adopt(converted, rate, listPrice, null);
            }
            return outOfRange(listPrice, plain.flag() == DiscountFlag.ABOVE_LIST
                    && converted.flag() == DiscountFlag.ABOVE_LIST);
        }
        if (currency.foreign()) {
            if (in1) {
                return adopt(plain, BigDecimal.ONE, listPrice, "客户单价按" + currency.baseCurrencyName() + "标价计算");
            }
            return new CandidatePricing(listPrice, null, null, RATE_MISSING,
                    label(currency) + "参考汇率未维护, 请财务在币种资料中填写");
        }
        if (in1) {
            return adopt(plain, BigDecimal.ONE, listPrice, null);
        }
        return outOfRange(listPrice, plain.flag() == DiscountFlag.ABOVE_LIST);
    }

    /** 取 4 位后的折扣落在 (0.3, 1](与服务端保存时反推折扣同一个判断)。 */
    private static boolean plausible(DiscountQuote quote) {
        return SalesPriceAuthority.plausibleDiscount(quote.discount());
    }

    private static CandidatePricing adopt(DiscountQuote quote, BigDecimal rate, BigDecimal listPrice, String note) {
        return new CandidatePricing(listPrice, quote.discount(), rate,
                quote.flag() == DiscountFlag.ROUNDED ? ROUNDED : OK, note);
    }

    private static CandidatePricing outOfRange(BigDecimal listPrice, boolean above) {
        if (above) {
            return new CandidatePricing(listPrice, null, null, ABOVE_LIST, "客户单价高于标价, 请核对");
        }
        return new CandidatePricing(listPrice, null, null, OUT_OF_RANGE, "算出来的折扣低于 3 折, 可能对应错货品, 请核对");
    }

    private static String label(CurrencyInfo currency) {
        return currency.fileCurrencyName() == null ? "外币" : currency.fileCurrencyName();
    }
}

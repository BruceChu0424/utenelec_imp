package com.uten.imp.common.finance;

import com.uten.imp.common.finance.MoneyPolicy.DiscountFlag;
import com.uten.imp.common.finance.MoneyPolicy.DiscountQuote;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;

import static org.assertj.core.api.Assertions.assertThat;

/** ADR-134: 由对方单价反推折扣, 只算倍率, 不改任何单价。 */
class MoneyPolicyDiscountFromUnitPriceTest {

    private AutoCloseable precision;

    @BeforeEach
    void bindDiscountRoundingChoice() {
        // ADR-134 的既有口径是四位倍率；除不尽时按用户显式选择四位 HALF_UP 取舍。
        precision = BusinessPrecisionContext.use(java.util.Map.of(
                "money.discount", new BusinessPrecisionContext.Choice(4, "HALF_UP")));
    }

    @AfterEach
    void releaseDiscountRoundingChoice() throws Exception {
        precision.close();
    }

    private static DiscountQuote quote(String counterpart, String rate, String list) {
        return MoneyPolicy.discountFromUnitPrice(
                counterpart == null ? null : new BigDecimal(counterpart),
                rate == null ? null : new BigDecimal(rate),
                list == null ? null : new BigDecimal(list));
    }

    @Test
    void samePriceAsListIsNoDiscount() {
        DiscountQuote q = quote("21", "1", "21.0000");
        assertThat(q.flag()).isEqualTo(DiscountFlag.OK);
        assertThat(q.discount()).isEqualByComparingTo("1");
        // 精确商按原样保留，不再人为固定四位刻度。
        assertThat(q.unitGap()).isEqualByComparingTo("0");
    }

    @Test
    void exactRatioIsOk() {
        DiscountQuote q = quote("18.9", "1", "21");
        assertThat(q.flag()).isEqualTo(DiscountFlag.OK);
        assertThat(q.discount()).isEqualByComparingTo("0.9");
    }

    @Test
    void nonTerminatingRatioIsRoundedToFourPlacesAndReportsTheUnitGap() {
        // 945/1023 除不尽（分母含 3/11/31 因子），按显式四位 HALF_UP 取舍并给出单位差。
        DiscountQuote q = quote("9.45", "1", "10.23");
        assertThat(q.flag()).isEqualTo(DiscountFlag.ROUNDED);
        assertThat(q.discount()).isEqualByComparingTo("0.9238");
        // 9.45 - 10.23 * 0.9238 = 9.45 - 9.450474 = -0.000474
        assertThat(q.unitGap()).isEqualByComparingTo("0.000474");
    }

    @Test
    void foreignCurrencyUsesTheRate() {
        DiscountQuote q = quote("1.1", "7.1", "8.59");
        assertThat(q.discount()).isEqualByComparingTo("0.9092");
        assertThat(q.flag()).isEqualTo(DiscountFlag.ROUNDED);
    }

    @Test
    void aboveListIsNeverClampedToOne() {
        DiscountQuote q = quote("22.11", "1", "21");
        assertThat(q.flag()).isEqualTo(DiscountFlag.ABOVE_LIST);
        assertThat(q.discount()).isNull();
    }

    @Test
    void roundingThatLandsExactlyOnOneIsAccepted() {
        DiscountQuote q = quote("21.00001", "1", "21");
        assertThat(q.discount()).isEqualByComparingTo("1");
        assertThat(q.flag()).isEqualTo(DiscountFlag.ROUNDED);
    }

    @Test
    void missingOrZeroListPriceNeedsFinancePricing() {
        assertThat(quote("15.96", "1", "0").flag()).isEqualTo(DiscountFlag.NO_LIST_PRICE);
        assertThat(quote("15.96", "1", null).flag()).isEqualTo(DiscountFlag.NO_LIST_PRICE);
        assertThat(quote("15.96", "1", "0").discount()).isNull();
    }

    @Test
    void invalidInputsGiveNoDiscount() {
        assertThat(quote(null, "1", "21").flag()).isEqualTo(DiscountFlag.INVALID);
        assertThat(quote("0", "1", "21").flag()).isEqualTo(DiscountFlag.INVALID);
        assertThat(quote("21", null, "21").flag()).isEqualTo(DiscountFlag.INVALID);
        assertThat(quote("21", "0", "21").flag()).isEqualTo(DiscountFlag.INVALID);
        assertThat(quote("0.00001", "1", "21").flag()).isEqualTo(DiscountFlag.INVALID);
    }
}

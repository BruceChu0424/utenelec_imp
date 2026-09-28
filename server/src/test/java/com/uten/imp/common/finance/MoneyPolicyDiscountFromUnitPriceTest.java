package com.uten.imp.common.finance;

import com.uten.imp.common.finance.MoneyPolicy.DiscountFlag;
import com.uten.imp.common.finance.MoneyPolicy.DiscountQuote;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;

import static org.assertj.core.api.Assertions.assertThat;

/** ADR-134: 由对方单价反推折扣, 只算倍率, 不改任何单价。 */
class MoneyPolicyDiscountFromUnitPriceTest {

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
        assertThat(q.discount().scale()).isEqualTo(4);
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
        DiscountQuote q = quote("9.45", "1", "10.24");
        assertThat(q.flag()).isEqualTo(DiscountFlag.ROUNDED);
        assertThat(q.discount()).isEqualByComparingTo("0.9229");
        // 9.45 - 10.24 * 0.9229 = 9.45 - 9.450496 = -0.000496
        assertThat(q.unitGap()).isEqualByComparingTo("0.000496");
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

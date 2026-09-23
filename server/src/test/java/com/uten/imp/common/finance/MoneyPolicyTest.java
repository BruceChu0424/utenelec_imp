package com.uten.imp.common.finance;

import com.uten.imp.common.web.ApiException;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.Arrays;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class MoneyPolicyTest {

    @Test
    void productsKeepEveryDigitAndNeverRound() {
        // Dart double 下 3 × 0.1 = 0.30000000000000004; 服务端十进制乘积必须恰好 0.3。
        assertThat(MoneyPolicy.exactProduct(new BigDecimal("3"), new BigDecimal("0.1")))
                .isEqualByComparingTo("0.3");
        // 外币收货草稿: 3 × 0.1 × 7.1 = 2.13, 与审核后的权威值同一规则。
        var line = MoneyPolicy.line(new BigDecimal("3"), new BigDecimal("0.1"), null, new BigDecimal("7.1"));
        assertThat(line.original()).isEqualByComparingTo("0.3");
        assertThat(line.local()).isEqualByComparingTo("2.13");
        assertThat(MoneyPolicy.local(new BigDecimal("1.2345"), new BigDecimal("7.123456")))
                .isEqualByComparingTo("8.793906432");
        assertThat(MoneyPolicy.exactProduct(new BigDecimal("3"), new BigDecimal("33.3333333333"),
                new BigDecimal("0.9"))).isEqualByComparingTo("89.99999999991");
        // 表示统一补到 4 位, 数值不变。
        assertThat(MoneyPolicy.exactProduct(new BigDecimal("3"), new BigDecimal("0.1")).toPlainString())
                .isEqualTo("0.3000");
    }

    @Test
    void missingPriceMeansMissingAmountAndMissingRateMeansMissingLocal() {
        var noPrice = MoneyPolicy.line(BigDecimal.ONE, null, null, BigDecimal.ONE);
        assertThat(noPrice.original()).isNull();
        assertThat(noPrice.local()).isNull();
        var noRate = MoneyPolicy.line(BigDecimal.ONE, BigDecimal.TEN, null, null);
        assertThat(noRate.original()).isEqualByComparingTo("10");
        assertThat(noRate.local()).isNull();
    }

    @Test
    void zeroOrMissingDiscountMeansNoDiscount() {
        assertThat(MoneyPolicy.exactProduct(BigDecimal.TEN, BigDecimal.ONE, BigDecimal.ZERO))
                .isEqualByComparingTo("10");
        assertThat(MoneyPolicy.exactProduct(BigDecimal.TEN, BigDecimal.ONE, new BigDecimal("0.85")))
                .isEqualByComparingTo("8.5");
    }

    @Test
    void cumulativeProrationConservesTheSourceTotalAndTheLastBatchTakesTheRemainder() {
        BigDecimal total = new BigDecimal("100.0000");
        BigDecimal prior = BigDecimal.ZERO;
        BigDecimal[] batches = new BigDecimal[3];
        for (int i = 0; i < 3; i++) {
            batches[i] = MoneyPolicy.prorate(total, BigDecimal.valueOf(i + 1), new BigDecimal("3"), prior);
            prior = prior.add(batches[i]);
        }
        assertThat(Arrays.stream(batches).map(BigDecimal::toPlainString).toList())
                .containsExactly("33.3333", "33.3334", "33.3333");
        assertThat(prior).isEqualByComparingTo(total);
    }

    @Test
    void terminatingSharesStayExactAndOnlyNonTerminatingSharesRoundToTheSourcePrecision() {
        // 能整除取精确值(0.5 / 16 = 0.03125), 部分出货就是本批数量的精确乘积, 不截成 4 位。
        assertThat(MoneyPolicy.cumulativeShare(new BigDecimal("0.5"), BigDecimal.ONE, new BigDecimal("16")))
                .isEqualByComparingTo("0.03125");
        assertThat(MoneyPolicy.cumulativeShare(new BigDecimal("1.2345"), BigDecimal.ONE, BigDecimal.TEN))
                .isEqualByComparingTo("0.12345");
        // 除不尽取到来源自身位数的最近值: 100 × 2/3 → 66.6667; 1.00001 × 1/3 → 0.33334(5 位)。
        assertThat(MoneyPolicy.cumulativeShare(new BigDecimal("100"), new BigDecimal("2"), new BigDecimal("3")))
                .isEqualByComparingTo("66.6667");
        assertThat(MoneyPolicy.cumulativeShare(new BigDecimal("1.00001"), BigDecimal.ONE, new BigDecimal("3")))
                .isEqualByComparingTo("0.33334");
        // 按来源金额自身小数位取位(123.45678 → 5 位, 这里恰好整除)。
        assertThat(MoneyPolicy.cumulativeShare(new BigDecimal("123.45678"), BigDecimal.ONE, new BigDecimal("3")))
                .isEqualByComparingTo("41.15226");
        // 全额退货: 收货精确额 123.45678 退完, 余额恰好为 0(旧口径得 123.4568, AP 永远剩尾差)。
        BigDecimal credit = MoneyPolicy.prorate(new BigDecimal("123.45678"), new BigDecimal("3"),
                new BigDecimal("3"), BigDecimal.ZERO);
        assertThat(new BigDecimal("123.45678").subtract(credit)).isZero();
    }

    @Test
    void eventSlicesSumToTheSourceInAnyOrder() {
        BigDecimal total = new BigDecimal("100");
        BigDecimal whole = new BigDecimal("3");
        // 先合格 2 再不合格 1 / 先不合格 1 再合格 2: 两种顺序切出的数都一样, 两片之和恰好 100。
        BigDecimal passFirst = MoneyPolicy.amountSlice(total, whole, BigDecimal.ZERO, new BigDecimal("2"));
        BigDecimal failLast = MoneyPolicy.amountSlice(total, whole, new BigDecimal("2"), BigDecimal.ONE);
        assertThat(passFirst).isEqualByComparingTo("66.6667");
        assertThat(failLast).isEqualByComparingTo("33.3333");
        assertThat(passFirst.add(failLast)).isEqualByComparingTo(total);
        BigDecimal failFirst = MoneyPolicy.amountSlice(total, whole, BigDecimal.ZERO, BigDecimal.ONE);
        BigDecimal passLast = MoneyPolicy.amountSlice(total, whole, BigDecimal.ONE, new BigDecimal("2"));
        assertThat(failFirst).isEqualByComparingTo("33.3333");
        assertThat(passLast).isEqualByComparingTo("66.6667");
        assertThat(failFirst.add(passLast)).isEqualByComparingTo(total);
    }

    @Test
    void fourDigitValueColumnsSliceLikeTheDatabaseGuardAndAgreeWithTheExactRuleWhenNonTerminating() {
        BigDecimal total = new BigDecimal("100.0000");
        BigDecimal whole = new BigDecimal("3");
        // 库存价值 4 位列: ROUND(来源 × 累计量 / 来源量, 4) 的差; 除不尽时与 cumulativeShare 同值。
        assertThat(MoneyPolicy.projectedSlice(total, whole, BigDecimal.ZERO, new BigDecimal("2")))
                .isEqualByComparingTo(MoneyPolicy.amountSlice(total, whole, BigDecimal.ZERO, new BigDecimal("2")))
                .isEqualByComparingTo("66.6667");
        // 能整除但位数超过 4 位时, 4 位价值列只能取到 4 位, 两片仍守恒。
        BigDecimal first = MoneyPolicy.projectedSlice(new BigDecimal("0.0247"), new BigDecimal("2"),
                BigDecimal.ZERO, BigDecimal.ONE);
        BigDecimal last = MoneyPolicy.projectedSlice(new BigDecimal("0.0247"), new BigDecimal("2"),
                BigDecimal.ONE, BigDecimal.ONE);
        assertThat(first).isEqualByComparingTo("0.0124");
        assertThat(first.add(last)).isEqualByComparingTo("0.0247");
    }

    @Test
    void quantitiesAndDiscountsBeyondTheirStoredScaleAreRejectedBeforeAnyAmountIsDerived() {
        assertThatThrownBy(() -> MoneyPolicy.line(new BigDecimal("1.00005"), BigDecimal.TEN, null, BigDecimal.ONE))
                .isInstanceOf(ApiException.class).hasMessageContaining("数量");
        assertThatThrownBy(() -> MoneyPolicy.exactProduct(BigDecimal.ONE, BigDecimal.TEN, new BigDecimal("0.85001")))
                .isInstanceOf(ApiException.class).hasMessageContaining("折扣");
        assertThat(MoneyPolicy.line(new BigDecimal("1.0001"), BigDecimal.TEN, null, BigDecimal.ONE).original())
                .isEqualByComparingTo("10.001");
    }

    @Test
    void manyBatchesAlwaysSumToTheSource() {
        BigDecimal total = new BigDecimal("1000.0001");
        BigDecimal source = new BigDecimal("7");
        BigDecimal cumulative = BigDecimal.ZERO;
        BigDecimal prior = BigDecimal.ZERO;
        for (BigDecimal batch : List.of(new BigDecimal("1.5"), new BigDecimal("0.25"), new BigDecimal("2"),
                new BigDecimal("3.25"))) {
            cumulative = cumulative.add(batch);
            prior = prior.add(MoneyPolicy.prorate(total, cumulative, source, prior));
        }
        assertThat(prior).isEqualByComparingTo(total);
    }

    @Test
    void overAllocationFailsClosedOnlyAtTheLastBatch() {
        assertThat(MoneyPolicy.prorate(BigDecimal.ONE, BigDecimal.ONE, new BigDecimal("3"), new BigDecimal("0.5")))
                .isZero();
        assertThatThrownBy(() -> MoneyPolicy.prorate(BigDecimal.ONE, new BigDecimal("3"), new BigDecimal("3"),
                new BigDecimal("1.5"))).isInstanceOf(ApiException.class);
        assertThatThrownBy(() -> MoneyPolicy.cumulativeShare(BigDecimal.ONE, new BigDecimal("4"), new BigDecimal("3")))
                .isInstanceOf(ApiException.class);
    }

    @Test
    void quantitiesAreSeparatedFromMoney() {
        assertThat(MoneyPolicy.quantity(new BigDecimal("1.23455"))).isEqualByComparingTo("1.2346");
        assertThat(MoneyPolicy.quantityFromBase(BigDecimal.TEN, new BigDecimal("3"))).isEqualByComparingTo("3.3333");
        assertThat(MoneyPolicy.quantityShare(new BigDecimal("10"), new BigDecimal("4"), new BigDecimal("10")))
                .isEqualByComparingTo("4");
        BigDecimal first = MoneyPolicy.quantitySlice(BigDecimal.ONE, new BigDecimal("3"), BigDecimal.ZERO, BigDecimal.ONE);
        BigDecimal second = MoneyPolicy.quantitySlice(BigDecimal.ONE, new BigDecimal("3"), BigDecimal.ONE, BigDecimal.ONE);
        BigDecimal third = MoneyPolicy.quantitySlice(BigDecimal.ONE, new BigDecimal("3"), new BigDecimal("2"), BigDecimal.ONE);
        assertThat(first.add(second).add(third)).isEqualByComparingTo("1");
    }

    @Test
    void displayHelpersDoNotChangeValues() {
        assertThat(MoneyPolicy.canonical(new BigDecimal("1E+2")).toPlainString()).isEqualTo("100.0000");
        assertThat(MoneyPolicy.canonical(new BigDecimal("0.123456789")).toPlainString()).isEqualTo("0.123456789");
        assertThat(MoneyPolicy.canonicalRate(new BigDecimal("7.1")).toPlainString()).isEqualTo("7.100000");
        assertThat(MoneyPolicy.percentOf(BigDecimal.ONE, new BigDecimal("3"))).isEqualByComparingTo("33.33");
        assertThat(MoneyPolicy.unitValue(BigDecimal.ONE, new BigDecimal("4"))).isEqualByComparingTo("0.25");
    }
}

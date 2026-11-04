package com.uten.imp.common.finance;

import com.uten.imp.common.web.ApiException;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.AfterEach;

import java.math.BigDecimal;
import java.util.Arrays;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class MoneyPolicyTest {
    private AutoCloseable userChoice;
    @BeforeEach void explicitUserInputsForTheseAllocationScenarios(){
        // Scenario input, not a product default. Missing-choice behavior has its
        // own tests; finite values must remain exact even with these choices.
        var choices=new java.util.HashMap<String,BusinessPrecisionContext.Choice>();
        for(String key:List.of("money.cumulative-share","quantity.from-base","quantity.slice"))choices.put(key,new BusinessPrecisionContext.Choice(4,"HALF_UP"));
        choices.put("report.percentage",new BusinessPrecisionContext.Choice(2,"HALF_UP"));
        userChoice=BusinessPrecisionContext.use(choices);
    }
    @AfterEach void releaseUserInputs()throws Exception{userChoice.close();assertThat(BusinessPrecisionContext.choices()).isEmpty();}

    @Test
    void quantityDisplayRetainsEveryDigitRegardlessOfOldRequestedDisplayScale() {
        BigDecimal exact = new BigDecimal("1.2345");
        assertThat(MoneyPolicy.quantityDisplay(exact, 3).toPlainString()).isEqualTo("1.2345");
        assertThat(MoneyPolicy.quantityDisplay(new BigDecimal("1.2344"), 3).toPlainString()).isEqualTo("1.2344");
        assertThat(MoneyPolicy.quantityDisplay(BigDecimal.ONE, 3).toPlainString()).isEqualTo("1");
        assertThat(MoneyPolicy.quantityDisplay(null, 3)).isNull();
        assertThat(exact.toPlainString()).isEqualTo("1.2345");
    }

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
    void terminatingSharesStayExactAndNonTerminatingSharesUseTheExplicitUserPrecision() throws Exception {
        // 能整除取精确值(0.5 / 16 = 0.03125), 部分出货就是本批数量的精确乘积, 不截成 4 位。
        assertThat(MoneyPolicy.cumulativeShare(new BigDecimal("0.5"), BigDecimal.ONE, new BigDecimal("16")))
                .isEqualByComparingTo("0.03125");
        assertThat(MoneyPolicy.cumulativeShare(new BigDecimal("1.2345"), BigDecimal.ONE, BigDecimal.TEN))
                .isEqualByComparingTo("0.12345");
        // 本次用户选择4位；来源自身小数位不能替代用户的选择。
        assertThat(MoneyPolicy.cumulativeShare(new BigDecimal("100"), new BigDecimal("2"), new BigDecimal("3")))
                .isEqualByComparingTo("66.6667");
        try(var selected=BusinessPrecisionContext.use(java.util.Map.of("money.cumulative-share",new BusinessPrecisionContext.Choice(5,"HALF_UP")))){
            assertThat(MoneyPolicy.cumulativeShare(new BigDecimal("1.00001"), BigDecimal.ONE, new BigDecimal("3")))
                    .isEqualByComparingTo("0.33334");
        }
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
    void projectedSlicesUseTheSameRuleAndNeverRoundAnExactlyFiniteHalf() {
        BigDecimal total = new BigDecimal("100.0000");
        BigDecimal whole = new BigDecimal("3");
        // 本次明确选择4位，除不尽时与同源累计分摊一致。
        assertThat(MoneyPolicy.projectedSlice(total, whole, BigDecimal.ZERO, new BigDecimal("2")))
                .isEqualByComparingTo(MoneyPolicy.amountSlice(total, whole, BigDecimal.ZERO, new BigDecimal("2")))
                .isEqualByComparingTo("66.6667");
        // 有限结果超过旧4位仍完整保留，即使本次为其它除法选了4位。
        BigDecimal first = MoneyPolicy.projectedSlice(new BigDecimal("0.0247"), new BigDecimal("2"),
                BigDecimal.ZERO, BigDecimal.ONE);
        BigDecimal last = MoneyPolicy.projectedSlice(new BigDecimal("0.0247"), new BigDecimal("2"),
                BigDecimal.ONE, BigDecimal.ONE);
        assertThat(first).isEqualByComparingTo("0.01235");
        assertThat(first.add(last)).isEqualByComparingTo("0.0247");
    }

    @Test
    void quantitiesAndDiscountsBeyondTheirStoredScaleAreRejectedBeforeAnyAmountIsDerived() {
        assertThatThrownBy(() -> MoneyPolicy.line(new BigDecimal("1.0000000000000000000000005"), BigDecimal.TEN, null, BigDecimal.ONE))
                .isInstanceOf(ApiException.class).hasMessageContaining("数量");
        assertThatThrownBy(() -> MoneyPolicy.line(new BigDecimal("1.0000000000000000000000005"), null, null, null))
                .isInstanceOf(ApiException.class).hasMessageContaining("数量");
        assertThatThrownBy(() -> MoneyPolicy.line(new BigDecimal("1E40"), null, null, null))
                .isInstanceOf(ApiException.class).hasMessageContaining("数量");
        assertThat(MoneyPolicy.line(new BigDecimal("1.00010"), null, null, null).original()).isNull();
        assertThatThrownBy(() -> MoneyPolicy.exactProduct(BigDecimal.ONE, BigDecimal.TEN, new BigDecimal("0.8500000000000000000000001")))
                .isInstanceOf(ApiException.class).hasMessageContaining("折扣");
        assertThat(MoneyPolicy.line(new BigDecimal("1.0001"), BigDecimal.TEN, null, BigDecimal.ONE).original())
                .isEqualByComparingTo("10.001");
        assertThat(MoneyPolicy.line(new BigDecimal("1.00005"),BigDecimal.TEN,null,BigDecimal.ONE).original()).isEqualByComparingTo("10.0005");
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
        assertThat(MoneyPolicy.quantity(new BigDecimal("1.23455"))).isEqualByComparingTo("1.23455");
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

package com.uten.imp.common.finance;

import com.uten.imp.common.columns.ExtraColumnCalculator;
import com.uten.imp.common.columns.ExtraColumnSnapshot;
import com.uten.imp.common.web.ApiException;
import org.junit.jupiter.api.Test;
import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;
import static org.assertj.core.api.Assertions.*;

class MoneyPolicyTotalAmountInputTest {
    private static BigDecimal n(String value) { return new BigDecimal(value); }

    @Test void repeatingReferencePriceNeverReplacesAgreedTotal() throws Exception {
        try (var choices = BusinessPrecisionContext.use(java.util.Map.of(
                "money.reference-unit-price", new BusinessPrecisionContext.Choice(10, "DOWN")))) {
            var price = MoneyPolicy.referenceUnitPrice(n("100"), n("3000"));
            assertThat(price).isEqualByComparingTo("0.0333333333");
            assertThat(MoneyPolicy.orderBaseAmount(n("3000"), price, n("100"))).isEqualByComparingTo("100");
            assertThat(MoneyPolicy.referenceUnitPrice(n("100"), n("6"))).isEqualByComparingTo("16.6666666666");
            assertThat(MoneyPolicy.local(n("100"), n("7.123456"))).isEqualByComparingTo("712.3456");
        }
    }

    @Test void exactInputSurvivesTinyPricesAndAdditionalFees() throws Exception {
        try (var choices = BusinessPrecisionContext.use(java.util.Map.of(
                "money.reference-unit-price", new BusinessPrecisionContext.Choice(10, "DOWN")))) {
            assertThat(MoneyPolicy.referenceUnitPrice(n("0.000000000000000000000001"), n("10000")))
                    .isEqualByComparingTo("0");
            var base = MoneyPolicy.orderBaseAmount(n("3"), n("33.3333333333"), n("100"));
            assertThat(ExtraColumnCalculator.apply(base, List.of(
                    new ExtraColumnSnapshot(UUID.randomUUID(), "包装费", "AMOUNT", "ADD", "5"))))
                    .isEqualByComparingTo("105");
            assertThat(MoneyPolicy.orderBaseAmount(n("3"), n("0.1"), null)).isEqualByComparingTo("0.3");
        }
    }

    @Test void quantityRevisionsKeepExactRatioAndRejectUnrepresentableConsideration() {
        assertThat(MoneyPolicy.revisedTotalAmountInput(n("100"), n("3000"), n("6000")))
                .isEqualByComparingTo("200");
        assertThat(MoneyPolicy.revisedTotalAmountInput(n("100"), n("3000"), n("1500")))
                .isEqualByComparingTo("50");
        // 除不尽不再一刀切报错：改为要求本次显式精度选择（业务精度契约）。
        assertThatThrownBy(() -> MoneyPolicy.revisedTotalAmountInput(n("100"), n("3000"), n("1000")))
                .isInstanceOf(BusinessPrecisionRequiredException.class);
        assertThat(MoneyPolicy.orderOverageAmount(n("3"), n("0.0333333333"), n("100"), n("3000")))
                .isEqualByComparingTo("0.1");
    }

    @Test void inputBoundsAndZeroDivisorsFailBeforePersistence() {
        assertThatThrownBy(() -> MoneyPolicy.referenceUnitPrice(n("100"), n("0"))).isInstanceOf(ApiException.class);
        assertThatThrownBy(() -> MoneyPolicy.referenceUnitPrice(n("-1"), n("1"))).isInstanceOf(ApiException.class);
        // 五位小数数量在精确存储口径下合法；除不尽改为要求显式精度选择。
        assertThatThrownBy(() -> MoneyPolicy.referenceUnitPrice(n("100"), n("1.00001")))
                .isInstanceOf(BusinessPrecisionRequiredException.class);
        assertThatThrownBy(() -> MoneyPolicy.totalAmountInput(n("0.0000000000000000000000001"))).isInstanceOf(ApiException.class);
        assertThat(MoneyPolicy.referenceUnitPrice(n("0"), n("1"))).isEqualByComparingTo("0");
    }
}

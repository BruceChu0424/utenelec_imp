package com.uten.imp.features.sales.order;

import org.junit.jupiter.api.Test;

import java.math.BigDecimal;

import static org.assertj.core.api.Assertions.assertThat;

class SalesOrderQuantityFormulaTest {

    @Test
    void minimumQuantityIncludesReturnedAndFlaggedQuantities() {
        assertThat(SalesOrderService.minimumOrderQty(
                bd("60"), bd("10"), bd("5")))
                .isEqualByComparingTo("55");
    }

    @Test
    void outstandingUsesTheSameFourQuantityLedger() {
        assertThat(SalesOrderService.outstanding(
                bd("100"), bd("60"), bd("10"), bd("5")))
                .isEqualByComparingTo("45");
    }

    @Test
    void minimumQuantityNeverBecomesNegative() {
        assertThat(SalesOrderService.minimumOrderQty(
                bd("4"), bd("10"), bd("0")))
                .isEqualByComparingTo(BigDecimal.ZERO);
    }

    @Test
    void discountedQuantityChangeReusesAuthoritativeOrderAmountFormula() {
        BigDecimal original = SalesOrderService.authoritativeOrderAmount(
                bd("20"), bd("100"), bd("0.8"));

        assertThat(original).isEqualByComparingTo("1600.0000");
    }

    private static BigDecimal bd(String value) {
        return new BigDecimal(value);
    }
}

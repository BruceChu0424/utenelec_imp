package com.uten.imp.features.sales.order;

import com.uten.imp.common.web.ApiException;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class SalesOrderCommercialAuthorityTest {

    @Test
    void serverComputesOrderAmountFromQuantityAndUnitPrice() {
        assertThat(SalesOrderService.authoritativeOrderAmount(
                new BigDecimal("3.5"), new BigDecimal("12.34")))
                .isEqualByComparingTo("43.1900");
        assertThat(SalesOrderService.authoritativeLocalAmount(
                new BigDecimal("43.1900"), new BigDecimal("7.200000")))
                .isEqualByComparingTo("310.9680");
    }

    @Test
    void negativeOrNonPositiveCommercialInputFailsClosed() {
        assertThatThrownBy(() ->
                SalesOrderService.authoritativeOrderAmount(
                        BigDecimal.ZERO, BigDecimal.ONE))
                .isInstanceOf(ApiException.class);
        assertThatThrownBy(() ->
                SalesOrderService.authoritativeOrderAmount(
                        BigDecimal.ONE, new BigDecimal("-0.01")))
                .isInstanceOf(ApiException.class);
        assertThatThrownBy(() ->
                SalesOrderService.authoritativeLocalAmount(
                        BigDecimal.ONE, BigDecimal.ZERO))
                .isInstanceOf(ApiException.class);
    }
}

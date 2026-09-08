package com.uten.imp.common.util;

import com.uten.imp.common.web.ApiException;
import org.junit.jupiter.api.Test;
import java.math.BigDecimal;
import static org.junit.jupiter.api.Assertions.*;

class FinancialExactAmountTest {
    @Test void preservesActualValueAndFullFiniteProducts() {
        BigDecimal product=new BigDecimal("1.2345").multiply(new BigDecimal("1.2345"));
        assertEquals(new BigDecimal("1.52399025"),FinancialExactAmount.require(product,"货款"));
        assertEquals(0,new BigDecimal("-0.000000000000000000000001").compareTo(
                FinancialExactAmount.require(new BigDecimal("-0.000000000000000000000001"),"减款")));
        assertEquals(0,new BigDecimal("100.2300").compareTo(FinancialExactAmount.require(new BigDecimal("100.2300"),"实际金额")));
    }
    @Test void rejectsUnrepresentableFactsInsteadOfRoundingOrExpandingTheirText() {
        assertThrows(ApiException.class,()->FinancialExactAmount.require(new BigDecimal("1E40"),"金额"));
        assertThrows(ApiException.class,()->FinancialExactAmount.require(new BigDecimal("1E-25"),"金额"));
        assertThrows(ApiException.class,()->FinancialExactAmount.require(new BigDecimal("1E-1000000000"),"金额"));
        assertThrows(ApiException.class,()->FinancialExactAmount.require(null,"金额"));
        assertEquals(BigDecimal.ZERO,FinancialExactAmount.require(new BigDecimal("0E-1000000000"),"金额"));
        assertNull(FinancialExactAmount.optional(null,"未提供的金额"));
    }
    @Test void legalPriceQuantityDiscountAndRateHaveAnExactFiniteProductWithinTheMoneyBound() {
        BigDecimal price=FinancialExactAmount.unitPrice(new BigDecimal("0.1234567891"),"单价");
        BigDecimal rate=FinancialExactAmount.rate(new BigDecimal("7.123456"),"汇率");
        BigDecimal local=price.multiply(new BigDecimal("1.2345")).multiply(new BigDecimal("0.9876")).multiply(rate);
        assertEquals(0,local.compareTo(FinancialExactAmount.require(local,"本币金额")));
        assertEquals(24,local.scale());
        assertThrows(ApiException.class,()->FinancialExactAmount.unitPrice(new BigDecimal("0.12345678912"),"单价"));
        assertThrows(ApiException.class,()->FinancialExactAmount.rate(new BigDecimal("7.1234567"),"汇率"));
        assertEquals(new BigDecimal("12.3400"),FinancialExactAmount.canonicalMoney(new BigDecimal("12.340000"),"金额"));
        assertEquals(new BigDecimal("12.345678"),FinancialExactAmount.canonicalMoney(new BigDecimal("12.345678"),"金额"));
    }
    @Test void actualTwentyFourDigitAmountRetainsEveryDigitAfterSixDigitBookRate() {
        BigDecimal actual=FinancialExactAmount.require(new BigDecimal("1e-24"),"银行实际原币");
        BigDecimal book=actual.multiply(FinancialExactAmount.rate(new BigDecimal("7.000001"),"账面汇率"));
        assertEquals(new BigDecimal("0.000000000000000000000007000001"),FinancialExactAmount.book(book,"账面金额"));
        assertEquals(book,FinancialExactAmount.canonicalMoney(book,"账面金额"));
        assertThrows(ApiException.class,()->FinancialExactAmount.require(book,"原始输入"));
        assertThrows(ApiException.class,()->FinancialExactAmount.book(new BigDecimal("1e-31"),"账面金额"));
    }
}

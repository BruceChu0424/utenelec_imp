package com.uten.imp.features.purchase.receipt;

import com.uten.imp.common.web.ApiException;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class PurchaseReceiptAmountAuthorityTest {

    @Test
    void partialSlicesKeepExactPriceAndFinalSliceTakesTheApprovedRemainder() {
        var partial = PurchaseReceiptAmountAuthority.sourceAmounts(
                BigDecimal.ONE, new BigDecimal("0.33335"), BigDecimal.ONE,
                new BigDecimal("3"), new BigDecimal("1.0001"), new BigDecimal("1.0001"),
                BigDecimal.ZERO, BigDecimal.ZERO, BigDecimal.ZERO);
        var second = PurchaseReceiptAmountAuthority.sourceAmounts(
                BigDecimal.ONE, new BigDecimal("0.33335"), BigDecimal.ONE,
                new BigDecimal("3"), new BigDecimal("1.0001"), new BigDecimal("1.0001"),
                BigDecimal.ONE, partial.original(), partial.local());
        var last = PurchaseReceiptAmountAuthority.sourceAmounts(
                BigDecimal.ONE, new BigDecimal("0.33335"), BigDecimal.ONE,
                new BigDecimal("3"), new BigDecimal("1.0001"), new BigDecimal("1.0001"),
                new BigDecimal("2"), partial.original().add(second.original()),
                partial.local().add(second.local()));
        var historicalLast = PurchaseReceiptAmountAuthority.sourceAmounts(
                BigDecimal.ONE, new BigDecimal("0.33335"), BigDecimal.ONE,
                new BigDecimal("3"), new BigDecimal("1.0001"), new BigDecimal("1.0001"),
                new BigDecimal("2"), new BigDecimal("0.6668"), new BigDecimal("0.6668"));

        // ADR-112: 来源金额与单价不一致(1.0001 ≠ 3 × 0.33335)时按「累计量份额 − 已收」分摊,
        // 除不尽的累计份额取到来源金额位数(0.3334 / 0.6667), 末批取全部剩余; 合计恰好等于来源金额。
        assertThat(partial.original()).isEqualByComparingTo("0.3334");
        assertThat(partial.local()).isEqualByComparingTo("0.3334");
        assertThat(second.original()).isEqualByComparingTo("0.3333");
        assertThat(second.local()).isEqualByComparingTo("0.3333");
        assertThat(last.original()).isEqualByComparingTo("0.3334");
        assertThat(last.local()).isEqualByComparingTo("0.3334");
        assertThat(partial.original().add(second.original()).add(last.original()))
                .isEqualByComparingTo("1.0001");
        assertThat(partial.local().add(second.local()).add(last.local()))
                .isEqualByComparingTo("1.0001");
        // 服务端派生的订单(金额 = 数量 × 单价)每批就是本批数量的精确乘积。
        var exact = PurchaseReceiptAmountAuthority.sourceAmounts(
                BigDecimal.ONE, new BigDecimal("0.33335"), new BigDecimal("7.1"),
                new BigDecimal("3"), new BigDecimal("1.00005"), new BigDecimal("7.100355"),
                BigDecimal.ZERO, BigDecimal.ZERO, BigDecimal.ZERO);
        assertThat(exact.original()).isEqualByComparingTo("0.33335");
        assertThat(exact.local()).isEqualByComparingTo("2.366785");
        // Previously approved amounts stay authoritative; no retroactive repricing.
        assertThat(historicalLast.original()).isEqualByComparingTo("0.3333");
        assertThat(historicalLast.local()).isEqualByComparingTo("0.3333");
    }

    @Test
    void duplicateOrderLineAndHeaderTamperingFailClosed() {
        UUID itemId = UUID.randomUUID();
        assertThatThrownBy(() -> PurchaseReceiptAmountAuthority.requireDistinctOrderItems(
                List.of(itemId, itemId))).isInstanceOf(ApiException.class);

        UUID supplier = UUID.randomUUID();
        UUID currency = UUID.randomUUID();
        UUID method = UUID.randomUUID();
        assertThatThrownBy(() -> PurchaseReceiptAmountAuthority.requireHeaderMatches(
                supplier, UUID.randomUUID(), BigDecimal.ONE, method, new BigDecimal("13"),
                supplier, currency, BigDecimal.ONE, method, new BigDecimal("13")))
                .hasMessageContaining("币种、汇率、税率或结算方式");
        assertThatThrownBy(() -> PurchaseReceiptAmountAuthority.requireHeaderMatches(
                supplier, currency, new BigDecimal("2"), method, new BigDecimal("13"),
                supplier, currency, BigDecimal.ONE, method, new BigDecimal("13")))
                .hasMessageContaining("币种、汇率、税率或结算方式");
        assertThatThrownBy(() -> PurchaseReceiptAmountAuthority.requireHeaderMatches(
                supplier, currency, BigDecimal.ONE, UUID.randomUUID(), new BigDecimal("13"),
                supplier, currency, BigDecimal.ONE, method, new BigDecimal("13")))
                .hasMessageContaining("币种、汇率、税率或结算方式");
        assertThatThrownBy(() -> PurchaseReceiptAmountAuthority.requireHeaderMatches(
                supplier, currency, BigDecimal.ONE, method, new BigDecimal("9"),
                supplier, currency, BigDecimal.ONE, method, new BigDecimal("13")))
                .hasMessageContaining("币种、汇率、税率或结算方式");
    }
}

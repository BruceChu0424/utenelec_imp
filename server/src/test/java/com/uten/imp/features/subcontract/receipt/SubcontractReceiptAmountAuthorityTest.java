package com.uten.imp.features.subcontract.receipt;

import com.uten.imp.common.web.ApiException;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class SubcontractReceiptAmountAuthorityTest {

    @Test
    void partialAndFinalSlicesUseApprovedOrderAndAbsorbRoundingTail() {
        var partial = SubcontractReceiptAmountAuthority.sourceAmounts(
                BigDecimal.ONE, new BigDecimal("0.33335"), BigDecimal.ONE,
                new BigDecimal("3"), new BigDecimal("1.0001"), new BigDecimal("1.0001"),
                BigDecimal.ZERO, BigDecimal.ZERO, BigDecimal.ZERO);
        var last = SubcontractReceiptAmountAuthority.sourceAmounts(
                BigDecimal.ONE, new BigDecimal("0.33335"), BigDecimal.ONE,
                new BigDecimal("3"), new BigDecimal("1.0001"), new BigDecimal("1.0001"),
                new BigDecimal("2"), new BigDecimal("0.6668"), new BigDecimal("0.6668"));

        assertThat(partial.original()).isEqualByComparingTo("0.3334");
        assertThat(last.original()).isEqualByComparingTo("0.3333");
        assertThat(last.local()).isEqualByComparingTo("0.3333");
    }

    @Test
    void duplicateOrderLineAndHeaderTamperingFailClosed() {
        UUID itemId = UUID.randomUUID();
        assertThatThrownBy(() -> SubcontractReceiptAmountAuthority.requireDistinctOrderItems(
                List.of(itemId, itemId))).isInstanceOf(ApiException.class);

        UUID supplier = UUID.randomUUID();
        UUID currency = UUID.randomUUID();
        UUID method = UUID.randomUUID();
        assertThatThrownBy(() -> SubcontractReceiptAmountAuthority.requireHeaderMatches(
                supplier, currency, new BigDecimal("2"), method, new BigDecimal("13"),
                supplier, currency, BigDecimal.ONE, method, new BigDecimal("13")))
                .hasMessageContaining("币种、汇率、税率或结算方式");
        assertThatThrownBy(() -> SubcontractReceiptAmountAuthority.requireHeaderMatches(
                supplier, currency, BigDecimal.ONE, UUID.randomUUID(), new BigDecimal("13"),
                supplier, currency, BigDecimal.ONE, method, new BigDecimal("13")))
                .hasMessageContaining("币种、汇率、税率或结算方式");
        assertThatThrownBy(() -> SubcontractReceiptAmountAuthority.requireHeaderMatches(
                supplier, currency, BigDecimal.ONE, method, null,
                supplier, currency, BigDecimal.ONE, method, new BigDecimal("13")))
                .hasMessageContaining("币种、汇率、税率或结算方式");
    }
}

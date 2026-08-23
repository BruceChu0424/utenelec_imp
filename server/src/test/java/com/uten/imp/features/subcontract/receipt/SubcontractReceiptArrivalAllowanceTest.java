package com.uten.imp.features.subcontract.receipt;

import com.uten.imp.common.web.ApiException;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class SubcontractReceiptArrivalAllowanceTest {

    @Test
    void approvedFiveUnitOverageExtendsTenUnitOrderToFifteenAndSurvivesReverseReapproval() {
        var currentDecision = SubcontractReceiptAmountAuthority.authorizedSource(
                new BigDecimal("10"), new BigDecimal("100"), new BigDecimal("100"),
                new BigDecimal("10"), BigDecimal.ONE, BigDecimal.ZERO, new BigDecimal("5"));
        var postedThenReversedAndReapproved = SubcontractReceiptAmountAuthority.authorizedSource(
                new BigDecimal("10"), new BigDecimal("100"), new BigDecimal("100"),
                new BigDecimal("10"), BigDecimal.ONE, BigDecimal.ZERO, new BigDecimal("5"));

        assertThat(currentDecision.qty()).isEqualByComparingTo("15");
        assertThat(currentDecision.original()).isEqualByComparingTo("150");
        assertThat(postedThenReversedAndReapproved).isEqualTo(currentDecision);
    }

    @Test
    void hundredUnitsRemainBlockedWhenFinanceApprovedOnlyFiveExcess() {
        var authorized = SubcontractReceiptAmountAuthority.authorizedSource(
                new BigDecimal("10"), new BigDecimal("100"), new BigDecimal("100"),
                new BigDecimal("10"), BigDecimal.ONE, BigDecimal.ZERO, new BigDecimal("5"));
        assertThatThrownBy(() -> SubcontractReceiptAmountAuthority.sourceAmounts(
                new BigDecimal("100"), new BigDecimal("10"), BigDecimal.ONE,
                authorized.qty(), authorized.original(), authorized.local(),
                BigDecimal.ZERO, BigDecimal.ZERO, BigDecimal.ZERO))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("超过财务批准订单行剩余额度");
    }
}

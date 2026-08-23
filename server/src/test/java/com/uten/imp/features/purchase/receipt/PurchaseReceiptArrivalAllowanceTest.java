package com.uten.imp.features.purchase.receipt;

import com.uten.imp.common.web.ApiException;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class PurchaseReceiptArrivalAllowanceTest {

    @Test
    void approvedFiveUnitOverageExtendsTenUnitOrderToFifteenWithoutDoubleCountingAfterPosting() {
        var beforeRecordApproval = PurchaseReceiptAmountAuthority.authorizedSource(
                new BigDecimal("10"), new BigDecimal("100"), new BigDecimal("100"),
                new BigDecimal("10"), BigDecimal.ONE, BigDecimal.ZERO, new BigDecimal("5"));
        var afterRecordApproval = PurchaseReceiptAmountAuthority.authorizedSource(
                new BigDecimal("10"), new BigDecimal("100"), new BigDecimal("100"),
                new BigDecimal("10"), BigDecimal.ONE, new BigDecimal("5"), BigDecimal.ZERO);

        assertThat(beforeRecordApproval.qty()).isEqualByComparingTo("15");
        assertThat(beforeRecordApproval.original()).isEqualByComparingTo("150");
        assertThat(afterRecordApproval).isEqualTo(beforeRecordApproval);
        assertThat(PurchaseReceiptAmountAuthority.sourceAmounts(
                new BigDecimal("15"), new BigDecimal("10"), BigDecimal.ONE,
                beforeRecordApproval.qty(), beforeRecordApproval.original(), beforeRecordApproval.local(),
                BigDecimal.ZERO, BigDecimal.ZERO, BigDecimal.ZERO).original())
                .isEqualByComparingTo("150");
    }

    @Test
    void unapprovedHundredUnitReceiptCannotUseFiveUnitCustomAllowance() {
        var authorized = PurchaseReceiptAmountAuthority.authorizedSource(
                new BigDecimal("10"), new BigDecimal("100"), new BigDecimal("100"),
                new BigDecimal("10"), BigDecimal.ONE, BigDecimal.ZERO, new BigDecimal("5"));
        assertThatThrownBy(() -> PurchaseReceiptAmountAuthority.sourceAmounts(
                new BigDecimal("100"), new BigDecimal("10"), BigDecimal.ONE,
                authorized.qty(), authorized.original(), authorized.local(),
                BigDecimal.ZERO, BigDecimal.ZERO, BigDecimal.ZERO))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("超过财务批准订单行剩余额度");
    }
}

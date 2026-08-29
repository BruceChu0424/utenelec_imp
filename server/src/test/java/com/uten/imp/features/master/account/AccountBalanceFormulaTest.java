package com.uten.imp.features.master.account;

import org.junit.jupiter.api.Test;

import java.math.BigDecimal;

import static org.assertj.core.api.Assertions.assertThat;

class AccountBalanceFormulaTest {

    @Test
    void recomputeIncludesPostedAdjustmentsWithoutChangingReceiptPaymentTotals() {
        Account account = new Account();
        account.setInitBalance(new BigDecimal("100.0000"));
        account.setReceiptsTotal(new BigDecimal("30.0000"));
        account.setPaymentsTotal(new BigDecimal("20.0000"));
        account.setBalanceAdjustmentsTotal(new BigDecimal("-5.5000"));

        assertThat(AccountService.recomputeBalance(account))
                .isEqualByComparingTo("104.5000");
        assertThat(account.getReceiptsTotal()).isEqualByComparingTo("30.0000");
        assertThat(account.getPaymentsTotal()).isEqualByComparingTo("20.0000");
    }
}

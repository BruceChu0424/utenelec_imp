package com.uten.imp.features.finance.asset.application;

import com.uten.imp.common.web.ApiException;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThatCode;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class FinanceAssetLedgerPostingServiceTest {

    @Test
    void acceptsExactlyBalancedBigDecimalEntries() {
        UUID debit = UUID.randomUUID();
        UUID credit = UUID.randomUUID();
        assertThatCode(() -> FinanceAssetLedgerPostingService.validateEntries(List.of(
                new FinanceAssetLedgerPostingService.Entry(debit, 1, new BigDecimal("100.10"), "debit"),
                new FinanceAssetLedgerPostingService.Entry(credit, -1, new BigDecimal("100.1000"), "credit"))))
                .doesNotThrowAnyException();
    }

    @Test
    void rejectsUnbalancedOrEmptyAmountEntries() {
        UUID account = UUID.randomUUID();
        assertThatThrownBy(() -> FinanceAssetLedgerPostingService.validateEntries(List.of(
                new FinanceAssetLedgerPostingService.Entry(account, 1, BigDecimal.ONE, "debit"))))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("not balanced");
        assertThatThrownBy(() -> FinanceAssetLedgerPostingService.validateEntries(List.of(
                new FinanceAssetLedgerPostingService.Entry(account, 1, BigDecimal.ZERO, "zero"))))
                .isInstanceOf(ApiException.class);
    }
}

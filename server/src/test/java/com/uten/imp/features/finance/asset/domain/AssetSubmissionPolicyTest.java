package com.uten.imp.features.finance.asset.domain;

import com.uten.imp.common.web.ApiException;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThatCode;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class AssetSubmissionPolicyTest {

    @Test
    void fixedAssetRequiresAllFourAccountsAndOrderedDates() {
        var input = new AssetSubmissionPolicy.FixedAssetInput(
                new AssetSubmissionPolicy.PolicyInput(UUID.randomUUID(), null, null, null, null),
                new BigDecimal("100"), BigDecimal.ZERO, 12, "2026-08",
                LocalDate.parse("2026-08-02"), LocalDate.parse("2026-08-01"), LocalDate.parse("2026-07-31"));

        assertThatThrownBy(() -> AssetSubmissionPolicy.validateFixedAsset(input))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("cost account")
                .hasMessageContaining("acceptanceDate")
                .hasMessageContaining("readyForUseDate");
    }

    @Test
    void validDeferredExpenseCanBeSubmitted() {
        UUID category = UUID.randomUUID();
        UUID account = UUID.randomUUID();
        var input = new AssetSubmissionPolicy.DeferredInput(
                new AssetSubmissionPolicy.PolicyInput(category, account, account, account, account),
                new BigDecimal("3600"), 36, "2026-08",
                LocalDate.parse("2026-08-01"), LocalDate.parse("2029-07-31"));

        assertThatCode(() -> AssetSubmissionPolicy.validateDeferredExpense(input)).doesNotThrowAnyException();
    }

    @Test
    void rejectsAmountsThatRoundToZeroAtPostingPrecision() {
        UUID account = UUID.randomUUID();
        var policy = new AssetSubmissionPolicy.PolicyInput(UUID.randomUUID(), account, account, account, account);
        var fixed = new AssetSubmissionPolicy.FixedAssetInput(policy, new BigDecimal("0.01"),
                new BigDecimal("0.9999"), 1200, "2026-09",
                LocalDate.parse("2026-07-01"), LocalDate.parse("2026-07-02"), LocalDate.parse("2026-08-01"));
        var deferred = new AssetSubmissionPolicy.DeferredInput(policy, new BigDecimal("0.01"),
                1200, "2026-08", LocalDate.parse("2026-08-01"), LocalDate.parse("2126-07-31"));

        assertThatThrownBy(() -> AssetSubmissionPolicy.validateFixedAsset(fixed))
                .hasMessageContaining("four-decimal ledger precision");
        assertThatThrownBy(() -> AssetSubmissionPolicy.validateDeferredExpense(deferred))
                .hasMessageContaining("four-decimal ledger precision");
    }

    @Test
    void deferredScheduleWindowMustExactlyMatchInclusiveBenefitMonths() {
        UUID account = UUID.randomUUID();
        var policy = new AssetSubmissionPolicy.PolicyInput(
                UUID.randomUUID(), account, null, account, account);
        var misaligned = new AssetSubmissionPolicy.DeferredInput(
                policy, new BigDecimal("1200.00"), 12, "2026-02",
                LocalDate.parse("2026-01-15"), LocalDate.parse("2026-12-31"));

        assertThatThrownBy(() -> AssetSubmissionPolicy.validateDeferredExpense(misaligned))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("benefitStartDate calendar month");

        var aligned = new AssetSubmissionPolicy.DeferredInput(
                policy, new BigDecimal("1200.00"), 12, "2026-01",
                LocalDate.parse("2026-01-15"), LocalDate.parse("2026-12-31"));
        assertThatCode(() -> AssetSubmissionPolicy.validateDeferredExpense(aligned))
                .doesNotThrowAnyException();
    }
}

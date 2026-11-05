package com.uten.imp.features.finance.asset.domain;

import com.uten.imp.common.finance.BusinessPrecisionContext;
import com.uten.imp.common.web.ApiException;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThatCode;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class AssetSubmissionPolicyTest {

    private AutoCloseable precision;

    @BeforeEach
    void bindStraightLineShareChoice() {
        // 2026-11-04 显式精度选择契约（0aaffa3aa/d533807ca 范式）：月折旧/摊销额经
        // MoneyPolicy.cumulativeShare 的 money.cumulative-share 除法，测试按两位账面货币 HALF_UP 给出显式选择。
        precision = BusinessPrecisionContext.use(java.util.Map.of(
                "money.cumulative-share", new BusinessPrecisionContext.Choice(2, "HALF_UP")));
    }

    @AfterEach
    void releaseStraightLineShareChoice() throws Exception {
        precision.close();
    }

    @Test
    void fixedAssetRequiresAllFourAccountsAndOrderedDates() {
        var input = new AssetSubmissionPolicy.FixedAssetInput(
                new AssetSubmissionPolicy.PolicyInput(UUID.randomUUID(), null, null, null, null),
                new BigDecimal("100"), BigDecimal.ZERO, 12, "2026-08",
                LocalDate.parse("2026-08-02"), LocalDate.parse("2026-08-01"), LocalDate.parse("2026-07-31"));

        assertThatThrownBy(() -> AssetSubmissionPolicy.validateFixedAsset(input))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("成本科目")
                .hasMessageContaining("验收日期")
                .hasMessageContaining("可使用");
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
                .hasMessageContaining("月折旧额是 0");
        assertThatThrownBy(() -> AssetSubmissionPolicy.validateDeferredExpense(deferred))
                .hasMessageContaining("月摊销额是 0");
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
                .hasMessageContaining("受益开始日期所在月份");

        var aligned = new AssetSubmissionPolicy.DeferredInput(
                policy, new BigDecimal("1200.00"), 12, "2026-01",
                LocalDate.parse("2026-01-15"), LocalDate.parse("2026-12-31"));
        assertThatCode(() -> AssetSubmissionPolicy.validateDeferredExpense(aligned))
                .doesNotThrowAnyException();
    }
}

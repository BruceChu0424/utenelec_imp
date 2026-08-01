package com.uten.imp.features.finance.asset.domain;

import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

class AssetCategoryPolicyReadinessTest {

    @Test
    void fixedAssetsRequireAccumulatedAccountAndResidualPolicy() {
        UUID account = UUID.randomUUID();
        var missing = AssetCategoryPolicyReadiness.missing(new AssetCategoryPolicyReadiness.Input(
                "FIXED_ASSET", account, null, account, account,
                "STRAIGHT_LINE", 60, null, LocalDate.parse("2026-08-01")));
        assertThat(missing).containsExactly("accumulatedStyleId", "defaultResidualRate");
    }

    @Test
    void deferredExpenseDoesNotUseAnAccumulatedContraAccount() {
        UUID account = UUID.randomUUID();
        var input = new AssetCategoryPolicyReadiness.Input(
                "DEFERRED_EXPENSE", account, null, account, account,
                "STRAIGHT_LINE", 36, BigDecimal.ZERO, LocalDate.parse("2026-08-01"));
        assertThat(AssetCategoryPolicyReadiness.ready(input)).isTrue();
    }

    @Test
    void unimplementedMethodsCannotBeActivatedAsIfSupported() {
        UUID account = UUID.randomUUID();
        var input = new AssetCategoryPolicyReadiness.Input(
                "FIXED_ASSET", account, account, account, account,
                "DOUBLE_DECLINING_BALANCE", 60, BigDecimal.ZERO, LocalDate.parse("2026-08-01"));
        assertThat(AssetCategoryPolicyReadiness.missing(input)).contains("supportedDefaultMethod");
    }
}
